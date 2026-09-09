import AppKit
import Foundation
import SwiftUI

enum AriaRelease { static let displayText = "Navigation test" }

// All requests, including artwork and artist prefetching, stay inside this fixture.
private final class NavigationProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let payload: Any
        let status: Int
        switch request.url?.path {
        case "/api/tracks":
            payload = (0..<80).flatMap { album in
                (1...30).map { track -> [String: Any] in
                    ["id": "album-\(album)-track-\(track)", "albumID": "album-\(album)",
                     "title": String(format: "Track %02d", track), "artist": "Navigation Artist",
                     "album": String(format: "Album %02d", album), "trackNumber": track,
                     "year": 2000 + album, "duration": 180]
                }
            }
            status = 200
        case "/api/playlists":
            payload = [["id": "00000000-0000-0000-0000-000000000001", "title": "Test playlist",
                        "trackIDs": [], "revision": 0]]
            status = 200
        default:
            payload = [:]
            status = 404
        }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
@MainActor
struct MacNavigationPreview: App {
    @State private var player: MacPlayerViewModel = {
        URLProtocol.registerClass(NavigationProtocol.self)
        return MacPlayerViewModel(serverClient: AriaServerClient(baseURLs: [URL(string: "https://aria-navigation.invalid")!]))
    }()

    var body: some Scene {
        WindowGroup("Aria navigation preview") {
            ContentView()
                .environment(player)
                .frame(minWidth: 860, minHeight: 600)
                .task {
                    await player.refreshCatalog()
                    // Keep the player fixture small while leaving the library long.
                    if let first = player.catalog.first {
                        player.play(first, from: Array(player.catalog.prefix(30)))
                        player.isPlaying = false
                    }
                }
        }
        .defaultSize(width: 1040, height: 700)
    }
}
