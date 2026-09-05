import SwiftUI

struct FullscreenPlayerView: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @State private var artworkPalette: ArtworkPalette?
    @State private var showsLyrics = true
    @State private var expandsLyrics = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                if let error = player.playbackErrorMessage {
                    InlinePlaybackError(message: error)
                }

                GeometryReader { geometry in
                    let padding: CGFloat = geometry.size.width < 700 ? 22 : 32
                    let width = max(geometry.size.width - padding * 2, 1)
                    let diameter = min(width * 0.48, max(220, geometry.size.height - (player.isAudioVisualizerEnabled ? 334 : 300)), 480)

                    VStack(alignment: .leading, spacing: 20) {
                        masthead

                        ZStack(alignment: .topLeading) {
                            VinylRecordView(track: player.currentTrack, isPlaying: player.isPlaying)
                                .frame(width: diameter, height: diameter)

                            VinylQueueView(recordDiameter: diameter)
                                .padding(.leading, diameter * 0.62)
                        }
                        .frame(height: diameter)

                        HStack(alignment: .top, spacing: 28) {
                            lyricsSleeve
                                .frame(width: diameter - 16)
                                .frame(maxHeight: .infinity)

                            VinylPlayerControls(showsLyrics: $showsLyrics)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .padding(.horizontal, padding)
                    .padding(.top, 30)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: player.currentTrack?.artworkURL) { await loadArtworkPalette() }
        .sheet(isPresented: $expandsLyrics) {
            if let track = player.currentTrack {
                VStack(spacing: 0) {
                    HStack {
                        Text("Lyrics · \(track.title)")
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        Button("Done") { expandsLyrics = false }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(20)
                    MacKaraokeLyricsView(track: track, showsChrome: false)
                }
                .frame(minWidth: 520, minHeight: 540)
                .background(Color.ariaBackground)
                .environmentObject(player)
            }
        }
    }

    private var background: some View {
        let palette = artworkPalette ?? player.currentTrack?.artwork ?? .fallback
        return ZStack {
            Color(hex: "141719")
            RadialGradient(
                colors: [Color(hex: palette.topHex).opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 720
            )
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.32)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var masthead: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(player.isPlaying ? Color.ariaAccent : .white.opacity(0.3))
                .frame(width: 5, height: 5)
            Text("NOW PLAYING")
                .tracking(2.5)
            Spacer()
            Text(player.playbackPreparationMessage?.uppercased() ?? (player.currentTrack == nil ? "READY WHEN YOU ARE" : player.isPlaying ? "ON THE TURNTABLE" : "PAUSED"))
                .lineLimit(1)
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.3))
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.leading, 16)
        .accessibilityElement(children: .combine)
    }

    private var lyricsSleeve: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("LYRICS", systemImage: "quote.opening")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                if showsLyrics, player.currentTrack != nil {
                    Button { expandsLyrics = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Expand lyrics")
                    .accessibilityLabel("Expand lyrics")
                }
            }

            if showsLyrics, let track = player.currentTrack {
                MacKaraokeLyricsView(track: track, showsChrome: false, isCompact: true)
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 12)
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 18)
                        }
                    }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(player.currentTrack == nil ? "A little room for music." : "Just you and the music.")
                        .font(.system(size: 22, weight: .medium, design: .serif))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(player.currentTrack == nil ? "Choose an album or playlist to get things spinning." : "Show lyrics with the quotation button.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 16)
        .padding(.top, 8)
    }

    private func loadArtworkPalette() async {
        artworkPalette = nil
        guard let track = player.currentTrack, let url = track.artworkURL else { return }
        let palette = await AriaArtworkCache.shared.palette(for: url, symbolName: track.artwork.symbolName)
        guard !Task.isCancelled, player.currentTrack?.id == track.id else { return }
        withAnimation(.easeOut(duration: 0.4)) { artworkPalette = palette ?? track.artwork }
    }
}

