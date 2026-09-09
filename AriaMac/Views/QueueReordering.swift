import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let ariaQueueTrack = UTType(exportedAs: "com.tofi.aria.mac.queue-track", conformingTo: .data)
}

final class QueueDragState: ObservableObject {
    @Published var sourceID: UUID?
    @Published var targetID: UUID?
}

extension View {
    func queueReorderable(trackID: UUID, enabled: Bool, dragState: QueueDragState, spacing: CGFloat) -> some View {
        modifier(QueueReorderingModifier(dragState: dragState, trackID: trackID, enabled: enabled, spacing: spacing))
    }
}

private struct QueueReorderingModifier: ViewModifier {
    @Environment(MacPlayerViewModel.self) private var player
    @ObservedObject var dragState: QueueDragState
    let trackID: UUID
    let enabled: Bool
    let spacing: CGFloat

    private var movesDown: Bool {
        guard dragState.targetID == trackID, let sourceID = dragState.sourceID,
              let sourceIndex = player.queueIndex(for: sourceID),
              let targetIndex = player.queueIndex(for: trackID) else { return false }
        return sourceIndex < targetIndex
    }

    private var isDropTarget: Binding<Bool> {
        Binding(
            get: { dragState.targetID == trackID },
            set: { targeted in
                if targeted {
                    dragState.targetID = trackID
                } else if dragState.targetID == trackID {
                    dragState.targetID = nil
                }
            }
        )
    }

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay(alignment: movesDown ? .bottom : .top) {
                    if dragState.targetID == trackID,
                       let sourceID = dragState.sourceID, sourceID != trackID,
                       player.canMoveQueuedTrack(sourceID) {
                        // The move lands after the target when dragging down,
                        // and before it when dragging up. Center the marker in
                        // that gap without covering either song.
                        Capsule()
                            .fill(Color.ariaAccent)
                            .frame(height: 2)
                            .offset(y: (movesDown ? 1 : -1) * (spacing / 2 + 1))
                            .allowsHitTesting(false)
                    }
                }
                .onDrag {
                    dragState.sourceID = trackID
                    dragState.targetID = nil
                    return NSItemProvider(item: Data(trackID.uuidString.utf8) as NSData,
                                          typeIdentifier: UTType.ariaQueueTrack.identifier)
                }
                // Accept the source's native transfer operation; requesting a
                // move proposal can make macOS reject SwiftUI onDrag sources.
                .onDrop(of: [.ariaQueueTrack], isTargeted: isDropTarget, perform: performDrop)
                .accessibilityHint("Drag to the highlighted gap to change the queue order")
        } else {
            content
        }
    }

    private func performDrop(_ providers: [NSItemProvider]) -> Bool {
        dragState.sourceID = nil
        dragState.targetID = nil
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
