import SwiftUI

struct ArtworkView: View {
    @Environment(\.displayScale) private var displayScale
    @State private var cachedArtwork: NSImage?
    @State private var loadedKey: String?

    let track: Track
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        let warmImage = track.artworkURL.flatMap {
            AriaArtworkCache.shared.cachedImage(for: $0, maxPixelSize: pixelSize)
        }
        ArtworkImage(track: track, image: loadedKey == requestKey ? cachedArtwork : warmImage, size: size, cornerRadius: cornerRadius)
            .task(id: requestKey) {
                await loadArtwork()
            }
    }

    private var requestKey: String { "\(track.artworkURL?.absoluteString ?? "")|\(pixelSize)" }

    private var pixelSize: Int { AriaArtworkCache.pixelSize(for: size * displayScale) }

    private func loadArtwork() async {
        guard let artworkURL = track.artworkURL else { return }
        let key = requestKey
        let image: NSImage?
        if let warmImage = AriaArtworkCache.shared.cachedImage(for: artworkURL, maxPixelSize: pixelSize) {
            image = warmImage
        } else {
            image = await AriaArtworkCache.shared.image(for: artworkURL, maxPixelSize: pixelSize)
        }
        guard !Task.isCancelled else { return }
        // Pin the visible image even if NSCache later evicts its entry.
        cachedArtwork = image
        loadedKey = key
    }
}

/// Pure artwork rendering, also used by album rows that share one loaded thumbnail.
/// Keeping loading outside the row avoids restarting tasks and fades during scrolling.
struct ArtworkImage: View {
    let track: Track
    let image: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .transition(.opacity)
            } else {
                fallbackArtwork
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
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
}
