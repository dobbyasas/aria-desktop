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
        precondition(!pauseEngine.isRunning, "Pausing must suspend the audio engine, not render silence")
        precondition(abs(paused.elapsed - pausePosition) < 1 / rate, "Pausing must freeze the playback position")
        paused.play()
        let resumed = try render(pauseEngine, frames: counts[0] - 5_000 + 1_024)
        precondition(resumed.prefix(counts[0] - 5_000).allSatisfy { abs($0 - values[0]) < 0.00001 })
        precondition(resumed.suffix(1_024).allSatisfy { abs($0 - values[1]) < 0.00001 })
        paused.stop()
        precondition(!pauseEngine.isRunning, "Stopping must release the running output engine")
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
            if observedEngine.isRunning { _ = try render(observedEngine, frames: 1_024) }
            try await Task.sleep(for: .milliseconds(2))
        }
        precondition(observedTracks == [tracks[1].id, tracks[2].id], "Track metadata must follow the audible sequence: \(observedTracks), expected \([tracks[1].id, tracks[2].id]); finished \(finishedCount)")
        precondition(finishedCount == 1, "The end of a queue must publish completion exactly once")
        precondition(!observedEngine.isRunning, "A finished queue must shut down output")
        precondition(abs(observed.elapsed - Double(counts[2]) / rate) < 1 / rate)
        observed.stop()
        observedEngine.stop()
        print("PASS: track changes, final duration, and end-of-queue notification follow playback")

        // Delayed preparation is deterministic: the requested file is held until released.
        // Even an album must start and resume while its next song is still unavailable.
        let delayedFiles = PreparationGate(blocked: [tracks[1].streamURL!])
        let (prompt, promptEngine) = try output(prepareFile: { url, _ in try await delayedFiles.prepare(url) })
        var promptMessage: String?
        prompt.onPreparationChanged = { promptMessage = $0 }
        let album = tracks.map { track -> Track in
            var track = track
            track.album = "Continuous album"
            return track
        }
        prompt.load(album[0], queue: album, repeatMode: .off)
        try await waitUntil { await delayedFiles.requestCount(tracks[1].streamURL!) == 1 }
        precondition(prompt.isReady && prompt.isPreparing && promptEngine.isRunning,
                     "The selected song must start before the next album song is prepared")
        precondition(promptMessage == nil, "Background prefetch must not show a playback-blocking message")
        let promptAudio = try render(promptEngine, frames: 1_024)
        precondition(promptAudio.allSatisfy { abs($0 - values[0]) < 0.00001 })
        prompt.pause()
        prompt.play()
        precondition(promptEngine.isRunning, "Resume must not wait for an upcoming download")
        _ = try render(promptEngine, frames: 1_024)
        await delayedFiles.release(tracks[1].streamURL!)
        try await ready(prompt, failure: { nil })
        let afterDownload = try render(promptEngine, frames: counts[0] - 2_048 + counts[1] + 1_024)
        precondition(afterDownload.prefix(counts[0] - 2_048).allSatisfy { abs($0 - values[0]) < 0.00001 })
        precondition(afterDownload[(counts[0] - 2_048)..<(counts[0] - 2_048 + counts[1])].allSatisfy { abs($0 - values[1]) < 0.00001 })
        precondition(afterDownload.suffix(1_024).allSatisfy { abs($0 - values[2]) < 0.00001 })
        prompt.stop()
        print("PASS: album starts and resumes during a delayed next-song download, then transitions without a gap")

        // A ramp catches repeated or skipped frames as well as silent interruptions.
        let rampURL = directory.appendingPathComponent("ramp.caf")
        try writeAudio(rampURL, count: 44_100, value: 0, ramp: true)
        let ramp = Track(title: "Ramp", streamURL: rampURL)
        let editFiles = PreparationGate(blocked: [tracks[2].streamURL!])
        let (live, liveEngine) = try output(prepareFile: { url, _ in try await editFiles.prepare(url) })
        live.load(ramp, queue: [ramp, tracks[0], tracks[1]], repeatMode: .off)
        try await ready(live, failure: { nil })
        _ = try render(liveEngine, frames: 4_000)
        let livePosition = live.elapsed
        live.updateQueue([ramp, tracks[2], tracks[1], tracks[0]], repeatMode: .off)
        precondition(liveEngine.isRunning && live.isReady, "Editing a playing queue must keep output running")
        precondition(abs(live.elapsed - livePosition) < 1 / rate, "A queue edit must preserve position synchronously")
        try await waitUntil { await editFiles.requestCount(tracks[2].streamURL!) == 1 }
        // Appending, deleting, and changing repeat while this song downloads must reuse it.
        live.updateQueue([ramp, tracks[2], tracks[1]], repeatMode: .off)
        live.updateQueue([ramp, tracks[2], tracks[1], tracks[0]], repeatMode: .all)
        let duringEdit = try render(liveEngine, frames: 4_000)
        for (index, sample) in duringEdit.enumerated() {
            precondition(abs(sample - Float(index + 4_000) / 44_100) < 0.00001,
                         "Live queue edits must not repeat, skip, mix, or silence the current audio")
        }
        await editFiles.release(tracks[2].streamURL!)
        try await ready(live, failure: { nil })
        let rampRequests = await editFiles.requestCount(rampURL)
        let nextRequests = await editFiles.requestCount(tracks[2].streamURL!)
        precondition(rampRequests == 1 && nextRequests == 1, "Queue edits must reuse current audio and unchanged in-flight preparation")
        let afterEdit = try render(liveEngine, frames: 44_100 - 8_000 + 1_024)
        for index in 0..<(44_100 - 8_000) {
            precondition(abs(afterEdit[index] - Float(index + 8_000) / 44_100) < 0.00001)
        }
        precondition(afterEdit.suffix(1_024).allSatisfy { abs($0 - values[2]) < 0.00001 }, "The edited queue must play the new next song")
        live.stop()
        print("PASS: live queue edits preserve every current-song sample and reuse downloads")

        // Editing while the first song is downloading must not restart that download.
        let startupFiles = PreparationGate(blocked: [tracks[0].streamURL!])
        let (startup, startupEngine) = try output(prepareFile: { url, _ in try await startupFiles.prepare(url) })
        startup.load(tracks[0], queue: tracks, repeatMode: .off)
        try await waitUntil { await startupFiles.requestCount(tracks[0].streamURL!) == 1 }
        startup.updateQueue([tracks[0], tracks[2], tracks[1]], repeatMode: .off)
        await startupFiles.release(tracks[0].streamURL!)
        try await ready(startup, failure: { nil })
        let startupRequests = await startupFiles.requestCount(tracks[0].streamURL!)
        precondition(startupRequests == 1)
        let startupAudio = try render(startupEngine, frames: counts[0] + 1_024)
        precondition(startupAudio.prefix(counts[0]).allSatisfy { abs($0 - values[0]) < 0.00001 })
        precondition(startupAudio.suffix(1_024).allSatisfy { abs($0 - values[2]) < 0.00001 })
        startup.stop()
        print("PASS: queue edits during startup preserve the first download and use the latest order")

        // A queue edit can arrive before the UI receives the previous track's completion.
        let (boundary, boundaryEngine) = try output()
        boundary.load(tracks[0], queue: tracks, repeatMode: .off)
        try await ready(boundary, failure: { nil })
        _ = try render(boundaryEngine, frames: counts[0] + 2_048)
        boundary.updateQueue([tracks[0], tracks[1]], repeatMode: .one)
        precondition(boundary.currentTrack?.id == tracks[1].id, "Edits must keep the track already audible at a boundary")
        try await ready(boundary, failure: { nil })
        let boundaryAudio = try render(boundaryEngine, frames: counts[1] - 2_048 + 1_024)
        precondition(boundaryAudio.allSatisfy { abs($0 - values[1]) < 0.00001 })
        boundary.stop()
        print("PASS: a boundary-time edit preserves the audible song and applies repeat-one gaplessly")

        // A failed future track is reported only after all available music has played.
        let (broken, brokenEngine) = try output()
        var brokenAlbum = album
        brokenAlbum[1].streamURL = directory.appendingPathComponent("missing.caf")
        var futureFailure: String?
        broken.onFailure = { futureFailure = $0 }
        broken.load(brokenAlbum[0], queue: brokenAlbum, repeatMode: .off)
        try await ready(broken, failure: { futureFailure })
        precondition(brokenEngine.isRunning && futureFailure == nil)
        let buffered = try render(brokenEngine, frames: counts[0])
        precondition(buffered.allSatisfy { abs($0 - values[0]) < 0.00001 })
        _ = try render(brokenEngine, frames: 1_024)
        try await waitUntil { futureFailure != nil }
        precondition(!brokenEngine.isRunning)
        broken.stop()
        print("PASS: an unavailable later album song does not delay or truncate the first song")

        // If the next file is slower than playback, resume it from frame zero after buffering.
        let stalledFiles = PreparationGate(blocked: [tracks[1].streamURL!])
        let (stalled, stalledEngine) = try output(prepareFile: { url, _ in try await stalledFiles.prepare(url) })
        stalled.load(tracks[0], queue: Array(tracks.prefix(2)), repeatMode: .off)
        try await waitUntil { await stalledFiles.requestCount(tracks[1].streamURL!) == 1 }
        _ = try render(stalledEngine, frames: counts[0] + 1_024)
        try await waitUntil { !stalledEngine.isRunning }
        await stalledFiles.release(tracks[1].streamURL!)
        try await ready(stalled, failure: { nil })
        let recovered = try render(stalledEngine, frames: counts[1])
        precondition(recovered.allSatisfy { abs($0 - values[1]) < 0.00001 }, "A network stall must not skip the start of the next song")
        stalled.stop()
        print("PASS: a genuine network stall buffers and recovers without skipping audio")

        // Removed in-flight audio may still finish; it must never return to the queue.
        let obsoleteFiles = PreparationGate(blocked: [tracks[1].streamURL!])
        let (obsolete, obsoleteEngine) = try output(prepareFile: { url, _ in try await obsoleteFiles.prepare(url) })
        obsolete.load(tracks[0], queue: tracks, repeatMode: .off)
        try await waitUntil { await obsoleteFiles.requestCount(tracks[1].streamURL!) == 1 }
        _ = try render(obsoleteEngine, frames: 1_024)
        obsolete.updateQueue([tracks[0], tracks[2]], repeatMode: .off)
        try await ready(obsolete, failure: { nil })
        await obsoleteFiles.release(tracks[1].streamURL!)
        for _ in 0..<10 { await Task.yield() }
        let withoutObsolete = try render(obsoleteEngine, frames: counts[0] - 1_024 + 1_024)
        precondition(withoutObsolete.prefix(counts[0] - 1_024).allSatisfy { abs($0 - values[0]) < 0.00001 })
        precondition(withoutObsolete.suffix(1_024).allSatisfy { abs($0 - values[2]) < 0.00001 })
        obsolete.stop()
        print("PASS: late completion of a removed download cannot restore stale audio")

        // Keep replenishing a longer album while reusing the fixed pool of player nodes.
        let longAlbum = try (0..<7).map { index in
            let url = directory.appendingPathComponent("long-album-\(index).caf")
            try writeAudio(url, count: 11_029, value: Float(index + 1) / 10)
            return Track(title: "Long album \(index)", album: "Long album", streamURL: url)
        }
        let lookaheadFiles = PreparationGate(blocked: [])
        let (rolling, rollingEngine) = try output(prepareFile: { url, _ in try await lookaheadFiles.prepare(url) })
        var rollingTracks: [UUID] = []
        rolling.onTrackChanged = { rollingTracks.append($0.id) }
        rolling.load(longAlbum[0], queue: longAlbum, repeatMode: .off)
        try await ready(rolling, failure: { nil })
        let distantRequests = await lookaheadFiles.requestCount(longAlbum[3].streamURL!)
        precondition(distantRequests == 0, "The startup lookahead must be bounded even for albums")
        var rollingAudio: [Float] = []
        while rollingAudio.count < 11_029 * longAlbum.count {
            rollingAudio += try render(rollingEngine, frames: min(1_024, 11_029 * longAlbum.count - rollingAudio.count))
            try await Task.sleep(for: .milliseconds(2))
        }
        for (index, sample) in rollingAudio.enumerated() {
            precondition(abs(sample - Float(index / 11_029 + 1) / 10) < 0.00001,
                         "Rolling lookahead inserted, skipped, or mixed audio at frame \(index)")
        }
        precondition(rollingTracks == longAlbum.dropFirst().map(\.id))
        rolling.stop()
        print("PASS: bounded background lookahead stays sample-contiguous throughout a seven-song album")

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

    static func output(prepareFile: GaplessAudioPlayer.PrepareFile? = nil) throws -> (GaplessAudioPlayer, AVAudioEngine) {
        let engine = AVAudioEngine()
        let player = GaplessAudioPlayer(engine: engine, prepareFile: prepareFile)
        try engine.enableManualRenderingMode(.offline, format: GaplessAudioFiles.outputFormat, maximumFrameCount: 1024)
        return (player, engine)
    }

    static func ready(_ player: GaplessAudioPlayer, failure: () -> String?) async throws {
        for _ in 0..<500 {
            if let error = failure() { fatalError(error) }
            if player.isReady && !player.isPreparing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Audio preparation timed out")
    }

    static func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Condition timed out")
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

    static func writeAudio(_ url: URL, count: Int, value: Float, rate: Double = 44_100, channels: AVAudioChannelCount = 2, ramp: Bool = false) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(channels) {
            for frame in 0..<count { buffer.floatChannelData![channel][frame] = ramp ? Float(frame) / Float(count) : value }
        }
        try file.write(from: buffer)
    }
}

// Test-only delayed file preparation. Cancellation may complete late, as a real
// download/decoder can; the player must still reject stale results.
actor PreparationGate {
    private var blocked: Set<URL>
    private var requests: [URL: Int] = [:]
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    init(blocked: Set<URL>) { self.blocked = blocked }

    func prepare(_ url: URL) async throws -> URL {
        requests[url, default: 0] += 1
        if blocked.contains(url) {
            await withCheckedContinuation { waiters[url, default: []].append($0) }
        }
        return url
    }

    func requestCount(_ url: URL) -> Int { requests[url, default: 0] }

    func release(_ url: URL) {
        blocked.remove(url)
        waiters.removeValue(forKey: url)?.forEach { $0.resume() }
    }
}
