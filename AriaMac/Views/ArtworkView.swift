import SwiftUI

struct ArtworkView: View {
    @State private var cachedArtwork: NSImage?

    let track: Track
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            fallbackArtwork

            if let cachedArtwork {
                Image(nsImage: cachedArtwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .task(id: track.artworkURL) {
            await loadArtwork()
        }
        .accessibilityLabel("\(track.title) artwork")
    }

    private var fallbackArtwork: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: track.artwork.topHex), Color(hex: track.artwork.bottomHex)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: track.artwork.symbolName)
                .font(.system(size: size * 0.28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .shadow(radius: 14)
        }
    }

    private func loadArtwork() async {
        cachedArtwork = nil

        guard let artworkURL = track.artworkURL else {
            return
        }

        guard let image = await AriaArtworkCache.shared.image(for: artworkURL) else {
            return
        }

        guard !Task.isCancelled, track.artworkURL == artworkURL else {
            return
        }

        withAnimation(.easeOut(duration: 0.18)) {
            cachedArtwork = image
        }
    }
}
