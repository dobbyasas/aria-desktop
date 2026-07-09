import SwiftUI

@main
struct AriaMacApp: App {
    @StateObject private var player = MacPlayerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .frame(minWidth: 860, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") {
                    player.playPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Previous Track") {
                    player.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Button("Next Track") {
                    player.next()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Divider()

                Button(player.isShuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On") {
                    player.toggleShuffle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button(player.repeatMode.title) {
                    player.cycleRepeatMode()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandMenu("Library") {
                Button("Refresh Library") {
                    Task {
                        await player.refreshCatalog()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
