import AppKit
import SwiftUI
import QuartzCore
import ImageIO

enum AriaRelease { static let displayText = "List scroll benchmark" }

private final class BenchmarkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
@MainActor
struct ListScrollBenchmark {
    // Offline UI fixture: no audio streams, server connection, or library mutations.
    // Reports synchronous scroll/layout/display work; this is not end-to-end GPU frame time.
    // ARIA_TRACK_COUNT selects album length; ARIA_MANUAL_PREVIEW=1 leaves it open for inspection.
    static func main() {
        URLProtocol.registerClass(BenchmarkProtocol.self)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let player = MacPlayerViewModel(serverClient: AriaServerClient(baseURLs: []), startsBackgroundTasks: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aria-album-scroll-\(UUID())")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cover = directory.appendingPathComponent("cover.png")
        let context = CGContext(data: nil, width: 2000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.18, green: 0.4, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let destination = CGImageDestinationCreateWithURL(cover as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let count = Int(ProcessInfo.processInfo.environment["ARIA_TRACK_COUNT"] ?? "1000")!
        let tracks = (1...count).map { Track(title: "Track \($0)", artist: "Scroll benchmark", album: "Album", duration: 180, trackNumber: $0, artworkURL: cover) }
        let album = AriaAlbum(title: "List scroll benchmark", artist: "Scroll benchmark", year: 2026, tracks: tracks)
        let mode = ProcessInfo.processInfo.environment["ARIA_LIST"] ?? "songs"
        let page: AnyView
        switch mode {
        case "album": page = AnyView(MacAlbumDetailView(album: album, onBack: {}))
        case "playlist": page = AnyView(MacPlaylistDetailView(playlist: AriaPlaylist(title: "Test playlist", subtitle: "Scrolling check", tracks: tracks)))
        case "queue":
            player.play(tracks[0], from: tracks)
            player.isPlaying = false
            page = AnyView(FullscreenPlayerView())
        case "albums":
            let albums = (0..<count / 10).map { AriaAlbum(title: "Album \($0)", artist: "Scroll benchmark", year: 2026, tracks: Array(tracks.prefix(10))) }
            page = AnyView(AlbumsView(albums: albums, isSearching: false, onOpenAlbum: { _ in }))
        default: page = AnyView(SongsView(tracks: tracks, isSearching: false))
        }
        let view = page.environment(player).preferredColorScheme(.dark)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        var samples: [Double] = []
        var tick = 0
        var timer: Timer?
        let start = CACurrentMediaTime()
        if ProcessInfo.processInfo.environment["ARIA_MANUAL_PREVIEW"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let scroll = findScroll(host) else { fatalError("Missing scroll view") }
                print("INITIAL height=\(scroll.documentView!.bounds.height), startup=\(CACurrentMediaTime() - start)")
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let begin = CACurrentMediaTime()
                        let maxY = max(0, scroll.documentView!.bounds.height - scroll.contentView.bounds.height)
                        let y = CGFloat(tick % 180) / 179 * min(14_320, maxY)
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        host.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        samples.append((CACurrentMediaTime() - begin) * 1000)
                        tick += 1
                        if tick >= 360 {
                            timer?.invalidate()
                            let sorted = samples.sorted()
                            print("RESULT list=\(mode) tracks=\(count) mean=\(samples.reduce(0,+)/Double(samples.count))ms p95=\(sorted[Int(Double(sorted.count)*0.95)])ms max=\(sorted.last!)ms total=\(CACurrentMediaTime()-start)s")
                            app.stop(nil)
                            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: true)
                        }
                    }
                }
            }
        }
        app.run()
    }
    static func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = findScroll(child) { return scroll } }
        return nil
    }
}
