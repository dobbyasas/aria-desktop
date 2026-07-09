import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let playbackError = player.playbackErrorMessage {
                InlinePlaybackError(message: playbackError)
            }

            Divider()
                .overlay(Color.ariaDivider)

            ViewThatFits(in: .horizontal) {
                expandedLayout
                compactLayout
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Color.black.opacity(0.24))
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

            volumeControl
                .frame(width: 120)
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

            VStack(spacing: 9) {
                transportControls
                progressArea
            }
        }
    }

    private var currentTrackSummary: some View {
        HStack(spacing: 12) {
            if let track = player.currentTrack {
                ArtworkView(track: track, size: 54, cornerRadius: 7)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.headline)
                        .foregroundStyle(Color.ariaTextPrimary)
                        .lineLimit(1)

                    Text("\(track.artist) - \(track.album)")
                        .font(.subheadline)
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
