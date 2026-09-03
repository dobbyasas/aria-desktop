import SwiftUI

struct FullscreenPlayerView: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @State private var artworkPalette: ArtworkPalette?
    @State private var showsLyrics = false
    @State private var showsQueue = false

    private let chrome = Color(hex: "#C8CAC6")
    private let chromeDark = Color(hex: "#8D918E")
    private let cobalt = Color(hex: "#16458A")
    private let ink = Color(hex: "#111820")
    private let paper = Color(hex: "#E7E5DD")
    private let signal = Color(hex: "#F04B35")

    var body: some View {
        ZStack {
            Color(hex: "#747B80").ignoresSafeArea()

            VStack(spacing: 0) {
                if let track = player.currentTrack {
                    applicationTitleBar(track.title)
                    modeStrip

                    GeometryReader { proxy in
                        Group {
                            if showsLyrics || showsQueue {
                                alternateWorkspace(for: track, in: proxy.size)
                            } else {
                                playerWorkspace(for: track, in: proxy.size)
                            }
                        }
                    }

                    controlShelf(track: track)
                } else {
                    applicationTitleBar("No File Open")
                    modeStrip
                    emptyWorkspace
                }
            }
            .background(chrome)
            .overlay {
                Rectangle().stroke(Color.black.opacity(0.76), lineWidth: 2)
            }
            .shadow(color: .black.opacity(0.42), radius: 18, y: 12)
            .padding(24)

            if let playbackError = player.playbackErrorMessage {
                InlinePlaybackError(message: playbackError)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: player.currentTrack?.artworkURL) {
            await loadArtworkPalette()
        }
        .animation(.easeInOut(duration: 0.16), value: showsLyrics)
        .animation(.easeInOut(duration: 0.16), value: showsQueue)
    }

    private func applicationTitleBar(_ title: String) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Rectangle().fill(Color.white.opacity(0.86)).frame(width: 3, height: 13)
                Rectangle().fill(Color.white.opacity(0.86)).frame(width: 3, height: 13)
                Rectangle().fill(Color.white.opacity(0.86)).frame(width: 3, height: 13)
            }

            Text("ARIA PLAYER")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .tracking(1.2)

            Text("— " + title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .opacity(0.84)

            Spacer()

            Text(player.isPlaying ? "PLAYING" : "READY")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(Color.white.opacity(0.16))

            Rectangle()
                .fill(player.isPlaying ? Color(hex: "#5CFF88") : Color.white.opacity(0.28))
                .frame(width: 7, height: 7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(cobalt)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.42)).frame(height: 1)
        }
    }

    private var modeStrip: some View {
        HStack(spacing: 0) {
            Text("FILE")
            Text("VIEW")
            Text("PLAYBACK")
            Text("WINDOW")

            Spacer()

            modeButton("PLAYER", selected: !showsLyrics && !showsQueue) {
                showsLyrics = false
                showsQueue = false
            }
            modeButton("LYRICS", selected: showsLyrics) {
                showsLyrics = true
                showsQueue = false
            }
            modeButton("QUEUE", selected: showsQueue) {
                showsQueue = true
                showsLyrics = false
            }
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(ink.opacity(0.78))
        .padding(.leading, 13)
        .frame(height: 32)
        .background(chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.38)).frame(height: 1)
        }
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(selected ? .white : ink.opacity(0.72))
                .padding(.horizontal, 13)
                .frame(height: 31)
                .background(selected ? cobalt : Color.clear)
                .overlay {
                    Rectangle().stroke(Color.black.opacity(selected ? 0.28 : 0.16), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func playerWorkspace(for track: Track, in size: CGSize) -> some View {
        let artworkSize = min(size.height * 0.58, size.width * 0.40, 430)

        return HStack(spacing: 0) {
            artworkDocument(track, size: artworkSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            trackInspector(track)
                .frame(width: max(330, size.width * 0.39))
        }
        .padding(8)
        .background(chromeDark)
        .transition(.opacity)
    }

    private func artworkDocument(_ track: Track, size: CGFloat) -> some View {
        ZStack {
            Color(hex: "#111820")

            VStack(spacing: 0) {
                HStack {
                    Text("CANVAS 01")
                    Spacer()
                    Text("100%")
                }
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.42))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.white.opacity(0.035))

                Spacer(minLength: 12)

                ArtworkView(track: track, size: size, cornerRadius: 0)
                    .overlay {
                        Rectangle().stroke(Color.white.opacity(0.22), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 10)

                Spacer(minLength: 12)

                HStack {
                    Text("RGB / DIGITAL AUDIO")
                    Spacer()
                    Text("44.1 KHZ  •  STEREO")
                }
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.36))
                .padding(.horizontal, 10)
                .frame(height: 24)
            }
        }
        .overlay {
            Rectangle().stroke(Color.black.opacity(0.7), lineWidth: 2)
        }
    }

    private func trackInspector(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(dynamicAccent(for: track))
                .frame(height: 8)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TRACK")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(ink.opacity(0.48))

                    Text(trackIndexText)
                        .font(.system(size: 70, weight: .black, design: .monospaced))
                        .foregroundStyle(cobalt)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(player.elapsed.ariaClockText)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                    Text("OF " + track.duration.ariaDurationText)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(ink.opacity(0.45))
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 8) {
                Text(track.title)
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.72)

                Text(track.artist.uppercased())
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(cobalt)

                Text(track.album)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ink.opacity(0.55))
                    .lineLimit(2)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)

            Spacer(minLength: 12)

            ClassicSpectrumMeter(levels: player.spectrumLevels, color: signal)
                .frame(height: 78)
                .padding(.horizontal, 22)

            HStack {
                Text(player.isShuffleEnabled ? "RANDOM ON" : "RANDOM OFF")
                Spacer()
                Text(player.repeatMode.title.uppercased())
            }
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .foregroundStyle(ink.opacity(0.45))
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
        }
        .foregroundStyle(ink)
        .background(paper)
        .overlay {
            Rectangle().stroke(Color.black.opacity(0.55), lineWidth: 2)
        }
    }

    private func alternateWorkspace(for track: Track, in size: CGSize) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ArtworkView(track: track, size: min(190, size.height * 0.32), cornerRadius: 0)
                    .overlay { Rectangle().stroke(Color.black.opacity(0.42), lineWidth: 1) }

                Text(track.title)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(ink)
                    .lineLimit(3)

                Text(track.artist.uppercased())
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(cobalt)

                Spacer()

                Text(showsLyrics ? "DOCUMENT: LYRICS" : "DOCUMENT: PLAY QUEUE")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.45))
            }
            .padding(18)
            .frame(width: 250)
            .frame(maxHeight: .infinity)
            .background(paper)
            .overlay { Rectangle().stroke(Color.black.opacity(0.52), lineWidth: 2) }

            Group {
                if showsLyrics {
                    MacKaraokeLyricsView(track: track, showsChrome: false)
                } else {
                    FullscreenQueueView()
                }
            }
            .background(Color(hex: "#111820"))
            .overlay { Rectangle().stroke(Color.black.opacity(0.72), lineWidth: 2) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(8)
        .background(chromeDark)
        .transition(.opacity)
    }

    private func controlShelf(track: Track) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.elapsed.ariaClockText)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                Text("TIME ELAPSED")
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .foregroundStyle(Color(hex: "#66D690").opacity(0.65))
            }
            .foregroundStyle(Color(hex: "#7CFFAA"))
            .padding(.horizontal, 12)
            .frame(width: 128, height: 54, alignment: .leading)
            .background(ink)
            .overlay { Rectangle().stroke(Color.black.opacity(0.8), lineWidth: 2) }

            ClassicTransportControls()

            Slider(
                value: Binding(
                    get: { player.progress },
                    set: { player.seek(toProgress: $0) }
                ),
                in: 0...1
            )
            .tint(cobalt)

            HStack(spacing: 8) {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                Slider(value: $player.volume, in: 0...1)
                    .tint(cobalt)
                    .frame(width: 95)
                Text(String(format: "%02d", Int(player.volume * 99)))
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .frame(width: 20)
            }
            .foregroundStyle(ink.opacity(0.66))
        }
        .padding(.horizontal, 10)
        .frame(height: 76)
        .background(chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.85)).frame(height: 1)
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 10) {
            Text("NO FILE OPEN")
                .font(.system(size: 42, weight: .black, design: .monospaced))
            Text("CHOOSE A SONG FROM THE LIBRARY TO BEGIN")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1)
                .opacity(0.48)
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paper)
        .padding(8)
        .background(chromeDark)
    }

    private var trackIndexText: String {
        guard let track = player.currentTrack,
              let index = player.queue.firstIndex(where: { $0.id == track.id }) else {
            return "--"
        }
        return String(format: "%02d", index + 1)
    }

    private func dynamicAccent(for track: Track) -> Color {
        Color(hex: (artworkPalette ?? track.artwork).topHex)
    }

    private func loadArtworkPalette() async {
        guard let track = player.currentTrack else {
            artworkPalette = nil
            return
        }

        guard let artworkURL = track.artworkURL else {
            artworkPalette = track.artwork
            return
        }

        let palette = await AriaArtworkCache.shared.palette(
            for: artworkURL,
            symbolName: track.artwork.symbolName
        )

        guard !Task.isCancelled, player.currentTrack?.id == track.id else { return }
        artworkPalette = palette ?? track.artwork
    }
}

