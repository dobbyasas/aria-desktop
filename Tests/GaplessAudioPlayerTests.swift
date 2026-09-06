import AVFoundation
import AudioToolbox
import Foundation

@main
@MainActor
struct GaplessAudioPlayerTests {
    static let rate = 44_100.0

    static func main() async throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aria-gapless-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counts = [11_029, 22_073, 14_417]
        let values: [Float] = [0.25, -0.5, 0.75]
        let tracks = try zip(counts, values).enumerated().map { index, pair in
            let url = directory.appendingPathComponent("\(index).caf")
            try writeAudio(url, count: pair.0, value: pair.1)
            return Track(title: "Track \(index)", duration: Double(pair.0) / rate, streamURL: url)
        }
        let (player, engine) = try output()
        var failure: String?
        player.onFailure = { failure = $0 }
        player.load(tracks[0], queue: tracks, repeatMode: .off)
        try await ready(player, failure: { failure })
        let samples = try render(engine, frames: counts.reduce(0, +))
        var cursor = 0
        for (count, value) in zip(counts, values) {
            // Compare every sample, including both sides of boundaries that fall inside render blocks.
            for frame in cursor..<(cursor + count) {
                precondition(abs(samples[frame] - value) < 0.00001,
                             "Inserted/dropped audio at frame \(frame): \(samples[frame]), expected \(value)")
            }
            cursor += count
        }
        print("PASS: \(samples.count) rendered frames; zero inserted, missing, or mixed samples at both transitions")
        player.stop()
        engine.stop()

        // A paused seek must stay paused, then resume at the exact requested sample.
        let (seeking, seekEngine) = try output()
        seeking.load(tracks[0], queue: tracks, repeatMode: .off, playing: false)
        try await ready(seeking, failure: { nil })
        precondition(!seekEngine.isRunning, "Preparing paused audio must not start output")
        seeking.seek(to: 0.1)
        try await ready(seeking, failure: { nil })
        precondition(!seekEngine.isRunning, "Seeking while paused must remain paused")
        seeking.play()
        let remainder = counts[0] - 4_410
        let sought = try render(seekEngine, frames: remainder + 1_024)
        precondition(sought.prefix(remainder).allSatisfy { abs($0 - values[0]) < 0.00001 })
        precondition(sought.suffix(1_024).allSatisfy { abs($0 - values[1]) < 0.00001 })
        seeking.stop()
        seekEngine.stop()
        print("PASS: paused seeking and sample-accurate transition from a partial track")

        let (repeating, repeatEngine) = try output()
        repeating.load(tracks[0], queue: tracks, repeatMode: .one)
        try await ready(repeating, failure: { nil })
        let repeated = try render(repeatEngine, frames: counts[0] * 2 + 1_024)
        precondition(repeated.allSatisfy { abs($0 - values[0]) < 0.00001 }, "Repeat-one must not render the next song or a gap")
        repeating.stop()
        repeatEngine.stop()
        print("PASS: repeat-one renders consecutive copies without an inserted sample")

        let (edited, editEngine) = try output()
        edited.load(tracks[0], queue: tracks, repeatMode: .off, playing: false)
        try await ready(edited, failure: { nil })
        edited.updateQueue([tracks[0], tracks[2], tracks[1]], repeatMode: .off)
        try await ready(edited, failure: { nil })
        edited.play()
        let reordered = try render(editEngine, frames: counts[0] + 1_024)
        precondition(reordered.suffix(1_024).allSatisfy { abs($0 - values[2]) < 0.00001 }, "A queue edit must discard stale scheduled audio")
        edited.stop()
        editEngine.stop()
        print("PASS: queue reordering replaces previously scheduled future audio")

        // Replacing a still-preparing selection must prevent stale completion callbacks.
        let (cancelled, cancelEngine) = try output()
        cancelled.load(tracks[0], queue: tracks, repeatMode: .off)
        cancelled.load(tracks[2], queue: [tracks[2]], repeatMode: .off)
        try await ready(cancelled, failure: { nil })
        let replacement = try render(cancelEngine, frames: 1_024)
        precondition(replacement.allSatisfy { abs($0 - values[2]) < 0.00001 })
        cancelled.stop()
        cancelEngine.stop()
        print("PASS: rapid track replacement cancels stale preparation")

