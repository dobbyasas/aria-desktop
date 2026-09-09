import AVFoundation
import Foundation

/// A small lookahead on one engine clock. Each track owns a player node so future
/// audio can be replaced without stopping or rescheduling the audible track.
@MainActor
final class GaplessAudioPlayer {
    var onTrackChanged: ((Track) -> Void)?
    var onFinished: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPreparationChanged: ((String?) -> Void)?

    typealias PrepareFile = @Sendable (URL, Double?) async throws -> URL

    private let engine: AVAudioEngine
    private let nodes = (0..<3).map { _ in AVAudioPlayerNode() }
    private let files = GaplessAudioFiles()
    private let prepareFile: PrepareFile?
    private var format = GaplessAudioFiles.outputFormat
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchTrack: Track?
    private var generation = UUID()
    private var prefetchGeneration = UUID()
    private var sequence: [Track] = []
    private var sequenceIndex = 0
    private var scheduled: [ScheduledTrack] = []
    private var initialOffset: TimeInterval = 0
    private var lastKnownElapsed: TimeInterval = 0
    private var lastDuration: TimeInterval = 0
    private var wantsPlayback = false
    private var pendingFailure: String?
    private var configurationObserver: NSObjectProtocol?
    private var hasTap = false
    private var outputAnchor: AVAudioFramePosition?
    private(set) var currentTrack: Track?
    private(set) var isLoaded = false
    private var mode: RepeatMode = .off

    var isReady: Bool { !scheduled.isEmpty }
    var isPreparing: Bool { loadTask != nil || prefetchTask != nil }

    var volume: Float = 1 {
        didSet { nodes.forEach { $0.volume = min(max(volume, 0), 1) } }
    }

    var duration: TimeInterval {
        scheduled.first.map { Double($0.file.length) / format.sampleRate } ?? lastDuration
    }

    var elapsed: TimeInterval {
        guard let first = scheduled.first else { return initialOffset }
        guard let sample = playerSample(first.node) else {
            return max(lastKnownElapsed, Double(first.fileOffset) / format.sampleRate)
        }
        lastKnownElapsed = min(Double(first.file.length) / format.sampleRate,
                               max(0, Double(sample + first.fileOffset) / format.sampleRate))
        return lastKnownElapsed
    }

