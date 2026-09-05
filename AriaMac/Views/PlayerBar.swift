import SwiftUI

struct MacPlaybackSessionMenu: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    var body: some View {
        Menu {
            Section("Playback session") {
                Label(player.playbackSessionTitle, systemImage: sessionSymbol)
                if let error = player.playbackSessionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                }
            }

            if !player.playbackDevices.isEmpty {
                Section("Connected devices") {
                    ForEach(player.playbackDevices) { device in
                        Label(
                            device.isHost ? "\(device.name) · playing" : device.name,
                            systemImage: device.isHost ? "speaker.wave.2.fill" : deviceSymbol(for: device)
                        )
                    }
                }
            }

            Divider()

            if player.isSharedPlaybackSession {
                Button("Listen Separately on This Mac", systemImage: "speaker.wave.2.circle") {
                    player.startSeparatePlaybackSession()
                }
            } else {
                Button("Join Shared Session", systemImage: "rectangle.connected.to.line.below") {
                    player.joinSharedPlaybackSession()
                }
            }
        } label: {
            Image(systemName: sessionSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(player.playbackSessionError == nil ? Color.ariaTextSecondary : Color.orange)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(player.playbackSessionTitle)
        .accessibilityLabel(player.playbackSessionTitle)
    }

    private var sessionSymbol: String {
        if player.playbackSessionRole == nil {
            return "antenna.radiowaves.left.and.right"
        }
        if player.isRemoteController {
            return "iphone.and.arrow.forward"
        }
        return player.isSharedPlaybackSession ? "speaker.wave.2.fill" : "headphones"
    }

    private func deviceSymbol(for device: PlaybackDevice) -> String {
        device.platform == "macOS" ? "desktopcomputer" : "iphone"
    }
}

struct PlayerBar: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let playbackError = player.playbackErrorMessage {
                InlinePlaybackError(message: playbackError)
            }

            if let message = player.playbackPreparationMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(message).font(.caption).foregroundStyle(Color.ariaTextSecondary)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
            }

            Divider()
                .overlay(Color.ariaDivider)

            ViewThatFits(in: .horizontal) {
                expandedLayout
                compactLayout
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(Color.ariaSurface)
        }
    }

    private var expandedLayout: some View {
        HStack(spacing: 16) {
            currentTrackSummary
                .frame(minWidth: 210, idealWidth: 280, maxWidth: 340, alignment: .leading)

            Spacer(minLength: 8)

            VStack(spacing: 9) {
                transportControls
                progressArea
            }
            .frame(minWidth: 280, idealWidth: 440, maxWidth: 620)

            Spacer(minLength: 8)

            MacPlaybackSessionMenu()

            volumeControl
                .frame(width: 120)
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                currentTrackSummary
                    .frame(maxWidth: .infinity, alignment: .leading)

                MacPlaybackSessionMenu()

                volumeControl
                    .frame(width: 118)
            }

            VStack(spacing: 9) {
                transportControls
                progressArea
            }
        }
    }

    private var currentTrackSummary: some View {
        HStack(spacing: 12) {
            if let track = player.currentTrack {
                ArtworkView(track: track, size: 48, cornerRadius: 7)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ariaTextPrimary)
                        .lineLimit(1)

                    HStack(spacing: 0) {
                        ArtistNameLink(name: track.artist)
                        Text(" - \(track.album)")
                    }
                        .font(.caption)
                        .foregroundStyle(Color.ariaTextSecondary)
                        .lineLimit(1)
                }
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 54, height: 54)
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundStyle(Color.ariaTextSecondary)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing playing")
                        .font(.headline)
                        .foregroundStyle(Color.ariaTextPrimary)

                    Text("Choose a song from the library")
                        .font(.subheadline)
                        .foregroundStyle(Color.ariaTextSecondary)
                }
            }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 16) {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffleEnabled ? Color.ariaAccent : Color.ariaTextSecondary)
            }
            .help(player.isShuffleEnabled ? "Turn shuffle off" : "Shuffle queue")

            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill")
            }
            .disabled(!player.canSkipToPreviousTrack)
            .help("Previous")

            Button {
                player.playPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.ariaAccent))
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
            }
            .disabled(!player.canSkipToNextTrack)
            .help("Next")

            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: player.repeatMode.systemImage)
                    .foregroundStyle(player.repeatMode == .off ? Color.ariaTextSecondary : Color.ariaAccent)
            }
            .help(player.repeatMode.title)

            Menu {
                Button(
                    player.isLyricsPresented ? "Hide Lyrics" : "Show Lyrics",
                    systemImage: "quote.bubble"
                ) {
                    player.toggleLyrics()
                }
                .disabled(player.currentTrack == nil)

                Button(
                    player.isAudioVisualizerEnabled ? "Hide Visualizer" : "Show Visualizer",
                    systemImage: "waveform"
                ) {
                    player.toggleAudioVisualizer()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(
                        player.isLyricsPresented || player.isAudioVisualizerEnabled
                            ? Color.ariaAccent
                            : Color.ariaTextSecondary
                    )
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Player options")
        }
        .buttonStyle(.plain)
        .font(.system(size: 16, weight: .semibold))
    }

    private var progressArea: some View {
        HStack(spacing: 10) {
            Text(player.elapsed.ariaClockText)
                .frame(width: 46, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { player.progress },
                    set: { player.seek(toProgress: $0) }
                ),
                in: 0...1
            )
            .tint(Color.ariaAccent)
            .disabled(player.currentTrack == nil)

            Text((player.currentTrack?.duration ?? 0).ariaDurationText)
                .frame(width: 46, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(Color.ariaTextSecondary)
    }

    private var volumeControl: some View {
        HStack(spacing: 8) {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(Color.ariaTextSecondary)

            Slider(value: $player.volume, in: 0...1)
                .tint(Color.ariaAccent)
        }
        .help("Volume")
    }
}

