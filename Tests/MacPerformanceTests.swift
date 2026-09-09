import AppKit
import AVFoundation
import Foundation
import ImageIO
import Observation

@main
@MainActor
struct MacPerformanceTests {
    private final class Counter: @unchecked Sendable { var value = 0 }

    static func main() async throws {
        let player = MacPlayerViewModel(serverClient: AriaServerClient(baseURLs: []), startsBackgroundTasks: false)
        let track = Track(title: "Observation check", duration: 180)
        player.addToQueue(track)
        player.currentTrack = track
        let libraryChanges = Counter()
        let positionChanges = Counter()
        withObservationTracking {
            _ = player.catalog
            _ = player.queue
            _ = player.currentTrack
        } onChange: { libraryChanges.value += 1 }
        withObservationTracking {
            _ = player.elapsed
        } onChange: { positionChanges.value += 1 }
        for tick in 1...100 { player.elapsed = Double(tick) / 2 }
        precondition(libraryChanges.value == 0, "Playback ticks must not invalidate library/queue observers")
        precondition(positionChanges.value == 1, "Position observers must receive playback updates")
        player.addToQueue(Track(title: "Queue change"))
        precondition(libraryChanges.value == 1, "Real queue changes must still invalidate the queue")
        print("PASS: 100 playback ticks produce zero library/queue invalidations; real queue edits still notify")

        let queueLookupChanges = Counter()
        withObservationTracking {
            _ = player.queueIndex(for: track.id)
        } onChange: { queueLookupChanges.value += 1 }
        player.addToQueue(Track(title: "Lookup invalidation"))
        precondition(queueLookupChanges.value == 1, "Cached queue lookups must still observe queue edits")
        print("PASS: cached queue lookups retain Observation notifications")

        let firstWindow = UUID(), secondWindow = UUID()
        player.setPlaybackWindowVisible(true, id: firstWindow)
        player.setPlaybackWindowVisible(true, id: secondWindow)
        player.setPlaybackWindowVisible(false, id: firstWindow)
        precondition(player.hasVisiblePlaybackWindow, "Hiding one window must not suspend another")
        player.setPlaybackWindowVisible(false, id: secondWindow)
        precondition(!player.hasVisiblePlaybackWindow)
        print("PASS: background visual work follows the last visible window")

        for rate in [44_100.0, 96_000.0, 192_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
            buffer.frameLength = 1_024
            for channel in 0..<2 {
                for frame in 0..<1_024 {
                    buffer.floatChannelData![channel][frame] = 0.4 * sin(Float(frame) * 2 * .pi * 440 / Float(rate))
                }
            }
            let analyzer = AudioSpectrumAnalyzer(bandCount: 36)
            var updates = 0
            analyzer.onLevels = { levels in
                updates += 1
                precondition(levels.count == 36 && levels.allSatisfy { $0.isFinite && $0 >= 0.025 && $0 <= 1 })
            }
            let buffers = Int(rate * 10 / 1_024)
            for _ in 0..<buffers { analyzer.analyze(buffer) }
            precondition(updates > 100 && updates <= 201, "Analysis must stay under 20 updates/s at every sample rate")
            print("PASS: \(Int(rate)) Hz audio produces \(updates) bounded visualizer updates over 10 seconds")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aria-artwork-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large-cover.png")
        let context = CGContext(data: nil, width: 3_000, height: 2_000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 2_000))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        precondition(AriaArtworkCache.shared.cachedImage(for: url, maxPixelSize: 64) == nil)
        async let first = AriaArtworkCache.shared.image(for: url, maxPixelSize: 64)
        async let second = AriaArtworkCache.shared.image(for: url, maxPixelSize: 64)
        let (row, duplicate) = await (first, second)
        precondition(row != nil && row === duplicate, "Concurrent row requests must share one decoded image")
        precondition(AriaArtworkCache.shared.cachedImage(for: url, maxPixelSize: 64) === row,
                     "Warm rows must synchronously reuse the decoded thumbnail")
        precondition(AriaArtworkCache.shared.cachedImage(for: url, maxPixelSize: 400) == nil,
                     "A larger cover must not use the row-sized variant")
        precondition(row!.size.width == 96 && row!.size.height == 64, "Row art must be downsampled with aspect ratio preserved")
        let record = await AriaArtworkCache.shared.image(for: url, maxPixelSize: 400)
        precondition(record!.size.width == 512 && record !== row, "Record art needs its own sharp Retina variant")
        let embedded = await AriaArtworkCache.shared.image(from: try Data(contentsOf: url), maxPixelSize: 60)
        precondition(embedded?.size == NSSize(width: 96, height: 64), "Embedded playlist covers must be downsampled")
        let badEmbedded = await AriaArtworkCache.shared.image(from: Data("bad image".utf8), maxPixelSize: 60)
        precondition(badEmbedded == nil)
        let corruptURL = directory.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corruptURL)
        let corrupt = await AriaArtworkCache.shared.image(for: corruptURL)
        precondition(corrupt == nil)
        print("PASS: concurrent artwork requests coalesce; 3000×2000 cover becomes 96×64 for rows and 512px for records; corrupt data is rejected")
    }
}