    init(engine: AVAudioEngine = AVAudioEngine(), prepareFile: PrepareFile? = nil) {
        self.engine = engine
        self.prepareFile = prepareFile
        for node in nodes {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
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
        prefetchTask?.cancel()
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
        wantsPlayback = playing
        isLoaded = true
        onPreparationChanged?("Buffering audio…")
        let token = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = track.streamURL else { throw GaplessAudioError.missingURL }
                let preparedURL = try await self.prepare(url, sampleRate: nil)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let file = try AVAudioFile(forReading: preparedURL)
                if self.format != file.processingFormat {
                    self.format = file.processingFormat
                    for node in self.nodes {
                        self.engine.disconnectNodeOutput(node)
                        self.engine.connect(node, to: self.engine.mainMixerNode, format: self.format)
                    }
                }
                self.append(track, file: file)
                self.advanceSequence()
                self.loadTask = nil
                self.onPreparationChanged?(nil)
                // The selected song is the only preparation on the startup path.
                if self.wantsPlayback { self.startOutput() }
                self.fillSchedule()
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    func play() {
        wantsPlayback = true
        if isReady {
            startOutput()
        } else if loadTask == nil, prefetchTask == nil, let currentTrack {
            load(currentTrack, queue: sequence, repeatMode: mode)
        }
    }

    func pause() {
        lastKnownElapsed = elapsed
        wantsPlayback = false
        engine.pause()
        nodes.forEach { $0.pause() }
        outputAnchor = nil
    }

    func stop() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        cancelPrefetch()
        nodes.forEach { $0.stop() }
        engine.stop()
        scheduled.removeAll()
        outputAnchor = nil
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
        let updated = queue.contains(where: { $0.id == currentTrack.id }) ? queue : [currentTrack] + queue
        guard !Self.sameAudio(updated, sequence) || mode != repeatMode else { return }

        // A completion may be waiting on the main actor after audio crossed a boundary.
        // Keep whichever track is actually rendering before invalidating future nodes.
        reconcilePlaybackPosition()
        guard let active = self.currentTrack else { return }
        sequence = updated.contains(where: { $0.id == active.id }) ? updated : [active] + updated
        mode = repeatMode
        sequenceIndex = sequence.firstIndex(where: { $0.id == active.id }) ?? 0
        pendingFailure = nil
        if let first = scheduled.first {
            advanceSequence()
            var keepCount = 1
            for entry in scheduled.dropFirst() {
                guard sequence.indices.contains(sequenceIndex),
                      Self.sameAudio(entry.track, sequence[sequenceIndex]) else { break }
                keepCount += 1
                advanceSequence()
            }
            let discarded = Array(scheduled.dropFirst(keepCount))
            scheduled.removeLast(scheduled.count - keepCount)
            discarded.forEach { $0.node.stop() }
            lastKnownElapsed = min(lastKnownElapsed, Double(first.file.length) / format.sampleRate)
        }
        // Do not restart a download when an edit leaves the next requested song intact.
        if let preparing = prefetchTrack,
           !sequence.indices.contains(sequenceIndex) || !Self.sameAudio(preparing, sequence[sequenceIndex]) {
            cancelPrefetch()
        }
        // Startup has its own task and keeps downloading the selected song through edits.
        if loadTask == nil { fillSchedule() }
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

    private func prepare(_ url: URL, sampleRate: Double?) async throws -> URL {
        if let prepareFile { return try await prepareFile(url, sampleRate) }
        return try await files.prepare(url, sampleRate: sampleRate)
    }

    private func cancelPrefetch() {
        prefetchGeneration = UUID()
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchTrack = nil
    }

    private func fillSchedule() {
        guard loadTask == nil, prefetchTask == nil, pendingFailure == nil, isLoaded else { return }
        let token = generation
        let prefetchToken = prefetchGeneration
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                while self.scheduled.count < self.nodes.count, self.sequence.indices.contains(self.sequenceIndex) {
                    let track = self.sequence[self.sequenceIndex]
                    self.prefetchTrack = track
                    guard let url = track.streamURL else { throw GaplessAudioError.missingURL }
                    let preparedURL = try await self.prepare(url, sampleRate: self.format.sampleRate)
                    try Task.checkCancellation()
                    guard self.generation == token, self.prefetchGeneration == prefetchToken else { return }
                    let file = try AVAudioFile(forReading: preparedURL)
                    self.append(track, file: file)
                    self.advanceSequence()
                    self.onPreparationChanged?(nil)
                    if self.wantsPlayback { self.startOutput() }
                }
                self.prefetchTask = nil
                self.prefetchTrack = nil
                await self.files.retainOnly(self.scheduled.compactMap { $0.track.streamURL })
            } catch {
                guard self.generation == token, self.prefetchGeneration == prefetchToken, !Task.isCancelled else { return }
                self.prefetchTask = nil
                self.prefetchTrack = nil
                self.pendingFailure = error.localizedDescription
                // A failed future download must not prevent the buffered music from playing.
                if self.scheduled.isEmpty { self.fail(error.localizedDescription) }
            }
        }
    }

    private func append(_ track: Track, file: AVAudioFile) {
        guard let node = nodes.first(where: { candidate in !scheduled.contains { $0.node === candidate } }) else { return }
        let offset = scheduled.isEmpty
            ? AVAudioFramePosition(min(initialOffset * format.sampleRate, Double(max(0, file.length - 1)))) : 0
        let entry = ScheduledTrack(track: track, file: file, node: node, fileOffset: offset,
                                   startSample: scheduled.last?.endSample ?? 0)
        scheduled.append(entry)
        scheduleSegment(entry)
    }