struct MacKaraokeLyricsView: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    let track: Track
    var showsChrome = true
    var isCompact = false

    @State private var lyrics: TrackLyrics?
    @State private var visibleLyricID: String?
    @State private var errorMessage: String?
    @State private var isLoading = true

    private var activeLineID: String? {
        lyrics?.activeLineID(at: player.elapsed)
    }

    var body: some View {
        Group {
            if showsChrome {
                karaokeChrome
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: track.id) {
            await loadLyrics()
        }
    }

    private var karaokeChrome: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: track.artwork.topHex).opacity(0.42),
                    Color(hex: track.artwork.bottomHex).opacity(0.24),
                    Color.ariaBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.ariaAccent.opacity(0.09), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 520
            )

            VStack(spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ariaBackground)
    }

    private var header: some View {
        HStack(spacing: 16) {
            ArtworkView(track: track, size: 60, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text("KARAOKE LYRICS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ariaAccent)
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.ariaTextPrimary)
                    .lineLimit(1)
                ArtistNameLink(name: track.artist)
                    .font(.subheadline)
                    .foregroundStyle(Color.ariaTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                player.hideLyrics()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.ariaTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Close karaoke lyrics")
            .accessibilityLabel("Close karaoke lyrics")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(Color.black.opacity(0.12))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.ariaDivider.opacity(0.6))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Finding lyrics…")
                    .foregroundStyle(Color.ariaTextSecondary)
            }
        } else if let errorMessage {
            messageView(
                title: "Lyrics unavailable",
                message: errorMessage,
                systemImage: "wifi.exclamationmark",
                retry: true
            )
        } else if let lyrics, lyrics.instrumental {
            messageView(
                title: "Instrumental",
                message: "This track does not have sung lyrics.",
                systemImage: "music.note",
                retry: false
            )
        } else if let lyrics, lyrics.available {
            lyricsView(lyrics)
        } else {
            messageView(
                title: "No lyrics found",
                message: "Aria checked the audio file and the online lyrics library.",
                systemImage: "quote.bubble",
                retry: true
            )
        }
    }

    private func lyricsView(_ lyrics: TrackLyrics) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: isCompact ? .leading : .center, spacing: isCompact ? 14 : lyrics.isSynced ? 26 : 18) {
                if lyrics.isSynced {
                    ForEach(lyrics.syncedLines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { line in
                        let isActive = line.id == activeLineID

                        Button {
                            seek(to: line.startTime)
                        } label: {
                            Text(line.text)
                                .font(
                                    .system(
                                        size: isCompact ? (isActive ? 21 : 17) : isActive ? (showsChrome ? 42 : 34) : (showsChrome ? 30 : 24),
                                        weight: isActive ? .bold : .semibold,
                                        design: .default
                                    )
                                )
                                .foregroundStyle(
                                    isActive
                                        ? Color.ariaTextPrimary
                                        : Color.ariaTextPrimary.opacity(0.3)
                                )
                                .multilineTextAlignment(isCompact ? .leading : .center)
                                .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .center)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                        .scaleEffect(isActive ? 1 : 0.97)
                        .animation(.easeOut(duration: 0.2), value: isActive)
                    }
                } else {
                    ForEach(Array(lyrics.plainLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: isCompact ? 18 : showsChrome ? 30 : 24, weight: .semibold))
                            .foregroundStyle(Color.ariaTextPrimary.opacity(0.88))
                            .multilineTextAlignment(isCompact ? .leading : .center)
                            .frame(maxWidth: .infinity, alignment: isCompact ? .leading : .center)
                    }
                }

                if lyrics.source == "lrclib" {
                    Text("Lyrics provided by LRCLIB")
                        .font(.caption)
                        .foregroundStyle(Color.ariaTextSecondary.opacity(0.7))
                        .padding(.top, 18)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: showsChrome ? 980 : 620)
            .padding(.horizontal, isCompact ? 0 : showsChrome ? 56 : 30)
            .padding(.vertical, isCompact ? 28 : showsChrome ? 180 : 100)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $visibleLyricID, anchor: .center)
        .onChange(of: activeLineID, initial: true) { _, newLineID in
            guard let newLineID else { return }
            withAnimation(.easeInOut(duration: 0.34)) {
                visibleLyricID = newLineID
            }
        }
    }

    private func messageView(
        title: String,
        message: String,
        systemImage: String,
        retry: Bool
    ) -> some View {
        VStack(spacing: isCompact ? 6 : 14) {
            Image(systemName: systemImage)
                .font(.system(size: isCompact ? 19 : 52, weight: .semibold))
                .foregroundStyle(Color.ariaAccent)
            Text(title)
                .font(.system(size: isCompact ? 16 : showsChrome ? 34 : 27, weight: .semibold))
                .foregroundStyle(Color.ariaTextPrimary)
            Text(message)
                .font(isCompact ? .caption : .title3)
                .foregroundStyle(Color.ariaTextSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(isCompact ? 3 : nil)
                .help(message)

            if retry {
                Button("Try again") {
                    Task { await loadLyrics() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.ariaAccent)
            }
        }
        .padding(isCompact ? 8 : 30)
    }

    private func loadLyrics() async {
        let requestedTrackID = track.id
        isLoading = true
        errorMessage = nil
        visibleLyricID = nil

        do {
            let loadedLyrics = try await AriaServerClient().fetchLyrics(for: track)
            guard !Task.isCancelled, player.currentTrack?.id == requestedTrackID else { return }
            lyrics = loadedLyrics
        } catch {
            guard !Task.isCancelled, player.currentTrack?.id == requestedTrackID else { return }
            lyrics = nil
            errorMessage = error.localizedDescription
        }

        if player.currentTrack?.id == requestedTrackID {
            isLoading = false
        }
    }

    private func seek(to startTime: TimeInterval) {
        guard track.duration > 0 else { return }
        player.seek(toProgress: min(max(startTime / track.duration, 0), 1))
    }
}

struct AudioVisualizer: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let levels: [Float]
    let hasTrack: Bool

    private var displayedLevels: [Float] {
        guard hasTrack else {
            return levels.map { _ in 0.035 }
        }

        guard !accessibilityReduceMotion else {
            return levels.enumerated().map { index, _ in
                Float(0.07 + 0.035 * (0.5 + 0.5 * sin(Double(index) * 1.17)))
            }
        }

        return levels
    }

    var body: some View {
        let bars = SpectrumBarsShape(levels: displayedLevels)

        bars
            .fill(hasTrack ? Color.ariaAccent : Color.ariaAccent.opacity(0.14))
        .animation(
            accessibilityReduceMotion
                ? nil
                : .easeOut(duration: 0.08),
            value: displayedLevels
        )
    }
}

