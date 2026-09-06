import AVFoundation
import Foundation

/// One output clock for the whole queue. Upcoming files are decoded before they are
/// scheduled; a track-end notification only updates state and never starts the next sound.
@MainActor
final class GaplessAudioPlayer {
    var onTrackChanged: ((Track) -> Void)?
    var onFinished: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPreparationChanged: ((String?) -> Void)?

    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private let files = GaplessAudioFiles()
    private var format = GaplessAudioFiles.outputFormat
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var sequence: [Track] = []
    private var sequenceIndex = 0
    private var scheduled: [ScheduledTrack] = []
    private var nextSample: AVAudioFramePosition = 0
    private var initialOffset: TimeInterval = 0
    private var lastKnownElapsed: TimeInterval = 0
    private var lastDuration: TimeInterval = 0
    private var wantsPlayback = false
    private var pendingFailure: String?
    private var configurationObserver: NSObjectProtocol?
    private var hasTap = false
    private(set) var currentTrack: Track?
    private(set) var isLoaded = false
    private var mode: RepeatMode = .off
    private var preparesAlbum = false

    var isReady: Bool { loadTask == nil && !scheduled.isEmpty }

    var volume: Float {
        get { node.volume }
        set { node.volume = min(max(newValue, 0), 1) }
    }

    var duration: TimeInterval {
        scheduled.first.map { Double($0.file.length) / format.sampleRate } ?? lastDuration
    }