    private func scheduleSegment(_ entry: ScheduledTrack) {
        let token = generation
        let scheduleID = UUID()
        let entryID = entry.id
        entry.scheduleID = scheduleID
        entry.node.scheduleSegment(
            entry.file, startingFrame: entry.fileOffset,
            frameCount: AVAudioFrameCount(entry.file.length - entry.fileOffset), at: nil,
            completionCallbackType: engine.isInManualRenderingMode ? .dataRendered : .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in self?.finished(entryID, generation: token, scheduleID: scheduleID) }
        }
    }

    private func advanceSequence() {
        switch mode {
        case .one: break
        case .all: sequenceIndex = (sequenceIndex + 1) % sequence.count
        case .off: sequenceIndex += 1
        }
    }

    private func startOutput() {
        guard let first = scheduled.first else { return }
        do {
            if !engine.isRunning {
                // Resume only the current node's timeline; future nodes are reset below.
                let played = max(0, playerSample(first.node) ?? 0)
                try engine.start()
                let now = engine.isInManualRenderingMode ? engine.manualRenderingSampleTime
                    : AVAudioFramePosition((first.node.lastRenderTime?.sampleTime ?? 0))
                // A short device lead lets all nodes share an exact start frame.
                let lead = engine.isInManualRenderingMode ? 0 : AVAudioFramePosition(format.sampleRate * 0.02)
                outputAnchor = now + lead - first.startSample - played
                first.node.play(at: AVAudioTime(sampleTime: now + lead, atRate: format.sampleRate))
                for entry in scheduled.dropFirst() {
                    // Pausing a node before its future start must not lose its start delay.
                    entry.node.stop()
                    scheduleSegment(entry)
                    playUpcoming(entry)
                }
            } else {
                for entry in scheduled where !entry.node.isPlaying { playUpcoming(entry) }
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func playUpcoming(_ entry: ScheduledTrack) {
        guard let first = scheduled.first, let outputAnchor else { return }
        let time = first.node.nodeTime(forPlayerTime: AVAudioTime(
            sampleTime: entry.startSample - first.startSample, atRate: format.sampleRate
        )) ?? AVAudioTime(sampleTime: outputAnchor + entry.startSample, atRate: format.sampleRate)
        entry.node.play(at: time)
    }

    private func playerSample(_ node: AVAudioPlayerNode) -> AVAudioFramePosition? {
        node.lastRenderTime.flatMap { node.playerTime(forNodeTime: $0)?.sampleTime }
    }

    private func reconcilePlaybackPosition() {
        guard let first = scheduled.first, let sample = playerSample(first.node),
              let last = scheduled.last(where: { $0.endSample <= first.startSample + sample }) else { return }
        finished(last.id, generation: generation)
    }

    private func finished(_ id: UUID, generation token: UUID, scheduleID: UUID? = nil) {
        guard generation == token, let index = scheduled.firstIndex(where: { $0.id == id }),
              scheduleID == nil || scheduled[index].scheduleID == scheduleID else { return }
        let completed = scheduled[index]
        let retired = Array(scheduled.prefix(index + 1))
        scheduled.removeFirst(index + 1)
        retired.forEach { $0.node.stop() }
        lastDuration = Double(completed.file.length) / format.sampleRate
        lastKnownElapsed = 0
        initialOffset = 0
        if let next = scheduled.first {
            currentTrack = next.track
            onTrackChanged?(next.track)
            fillSchedule()
        } else if let pendingFailure {
            fail(pendingFailure)
        } else if sequence.indices.contains(sequenceIndex) {
            let next = sequence[sequenceIndex]
            currentTrack = next
            outputAnchor = nil
            engine.pause()
            onPreparationChanged?("Buffering audio…")
            onTrackChanged?(next)
            fillSchedule()
        } else {
            initialOffset = Double(completed.file.length) / format.sampleRate
            wantsPlayback = false
            outputAnchor = nil
            engine.stop()
            onFinished?()
        }
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }

    private static func sameAudio(_ lhs: Track, _ rhs: Track) -> Bool {
        lhs.id == rhs.id && lhs.streamURL == rhs.streamURL
    }

    private static func sameAudio(_ lhs: [Track], _ rhs: [Track]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { sameAudio($0, $1) }
    }

    private final class ScheduledTrack {
        let id = UUID()
        var scheduleID = UUID()
        let track: Track
        let file: AVAudioFile
        let node: AVAudioPlayerNode
        let fileOffset: AVAudioFramePosition
        let startSample: AVAudioFramePosition
        var endSample: AVAudioFramePosition { startSample + file.length - fileOffset }

        init(track: Track, file: AVAudioFile, node: AVAudioPlayerNode,
             fileOffset: AVAudioFramePosition, startSample: AVAudioFramePosition) {
            self.track = track
            self.file = file
            self.node = node
            self.fileOffset = fileOffset
            self.startSample = startSample
        }
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
