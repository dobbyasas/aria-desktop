import AVFoundation
import Combine
import Foundation

@MainActor
final class TrackMetadataEditorSession: ObservableObject, Identifiable {
    let id = UUID()
    let originalTrack: Track
    @Published var draft: TrackMetadataDraft
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?

    init(track: Track) {
        originalTrack = track
        draft = TrackMetadataDraft(track: track)
    }
}

@MainActor
final class MacPlayerViewModel: ObservableObject {
    @Published private(set) var catalog: [Track] = []
    @Published private(set) var albums: [AriaAlbum] = []
    @Published private(set) var playlists: [AriaPlaylist] = []
    @Published private(set) var queue: [Track] = []
    @Published private(set) var isCatalogLoading = false
    @Published private(set) var catalogErrorMessage: String?
    @Published private(set) var playbackErrorMessage: String?
    @Published private(set) var downloadJob: AriaDownloadJob?
    @Published private(set) var isDownloadStarting = false
    @Published private(set) var downloadErrorMessage: String?
    @Published var currentTrack: Track?
    @Published var elapsed: TimeInterval = 0
    @Published var isPlaying = false
    @Published var isShuffleEnabled = false
    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var metadataEditorSession: TrackMetadataEditorSession?
    @Published var volume: Double = 0.86 {
        didSet {
            audioPlayer?.volume = Float(min(max(volume, 0), 1))
        }
    }

    private let serverClient: AriaServerClient
    private var audioPlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var timer: AnyCancellable?
    private var downloadPollTask: Task<Void, Never>?
    private var orderedQueue: [Track] = []