private struct VinylRecordView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let track: Track?
    let isPlaying: Bool
    @State private var rotation = VinylRotation()

    private var isSpinning: Bool { isPlaying && track != nil && !reduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let diameter = geometry.size.width
            ZStack {
                Circle()
                    .fill(.black.opacity(0.35))
                    .padding(-7)
                    .overlay(Circle().stroke(.white.opacity(0.07), lineWidth: 1).padding(-7))

                TimelineView(.animation(minimumInterval: 1 / 30, paused: !isSpinning)) { timeline in
                    record(diameter: diameter)
                        .rotationEffect(.degrees(rotation.degrees(at: timeline.date)))
                }

                // Light stays fixed over the moving grooves, like a real turntable.
                Circle()
                    .fill(AngularGradient(
                        colors: [.clear, .white.opacity(0.10), .clear, .clear, .white.opacity(0.07), .clear],
                        center: .center,
                        startAngle: .degrees(15),
                        endAngle: .degrees(375)
                    ))
                    .mask(Circle().stroke(lineWidth: diameter * 0.23).padding(diameter * 0.12))
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color(hex: "151719"))
                    .frame(width: diameter * 0.045)
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 2))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
            }
            .shadow(color: .black.opacity(0.45), radius: 22, x: 0, y: 18)
        }
        .onChange(of: isSpinning, initial: true) { _, spinning in
            rotation.setSpinning(spinning, at: .now)
        }
        .onDisappear { rotation.setSpinning(false, at: .now) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(track.map { "Vinyl record, \($0.album)" } ?? "Empty turntable")
        .accessibilityValue(track == nil ? "Ready" : isPlaying ? "Playing" : "Paused")
    }

    private func record(diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color(hex: "080A0B"))
            Circle().stroke(.white.opacity(0.18), lineWidth: 1).padding(2)
            Canvas { context, size in
                for groove in 0..<62 {
                    let inset = size.width * (0.025 + CGFloat(groove) * 0.0035)
                    let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                    context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(groove % 5 == 0 ? 0.13 : 0.045)), lineWidth: 0.6)
                }
            }
            Circle()
                .stroke(.white.opacity(0.13), lineWidth: 2)
                .frame(width: diameter * 0.52)
            if let track {
                ArtworkView(track: track, size: diameter * 0.49, cornerRadius: diameter)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(hex: "354641"))
                    .frame(width: diameter * 0.49)
                    .overlay {
                        Text("aria")
                            .font(.system(size: diameter * 0.09, weight: .medium, design: .serif))
                            .foregroundStyle(.white.opacity(0.7))
                            .offset(y: -diameter * 0.09)
                    }
            }
        }
    }
}

private struct VinylQueueView: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    let recordDiameter: CGFloat
    @Namespace private var scrollSpace
    @State private var scrollTarget: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("The queue")
                    .font(.system(size: 21, weight: .medium, design: .serif))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                Text("\(player.queue.count) \(player.queue.count == 1 ? "TRACK" : "TRACKS")")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.leading, recordDiameter * 0.20)

            if player.queue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your next favorite awaits.")
                        .font(.system(size: 15, weight: .medium))
                    Text("Play something from your collection.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .foregroundStyle(.white.opacity(0.65))
                .padding(.leading, recordDiameter * 0.44)
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                            GeometryReader { rowGeometry in
                                let midY = rowGeometry.frame(in: .named(scrollSpace)).midY + 36
                                let inset = VinylQueueArc.leadingInset(rowMidY: midY, diameter: recordDiameter)
                                VinylQueueRow(track: track, index: index)
                                    .padding(.leading, inset)
                            }
                            .frame(height: 52)
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 2)
                }
                .coordinateSpace(name: scrollSpace)
                .scrollIndicators(.hidden)
                .scrollPosition(id: $scrollTarget, anchor: .top)
                .onChange(of: player.currentTrack?.id, initial: true) { _, _ in
                    focusCurrentTrack()
                }
                .onChange(of: player.queue.map(\.id)) { _, _ in
                    focusCurrentTrack()
                }
            }
        }
    }

    private func focusCurrentTrack() {
        scrollTarget = player.queue.firstIndex(where: { $0.id == player.currentTrack?.id })
    }
}