        let (paused, pauseEngine) = try output()
        paused.load(tracks[0], queue: tracks, repeatMode: .off)
        try await ready(paused, failure: { nil })
        _ = try render(pauseEngine, frames: 5_000)
        let pausePosition = paused.elapsed
        paused.pause()
        let silence = try render(pauseEngine, frames: 2_048)
        precondition(silence.allSatisfy { abs($0) < 0.00001 })
        precondition(abs(paused.elapsed - pausePosition) < 1 / rate, "Pausing must freeze the playback position")
        paused.play()
        let resumed = try render(pauseEngine, frames: counts[0] - 5_000 + 1_024)
        precondition(resumed.prefix(counts[0] - 5_000).allSatisfy { abs($0 - values[0]) < 0.00001 })
        precondition(resumed.suffix(1_024).allSatisfy { abs($0 - values[1]) < 0.00001 })
        paused.stop()
        pauseEngine.stop()
        print("PASS: live pause/resume retains position and the scheduled transition")

        let (wrapped, wrapEngine) = try output()
        wrapped.load(tracks[1], queue: Array(tracks.prefix(2)), repeatMode: .all)
        try await ready(wrapped, failure: { nil })
        let wrapAudio = try render(wrapEngine, frames: counts[1] + counts[0])
        precondition(wrapAudio.prefix(counts[1]).allSatisfy { abs($0 - values[1]) < 0.00001 })
        precondition(wrapAudio.suffix(counts[0]).allSatisfy { abs($0 - values[0]) < 0.00001 })
        wrapped.stop()
        wrapEngine.stop()
        print("PASS: repeat-all wraps the queue without a silent sample")

        let (observed, observedEngine) = try output()
        var observedTracks: [UUID] = []
        var finishedCount = 0
        observed.onTrackChanged = { observedTracks.append($0.id) }
        observed.onFinished = { finishedCount += 1 }
        observed.load(tracks[0], queue: tracks, repeatMode: .off)
        try await ready(observed, failure: { nil })
        for _ in 0..<50 {
            _ = try render(observedEngine, frames: 1_024)
            try await Task.sleep(for: .milliseconds(2))
        }
        precondition(observedTracks == [tracks[1].id, tracks[2].id], "Track metadata must follow the audible sequence: \(observedTracks), expected \([tracks[1].id, tracks[2].id]); finished \(finishedCount)")
        precondition(finishedCount == 1, "The end of a queue must publish completion exactly once")
        precondition(abs(observed.elapsed - Double(counts[2]) / rate) < 1 / rate)
        observed.stop()
        observedEngine.stop()
        print("PASS: track changes, final duration, and end-of-queue notification follow playback")

        precondition(!GaplessAudioPlayer.isAlbum(tracks), "Unidentified library tracks are not an album")
        let album = tracks.map { track -> Track in
            var track = track
            track.album = "A continuous record"
            return track
        }
        precondition(GaplessAudioPlayer.isAlbum(album))
        var mixed = album
        mixed[1].album = "Another record"
        precondition(!GaplessAudioPlayer.isAlbum(mixed))

        // An album is fully prepared and scheduled before output starts. Original files
        // can disappear, and even a blocked UI thread cannot introduce an inter-track gap.
        let albumCounts = [7_111, 4_231, 11_111, 8_311]
        let albumValues: [Float] = [0.13, 0.23, 0.33, 0.43]
        let bufferedAlbum = try zip(albumCounts, albumValues).enumerated().map { index, pair in
            let url = directory.appendingPathComponent("album-\(index).caf")
            try writeAudio(url, count: pair.0, value: pair.1)
            return Track(title: "Album \(index)", album: "Continuous album", streamURL: url)
        }
        let (albumPlayer, albumEngine) = try output()
        albumPlayer.load(bufferedAlbum[0], queue: bufferedAlbum, repeatMode: .off)
        try await ready(albumPlayer, failure: { nil })
        for track in bufferedAlbum { try FileManager.default.removeItem(at: track.streamURL!) }
        let albumSamples = try render(albumEngine, frames: albumCounts.reduce(0, +))
        var albumCursor = 0
        for (count, value) in zip(albumCounts, albumValues) {
            precondition(albumSamples[albumCursor..<(albumCursor + count)].allSatisfy { abs($0 - value) < 0.00001 })
            albumCursor += count
        }
        albumPlayer.stop()
        albumEngine.stop()
        print("PASS: complete album stays sample-contiguous after all original files are removed, without UI callbacks")

        let (broken, brokenEngine) = try output()
        var brokenAlbum = album
        brokenAlbum[1].streamURL = directory.appendingPathComponent("missing.caf")
        var albumFailure: String?
        broken.onFailure = { albumFailure = $0 }
        broken.load(brokenAlbum[0], queue: brokenAlbum, repeatMode: .off)
        for _ in 0..<500 where albumFailure == nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(albumFailure != nil && !brokenEngine.isRunning, "An unprepared album must fail before audio starts")
        broken.stop()
        print("PASS: album preparation failure is reported before the first sound")

