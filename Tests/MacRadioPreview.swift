import AppKit
import Foundation
import SwiftUI

enum AriaRelease { static let displayText = "Radio preview" }

// The fixture never contacts the user's server or plays audio.
private let previewTracks = (0..<8).map { index in
    Track(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
          title: ["Smells Like Teen Spirit", "Come As You Are", "Everlong", "Black Hole Sun",
                  "Today", "Interstate Love Song", "Alive", "Creep"][index],
          artist: ["Nirvana", "Nirvana", "Foo Fighters", "Soundgarden", "The Smashing Pumpkins",
                   "Stone Temple Pilots", "Pearl Jam", "Radiohead"][index],
          album: "Radio collection", duration: 240,
          artwork: ArtworkPalette(topHex: "357872", bottomHex: "122B32", symbolName: "music.note"),
          isStandalone: true, isRadioDownload: index > 0)
}

private struct PreviewRadio: SongRadioProviding {
    func searchSongs(query: String, limit: Int) async throws -> [YouTubeMusicSongResult] { songs }
    func radio(seedVideoID: String, continuation: String?) async throws -> SongRadioPage {
        SongRadioPage(songs: songs, continuation: nil)
    }
    private var songs: [YouTubeMusicSongResult] {
        previewTracks.enumerated().map { index, track in
            YouTubeMusicSongResult(id: "preview-\(index)", title: track.title, artist: track.artist, artworkURL: nil)
        }
    }
}

private final class PreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data: Data
        var status = 200
        switch request.url?.path {
        case "/api/tracks": data = try! JSONEncoder().encode(previewTracks)
        case "/api/playlists": data = Data("[]".utf8)
        case "/api/playback/sync":
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let n = stream.read(&bytes, maxLength: bytes.count)
                    if n <= 0 { break }
                    body.append(bytes, count: n)
                }
            }
            let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
            data = try! JSONSerialization.data(withJSONObject: [
                "sessionID": json["sessionID"]!, "isShared": false, "role": "host", "devices": [],
                "latestCommandID": 0, "commands": [],
                "state": ["queueTrackIDs": [], "elapsed": 0, "isPlaying": false,
                          "isShuffleEnabled": false, "repeatMode": "off", "volume": 0.5]
            ])
        default: data = Data("{}".utf8); status = 404
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor
struct MacRadioPreview {
    static func main() async throws {
        _ = NSApplication.shared
        URLProtocol.registerClass(PreviewProtocol.self)
        let originalSession = UserDefaults.standard.object(forKey: "aria.playback.sessionID")
        let suite = "AriaRadioPreview.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            UserDefaults.standard.set(originalSession, forKey: "aria.playback.sessionID")
            defaults.removePersistentDomain(forName: suite)
        }
        let player = MacPlayerViewModel(serverClient: AriaServerClient(baseURLs: [URL(string: "https://aria-preview.invalid")!]),
                                       startsBackgroundTasks: false, radioClient: PreviewRadio(),
                                       radioDefaults: defaults, handlesAudioPlayback: false)
        await player.refreshCatalog()
        player.startRadio(previewTracks[0])
        for _ in 0..<100 where player.upNext.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        precondition(player.upNext.count == 3)
        player.elapsed = 42
        try await render(PlayerBar().environment(player), size: NSSize(width: 780, height: 250), name: "compact-player")
        try await render(ContentView().environment(player), size: NSSize(width: 1040, height: 700), name: "library")
        try await render(FullscreenPlayerView().environment(player), size: NSSize(width: 780, height: 700), name: "player")
        try await render(FullscreenPlayerView().environment(player), size: NSSize(width: 600, height: 600), name: "small-player")
        player.stopRadio()
        player.isPlaying = false
    }

    private static func render<V: View>(_ content: V, size: NSSize, name: String) async throws {
        let view = NSHostingView(rootView: content.preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.setContentSize(size)
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No rendered view") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: "/tmp/aria-mac-radio-\(name).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        window.orderOut(nil)
        print(url.path)
    }
}
