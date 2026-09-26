import Foundation
import Observation

private final class RadioURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor RadioProvider: SongRadioProviding {
    var songs: [YouTubeMusicSongResult]
    var delay: Duration
    var calls = 0
    init(_ songs: [YouTubeMusicSongResult], delay: Duration = .zero) {
        self.songs = songs
        self.delay = delay
    }
    func searchSongs(query: String, limit: Int) async throws -> [YouTubeMusicSongResult] { songs }
    func radio(seedVideoID: String, continuation: String?) async throws -> SongRadioPage {
        calls += 1
        // Deliberately return even when cancelled, exercising session guards.
        try? await Task.sleep(for: delay)
        return SongRadioPage(songs: songs, continuation: "next-page")
    }
}

@MainActor
final class MacRadioTests {
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var players: [MacPlayerViewModel] = []
    private var serverTracks: [Track] = []
    private var downloadTracks: [Track] = []
    private var downloadedLinks: [String] = []
    private var downloadSources: [String] = []
    private var bulkDeleteRequests = 0
    private var deletedIDs: [String] = []
    private var deleteBusyCount = 0
    private var deleteFails = false
    private var failedDownloadTitles: Set<String> = []
    private var reusedTrackID: UUID?
    private var jobs: [String: Data] = [:]
    private var activeJobID: String?
    private var completionPolls = 0

    func setUp() async throws {
        defaultsName = "AriaRadioTests.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsName)!
    }