        let highResolution = directory.appendingPathComponent("96khz.caf")
        try writeAudio(highResolution, count: 48_000, value: 0.2, rate: 96_000)
        let cache = GaplessAudioFiles()
        let preparedHighResolution = try await cache.prepare(highResolution)
        let highResolutionFile = try AVAudioFile(forReading: preparedHighResolution)
        precondition(highResolutionFile.processingFormat.sampleRate == 96_000)
        precondition(highResolutionFile.length == 48_000)
        print("PASS: native sample rate and frame count are retained for high-resolution audio")

        // Decode a mono, 48 kHz file to the queue's shared output format.
        let monoURL = directory.appendingPathComponent("mono.caf")
        try writeAudio(monoURL, count: 48_000, value: 0.3, rate: 48_000, channels: 1)
        let converted = directory.appendingPathComponent("mono-output.caf")
        try GaplessAudioFiles.decode(monoURL, to: converted)
        let decoded = try AVAudioFile(forReading: converted)
        precondition(decoded.processingFormat.channelCount == 2)
        precondition(decoded.processingFormat.sampleRate == rate)
        precondition(abs(decoded.length - 44_100) <= 1, "Resampling must preserve the authored duration")
        print("PASS: mono / 48 kHz normalization without duration drift")

        if let path = CommandLine.arguments.dropFirst().first {
            let mp3 = URL(fileURLWithPath: path)
            var fileID: AudioFileID?
            precondition(AudioFileOpenURL(mp3 as CFURL, .readPermission, 0, &fileID) == noErr)
            defer { AudioFileClose(fileID!) }
            var packetInfo = AudioFilePacketTableInfo()
            var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
            precondition(AudioFileGetProperty(fileID!, kAudioFilePropertyPacketTableInfo, &size, &packetInfo) == noErr)
            let mp3Output = directory.appendingPathComponent("mp3-decoded.caf")
            try GaplessAudioFiles.decode(mp3, to: mp3Output, sampleRate: nil)
            let pcm = try AVAudioFile(forReading: mp3Output)
            precondition(pcm.length == packetInfo.mNumberValidFrames,
                         "MP3 padding must be excluded: \(pcm.length) output frames, \(packetInfo.mNumberValidFrames) valid frames")
            print("PASS: library MP3 preserves \(pcm.length) valid frames and excludes \(packetInfo.mPrimingFrames + packetInfo.mRemainderFrames) padding frames")
        }

        // AAC priming and remainder metadata must not become added silence.
        let aac = directory.appendingPathComponent("gapless.m4a")
        let encode = Process()
        encode.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        encode.arguments = [tracks[0].streamURL!.path, aac.path, "-f", "m4af", "-d", "aac", "-b", "192000"]
        try encode.run()
        encode.waitUntilExit()
        precondition(encode.terminationStatus == 0)
        let decodedAAC = directory.appendingPathComponent("aac-decoded.caf")
        try GaplessAudioFiles.decode(aac, to: decodedAAC)
        let aacFile = try AVAudioFile(forReading: decodedAAC)
        precondition(aacFile.length == counts[0], "AAC encoder padding must not be rendered: \(aacFile.length) vs \(counts[0])")
        print("PASS: AAC priming/remainder metadata preserves exact source frame count")
    }

    static func output() throws -> (GaplessAudioPlayer, AVAudioEngine) {
        let engine = AVAudioEngine()
        let player = GaplessAudioPlayer(engine: engine)
        try engine.enableManualRenderingMode(.offline, format: GaplessAudioFiles.outputFormat, maximumFrameCount: 1024)
        return (player, engine)
    }

    static func ready(_ player: GaplessAudioPlayer, failure: () -> String?) async throws {
        for _ in 0..<500 {
            if let error = failure() { fatalError(error) }
            if player.isReady { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Audio preparation timed out")
    }

    static func render(_ engine: AVAudioEngine, frames: Int) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1024)!
        var samples: [Float] = []
        while samples.count < frames {
            let count = AVAudioFrameCount(min(1024, frames - samples.count))
            let result = try engine.renderOffline(count, to: buffer)
            precondition(result == .success, "Offline render failed: \(result)")
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    static func writeAudio(_ url: URL, count: Int, value: Float, rate: Double = 44_100, channels: AVAudioChannelCount = 2) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(channels) {
            for frame in 0..<count { buffer.floatChannelData![channel][frame] = value }
        }
        try file.write(from: buffer)
    }
}