    var elapsed: TimeInterval {
        guard let first = scheduled.first else { return initialOffset }
        guard let sample = node.lastRenderTime.flatMap({ node.playerTime(forNodeTime: $0)?.sampleTime }) else {
            return max(lastKnownElapsed, Double(first.fileOffset) / format.sampleRate)
        }
        lastKnownElapsed = min(Double(first.file.length) / format.sampleRate,
                               max(0, Double(sample - first.startSample + first.fileOffset) / format.sampleRate))
        return lastKnownElapsed
    }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isLoaded, let track = self.currentTrack else { return }
                self.load(track, queue: self.sequence, repeatMode: self.mode,
                          offset: self.elapsed, playing: self.wantsPlayback)
            }
        }
    }

    deinit {
        loadTask?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine.stop()
    }

    func load(_ track: Track, queue: [Track], repeatMode: RepeatMode,
              offset: TimeInterval = 0, playing: Bool = true) {
        stop()
        sequence = queue.contains(where: { $0.id == track.id }) ? queue : [track] + queue
        sequenceIndex = sequence.firstIndex(where: { $0.id == track.id }) ?? 0
        mode = repeatMode
        initialOffset = max(0, offset)
        lastKnownElapsed = initialOffset
        currentTrack = track
        preparesAlbum = Self.isAlbum(sequence)
        onPreparationChanged?(preparesAlbum ? "Preparing album for seamless playback…" : "Buffering audio…")
        wantsPlayback = playing
        isLoaded = true
        fillSchedule()
    }

    func play() {
        wantsPlayback = true
        if isReady {
            startOutput()
        } else if scheduled.isEmpty, loadTask == nil, let currentTrack {
            load(currentTrack, queue: sequence, repeatMode: mode)
        }
    }

    func pause() {
        wantsPlayback = false
        node.pause()
    }

    func stop() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        node.stop()
        scheduled.removeAll()
        nextSample = 0
        pendingFailure = nil
        wantsPlayback = false
        isLoaded = false
        currentTrack = nil
        initialOffset = 0
        lastKnownElapsed = 0
        lastDuration = 0
        onPreparationChanged?(nil)
    }

    func seek(to seconds: TimeInterval) {
        guard let currentTrack else { return }
        load(currentTrack, queue: sequence, repeatMode: mode, offset: seconds, playing: wantsPlayback)
    }

    func updateQueue(_ queue: [Track], repeatMode: RepeatMode) {
        guard isLoaded, let currentTrack else { return }
        let sameAudio = queue.map(\.streamURL) == sequence.map(\.streamURL)
        guard queue.map(\.id) != sequence.map(\.id) || !sameAudio || mode != repeatMode else { return }
        // Explicit queue edits invalidate scheduled future audio. Preserve the current position.
        load(currentTrack, queue: queue, repeatMode: repeatMode, offset: elapsed, playing: wantsPlayback)
    }

    func setAnalysisEnabled(_ enabled: Bool, handler: @escaping (AVAudioPCMBuffer) -> Void) {
        if hasTap {
            engine.mainMixerNode.removeTap(onBus: 0)
            hasTap = false
        }
        guard enabled else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            handler(buffer)
        }
        hasTap = true
    }

    private func fillSchedule() {
        guard loadTask == nil, pendingFailure == nil, isLoaded else { return }
        let token = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if self.nextSample == 0, self.scheduled.isEmpty {
                    guard let url = self.currentTrack?.streamURL else { throw GaplessAudioError.missingURL }
                    let firstURL = try await self.files.prepare(url)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    let firstFormat = try AVAudioFile(forReading: firstURL).processingFormat
                    if self.format != firstFormat {
                        self.engine.stop()
                        self.engine.disconnectNodeOutput(self.node)
                        self.engine.connect(self.node, to: self.engine.mainMixerNode, format: firstFormat)
                        self.format = firstFormat
                    }
                }
                if self.nextSample == 0, self.scheduled.isEmpty, self.preparesAlbum {
                    let remaining = self.mode == .one ? [self.sequence[self.sequenceIndex]]
                        : self.mode == .all ? self.sequence : Array(self.sequence[self.sequenceIndex...])
                    await self.files.retainOnly(self.sequence.compactMap(\.streamURL))
                    for (index, track) in remaining.enumerated() {
                        guard let url = track.streamURL else { throw GaplessAudioError.missingURL }
                        self.onPreparationChanged?("Preparing album · \(index + 1) of \(remaining.count)")
                        _ = try await self.files.prepare(url, sampleRate: self.format.sampleRate)
                        try Task.checkCancellation()
                        guard self.generation == token else { return }
                    }
                }
                let scheduleLimit = self.preparesAlbum && self.mode != .one ? max(self.sequence.count + 1, 3) : 3
                while self.scheduled.count < scheduleLimit, self.sequence.indices.contains(self.sequenceIndex) {
                    let track = self.sequence[self.sequenceIndex]
                    guard let url = track.streamURL else { throw GaplessAudioError.missingURL }
                    let preparedURL = try await self.files.prepare(url, sampleRate: self.format.sampleRate)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    let file = try AVAudioFile(forReading: preparedURL)
                    let offset = self.scheduled.isEmpty && self.nextSample == 0
                        ? AVAudioFramePosition(min(self.initialOffset * self.format.sampleRate, Double(max(0, file.length - 1)))) : 0
                    let entry = ScheduledTrack(track: track, file: file, fileOffset: offset,
                                               startSample: self.nextSample)
                    self.scheduled.append(entry)
                    self.nextSample += file.length - offset
                    self.node.scheduleSegment(
                        file, startingFrame: offset, frameCount: AVAudioFrameCount(file.length - offset),
                        at: AVAudioTime(sampleTime: entry.startSample, atRate: self.format.sampleRate),
                        // Device-playback callbacks are unavailable during offline rendering.
                        completionCallbackType: self.engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack
                    ) { [weak self] _ in
                        Task { @MainActor in self?.finished(entry.id, generation: token) }
                    }
                    switch self.mode {
                    case .one: break
                    case .all: self.sequenceIndex = (self.sequenceIndex + 1) % self.sequence.count
                    case .off: self.sequenceIndex += 1
                    }
                }
                guard self.generation == token else { return }
                self.loadTask = nil
                self.onPreparationChanged?(nil)
                if self.wantsPlayback { self.startOutput() }
                let retained = self.preparesAlbum ? self.sequence.compactMap(\.streamURL)
                    : self.scheduled.compactMap { $0.track.streamURL }
                await self.files.retainOnly(retained)
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.loadTask = nil
                self.pendingFailure = error.localizedDescription
                self.onPreparationChanged?(nil)
                if self.scheduled.isEmpty {
                    self.fail(error.localizedDescription)
                } else if self.wantsPlayback {
                    // Let already buffered music finish; report the failed next track at its boundary.
                    self.startOutput()
                }
            }
        }
    }

    private func startOutput() {
        guard !scheduled.isEmpty else { return }
        do {
            if !engine.isRunning { try engine.start() }
            if !node.isPlaying { node.play() }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func finished(_ id: UUID, generation token: UUID) {
        guard generation == token, let index = scheduled.firstIndex(where: { $0.id == id }) else { return }
        let completed = scheduled[index]
        // Completion tasks may arrive out of order when the main thread is busy.
        scheduled.removeFirst(index + 1)
        lastDuration = Double(completed.file.length) / format.sampleRate
        lastKnownElapsed = 0
        if let next = scheduled.first {
            currentTrack = next.track
            onTrackChanged?(next.track)
            fillSchedule()
        } else if let pendingFailure {
            fail(pendingFailure)
        } else if sequence.indices.contains(sequenceIndex) {
            // A network stall is a buffering condition, never a reason to skip part of a song.
            let next = sequence[sequenceIndex]
            currentTrack = next
            onPreparationChanged?("Buffering audio…")
            initialOffset = 0
            node.stop()
            nextSample = 0
            onTrackChanged?(next)
            fillSchedule()
        } else {
            initialOffset = Double(completed.file.length) / format.sampleRate
            wantsPlayback = false
            node.stop()
            onFinished?()
        }
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }

    static func isAlbum(_ tracks: [Track]) -> Bool {
        guard let first = tracks.first, tracks.count > 1 else { return false }
        if let id = first.serverAlbumID, !id.isEmpty {
            return tracks.allSatisfy { $0.serverAlbumID == id }
        }
        let name = first.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "Unknown Album" else { return false }
        return tracks.allSatisfy { $0.album == first.album && $0.year == first.year }
    }

    private struct ScheduledTrack {
        let id = UUID()
        let track: Track
        let file: AVAudioFile
        let fileOffset: AVAudioFramePosition
        let startSample: AVAudioFramePosition
    }
}

enum GaplessAudioError: LocalizedError {
    case missingURL
    case invalidResponse
    case emptyAudio
    case conversion

    var errorDescription: String? {
        switch self {
        case .missingURL: "This song is missing a playable stream URL."
        case .invalidResponse: "The song server could not provide the audio file."
        case .emptyAudio: "This file contains no playable audio."
        case .conversion: "Aria could not decode this audio file for continuous playback."
        }
    }
}
