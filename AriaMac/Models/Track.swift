import Foundation

struct Track: Identifiable, Hashable, Codable {
    let id: UUID
    var serverID: String?
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var year: Int
    var trackNumber: Int?
    var artwork: ArtworkPalette
    var streamURL: URL?
    var artworkURL: URL?
    var isExplicit: Bool

    init(
        id: UUID = UUID(),
        serverID: String? = nil,
        title: String,
        artist: String = "Unknown Artist",
        album: String = "Unknown Album",
        duration: TimeInterval = 0,
        year: Int = 0,
        trackNumber: Int? = nil,
        artwork: ArtworkPalette = .fallback,
        streamURL: URL? = nil,
        artworkURL: URL? = nil,
        isExplicit: Bool = false
    ) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.year = year
        self.trackNumber = trackNumber
        self.artwork = artwork
        self.streamURL = streamURL
        self.artworkURL = artworkURL
        self.isExplicit = isExplicit
    }

    var hasPlayableStream: Bool {
        streamURL != nil
    }
}

struct TrackMetadataDraft {
    var trackID: UUID
    var title: String
    var artist: String
    var album: String
    var year: String
    var trackNumber: String
    var duration: String
    var streamURL: String
    var artworkURL: String
    var isExplicit: Bool

    init(track: Track) {
        trackID = track.id
        title = track.title
        artist = track.artist
        album = track.album
        year = track.year > 0 ? String(track.year) : ""
        trackNumber = track.trackNumber.map(String.init) ?? ""
        duration = track.duration > 0 ? track.duration.ariaClockText : ""
        streamURL = track.streamURL?.absoluteString ?? ""
        artworkURL = track.artworkURL?.absoluteString ?? ""
        isExplicit = track.isExplicit
    }

    func validatedUpdate() throws -> TrackMetadataUpdate {
        let cleanTitle = required(title, field: "Title")
        let cleanArtist = optional(artist) ?? "Unknown Artist"
        let cleanAlbum = optional(album) ?? "Unknown Album"

        return TrackMetadataUpdate(
            title: cleanTitle,
            artist: cleanArtist,
            album: cleanAlbum,
            year: try optionalInt(year, field: "Year"),
            trackNumber: try optionalInt(trackNumber, field: "Track number"),
            duration: try optionalDuration(duration),
            streamURL: optional(streamURL),
            artworkURL: optional(artworkURL),
            isExplicit: isExplicit
        )
    }

    private func required(_ value: String, field: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Track" : trimmed
    }

    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalInt(_ value: String, field: String) throws -> Int? {
        guard let trimmed = optional(value) else { return nil }
        guard let parsed = Int(trimmed), parsed >= 0 else {
            throw TrackMetadataValidationError.invalidNumber(field)
        }

        return parsed
    }

    private func optionalDuration(_ value: String) throws -> TimeInterval? {
        guard let trimmed = optional(value) else { return nil }

        if let seconds = Double(trimmed.replacingOccurrences(of: ",", with: ".")), seconds >= 0 {
            return seconds
        }

        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2:
            return parts[0] * 60 + parts[1]
        case 3:
            return parts[0] * 3_600 + parts[1] * 60 + parts[2]
        default:
            throw TrackMetadataValidationError.invalidDuration
        }
    }
}

struct TrackMetadataUpdate: Encodable {
    var title: String
    var artist: String
    var album: String
    var year: Int?
    var trackNumber: Int?
    var duration: TimeInterval?
    var streamURL: String?
    var artworkURL: String?
    var isExplicit: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case artist
        case album
        case year
        case trackNumber
        case duration
        case streamURL
        case artworkURL
        case isExplicit
    }

    func applying(to track: Track, resolvingAgainst baseURL: URL) -> Track {
        var updatedTrack = track
        updatedTrack.title = title
        updatedTrack.artist = artist
        updatedTrack.album = album
        updatedTrack.year = year ?? 0
        updatedTrack.trackNumber = trackNumber
        updatedTrack.duration = duration ?? 0
        updatedTrack.streamURL = resolvedURL(from: streamURL, baseURL: baseURL)
        updatedTrack.artworkURL = resolvedURL(from: artworkURL, baseURL: baseURL)
        updatedTrack.isExplicit = isExplicit
        return updatedTrack
    }

    private func resolvedURL(from rawValue: String?, baseURL: URL) -> URL? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if let url = URL(string: value), url.scheme != nil {
            return url
        }

        if value.hasPrefix("/") {
            return URL(string: value, relativeTo: baseURL)?.absoluteURL
        }

        return baseURL.appendingPathComponent(value).absoluteURL
    }
}

enum TrackMetadataValidationError: LocalizedError {
    case invalidNumber(String)
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .invalidNumber(let field):
            "\(field) must be a whole number."
        case .invalidDuration:
            "Duration must be seconds, M:SS, or H:MM:SS."
        }
    }
}

struct ArtworkPalette: Hashable, Codable {
    var topHex: String
    var bottomHex: String
    var symbolName: String

    static let fallback = ArtworkPalette(
        topHex: "1DB954",
        bottomHex: "121212",
        symbolName: "music.note"
    )
}

enum RepeatMode: String, CaseIterable, Identifiable {
    case off
    case one
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:
            "Repeat off"
        case .one:
            "Repeat one"
        case .all:
            "Repeat all"
        }
    }

    var systemImage: String {
        switch self {
        case .off, .all:
            "repeat"
        case .one:
            "repeat.1"
        }
    }
}