    init(serverClient: AriaServerClient = AriaServerClient()) {
        self.serverClient = serverClient

        Task { [weak self] in
            await self?.refreshCatalog()
        }
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }

        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }

        timer?.cancel()
        downloadPollTask?.cancel()
    }

    var progress: Double {
        let duration = currentDuration
        guard duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    var upNext: [Track] {
        guard let currentTrack, let index = queue.firstIndex(where: { $0.id == currentTrack.id }) else {
            return queue
        }

        let nextIndex = queue.index(after: index)
        guard nextIndex < queue.endIndex else { return [] }
        return Array(queue[nextIndex...])
    }

    var canSkipToNextTrack: Bool {
        guard let currentTrack else { return false }
        guard let index = queue.firstIndex(where: { $0.id == currentTrack.id }) else { return queue.count > 1 }
        return queue.index(after: index) < queue.endIndex || repeatMode == .all
    }

    var canSkipToPreviousTrack: Bool {
        guard let currentTrack, let index = queue.firstIndex(where: { $0.id == currentTrack.id }) else { return false }
        return index > queue.startIndex || elapsed > 3 || repeatMode == .all
    }

    func refreshCatalog() async {
        isCatalogLoading = true
        catalogErrorMessage = nil
        await AriaArtworkCache.shared.removeExpiredArtwork()

        do {
            let tracks = try await serverClient.fetchTracks()
            replaceCatalog(with: tracks)
        } catch {
            catalogErrorMessage = error.localizedDescription
        }

        isCatalogLoading = false
    }

    func play(_ track: Track, from collection: [Track]? = nil) {
        playbackErrorMessage = nil

        if let collection, !collection.isEmpty {
            setPlaybackCollection(collection, ensuring: track)
        } else if queue.isEmpty {
            setPlaybackCollection([track], ensuring: track)
        } else if !queue.contains(where: { $0.id == track.id }) {
            queue.insert(track, at: 0)
            orderedQueue.insert(track, at: 0)
        }

        if isShuffleEnabled {
            shuffleQueue(keeping: track)
        }

        beginPlayback(for: freshestVersion(of: track))
    }

    func playPause() {
        guard let currentTrack else {
            if let firstTrack = catalog.first {
                play(firstTrack, from: catalog)
            }
            return
        }

        if audioPlayer == nil {
            beginPlayback(for: currentTrack)
            return
        }

        isPlaying.toggle()
        if isPlaying {
            playbackErrorMessage = nil
            audioPlayer?.play()
            startTimer()
        } else {
            audioPlayer?.pause()
            stopTimer()
        }
    }

    func next() {
        guard let currentTrack else { return }

        if repeatMode == .one {
            restart(currentTrack)
            return
        }

        if let nextTrack = orderedNext(after: currentTrack) {
            beginPlayback(for: nextTrack)
        } else if repeatMode == .all, let firstTrack = queue.first {
            beginPlayback(for: firstTrack)
        } else {
            elapsed = currentDuration
            isPlaying = false
            audioPlayer?.pause()
            stopTimer()
        }
    }

    func previous() {
        guard let currentTrack else { return }

        if elapsed > 3 {
            seek(toProgress: 0)
            return
        }

        guard let currentIndex = queue.firstIndex(where: { $0.id == currentTrack.id }) else {
            elapsed = 0
            return
        }

        if currentIndex > queue.startIndex {
            beginPlayback(for: queue[queue.index(before: currentIndex)])
        } else if repeatMode == .all, let lastTrack = queue.last {
            beginPlayback(for: lastTrack)
        } else {
            elapsed = 0
        }
    }

    func seek(toProgress progress: Double) {
        let duration = currentDuration
        guard duration > 0 else { return }

        let targetTime = min(max(progress, 0), 1) * duration
        elapsed = targetTime
        audioPlayer?.seek(to: CMTime(seconds: targetTime, preferredTimescale: 600))
    }

    func toggleShuffle() {
        if isShuffleEnabled {
            isShuffleEnabled = false
            restoreQueueOrder()
        } else {
            isShuffleEnabled = true
            shuffleQueue(keeping: currentTrack)
        }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
    }

    func playNext(_ track: Track) {
        guard currentTrack?.id != track.id else { return }
        queue.removeAll { $0.id == track.id }
        orderedQueue.removeAll { $0.id == track.id }

        guard let currentTrack, let currentIndex = queue.firstIndex(where: { $0.id == currentTrack.id }) else {
            queue.insert(track, at: 0)
            orderedQueue.insert(track, at: 0)
            return
        }

        queue.insert(track, at: queue.index(after: currentIndex))

        if let orderedIndex = orderedQueue.firstIndex(where: { $0.id == currentTrack.id }) {
            orderedQueue.insert(track, at: orderedQueue.index(after: orderedIndex))
        } else {
            orderedQueue.insert(track, at: 0)
        }
    }

    func addToFront(_ track: Track) {
        playNext(track)
    }

    func removeFromQueue(_ track: Track) {
        guard currentTrack?.id != track.id else { return }
        queue.removeAll { $0.id == track.id }
        orderedQueue.removeAll { $0.id == track.id }
    }

    func dismissPlaybackError() {
        playbackErrorMessage = nil
    }

    func startDownload(link: String, album: String, albumArtist: String, year: String) async {
        let request = AriaDownloadRequest(
            link: link.trimmingCharacters(in: .whitespacesAndNewlines),
            album: album.trimmingCharacters(in: .whitespacesAndNewlines),
            albumArtist: albumArtist.trimmingCharacters(in: .whitespacesAndNewlines),
            year: year.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        isDownloadStarting = true
        downloadErrorMessage = nil

        do {
            let job = try await serverClient.startDownload(request)
            downloadJob = job
            isDownloadStarting = false
            beginDownloadPolling(id: job.id)
        } catch {
            downloadErrorMessage = error.localizedDescription
            isDownloadStarting = false
        }
    }

    func clearFinishedDownload() {
        guard downloadJob?.isFinished == true else { return }
        downloadJob = nil
        downloadErrorMessage = nil
    }

    func editMetadata(for track: Track) {
        metadataEditorSession = TrackMetadataEditorSession(track: freshestVersion(of: track))
    }

    func cancelMetadataEditing() {
        metadataEditorSession = nil
    }

    func reloadMetadata(for session: TrackMetadataEditorSession) async {
        session.isLoading = true
        session.errorMessage = nil
        await loadMetadata(for: session)
    }

    func saveMetadata(for session: TrackMetadataEditorSession) async {
        session.errorMessage = nil

        do {
            let update = try session.draft.validatedUpdate()
            session.isSaving = true
            let updatedTrack = try await serverClient.updateTrackMetadata(
                for: session.originalTrack,
                metadata: update
            )
            applyUpdatedTrack(updatedTrack)
            session.isSaving = false
            metadataEditorSession = nil
        } catch {
            session.errorMessage = metadataSaveErrorMessage(for: error)
            session.isSaving = false
        }
    }

    private var currentDuration: TimeInterval {
        if let duration = currentTrack?.duration, duration > 0 {
            return duration
        }

        let playerDuration = audioPlayer?.currentItem?.duration.seconds ?? 0
        return playerDuration.isFinite ? max(playerDuration, 0) : 0
    }

    private func loadMetadata(for session: TrackMetadataEditorSession) async {
        do {
            let serverTrack = try await serverClient.fetchTrackMetadata(for: session.originalTrack)
            guard metadataEditorSession?.id == session.id else { return }
            session.draft = TrackMetadataDraft(track: serverTrack)
            session.isLoading = false
        } catch {
            guard metadataEditorSession?.id == session.id else { return }
            session.errorMessage = metadataLoadErrorMessage(for: error)
            session.isLoading = false
        }
    }

    private func metadataLoadErrorMessage(for error: Error) -> String {
        guard isUnsupportedMetadataEndpoint(error) else {
            return "Using local metadata. Server detail load failed: \(error.localizedDescription)"
        }

        return "This server does not expose per-song metadata loading yet, so Aria is using the catalog data already loaded."
    }

    private func beginDownloadPolling(id: String) {
        downloadPollTask?.cancel()
        downloadPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_250_000_000)
                } catch {
                    return
                }

                guard let self else { return }
                await self.refreshDownloadStatus(id: id)

                if self.downloadJob?.isFinished == true {
                    return
                }
            }
        }
    }

    private func refreshDownloadStatus(id: String) async {
        do {
            let job = try await serverClient.fetchDownloadStatus(id: id)
            downloadJob = job

            if job.isFinished {
                downloadPollTask?.cancel()

                if job.isSuccessful {
                    await refreshCatalog()
                }
            }
        } catch {
            downloadErrorMessage = "Download status failed: \(error.localizedDescription)"
        }
    }

    private func metadataSaveErrorMessage(for error: Error) -> String {
        guard isUnsupportedMetadataEndpoint(error) else {
            return error.localizedDescription
        }

        return "This server does not support metadata updates yet. Add PATCH or PUT /api/tracks/{id} on the server, then try Save again."
    }

    private func isUnsupportedMetadataEndpoint(_ error: Error) -> Bool {
        guard case AriaServerError.badStatus(let statusCode) = error else {
            return false
        }

        return [404, 405, 501].contains(statusCode)
    }

    private func beginPlayback(for track: Track) {
        let track = freshestVersion(of: track)
        currentTrack = track
        elapsed = 0

        guard startPlayback(for: track) else {
            isPlaying = false
            stopTimer()
            return
        }

        isPlaying = true
        startTimer()
    }

    private func restart(_ track: Track) {
        if let audioPlayer, currentTrack?.id == track.id {
            elapsed = 0
            isPlaying = true
            playbackErrorMessage = nil
            audioPlayer.seek(to: .zero)
            audioPlayer.play()
            startTimer()
        } else {
            beginPlayback(for: track)
        }
    }

    private func startPlayback(for track: Track) -> Bool {
        audioPlayer?.pause()
        removeItemObservers()

        guard let streamURL = track.streamURL else {
            audioPlayer = nil
            playbackErrorMessage = "This song is missing a playable stream URL."
            return false
        }

        let item = AVPlayerItem(url: streamURL)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(min(max(volume, 0), 1))
        audioPlayer = player

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.next()
            }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in
                self?.handlePlaybackFailure(error?.localizedDescription)
            }
        }

        player.play()
        return true
    }

    private func startTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, isPlaying else { return }

                if let seconds = audioPlayer?.currentTime().seconds, seconds.isFinite {
                    elapsed = max(seconds, 0)
                }

                updateCurrentTrackDurationIfNeeded()
            }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func removeItemObservers() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
    }

    private func handlePlaybackFailure(_ message: String?) {
        playbackErrorMessage = message ?? "Aria could not play this song."
        isPlaying = false
        stopTimer()
    }

    private func orderedNext(after track: Track) -> Track? {
        guard let currentIndex = queue.firstIndex(where: { $0.id == track.id }) else { return queue.first }
        let nextIndex = queue.index(after: currentIndex)
        guard nextIndex < queue.endIndex else { return nil }
        return queue[nextIndex]
    }

    private func shuffleQueue(keeping track: Track?) {
        guard queue.count > 1 else { return }
        guard let track, let currentIndex = queue.firstIndex(where: { $0.id == track.id }) else {
            queue.shuffle()
            return
        }

        var otherTracks = queue
        otherTracks.remove(at: currentIndex)
        queue = [track] + otherTracks.shuffled()
    }

    private func restoreQueueOrder() {
        guard !orderedQueue.isEmpty else { return }
        let current = currentTrack
        queue = refreshedOrder(from: orderedQueue, using: catalog, preserving: current)

        if let current, !queue.contains(where: { $0.id == current.id }) {
            queue.insert(current, at: 0)
        }
    }

    private func setPlaybackCollection(_ collection: [Track], ensuring track: Track) {
        var nextQueue = uniqued(collection)

        if !nextQueue.contains(where: { $0.id == track.id }) {
            nextQueue.insert(track, at: 0)
        }

        orderedQueue = nextQueue
        queue = nextQueue
    }

    private func replaceCatalog(with tracks: [Track]) {
        let oldCurrent = currentTrack
        let playerAlreadyLoaded = audioPlayer != nil

        catalog = tracks
        rebuildDerivedCollections()

        orderedQueue = refreshedOrder(
            from: orderedQueue.isEmpty ? tracks : orderedQueue,
            using: tracks,
            preserving: oldCurrent
        )
        queue = refreshedOrder(
            from: queue.isEmpty ? tracks : queue,
            using: tracks,
            preserving: oldCurrent
        )

        if let oldCurrent, let refreshedTrack = tracks.first(where: { $0.id == oldCurrent.id }) {
            currentTrack = refreshedTrack
        } else if playerAlreadyLoaded {
            currentTrack = oldCurrent
        } else {
            currentTrack = tracks.first
        }

        if let currentTrack, !queue.contains(where: { $0.id == currentTrack.id }) {
            queue.insert(currentTrack, at: 0)
        }

        if tracks.isEmpty {
            currentTrack = nil
            elapsed = 0
            isPlaying = false
            stopTimer()
        }
    }

    private func refreshedOrder(from existing: [Track], using catalog: [Track], preserving current: Track?) -> [Track] {
        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var result: [Track] = []

        for track in existing {
            let candidate = byID[track.id] ?? (track.id == current?.id ? current : nil)
            guard let candidate, seen.insert(candidate.id).inserted else { continue }
            result.append(candidate)
        }

        for track in catalog where seen.insert(track.id).inserted {
            result.append(track)
        }

        return result
    }

    private func freshestVersion(of track: Track) -> Track {
        catalog.first { $0.id == track.id }
            ?? queue.first { $0.id == track.id }
            ?? track
    }

    private func rebuildDerivedCollections() {
        albums = Self.albums(from: catalog)
        playlists = Self.playlists(from: catalog)
    }

    private static func albums(from catalog: [Track]) -> [AriaAlbum] {
        Dictionary(grouping: catalog) { track in
            track.album.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        }
        .values
        .compactMap { tracks in
            let sortedTracks = tracks.sortedForAlbumPlayback()
            guard let firstTrack = sortedTracks.first else { return nil }

            return AriaAlbum(
                title: firstTrack.album,
                artist: displayArtist(for: sortedTracks),
                year: sortedTracks.compactMap { $0.year > 0 ? $0.year : nil }.min() ?? 0,
                tracks: sortedTracks
            )
        }
        .sorted { firstAlbum, secondAlbum in
            let artistOrder = firstAlbum.artist.localizedCaseInsensitiveCompare(secondAlbum.artist)
            if artistOrder != .orderedSame {
                return artistOrder == .orderedAscending
            }

            if firstAlbum.year != secondAlbum.year, firstAlbum.year > 0, secondAlbum.year > 0 {
                return firstAlbum.year < secondAlbum.year
            }

            return firstAlbum.title.localizedCaseInsensitiveCompare(secondAlbum.title) == .orderedAscending
        }
    }

    private static func displayArtist(for tracks: [Track]) -> String {
        let artistCounts = Dictionary(grouping: tracks) { track in
            track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .mapValues(\.count)
        .filter { !$0.key.isEmpty }

        guard let mostCommon = artistCounts.max(by: { first, second in
            if first.value == second.value {
                return first.key.localizedCaseInsensitiveCompare(second.key) == .orderedDescending
            }

            return first.value < second.value
        }) else {
            return "Unknown Artist"
        }

        let competingArtistCount = artistCounts
            .filter { $0.key != mostCommon.key }
            .map(\.value)
            .max() ?? 0

        return mostCommon.value > competingArtistCount ? mostCommon.key : "Various Artists"
    }

    private static func playlists(from tracks: [Track]) -> [AriaPlaylist] {
        guard !tracks.isEmpty else { return [] }

        return [
            AriaPlaylist(
                title: "All Songs",
                subtitle: subtitle(forTrackCount: tracks.count),
                tracks: tracks
            )
        ]
    }

    private static func subtitle(forTrackCount count: Int) -> String {
        count == 1 ? "1 song" : "\(count) songs"
    }

    private func updateCurrentTrackDurationIfNeeded() {
        guard let currentTrack, currentTrack.duration <= 0 else { return }
        let duration = audioPlayer?.currentItem?.duration.seconds ?? 0
        guard duration.isFinite, duration > 0 else { return }

        updateDuration(duration, for: currentTrack.id)
    }

    private func updateDuration(_ duration: TimeInterval, for trackID: UUID) {
        if currentTrack?.id == trackID {
            currentTrack?.duration = duration
        }

        replaceDuration(in: &catalog, duration: duration, trackID: trackID)
        replaceDuration(in: &queue, duration: duration, trackID: trackID)
        replaceDuration(in: &orderedQueue, duration: duration, trackID: trackID)
        rebuildDerivedCollections()
    }

    private func applyUpdatedTrack(_ updatedTrack: Track) {
        if currentTrack?.id == updatedTrack.id {
            currentTrack = updatedTrack
        }

        replaceTrack(in: &catalog, with: updatedTrack)
        replaceTrack(in: &queue, with: updatedTrack)
        replaceTrack(in: &orderedQueue, with: updatedTrack)
        rebuildDerivedCollections()
    }

    private func replaceTrack(in tracks: inout [Track], with updatedTrack: Track) {
        guard let index = tracks.firstIndex(where: { $0.id == updatedTrack.id }) else { return }
        tracks[index] = updatedTrack
    }

    private func replaceDuration(in tracks: inout [Track], duration: TimeInterval, trackID: UUID) {
        if let index = tracks.firstIndex(where: { $0.id == trackID }) {
            tracks[index].duration = duration
        }
    }

    private func uniqued(_ tracks: [Track]) -> [Track] {
        var seen = Set<UUID>()
        return tracks.filter { track in
            seen.insert(track.id).inserted
        }
    }
}

private extension Array where Element == Track {
    func sortedForAlbumPlayback() -> [Track] {
        sorted { firstTrack, secondTrack in
            switch (firstTrack.trackNumber, secondTrack.trackNumber) {
            case let (firstNumber?, secondNumber?) where firstNumber != secondNumber:
                return firstNumber < secondNumber
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return firstTrack.title.localizedCaseInsensitiveCompare(secondTrack.title) == .orderedAscending
            }
        }
    }
}
