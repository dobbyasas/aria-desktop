@preconcurrency import AVFoundation
import Foundation

/// Bounded, session-local disk preparation. Decoding never runs on the UI or render thread.
actor GaplessAudioFiles {
    static var outputFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    }

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("aria-audio-\(UUID().uuidString)", isDirectory: true)
    private struct Key: Hashable {
        let source: URL
        let sampleRate: Double?
    }
    private var prepared: [Key: URL] = [:]

    deinit { try? FileManager.default.removeItem(at: directory) }

    func prepare(_ source: URL, sampleRate: Double? = nil) async throws -> URL {
        let key = Key(source: source, sampleRate: sampleRate)
        if let existing = prepared[key] { return existing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input: URL
        if source.isFileURL {
            input = source
        } else {
            let (download, response) = try await URLSession.shared.download(from: source)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                try? FileManager.default.removeItem(at: download)
                throw GaplessAudioError.invalidResponse
            }
            input = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
            try FileManager.default.moveItem(at: download, to: input)
        }
        defer { if !source.isFileURL { try? FileManager.default.removeItem(at: input) } }
        let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let conversion = Task.detached(priority: .userInitiated) {
            try Self.decode(input, to: output, sampleRate: sampleRate)
        }
        do {
            try await withTaskCancellationHandler {
                try await conversion.value
                try Task.checkCancellation()
            } onCancel: {
                conversion.cancel()
            }
            prepared[key] = output
            if sampleRate == nil {
                let actualRate = try AVAudioFile(forReading: output).processingFormat.sampleRate
                prepared[Key(source: source, sampleRate: actualRate)] = output
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    func retainOnly(_ sources: [URL]) {
        let keep = Set(sources)
        var removed = Set<URL>()
        for key in Array(prepared.keys) where !keep.contains(key.source) {
            if let url = prepared.removeValue(forKey: key) { removed.insert(url) }
        }
        let retained = Set(prepared.values)
        for url in removed.subtracting(retained) { try? FileManager.default.removeItem(at: url) }
    }

    nonisolated static func decode(_ source: URL, to destination: URL, sampleRate: Double? = 44_100) throws {
        let input = try AVAudioFile(forReading: source)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate ?? input.processingFormat.sampleRate, channels: 2)!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: settings)
        if input.processingFormat == format {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)!
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(16_384, input.length - input.framePosition)))
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
            guard output.length > 0, output.length <= AVAudioFramePosition(UInt32.max) else { throw GaplessAudioError.emptyAudio }
            return
        }
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw GaplessAudioError.conversion
        }
        var inputError: Error?
        var finished = false
        while !finished {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { count, result in
                do {
                    guard input.framePosition < input.length else {
                        result.pointee = .endOfStream
                        return nil
                    }
                    let frames = min(count, inputBuffer.frameCapacity, AVAudioFrameCount(min(input.length - input.framePosition, Int64(UInt32.max))))
                    try input.read(into: inputBuffer, frameCount: frames)
                    result.pointee = inputBuffer.frameLength == 0 ? .endOfStream : .haveData
                    return inputBuffer.frameLength == 0 ? nil : inputBuffer
                } catch {
                    inputError = error
                    result.pointee = .endOfStream
                    return nil
                }
            }
            if let inputError { throw inputError }
            if let conversionError { throw conversionError }
            switch status {
            case .error: throw GaplessAudioError.conversion
            case .endOfStream: finished = true
            case .haveData, .inputRanDry: break
            @unknown default: throw GaplessAudioError.conversion
            }
            if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
        }
        guard output.length > 0, output.length <= AVAudioFramePosition(UInt32.max) else {
            throw GaplessAudioError.emptyAudio
        }
    }
}