    func tearDown() async throws {
        players.forEach { $0.stopRadio(); if $0.isPlaying { $0.playPause() } }
        players = []
        defaults.removePersistentDomain(forName: defaultsName)
        try await Task.sleep(for: .milliseconds(50))
        RadioURLProtocol.handler = nil
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(bytes, count: count)
        }
        return data
    }

    private func track(_ n: Int) -> Track {
        Track(title: "Song \(n)", artist: "Artist", album: "Album", duration: 240,
              artwork: ArtworkPalette(topHex: "111111", bottomHex: "222222", symbolName: "music.note"))
    }

    private func song(_ track: Track, id: String? = nil) -> YouTubeMusicSongResult {
        YouTubeMusicSongResult(id: id ?? String(track.id.uuidString.prefix(11)), title: track.title,
                              artist: track.artist, artworkURL: nil)
    }

    private func makePlayer(tracks: [Track], provider: RadioProvider) async throws -> MacPlayerViewModel {
        serverTracks = tracks
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RadioURLProtocol.self]
        var client = AriaServerClient(baseURLs: [URL(string: "https://aria.test")!])
        client.session = URLSession(configuration: configuration)
        // URLProtocol callbacks run off-main. This fixture is only mutated inside
        // the callback, or after awaiting the corresponding app operation.
        RadioURLProtocol.handler = { [self] request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/api/tracks"):
                return (200, try JSONEncoder().encode(serverTracks))
            case ("GET", "/api/playlists"):
                return (200, Data("[]".utf8))
            case ("GET", "/api/downloads"):
                if let activeJobID {
                    return (200, try JSONSerialization.data(withJSONObject: ["active": JSONSerialization.jsonObject(with: jobs[activeJobID]!)]))
                }
                return (200, Data("{\"active\":null}".utf8))
            case ("POST", "/api/downloads"):
                var body = request.httpBody
                if body == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(buffer, count: count)
                    }
                    body = data
                }
                let json = try JSONSerialization.jsonObject(with: body!) as! [String: String]
                downloadedLinks.append(json["link"]!)
                downloadSources.append(json["source"] ?? "manual")
                if !failedDownloadTitles.contains(json["album"]!), var track = downloadTracks.first(where: { $0.title == json["album"] }) {
                    track.isRadioDownload = json["source"] == "radio"
                    serverTracks.append(track)
                }
                var job: [String: Any] = ["id": "job", "status": failedDownloadTitles.contains(json["album"]!) ? "failed" : "succeeded", "phase": "Done", "message": "Done",
                    "progress": 1, "album": json["album"]!, "albumArtist": "Artist", "year": "", "filesStarted": 1, "outputTail": []]
                if let reusedTrackID { job["trackID"] = reusedTrackID.uuidString }
                job["id"] = "job-\(downloadedLinks.count)"
                if completionPolls > 0 {
                    job["status"] = "running"
                    activeJobID = job["id"] as? String
                }
                let data = try JSONSerialization.data(withJSONObject: job)
                jobs[job["id"] as! String] = data
                return (200, data)
            case ("GET", let path) where path.hasPrefix("/api/downloads/"):
                let id = String(path.split(separator: "/").last!)
                if id == activeJobID {
                    completionPolls -= 1
                    if completionPolls <= 0 {
                        var job = try JSONSerialization.jsonObject(with: jobs[id]!) as! [String: Any]
                        job["status"] = "succeeded"
                        jobs[id] = try JSONSerialization.data(withJSONObject: job)
                        activeJobID = nil
                    }
                }
                return (200, jobs[id]!)
            case ("POST", "/api/playback/sync"):
                let json = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
                return (200, try JSONSerialization.data(withJSONObject: [
                    "sessionID": json["sessionID"]!, "isShared": json["sessionID"] as? String == "shared",
                    "role": json["sessionID"] as? String == "shared" ? "controller" : "host",
                    "devices": [], "latestCommandID": 0, "commands": [],
                    "state": ["queueTrackIDs": [], "elapsed": 0, "isPlaying": false,
                              "isShuffleEnabled": false, "repeatMode": "off", "volume": 0.5]
                ]))
            case ("DELETE", let path):
                if deleteFails { return (500, Data("{\"error\":\"Server unavailable\"}".utf8)) }
                if activeJobID != nil { return (409, Data("{\"error\":\"Download in progress\"}".utf8)) }
                if deleteBusyCount > 0 {
                    deleteBusyCount -= 1
                    return (409, Data("{\"error\":\"Download in progress\"}".utf8))
                }
                if path == "/api/radio-downloads" {
                    bulkDeleteRequests += 1
                    let ids = serverTracks.filter { $0.isRadioDownload == true }.map { $0.id.uuidString.lowercased() }
                    serverTracks.removeAll { $0.isRadioDownload == true }
                    deletedIDs.append(contentsOf: ids)
                    return (200, try JSONSerialization.data(withJSONObject: ["deletedFiles": ids.count, "deletedTrackIDs": ids, "updatedPlaylists": 0]))
                }
                let id = String(path.split(separator: "/").last!).lowercased()
                deletedIDs.append(id)
                serverTracks.removeAll { $0.id.uuidString.lowercased() == id }
                return (200, Data("{}".utf8))
            default: throw URLError(.unsupportedURL)
            }
        }
        let player = MacPlayerViewModel(serverClient: client, startsBackgroundTasks: false,
                                       radioClient: provider, radioDefaults: defaults, handlesAudioPlayback: false)
        players.append(player)
        await player.refreshCatalog()
        player.startSeparatePlaybackSession()
        try await eventually { player.playbackSessionRole == .host }
        player.retryRadioDeletions()
        return player
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #file, line: UInt = #line) async throws {
        for _ in 0..<1200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fail("Condition did not become true", file: file, line: line)
    }

    func testDownloadedSeedPlaysFirstAndRefillsAfterNext() async throws {
        let tracks = (0..<8).map(track)
        let provider = RadioProvider(tracks.map { song($0) })
        let player = try await makePlayer(tracks: tracks, provider: provider)
        player.startRadio(tracks[0])
        try await eventually { player.queue.count == 4 }
        expectEqual(player.currentTrack?.id, tracks[0].id)
        expectEqual(player.upNext.map(\.id), Array(tracks[1...3]).map(\.id))
        expectTrue(downloadedLinks.isEmpty)
        player.next()
        try await eventually { player.upNext.count == 3 }
        expectEqual(player.currentTrack?.id, tracks[1].id)
        expectEqual(player.upNext.last?.id, tracks[4].id)
    }

    func testMissingSeedDownloadsBeforePlayingWithEmptyLibrary() async throws {
        let tracks = (0..<4).map(track)
        let provider = RadioProvider(tracks.map { song($0) })
        let player = try await makePlayer(tracks: [], provider: provider)
        downloadTracks = tracks
        player.startRadio(song(tracks[0]))
        try await eventually { player.queue.count == 4 }
        expectEqual(player.currentTrack?.id, tracks[0].id)
        expectEqual(downloadedLinks.count, 4)
        expectEqual(downloadSources, Array(repeating: "radio", count: 4))
        expectEqual(player.radioDownloadCount, 4)
        expectTrue(player.isPlaying)
    }

    func testCatalogRefreshPreservesPlaybackPositionAndRadioQueue() async throws {
        let tracks = (0..<6).map(track)
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider(tracks.map { song($0) }))
        player.startRadio(tracks[0])
        try await eventually { player.queue.count == 4 }
        player.elapsed = 42
        let ids = player.queue.map(\.id)
        let refreshStarted = Date()
        await player.refreshCatalog()
        expectEqual(player.queue.map(\.id), ids)
        expectEqual(player.currentTrack?.id, tracks[0].id)
        expectGreaterThanOrEqual(player.elapsed, 42)
        expectLessThanOrEqual(player.elapsed, 43 + Date().timeIntervalSince(refreshStarted))
        expectTrue(player.isPlaying)
    }

    func testOrdinaryPlaybackCancelsDelayedRadioResults() async throws {
        let tracks = (0..<6).map(track)
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider(tracks.map { song($0) }, delay: .milliseconds(120)))
        player.startRadio(tracks[0])
        try await eventually { player.currentTrack?.id == tracks[0].id }
        player.play(tracks[5], from: [tracks[5]])
        try await Task.sleep(for: .milliseconds(250))
        expectFalse(player.isRadioActive)
        expectEqual(player.queue.map(\.id), [tracks[5].id])
        expectNil(player.radioErrorMessage)
    }

    func testPauseWhileWaitingDoesNotAutoplayArrivingSong() async throws {
        let tracks = (0..<6).map(track)
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider(tracks.map { song($0) }, delay: .milliseconds(120)))
        player.startRadio(tracks[0])
        try await eventually { player.currentTrack?.id == tracks[0].id }
        player.next()
        expectTrue(player.isWaitingForRadioTrack)
        player.playPause()
        try await eventually { player.queue.count == 4 }
        expectFalse(player.isPlaying)
        expectEqual(player.currentTrack?.id, tracks[0].id)
        player.playPause()
        expectEqual(player.currentTrack?.id, tracks[1].id)
        expectTrue(player.isPlaying)
    }

    func testRemoveSkipsImmediatelyThenDeletesAndPersistsExclusion() async throws {
        let tracks = (0..<8).map(track)
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider(tracks.map { song($0) }))
        player.startRadio(tracks[0])
        try await eventually { player.queue.count == 4 }
        player.next()
        try await eventually { player.upNext.count == 3 }
        deleteBusyCount = 1
        player.removeCurrentSongFromRadio()
        expectEqual(player.currentTrack?.id, tracks[2].id)
        expectEqual(player.pendingRadioDeletionCount, 1)
        try await eventually { player.pendingRadioDeletionCount == 0 }
        expectEqual(deletedIDs, [tracks[1].id.uuidString.lowercased()])
        expectFalse(player.catalog.contains { $0.id == tracks[1].id })
        expectTrue(defaults.stringArray(forKey: "aria.radio.excludedSongs")!.contains(tracks[1].radioIdentity))
        player.startRadio(tracks[0])
        try await eventually { player.queue.count == 4 }
        expectFalse(player.queue.contains { $0.id == tracks[1].id })
        expectTrue(downloadedLinks.isEmpty)
    }

    func testBulkDeleteRemovesOnlyFlaggedTracksAndPreservesOrdinaryPlayback() async throws {
        var tracks = (0..<3).map(track)
        tracks[1].isRadioDownload = true
        tracks[2].isRadioDownload = true
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider(tracks.map { song($0) }))
        player.play(tracks[0], from: tracks)
        player.elapsed = 31
        expectEqual(player.radioDownloadCount, 2)
        await player.deleteAllRadioDownloads()
        expectEqual(bulkDeleteRequests, 1)
        expectEqual(Set(deletedIDs), Set(tracks.dropFirst().map { $0.id.uuidString.lowercased() }))
        expectEqual(player.queue.map(\.id), [tracks[0].id])
        expectEqual(player.currentTrack?.id, tracks[0].id)
        expectTrue(player.isPlaying)
        expectGreaterThanOrEqual(player.elapsed, 31)
        expectEqual(player.radioDownloadCount, 0)
        expectNil(player.radioCleanupError)
        expectNil(defaults.stringArray(forKey: "aria.radio.excludedSongs"))
    }

    func testBulkDeleteStopsRadioAndWaitsForDownloader() async throws {
        var tracks = (0..<6).map(track)
        tracks[0].isRadioDownload = true
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider(tracks.map { song($0) }))
        player.startRadio(tracks[0])
        try await eventually { player.queue.count == 4 }
        deleteBusyCount = 1
        let cleanup = Task { await player.deleteAllRadioDownloads() }
        try await eventually { player.isDeletingRadioDownloads }
        expectFalse(player.isRadioActive)
        player.startRadio(tracks[1])
        expectFalse(player.isRadioActive)
        await cleanup.value
        expectFalse(player.isDeletingRadioDownloads)
        expectFalse(player.isPlaying)
        expectEqual(player.radioDownloadCount, 0)
        expectFalse(player.catalog.contains { $0.id == tracks[0].id })
    }

    func testBulkDeleteFailureKeepsFlagsAndOffersRetry() async throws {
        var tracks = [track(0)]
        tracks[0].isRadioDownload = true
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider(tracks.map { song($0) }))
        deleteFails = true
        await player.deleteAllRadioDownloads()
        expectNotNil(player.radioCleanupError)
        expectEqual(player.radioDownloadCount, 1)
        expectFalse(player.isDeletingRadioDownloads)
        deleteFails = false
        await player.deleteAllRadioDownloads()
        expectNil(player.radioCleanupError)
        expectEqual(player.radioDownloadCount, 0)
    }

    func testReusedDownloadTrackIDHandlesDifferentSavedMetadataAndDislike() async throws {
        let tracks = (0..<6).map(track)
        let seed = YouTubeMusicSongResult(id: "abcdefghijk", title: "Different saved title", artist: "Artist", artworkURL: nil)
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider([seed] + tracks.dropFirst().map { song($0) }))
        reusedTrackID = tracks[0].id
        player.startRadio(seed)
        try await eventually { player.queue.count == 4 }
        expectEqual(player.currentTrack?.id, tracks[0].id)
        expectEqual(downloadedLinks.count, 1)
        player.removeCurrentSongFromRadio()
        try await eventually { player.pendingRadioDeletionCount == 0 }
        let excluded = defaults.stringArray(forKey: "aria.radio.excludedSongs")!
        expectTrue(excluded.contains("video:abcdefghijk"))
        expectTrue(excluded.contains(seed.radioIdentity))
    }

    func testFailedRecommendationDownloadSkipsToNextSong() async throws {
        let tracks = (0..<6).map(track)
        let player = try await makePlayer(tracks: [tracks[0]], provider: RadioProvider(tracks.map { song($0) }))
        downloadTracks = Array(tracks.dropFirst())
        failedDownloadTitles = [tracks[1].title]
        player.startRadio(tracks[0])
        try await eventually { player.queue.count == 4 }
        expectEqual(player.upNext.map(\.id), Array(tracks[2...4]).map(\.id))
        expectNil(player.radioErrorMessage)
        expectTrue(player.isPlaying)
    }

    func testFailedDeletionSurvivesStoppingRadioAndRetriesOnRelaunch() async throws {
        let tracks = (0..<7).map(track)
        let provider = RadioProvider(tracks.map { song($0) })
        let player = try await makePlayer(tracks: tracks, provider: provider)
        player.startRadio(tracks[0])
        try await eventually { player.queue.count == 4 }
        deleteFails = true
        player.removeCurrentSongFromRadio()
        try await eventually { player.radioDeletionError != nil }
        expectEqual(player.pendingRadioDeletionCount, 1)
        player.stopRadio()
        deleteFails = false
        let relaunched = try await makePlayer(tracks: tracks, provider: provider)
        try await eventually { relaunched.pendingRadioDeletionCount == 0 }
        expectEqual(deletedIDs, [tracks[0].id.uuidString.lowercased()])
        expectFalse(relaunched.catalog.contains { $0.id == tracks[0].id })
    }

    func testReplacingRadioCannotAppendCancelledSessionResults() async throws {
        let tracks = (0..<8).map(track)
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider(tracks.map { song($0) }, delay: .milliseconds(120)))
        player.startRadio(tracks[0])
        try await eventually { player.currentTrack?.id == tracks[0].id }
        player.startRadio(tracks[4])
        try await eventually { player.queue.count == 4 }
        expectEqual(player.queue.first?.id, tracks[4].id)
        expectEqual(player.currentTrack?.id, tracks[4].id)
        expectEqual(Set(player.queue.map(\.id)).count, 4)
        expectNil(player.radioErrorMessage)
    }

    func testManualDownloadsShareRadioQueueWithoutChangingTheirOrigin() async throws {
        let tracks = (0..<6).map(track)
        let player = try await makePlayer(tracks: [tracks[0]], provider: RadioProvider(tracks.prefix(5).map { song($0) }))
        downloadTracks = Array(tracks.dropFirst())
        player.startRadio(tracks[0])
        try await eventually { player.activeDownloadItem?.request.source == "radio" }
        player.enqueueDownload(song(tracks[5]))
        try await eventually { player.upNext.count == 3 && player.downloadQueue.allSatisfy { $0.isFinished } }
        expectEqual(downloadSources.filter { $0 == "manual" }.count, 1)
        expectEqual(player.catalog.first { $0.id == tracks[5].id }?.isRadioDownload, false)
        expectFalse(player.queue.contains { $0.id == tracks[5].id })
        expectEqual(player.radioDownloadCount, 3)
    }

    func testStartingRadioFromControllerPlaysLocally() async throws {
        let tracks = (0..<6).map(track)
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider(tracks.map { song($0) }))
        player.joinSharedPlaybackSession()
        try await eventually { player.isRemoteController }
        player.startRadio(tracks[0])
        try await eventually { player.upNext.count == 3 }
        expectEqual(player.playbackSessionRole, .host)
        expectFalse(player.isSharedPlaybackSession)
        expectTrue(player.isPlaying)
        expectEqual(player.currentTrack?.id, tracks[0].id)
    }

    func testStopRadioKeepsPreparedQueueWhenShuffleChanges() async throws {
        let tracks = (0..<9).map(track)
        let player = try await makePlayer(tracks: tracks, provider: RadioProvider(tracks.map { song($0) }))
        player.startRadio(tracks[0])
        try await eventually { player.queue.count == 4 }
        let prepared = Set(player.queue.map(\.id))
        player.stopRadio()
        player.toggleShuffle()
        player.toggleShuffle()
        expectEqual(Set(player.queue.map(\.id)), prepared)
        expectTrue(player.isPlaying)
    }

    func testRadioStateNotifiesViewsWithoutPlaybackTicks() async throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let player = try await makePlayer(tracks: [], provider: RadioProvider([]))
        let changes = Counter()
        withObservationTracking { _ = player.isRadioActive } onChange: { changes.value += 1 }
        player.startRadio(song(track(0)))
        expectEqual(changes.value, 1)
        player.stopRadio()
    }

    func testCleanupWaitsForAcceptedRadioJobAndStopsFurtherDownloads() async throws {
        let tracks = (0..<5).map(track)
        let player = try await makePlayer(tracks: [tracks[0]], provider: RadioProvider(tracks.map { song($0) }))
        downloadTracks = Array(tracks.dropFirst())
        completionPolls = 2
        player.startRadio(tracks[0])
        try await eventually { player.activeDownloadItem?.job?.isActive == true }
        await player.deleteAllRadioDownloads()
        expectEqual(downloadedLinks.count, 1)
        expectEqual(bulkDeleteRequests, 1)
        expectFalse(player.isRadioActive)
        expectEqual(player.catalog.map(\.id), [tracks[0].id])
        expectEqual(player.radioDownloadCount, 0)
        expectNil(player.radioCleanupError)
    }

    func testRadioParserKeepsPrimaryOrderSkipsUnavailableAndReadsContinuation() throws {
        func renderer(_ id: String, _ title: String) -> [String: Any] {
            ["playlistPanelVideoRenderer": ["videoId": id, "title": ["runs": [["text": title]]],
                "longBylineText": ["runs": [["text": "Artist", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCartist"]]], ["text": " • Album"]]]]]
        }
        let wrapped: [String: Any] = ["playlistPanelVideoWrapperRenderer": [
            "primaryRenderer": renderer("second", "Second"), "counterpart": [["counterpartRenderer": renderer("video", "Music Video")]]]]
        let panel: [String: Any] = ["contents": [renderer("first", "First"), wrapped, renderer("first", "Duplicate"),
            ["playlistPanelVideoRenderer": ["videoId": "blocked", "unplayableText": [:]]]],
            "continuations": [["nextRadioContinuationData": ["continuation": "token"]]]]
        for key in ["playlistPanelRenderer", "playlistPanelContinuation"] {
            let page = try YouTubeMusicSearchClient.parseRadioPage([key: panel])
            expectEqual(page.songs.map(\.id), ["first", "second"])
            expectEqual(page.songs.map(\.artist), ["Artist", "Artist"])
            expectEqual(page.continuation, "token")
        }
        expectThrowsError(try YouTubeMusicSearchClient.parseRadioPage(["error": "bad response"]))
    }

    func testBufferDeduplicatesAndExcludesAcrossPages() {
        let a = song(track(0), id: "original")
        let duplicate = song(track(0), id: "different-video")
        let b = song(track(1), id: "disliked")
        let c = song(track(2), id: "keep")
        var buffer = SongRadioBuffer()
        buffer.markSeen(a)
        buffer.append(SongRadioPage(songs: [a, duplicate, b, c, c], continuation: "next"), excluding: [b.radioIdentity])
        expectEqual(buffer.pending.map(\.id), [c.id])
        buffer.removeFirst()
        buffer.append(SongRadioPage(songs: [c], continuation: nil), excluding: [])
        expectTrue(buffer.pending.isEmpty)
    }

    func testIdentityReusesVideoIDAndMetadataWithoutMatchingOtherArtists() {
        var exact = track(0)
        exact.streamURL = URL(string: "https://aria.test/api/stream/Old%20Name%20[abcdefghijk].mp3")
        expectEqual(exact.youtubeVideoID, "abcdefghijk")
        let renamed = YouTubeMusicSongResult(id: "abcdefghijk", title: "Renamed", artist: "Other", artworkURL: nil)
        expectEqual(renamed.downloadedTrack(in: [exact])?.id, exact.id)
        let topic = YouTubeMusicSongResult(id: "another-id", title: "SONG 0", artist: "Artist - Topic", artworkURL: nil)
        expectEqual(topic.downloadedTrack(in: [exact])?.id, exact.id)
        let otherArtist = YouTubeMusicSongResult(id: "another-id", title: exact.title, artist: "Other", artworkURL: nil)
        expectNil(otherArtist.downloadedTrack(in: [exact]))
    }
}

private func fail(_ message: String, file: StaticString = #file, line: UInt = #line) -> Never {
    fatalError(message, file: file, line: line)
}
private func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}
private func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value, "Expected false", file: file, line: line)
}
private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    precondition(a == b, "Expected \(b), got \(a)", file: file, line: line)
}
private func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "Expected nil, got \(String(describing: value))", file: file, line: line)
}
private func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value != nil, "Expected a value", file: file, line: line)
}
private func expectGreaterThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    precondition(a >= b, "Expected \(a) >= \(b)", file: file, line: line)
}
private func expectLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    precondition(a <= b, "Expected \(a) <= \(b)", file: file, line: line)
}
private func expectThrowsError<T>(_ value: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try value() } catch { return }
    fail("Expected an error", file: file, line: line)
}

