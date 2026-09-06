import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let ariaQueueTrack = UTType(exportedAs: "com.tofi.aria.mac.queue-track", conformingTo: .data)
}

extension View {
    func queueReorderable(trackID: UUID, enabled: Bool) -> some View {
        modifier(QueueReorderingModifier(trackID: trackID, enabled: enabled))
    }
}

private struct QueueReorderingModifier: ViewModifier {
    @EnvironmentObject private var player: MacPlayerViewModel
    @State private var isDropTarget = false
    let trackID: UUID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.ariaAccent.opacity(isDropTarget ? 0.85 : 0), lineWidth: 2)
                        .allowsHitTesting(false)
                }
                .onDrag {
                    NSItemProvider(item: Data(trackID.uuidString.utf8) as NSData,
                                   typeIdentifier: UTType.ariaQueueTrack.identifier)
                }
                // Accept the source's native transfer operation; requesting a
                // move proposal can make macOS reject SwiftUI onDrag sources.
                .onDrop(of: [.ariaQueueTrack], isTargeted: $isDropTarget, perform: performDrop)
                .accessibilityHint("Drag onto another upcoming song to change the queue order")
        } else {
            content
        }
    }

    private func performDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Commit once on release so hovering (or cancelling a drag) never
        // reschedules playback or sends a series of remote queue commands.
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.ariaQueueTrack.identifier) { data, _ in
            guard let data, let value = String(data: data, encoding: .utf8),
                  let sourceID = UUID(uuidString: value) else { return }
            Task { @MainActor in player.moveQueuedTrack(sourceID, to: trackID) }
        }
        return true
    }
}
