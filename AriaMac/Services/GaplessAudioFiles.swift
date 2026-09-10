@preconcurrency import AVFoundation
import Foundation
import AudioToolbox

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

    typealias StreamConsumer = @MainActor @Sendable (AVAudioPCMBuffer, AVAudioFramePosition, AVAudioFramePosition, Bool) async throws -> Void

    /// Emit a short PCM chunk immediately, then apply consumer backpressure so
    /// even a long recording needs only a few seconds of queued PCM in memory.
    func stream(_ source: URL, offset: TimeInterval = 0, consume: @escaping StreamConsumer) async throws {
        let remote = source.isFileURL ? nil : HTTPAudioFile(source)
        let worker = Task.detached(priority: .userInitiated) {
            var audioFile: AudioFileID?
            if let remote {
                audioFile = try remote.open()
            } else {
                try Self.check(AudioFileOpenURL(source as CFURL, .readPermission, 0, &audioFile))
            }
            guard let audioFile else { throw GaplessAudioError.emptyAudio }
            defer { AudioFileClose(audioFile) }
            var decoder: ExtAudioFileRef?
            try Self.check(ExtAudioFileWrapAudioFileID(audioFile, false, &decoder))
            guard let decoder else { throw GaplessAudioError.conversion }
            defer { ExtAudioFileDispose(decoder) }
            var sourceFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(ExtAudioFileGetProperty(decoder, kExtAudioFileProperty_FileDataFormat, &size, &sourceFormat))
            let format = AVAudioFormat(standardFormatWithSampleRate: sourceFormat.mSampleRate, channels: 2)!
            var clientFormat = format.streamDescription.pointee
            try Self.check(ExtAudioFileSetProperty(decoder, kExtAudioFileProperty_ClientDataFormat, size, &clientFormat))
            var length: Int64 = 0
            size = UInt32(MemoryLayout<Int64>.size)
            try Self.check(ExtAudioFileGetProperty(decoder, kExtAudioFileProperty_FileLengthFrames, &size, &length))
            guard length > 0 else { throw GaplessAudioError.emptyAudio }
            let start = AVAudioFramePosition(min(max(0, offset * format.sampleRate), Double(length - 1)))
            if start > 0 { try Self.check(ExtAudioFileSeek(decoder, start)) }
            var position = start
            while position < length {
                try Task.checkCancellation()
                // About 93 ms at 44.1 kHz; no whole-song download or PCM conversion gate.
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
                var frames = AVAudioFrameCount(min(4_096, length - position))
                let status = ExtAudioFileRead(decoder, &frames, buffer.mutableAudioBufferList)
                if let error = remote?.error { throw error }
                try Self.check(status)
                guard frames > 0 else { throw GaplessAudioError.emptyAudio }
                buffer.frameLength = frames
                position += Int64(frames)
                try await consume(buffer, length, start, position == length)
            }
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
            remote?.cancel()
        }
    }

    nonisolated private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
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

// AudioFile's random-access callbacks let Apple's decoder read headers and small
// byte ranges, including end-of-file metadata, without downloading a whole song.
// All decoding and blocking I/O run on a detached task, never on the audio thread.
private final class HTTPAudioFile: @unchecked Sendable {
    let source: URL
    private(set) var length: Int64 = 0
    private let cancellation = AudioRequestCancellation()
    private var cache: [Int64: Data] = [:]
    private var cacheOrder: [Int64] = []
    private let blockSize: Int64 = 32_768
    private(set) var error: Error?

    init(_ source: URL) { self.source = source }

    func cancel() { cancellation.cancel() }

    func open() throws -> AudioFileID {
        var request = URLRequest(url: source)
        request.httpMethod = "HEAD"
        let (_, response) = try fetch(request)
        guard response.statusCode == 200, response.expectedContentLength > 0 else {
            throw GaplessAudioError.invalidResponse
        }
        length = response.expectedContentLength
        var file: AudioFileID?
        let status = AudioFileOpenWithCallbacks(Unmanaged.passUnretained(self).toOpaque(), { context, position, count, buffer, actual in
            let reader = Unmanaged<HTTPAudioFile>.fromOpaque(context).takeUnretainedValue()
            do {
                actual.pointee = try reader.read(position: position, count: count, into: buffer)
                return noErr
            } catch {
                reader.error = error
                actual.pointee = 0
                return kAudioFileUnspecifiedError
            }
        }, nil, { context in
            Unmanaged<HTTPAudioFile>.fromOpaque(context).takeUnretainedValue().length
        }, nil, 0, &file)
        guard status == noErr, let file else { throw error ?? NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return file
    }

    private func read(position: Int64, count: UInt32, into buffer: UnsafeMutableRawPointer) throws -> UInt32 {
        guard position >= 0 else { throw GaplessAudioError.invalidResponse }
        let count = Int(min(Int64(count), max(0, length - position)))
        var copied = 0
        while copied < count {
            try Task.checkCancellation()
            let cursor = position + Int64(copied)
            let start = cursor / blockSize * blockSize
            let data: Data
            if let cached = cache[start] {
                data = cached
            } else {
                let end = min(start + blockSize, length) - 1
                var request = URLRequest(url: source)
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                let (body, response) = try fetch(request)
                guard response.statusCode == 206,
                      response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(length)",
                      body.count == end - start + 1 else { throw GaplessAudioError.invalidResponse }
                data = body
                cache[start] = data
                cacheOrder.append(start)
                if cacheOrder.count > 8 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
            }
            let offset = Int(cursor - start)
            let size = min(count - copied, data.count - offset)
            guard size > 0 else { throw GaplessAudioError.invalidResponse }
            data.withUnsafeBytes { bytes in
                buffer.advanced(by: copied).copyMemory(from: bytes.baseAddress!.advanced(by: offset), byteCount: size)
            }
            copied += size
        }
        return UInt32(copied)
    }

    private func fetch(_ original: URLRequest) throws -> (Data, HTTPURLResponse) {
        var request = original
        request.timeoutInterval = 30
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let response = AudioHTTPResponse()
        let task = URLSession.shared.dataTask(with: request) { data, metadata, error in
            response.complete(data: data, metadata: metadata, error: error)
        }
        try cancellation.start(task)
        return try response.wait()
    }
}

/// Only cancellation crosses the decoder's serial task boundary.
private final class AudioRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionTask?

    func start(_ task: URLSessionTask) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.task = task
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = task
        lock.unlock()
        active?.cancel()
    }
}

private final class AudioHTTPResponse: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<(Data, HTTPURLResponse), Error>?

    func complete(data: Data?, metadata: URLResponse?, error: Error?) {
        if let error { result = .failure(error) }
        else if let data, let response = metadata as? HTTPURLResponse { result = .success((data, response)) }
        else { result = .failure(GaplessAudioError.invalidResponse) }
        ready.signal()
    }

    func wait() throws -> (Data, HTTPURLResponse) {
        ready.wait()
        return try result!.get()
    }
}