@main @MainActor
struct MacRadioTestRunner {
    static func main() async throws {
        setbuf(stdout, nil)
        let originalSession = UserDefaults.standard.object(forKey: "aria.playback.sessionID")
        defer { UserDefaults.standard.set(originalSession, forKey: "aria.playback.sessionID") }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testCleanupWaitsForAcceptedRadioJobAndStopsFurtherDownloads()
            try await test.tearDown()
            print("PASS: testCleanupWaitsForAcceptedRadioJobAndStopsFurtherDownloads")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testRadioStateNotifiesViewsWithoutPlaybackTicks()
            try await test.tearDown()
            print("PASS: testRadioStateNotifiesViewsWithoutPlaybackTicks")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testStopRadioKeepsPreparedQueueWhenShuffleChanges()
            try await test.tearDown()
            print("PASS: testStopRadioKeepsPreparedQueueWhenShuffleChanges")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testStartingRadioFromControllerPlaysLocally()
            try await test.tearDown()
            print("PASS: testStartingRadioFromControllerPlaysLocally")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testManualDownloadsShareRadioQueueWithoutChangingTheirOrigin()
            try await test.tearDown()
            print("PASS: testManualDownloadsShareRadioQueueWithoutChangingTheirOrigin")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testDownloadedSeedPlaysFirstAndRefillsAfterNext()
            try await test.tearDown()
            print("PASS: testDownloadedSeedPlaysFirstAndRefillsAfterNext")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testMissingSeedDownloadsBeforePlayingWithEmptyLibrary()
            try await test.tearDown()
            print("PASS: testMissingSeedDownloadsBeforePlayingWithEmptyLibrary")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testCatalogRefreshPreservesPlaybackPositionAndRadioQueue()
            try await test.tearDown()
            print("PASS: testCatalogRefreshPreservesPlaybackPositionAndRadioQueue")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testOrdinaryPlaybackCancelsDelayedRadioResults()
            try await test.tearDown()
            print("PASS: testOrdinaryPlaybackCancelsDelayedRadioResults")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testPauseWhileWaitingDoesNotAutoplayArrivingSong()
            try await test.tearDown()
            print("PASS: testPauseWhileWaitingDoesNotAutoplayArrivingSong")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testRemoveSkipsImmediatelyThenDeletesAndPersistsExclusion()
            try await test.tearDown()
            print("PASS: testRemoveSkipsImmediatelyThenDeletesAndPersistsExclusion")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testBulkDeleteRemovesOnlyFlaggedTracksAndPreservesOrdinaryPlayback()
            try await test.tearDown()
            print("PASS: testBulkDeleteRemovesOnlyFlaggedTracksAndPreservesOrdinaryPlayback")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testBulkDeleteStopsRadioAndWaitsForDownloader()
            try await test.tearDown()
            print("PASS: testBulkDeleteStopsRadioAndWaitsForDownloader")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testBulkDeleteFailureKeepsFlagsAndOffersRetry()
            try await test.tearDown()
            print("PASS: testBulkDeleteFailureKeepsFlagsAndOffersRetry")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testReusedDownloadTrackIDHandlesDifferentSavedMetadataAndDislike()
            try await test.tearDown()
            print("PASS: testReusedDownloadTrackIDHandlesDifferentSavedMetadataAndDislike")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testFailedRecommendationDownloadSkipsToNextSong()
            try await test.tearDown()
            print("PASS: testFailedRecommendationDownloadSkipsToNextSong")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testFailedDeletionSurvivesStoppingRadioAndRetriesOnRelaunch()
            try await test.tearDown()
            print("PASS: testFailedDeletionSurvivesStoppingRadioAndRetriesOnRelaunch")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try await test.testReplacingRadioCannotAppendCancelledSessionResults()
            try await test.tearDown()
            print("PASS: testReplacingRadioCannotAppendCancelledSessionResults")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            try test.testRadioParserKeepsPrimaryOrderSkipsUnavailableAndReadsContinuation()
            try await test.tearDown()
            print("PASS: testRadioParserKeepsPrimaryOrderSkipsUnavailableAndReadsContinuation")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            test.testBufferDeduplicatesAndExcludesAcrossPages()
            try await test.tearDown()
            print("PASS: testBufferDeduplicatesAndExcludesAcrossPages")
        }
        do {
            let test = MacRadioTests()
            try await test.setUp()
            test.testIdentityReusesVideoIDAndMetadataWithoutMatchingOtherArtists()
            try await test.tearDown()
            print("PASS: testIdentityReusesVideoIDAndMetadataWithoutMatchingOtherArtists")
        }
    }
}