private struct VinylQueueRow: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @State private var isHovering = false
    let track: Track
    let index: Int

    private var isCurrent: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        Button { player.play(track, from: player.queue) } label: {
            HStack(spacing: 9) {
                Group {
                    if isCurrent {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                            .foregroundStyle(Color.ariaAccent)
                    } else {
                        Text(String(format: "%02d", index + 1))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .frame(width: 20)

                ArtworkView(track: track, size: 34, cornerRadius: 4)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? .white : .white.opacity(0.74))
                        .lineLimit(1)
                    ArtistNameLink(name: track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(track.duration.ariaDurationText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(.white.opacity(isCurrent ? 0.075 : isHovering ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) {
                if isCurrent {
                    Capsule().fill(Color.ariaAccent).frame(width: 2, height: 18)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Play \(track.title)")
        .accessibilityLabel("\(isCurrent ? "Now playing" : "Play"), \(track.title), \(track.artist)")
    }
}

private struct VinylPlayerControls: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @Binding var showsLyrics: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(player.currentTrack?.title ?? "Nothing playing yet")
                    .font(.system(size: 26, weight: .medium, design: .serif))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .help(player.currentTrack?.title ?? "Nothing playing yet")
                if let track = player.currentTrack {
                    HStack(spacing: 5) {
                        ArtistNameLink(name: track.artist)
                        Text("·").foregroundStyle(.white.opacity(0.25))
                        Text(track.album).foregroundStyle(.white.opacity(0.35))
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                }
            }

            progressArea
            transportControls
            utilityControls

            if player.isAudioVisualizerEnabled {
                AudioVisualizer(levels: player.spectrumLevels, hasTrack: player.currentTrack != nil)
                    .frame(height: 22)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 4)
    }

    private var progressArea: some View {
        VStack(spacing: 0) {
            Slider(
                value: Binding(get: { player.progress }, set: { player.seek(toProgress: $0) }),
                in: 0...1
            )
            .tint(Color.ariaAccent)
            .controlSize(.small)
            .disabled(player.currentTrack == nil)
            .accessibilityLabel("Playback position")
            HStack {
                Text(player.elapsed.ariaClockText)
                Spacer()
                Text((player.currentTrack?.duration ?? 0).ariaDurationText)
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var transportControls: some View {
        HStack(spacing: 0) {
            control("shuffle", active: player.isShuffleEnabled, label: player.isShuffleEnabled ? "Turn shuffle off" : "Shuffle queue") {
                player.toggleShuffle()
            }
            Spacer(minLength: 8)
            control("backward.end.fill", label: "Previous track") { player.previous() }
                .disabled(!player.canSkipToPreviousTrack)
            Spacer(minLength: 10)
            Button { player.playPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .offset(x: player.isPlaying ? 0 : 1)
                    .foregroundStyle(Color(hex: "162521"))
                    .frame(width: 48, height: 48)
                    .background(Color(hex: "D3E4D6"), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil && player.queue.isEmpty)
            .help(player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer(minLength: 10)
            control("forward.end.fill", label: "Next track") { player.next() }
                .disabled(!player.canSkipToNextTrack)
            Spacer(minLength: 8)
            control(player.repeatMode.systemImage, active: player.repeatMode != .off, label: player.repeatMode.title) {
                player.cycleRepeatMode()
            }
        }
    }

    private var utilityControls: some View {
        HStack(spacing: 8) {
            MacPlaybackSessionMenu()
            control("quote.bubble", active: showsLyrics, label: showsLyrics ? "Hide lyrics" : "Show lyrics") {
                showsLyrics.toggle()
            }
            control("waveform", active: player.isAudioVisualizerEnabled, label: player.isAudioVisualizerEnabled ? "Hide visualizer" : "Show visualizer") {
                player.toggleAudioVisualizer()
            }
            Spacer(minLength: 0)
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Slider(value: $player.volume, in: 0...1)
                .tint(.white.opacity(0.65))
                .controlSize(.mini)
                .frame(minWidth: 45, maxWidth: 90)
                .accessibilityLabel("Volume")
        }
    }

    private func control(_ symbol: String, active: Bool = false, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Color.ariaAccent : .white.opacity(0.55))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
