import Foundation

@main
@MainActor
struct MacQueueTests {
    static func main() {
        // Run synchronous queue edits with no server endpoints. The main actor
        // never yields to background catalog/playback work during these checks.
        let player = MacPlayerViewModel(serverClient: AriaServerClient(baseURLs: []))
        let songs = (0..<6).map { Track(title: "Song \($0)") }
        let extra = Track(title: "Added song")
        let another = Track(title: "Another addition")

        let priorityPlayer = MacPlayerViewModel(serverClient: AriaServerClient(baseURLs: []))
        let songA = Track(title: "A")
        let songB = Track(title: "B")
        let songC = Track(title: "C")
        priorityPlayer.play(songs[0], from: songs)
        priorityPlayer.playNext(songA)
        priorityPlayer.playNext(songB)
        priorityPlayer.addToQueue(songC)
        expect(priorityPlayer, [songs[0], songB, songA, songC] + Array(songs.dropFirst()),
               "Play Next A, Play Next B, Add to Queue C must play B, A, C, then the playlist")

        // A playlist song dragged later must not extend the manually added
        // block all the way through the rest of the playlist.
        priorityPlayer.play(songs[0], from: songs)
        priorityPlayer.moveQueuedTrack(songs[1].id, to: songs[5].id)
        priorityPlayer.playNext(songA)
        priorityPlayer.playNext(songB)
        priorityPlayer.addToQueue(songC)
        expect(priorityPlayer, [songs[0], songB, songA, songC] + Array(songs[2...]) + [songs[1]],
               "Earlier playlist reordering must not put C after the playlist")

        // Moving a previous manual addition out into the playlist must also
        // leave a boundary after the current B/A block.
        priorityPlayer.play(songs[0], from: songs)
        priorityPlayer.addToQueue(extra)
        priorityPlayer.moveQueuedTrack(extra.id, to: songs[5].id)
        priorityPlayer.playNext(songA)
        priorityPlayer.playNext(songB)
        priorityPlayer.addToQueue(songC)
        expect(priorityPlayer, [songs[0], songB, songA, songC] + Array(songs.dropFirst()) + [extra],
               "An older manual addition later in the playlist must not move the B/A/C block")
        print("PASS: B, A, C, then playlist, including earlier queue edits and displaced manual songs")

        player.addToQueue(extra)
        player.addToQueue(another)
        expect(player, [extra, another], "Adding to an empty queue preserves insertion order")
        precondition(player.currentTrack == nil && !player.isPlaying, "Enqueueing must not start playback")

        player.play(songs[1], from: songs)
        player.elapsed = 42
        player.moveQueuedTrack(songs[2].id, to: songs[3].id)
        expect(player, [songs[0], songs[1], songs[3], songs[2], songs[4], songs[5]], "Adjacent downward drag swaps songs")
        player.moveQueuedTrack(songs[5].id, to: songs[3].id)
        expect(player, [songs[0], songs[1], songs[5], songs[3], songs[2], songs[4]], "Last song moves to first upcoming slot")
        player.moveQueuedTrack(songs[5].id, to: songs[4].id)
        expect(player, [songs[0], songs[1], songs[3], songs[2], songs[4], songs[5]], "First upcoming song moves to the end")
        precondition(player.currentTrack?.id == songs[1].id && player.elapsed == 42 && player.isPlaying,
                     "Reordering preserves current playback and its position")

        let beforeInvalidMoves = player.queue
        for (source, target) in [(songs[1].id, songs[3].id), (songs[3].id, songs[1].id),
                                 (songs[0].id, songs[3].id), (songs[3].id, songs[0].id),
                                 (songs[3].id, songs[3].id), (UUID(), songs[3].id), (songs[3].id, UUID())] {
            player.moveQueuedTrack(source, to: target)
            expect(player, beforeInvalidMoves, "Invalid, current, played, and self drops do nothing")
        }
        print("PASS: queue reordering in both directions, boundaries, invalid drops, and playback preservation")

        player.play(songs[0], from: songs)
        player.addToQueue(extra)
        player.addToQueue(another)
        expect(player, [songs[0], extra, another] + Array(songs.dropFirst()), "Manual songs precede the album in insertion order")
        player.playNext(songs[4])
        expect(player, [songs[0], songs[4], extra, another, songs[1], songs[2], songs[3], songs[5]], "Play Next takes priority over manual additions")
        player.addToQueue(songs[2])
        expect(player, [songs[0], songs[4], extra, another, songs[2], songs[1], songs[3], songs[5]], "Existing song moves to the end of manual additions without duplication")
        player.addToQueue(extra)
        expect(player, [songs[0], songs[4], another, songs[2], extra, songs[1], songs[3], songs[5]], "Re-adding a manual song moves it to the end of manual additions")
        let beforeCurrentAddition = player.queue
        player.addToQueue(songs[0])
        expect(player, beforeCurrentAddition, "Adding the current song does nothing")

        player.removeFromQueue(extra)
        player.removeFromQueue(another)
        player.removeFromQueue(songs[2])
        player.removeFromQueue(songs[4])
        player.addToQueue(extra)
        expect(player, [songs[0], extra, songs[1], songs[3], songs[5]], "Removed manual songs no longer affect insertion")
        print("PASS: Add to Queue matches iPhone ordering, Play Next priority, deduplication, and removal")

        player.play(songs[0], from: songs)
        player.moveQueuedTrack(songs[5].id, to: songs[2].id)
        player.addToQueue(extra)
        expect(player, [songs[0], extra, songs[1], songs[5], songs[2], songs[3], songs[4]], "Playlist reordering does not extend the manual addition block")
        player.play(songs[0], from: songs)
        player.addToQueue(another)
        expect(player, [songs[0], another] + Array(songs.dropFirst()), "Starting a new collection resets manual ordering")

        player.play(songs[5], from: songs)
        player.isPlaying = false
        player.elapsed = 19
        player.addToQueue(extra)
        player.addToQueue(another)
        player.moveQueuedTrack(extra.id, to: another.id)
        expect(player, songs + [another, extra], "Queue edits work after the final album song")
        precondition(!player.isPlaying && player.elapsed == 19, "Queue edits preserve paused playback")
        print("PASS: reorder/add interaction, collection reset, end of queue, and paused playback")
    }

    private static func expect(_ player: MacPlayerViewModel, _ expected: [Track], _ message: String) {
        precondition(player.queue.map(\.id) == expected.map(\.id),
                     "\(message): got \(player.queue.map(\.title))")
        let currentIndex = expected.firstIndex { $0.id == player.currentTrack?.id }
        for (index, track) in expected.enumerated() {
            precondition(player.queueIndex(for: track.id) == index, "Queue lookup must follow every edit")
            let movable = track.id != player.currentTrack?.id && (currentIndex.map { index > $0 } ?? true)
            precondition(player.canMoveQueuedTrack(track.id) == movable, "Only upcoming tracks may move")
        }
        precondition(player.queueIndex(for: UUID()) == nil)
    }
}