private struct SpectrumBarsShape: Shape {
    var vector: SpectrumVector

    init(levels: [Float]) {
        vector = SpectrumVector(values: levels.map(Double.init))
    }

    var animatableData: SpectrumVector {
        get { vector }
        set { vector = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0, !vector.values.isEmpty else { return Path() }

        let spacing = 2.6
        let barCount = vector.values.count
        let barWidth = max(1.8, (rect.width - spacing * Double(barCount - 1)) / Double(barCount))
        let maximumHeight = max(rect.height - 2, 2)
        var path = Path()

        for index in 0..<barCount {
            let rawLevel = min(max(vector.values[index], 0.025), 1)
            let level = min(pow(rawLevel, 0.82) * 1.08, 1)
            let height = maximumHeight * level
            let barRect = CGRect(
                x: rect.minX + Double(index) * (barWidth + spacing),
                y: rect.maxY - height,
                width: barWidth,
                height: height
            )
            path.addRoundedRect(
                in: barRect,
                cornerSize: CGSize(width: min(barWidth / 2, 2.8), height: min(barWidth / 2, 2.8))
            )
        }

        return path
    }
}

private struct SpectrumVector: VectorArithmetic {
    var values: [Double]

    static var zero: SpectrumVector {
        SpectrumVector(values: [])
    }

    static func + (lhs: SpectrumVector, rhs: SpectrumVector) -> SpectrumVector {
        SpectrumVector(values: combine(lhs.values, rhs.values, operation: +))
    }

    static func - (lhs: SpectrumVector, rhs: SpectrumVector) -> SpectrumVector {
        SpectrumVector(values: combine(lhs.values, rhs.values, operation: -))
    }

    static func += (lhs: inout SpectrumVector, rhs: SpectrumVector) {
        lhs = lhs + rhs
    }

    static func -= (lhs: inout SpectrumVector, rhs: SpectrumVector) {
        lhs = lhs - rhs
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    private static func combine(
        _ lhs: [Double],
        _ rhs: [Double],
        operation: (Double, Double) -> Double
    ) -> [Double] {
        let count = max(lhs.count, rhs.count)
        return (0..<count).map { index in
            operation(
                index < lhs.count ? lhs[index] : 0,
                index < rhs.count ? rhs[index] : 0
            )
        }
    }
}

struct InlinePlaybackError: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    var message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)

            Text(message)
                .font(.caption)
                .foregroundStyle(Color.ariaTextPrimary)
                .lineLimit(2)

            Spacer()

            Button {
                player.dismissPlaybackError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ariaTextSecondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
