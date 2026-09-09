import AppKit
import Foundation
import SwiftUI

enum AriaRelease { static let displayText = "Performance preview" }

// This preview never contacts the user's server or starts audio playback.
final class PreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
@MainActor
struct PerformancePreview: App {
    @State private var player: MacPlayerViewModel = {
        URLProtocol.registerClass(PreviewProtocol.self)
        let player = MacPlayerViewModel(serverClient: AriaServerClient(baseURLs: []), startsBackgroundTasks: false)
        let tracks = (0..<1_725).map { index in
            Track(title: "Song \(index + 1)", artist: "Aria performance check", album: "A continuous record", duration: 240)
        }
        player.play(tracks[0], from: tracks)
        return player
    }()
    var body: some Scene {
        WindowGroup("Aria performance preview") {
            ContentView()
                .environment(player)
                .frame(minWidth: 860, minHeight: 600)
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        if player.isPlaying { player.elapsed += 0.5 }
                    }
                }
        }
        .defaultSize(width: 1_040, height: 700)
    }
}