private struct ClassicSpectrumMeter: View {
    let levels: [Float]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let visibleLevels = Array(levels.prefix(28))
            let spacing: CGFloat = 2
            let width = max(2, (proxy.size.width - spacing * CGFloat(max(0, visibleLevels.count - 1))) / CGFloat(max(1, visibleLevels.count)))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(visibleLevels.enumerated()), id: \.offset) { _, level in
                    Rectangle()
                        .fill(color)
                        .frame(width: width, height: max(2, proxy.size.height * CGFloat(min(max(level, 0.025), 1))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .animation(.linear(duration: 0.07), value: levels)
        .accessibilityHidden(true)
    }
}

private struct ClassicTransportControls: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    var body: some View {
        HStack(spacing: 3) {
            classicButton("shuffle", active: player.isShuffleEnabled, help: "Shuffle") {
                player.toggleShuffle()
            }
            classicButton("backward.end.fill", help: "Previous") {
                player.previous()
            }
            .disabled(!player.canSkipToPreviousTrack)

            classicButton(player.isPlaying ? "pause.fill" : "play.fill", emphasized: true, help: player.isPlaying ? "Pause" : "Play") {
                player.playPause()
            }

            classicButton("forward.end.fill", help: "Next") {
                player.next()
            }
            .disabled(!player.canSkipToNextTrack)
            classicButton(player.repeatMode.systemImage, active: player.repeatMode != .off, help: player.repeatMode.title) {
                player.cycleRepeatMode()
            }
        }
    }

    private func classicButton(
        _ image: String,
        active: Bool = false,
        emphasized: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: emphasized ? 15 : 12, weight: .black))
                .foregroundStyle(active ? Color(hex: "#F04B35") : Color(hex: "#17202A"))
                .frame(width: emphasized ? 48 : 36, height: 42)
                .background(emphasized ? Color(hex: "#F3F1E9") : Color(hex: "#D8D9D5"))
                .overlay(alignment: .top) { Rectangle().fill(Color.white).frame(height: 1) }
                .overlay(alignment: .leading) { Rectangle().fill(Color.white).frame(width: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.42)).frame(height: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(Color.black.opacity(0.42)).frame(width: 1) }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct FullscreenQueueView: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Queue")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.ariaTextPrimary)

                Spacer()

                Text(queueCountText)
                    .font(.caption)
                    .foregroundStyle(Color.ariaTextPrimary.opacity(0.48))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .overlay(.white.opacity(0.08))

            if player.queue.isEmpty {
                VStack(spacing: 10) {
                    Spacer()

                    Image(systemName: "list.bullet")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.ariaAccent)

                    Text("Queue is empty")
                        .font(.headline)
                        .foregroundStyle(Color.ariaTextPrimary)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                            queueRow(track, index: index)
                        }
                    }
                    .padding(10)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var queueCountText: String {
        player.queue.count == 1 ? "1 song" : "\(player.queue.count) songs"
    }

    private func queueRow(_ track: Track, index: Int) -> some View {
        let isCurrent = player.currentTrack?.id == track.id

        return Button {
            player.play(track, from: player.queue)
        } label: {
            HStack(spacing: 9) {
                Group {
                    if isCurrent {
                        Image(systemName: player.isPlaying ? "waveform" : "speaker.fill")
                            .foregroundStyle(Color.ariaAccent)
                    } else {
                        Text("\(index + 1)")
                            .foregroundStyle(Color.ariaTextPrimary.opacity(0.42))
                    }
                }
                .font(.caption2.monospacedDigit())
                .frame(width: 18)

                ArtworkView(track: track, size: 38, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? Color.ariaTextPrimary : Color.ariaTextPrimary.opacity(0.82))
                        .lineLimit(1)

                    ArtistNameLink(name: track.artist)
                        .font(.caption)
                        .foregroundStyle(Color.ariaTextPrimary.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(track.duration.ariaDurationText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.ariaTextPrimary.opacity(0.42))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isCurrent ? Color.ariaAccent.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play \(track.title)")
        .accessibilityLabel(isCurrent ? "Now playing, \(track.title)" : "Play \(track.title)")
    }
}

private struct FullscreenPlayerControls: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @Binding var showsLyrics: Bool
    @Binding var showsQueue: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            progressArea
            transportControls
            utilityControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            playerButton(systemImage: "backward.fill", help: "Previous") {
                player.previous()
            }
            .disabled(!player.canSkipToPreviousTrack)

            Button {
                player.playPause()
            } label: {
                Label(
                    player.isPlaying ? "Pause" : "Play",
                    systemImage: player.isPlaying ? "pause.fill" : "play.fill"
                )
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.ariaAccent))
                    .foregroundStyle(Color.ariaBackground)
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")

            playerButton(systemImage: "forward.fill", help: "Next") {
                player.next()
            }
            .disabled(!player.canSkipToNextTrack)
        }
    }

    private var utilityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                playerButton(
                    systemImage: "shuffle",
                    isActive: player.isShuffleEnabled,
                    help: player.isShuffleEnabled ? "Turn shuffle off" : "Shuffle queue"
                ) {
                    player.toggleShuffle()
                }

                playerButton(
                    systemImage: player.repeatMode.systemImage,
                    isActive: player.repeatMode != .off,
                    help: player.repeatMode.title
                ) {
                    player.cycleRepeatMode()
                }

                playerButton(
                    systemImage: "quote.bubble",
                    isActive: showsLyrics,
                    help: showsLyrics ? "Hide lyrics" : "Show lyrics"
                ) {
                    let shouldShow = !showsLyrics
                    showsLyrics = shouldShow
                    if shouldShow { showsQueue = false }
                }

                playerButton(
                    systemImage: "list.bullet",
                    isActive: showsQueue,
                    help: showsQueue ? "Hide queue" : "Show queue"
                ) {
                    let shouldShow = !showsQueue
                    showsQueue = shouldShow
                    if shouldShow { showsLyrics = false }
                }

                playerButton(
                    systemImage: "waveform",
                    isActive: player.isAudioVisualizerEnabled,
                    help: player.isAudioVisualizerEnabled ? "Hide visualizer" : "Show visualizer"
                ) {
                    player.toggleAudioVisualizer()
                }
            }

            HStack(spacing: 8) {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(Color.ariaTextPrimary.opacity(0.7))

                Slider(value: $player.volume, in: 0...1)
                    .tint(Color.ariaTextPrimary)
                    .frame(maxWidth: .infinity)
            }
            .help("Volume")
        }
    }

    private var progressArea: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { player.progress },
                    set: { player.seek(toProgress: $0) }
                ),
                in: 0...1
            )
            .tint(Color.ariaTextPrimary)
            .disabled(player.currentTrack == nil)

            HStack {
                Text(player.elapsed.ariaClockText)
                Spacer()
                Text((player.currentTrack?.duration ?? 0).ariaDurationText)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(Color.ariaTextPrimary.opacity(0.62))
    }

    private func playerButton(
        systemImage: String,
        isActive: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? Color.ariaAccent : Color.ariaTextPrimary.opacity(0.72))
                .frame(width: 50, height: 50)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct PlayerBar: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let playbackError = player.playbackErrorMessage {
                InlinePlaybackError(message: playbackError)
            }

            compactTimeline

            ViewThatFits(in: .horizontal) {
                expandedLayout
                compactLayout
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(Color.ariaSurface)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.ariaDivider).frame(height: 1)
            }
        }
    }

    private var expandedLayout: some View {
        HStack(spacing: 16) {
            currentTrackSummary
                .frame(minWidth: 210, idealWidth: 280, maxWidth: 340, alignment: .leading)

            Spacer(minLength: 8)

            transportControls

            Spacer(minLength: 8)

            HStack(spacing: 14) {
                secondaryControls
                volumeControl.frame(width: 120)
            }
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                currentTrackSummary
                    .frame(maxWidth: .infinity, alignment: .leading)

                volumeControl
                    .frame(width: 118)
            }

            HStack {
                transportControls
                Spacer()
                secondaryControls
            }
        }
    }

    private var currentTrackSummary: some View {
        HStack(spacing: 12) {
            if let track = player.currentTrack {
                ArtworkView(track: track, size: 46, cornerRadius: 4)

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
        HStack(spacing: 14) {
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
                    .frame(width: 48, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.ariaAccent))
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
        }
        .buttonStyle(.plain)
        .font(.system(size: 16, weight: .semibold))
    }

    private var secondaryControls: some View {
        HStack(spacing: 12) {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffleEnabled ? Color.ariaAccent : Color.ariaTextSecondary)
            }
            .help(player.isShuffleEnabled ? "Turn shuffle off" : "Shuffle queue")

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
        .font(.system(size: 14, weight: .semibold))
    }

    private var compactTimeline: some View {
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
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .background(Color.ariaSurface)
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

    @State private var lyrics: TrackLyrics?
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
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .center, spacing: lyrics.isSynced ? 26 : 18) {
                    if lyrics.isSynced {
                        ForEach(lyrics.syncedLines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { line in
                            let isActive = line.id == activeLineID

                            Button {
                                seek(to: line.startTime)
                            } label: {
                                Text(line.text)
                                    .font(
                                        .system(
                                            size: isActive ? (showsChrome ? 42 : 34) : (showsChrome ? 30 : 24),
                                            weight: isActive ? .bold : .semibold,
                                            design: .default
                                        )
                                    )
                                    .foregroundStyle(
                                        isActive
                                            ? Color.ariaTextPrimary
                                            : Color.ariaTextPrimary.opacity(0.3)
                                    )
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, alignment: .center)
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
                                .font(.system(size: showsChrome ? 30 : 24, weight: .semibold))
                                .foregroundStyle(Color.ariaTextPrimary.opacity(0.88))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }

                    if lyrics.source == "lrclib" {
                        Text("Lyrics provided by LRCLIB")
                            .font(.caption)
                            .foregroundStyle(Color.ariaTextSecondary.opacity(0.7))
                            .padding(.top, 18)
                    }
                }
                .frame(maxWidth: showsChrome ? 980 : 620)
                .padding(.horizontal, showsChrome ? 56 : 30)
                .padding(.vertical, showsChrome ? 180 : 100)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: activeLineID) { _, newLineID in
                guard let newLineID else { return }
                withAnimation(.easeInOut(duration: 0.34)) {
                    proxy.scrollTo(newLineID, anchor: .center)
                }
            }
        }
    }

    private func messageView(
        title: String,
        message: String,
        systemImage: String,
        retry: Bool
    ) -> some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(Color.ariaAccent)
            Text(title)
                .font(.system(size: showsChrome ? 34 : 27, weight: .semibold))
                .foregroundStyle(Color.ariaTextPrimary)
            Text(message)
                .font(.title3)
                .foregroundStyle(Color.ariaTextSecondary)
                .multilineTextAlignment(.center)

            if retry {
                Button("Try again") {
                    Task { await loadLyrics() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.ariaAccent)
            }
        }
        .padding(30)
    }

    private func loadLyrics() async {
        let requestedTrackID = track.id
        isLoading = true
        errorMessage = nil

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

private struct InlinePlaybackError: View {
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
