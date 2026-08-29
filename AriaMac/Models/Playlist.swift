import Foundation

struct AriaPlaylist: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var subtitle: String
    var tracks: [Track]
    var coverImageData: Data?
    var revision: Int

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String,
        tracks: [Track],
        coverImageData: Data? = nil,
        revision: Int = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.tracks = tracks
        self.coverImageData = coverImageData
        self.revision = revision
    }
}

struct AriaServerPlaylist: Codable {
    var id: UUID
    var title: String
    var trackIDs: [UUID]
    var coverImageData: Data?
    var revision: Int

    init(playlist: AriaPlaylist) {
        id = playlist.id
        title = playlist.title
        trackIDs = playlist.tracks.map(\.id)
        coverImageData = playlist.coverImageData
        revision = playlist.revision
    }

    func playlist(using tracksByID: [UUID: Track]) -> AriaPlaylist {
        let tracks = trackIDs.compactMap { tracksByID[$0] }
        return AriaPlaylist(
            id: id,
            title: title,
            subtitle: tracks.count == 1 ? "1 song" : "\(tracks.count) songs",
            tracks: tracks,
            coverImageData: coverImageData,
            revision: revision
        )
    }
}

struct AriaAlbum: Identifiable, Hashable {
    var title: String
    var artist: String
    var year: Int
    var tracks: [Track]

    var id: String {
        title.localizedLowercase
    }

    var artworkTrack: Track? {
        tracks.first
    }

    var duration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }
}
