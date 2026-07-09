import Foundation

struct AriaServerClient {
    var baseURLs: [URL]
    var tracksPath: String

    init(
        baseURLs: [URL] = Self.defaultBaseURLs,
        tracksPath: String = "api/tracks"
    ) {
        self.baseURLs = Self.unique(baseURLs)
        self.tracksPath = tracksPath
    }

    func fetchTracks(pageSize: Int = 250) async throws -> [Track] {
        var failures: [String] = []

        for baseURL in baseURLs {
            do {
                return try await fetchTracks(from: baseURL, pageSize: pageSize)
            } catch {
                failures.append("\(baseURL.absoluteString): \(error.localizedDescription)")
            }
        }

        throw AriaServerError.unreachable(failures)
    }

    private func fetchTracks(from baseURL: URL, pageSize: Int) async throws -> [Track] {
        var offset = 0
        var tracks: [Track] = []
        var seenPageSignatures = Set<String>()

        while true {
            let page = try await fetchTrackPage(offset: offset, limit: pageSize, baseURL: baseURL)
            let pageSignature = page.identitySignature

            guard !seenPageSignatures.contains(pageSignature) else {
                break
            }

            seenPageSignatures.insert(pageSignature)
            tracks.append(contentsOf: page.tracks(resolvingAgainst: baseURL))

            guard page.hasMore, !page.tracks.isEmpty else {
                break
            }

            offset += page.tracks.count
        }

        guard !tracks.isEmpty else {
            throw AriaServerError.emptyCatalog
        }

        return uniqued(tracks)
    }

    func fetchTrackMetadata(for track: Track) async throws -> Track {
        var failures: [String] = []

        for baseURL in baseURLs {
            do {
                let (data, _) = try await sendRequest(to: trackEndpoint(for: track, baseURL: baseURL), method: "GET")
                return try decodeTrack(from: data, fallback: track, baseURL: baseURL)
            } catch {
                failures.append("\(baseURL.absoluteString): \(error.localizedDescription)")
            }
        }

        throw AriaServerError.unreachable(failures)
    }

    func updateTrackMetadata(for track: Track, metadata: TrackMetadataUpdate) async throws -> Track {
        let body = try JSONEncoder().encode(metadata)
        var failures: [String] = []

        for baseURL in baseURLs {
            let endpoint = trackEndpoint(for: track, baseURL: baseURL)
            var firstError: Error?

            for method in ["PATCH", "PUT"] {
                do {
                    let (data, response) = try await sendRequest(
                        to: endpoint,
                        method: method,
                        body: body,
                        contentType: "application/json"
                    )

                    let fallback = metadata.applying(to: track, resolvingAgainst: baseURL)
                    guard !data.isEmpty, response.statusCode != 204 else {
                        return fallback
                    }

                    return try decodeTrack(from: data, fallback: fallback, baseURL: baseURL)
                } catch AriaServerError.badStatus(let statusCode) where [404, 405, 501].contains(statusCode) {
                    firstError = firstError ?? AriaServerError.badStatus(statusCode)
                    continue
                } catch {
                    firstError = firstError ?? error
                    break
                }
            }

            if let firstError {
                failures.append("\(baseURL.absoluteString): \(firstError.localizedDescription)")
            }
        }

        throw AriaServerError.unreachable(failures)
    }

    func startDownload(_ request: AriaDownloadRequest) async throws -> AriaDownloadJob {
        let body = try JSONEncoder().encode(request)
        var failures: [String] = []

        for baseURL in baseURLs {
            do {
                let (data, _) = try await sendRequest(
                    to: downloadsEndpoint(baseURL: baseURL),
                    method: "POST",
                    body: body,
                    contentType: "application/json"
                )
                return try decodeDownloadJob(from: data)
            } catch {
                failures.append("\(baseURL.absoluteString): \(error.localizedDescription)")
            }
        }

        throw AriaServerError.unreachable(failures)
    }

    func fetchDownloadStatus(id: String) async throws -> AriaDownloadJob {
        var failures: [String] = []

        for baseURL in baseURLs {
            do {
                let (data, _) = try await sendRequest(to: downloadStatusEndpoint(id: id, baseURL: baseURL), method: "GET")
                return try decodeDownloadJob(from: data)
            } catch {
                failures.append("\(baseURL.absoluteString): \(error.localizedDescription)")
            }
        }

        throw AriaServerError.unreachable(failures)
    }

    private func fetchTrackPage(offset: Int, limit: Int, baseURL: URL) async throws -> TracksPage {
        var components = URLComponents(
            url: tracksEndpoint(baseURL: baseURL),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let url = components?.url else {
            throw AriaServerError.invalidURL
        }

        let (data, _) = try await sendRequest(to: url, method: "GET")

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(TracksPage.self, from: data)
        } catch {
            throw AriaServerError.decoding(error)
        }
    }

    private func uniqued(_ tracks: [Track]) -> [Track] {
        var seen = Set<UUID>()
        return tracks.filter { track in
            seen.insert(track.id).inserted
        }
    }

    private func sendRequest(
        to url: URL,
        method: String,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        request.httpBody = body

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AriaServerError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw AriaServerError.badStatus(httpResponse.statusCode)
        }

        return (data, httpResponse)
    }

    private func decodeTrack(from data: Data, fallback: Track, baseURL: URL) throws -> Track {
        let decoder = JSONDecoder()

        if let payload = try? decoder.decode(ServerTrackPayload.self, from: data) {
            return payload.track(resolvingAgainst: baseURL, fallbackID: fallback.id)
        }

        if let response = try? decoder.decode(SingleTrackResponse.self, from: data) {
            return response.item.track(resolvingAgainst: baseURL, fallbackID: fallback.id)
        }

        if let page = try? decoder.decode(TracksPage.self, from: data), let firstPayload = page.tracks.first {
            return firstPayload.track(resolvingAgainst: baseURL, fallbackID: fallback.id)
        }

        throw AriaServerError.decoding(
            DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Expected a track metadata object in the response."
                )
            )
        )
    }

    private func decodeDownloadJob(from data: Data) throws -> AriaDownloadJob {
        do {
            return try JSONDecoder().decode(AriaDownloadJob.self, from: data)
        } catch {
            throw AriaServerError.decoding(error)
        }
    }

    private func trackEndpoint(for track: Track, baseURL: URL) -> URL {
        tracksEndpoint(baseURL: baseURL).appendingPathComponent(track.serverID ?? track.id.uuidString)
    }

    private func tracksEndpoint(baseURL: URL) -> URL {
        tracksPath
            .split(separator: "/")
            .reduce(baseURL) { url, component in
                url.appendingPathComponent(String(component))
            }
    }

    private func downloadsEndpoint(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("downloads")
    }

    private func downloadStatusEndpoint(id: String, baseURL: URL) -> URL {
        downloadsEndpoint(baseURL: baseURL).appendingPathComponent(id)
    }

    private static let defaultBaseURLs = [
        URL(string: "http://100.93.250.104:8000")!,
        URL(string: "http://192.168.0.16:8000")!
    ]

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []

        return urls.filter { url in
            let key = url.absoluteString
            guard !seen.contains(key) else { return false }

            seen.insert(key)
            return true
        }
    }
}

struct AriaDownloadRequest: Encodable {
    var link: String
    var album: String
    var albumArtist: String
    var year: String
}

struct AriaDownloadJob: Decodable, Identifiable, Equatable {
    var id: String
    var status: String
    var phase: String
    var message: String
    var progress: Double
    var album: String
    var albumArtist: String
    var year: String
    var filesStarted: Int
    var newFiles: Int?
    var error: String?
    var outputTail: [String]

    var isActive: Bool {
        status == "queued" || status == "running"
    }

    var isFinished: Bool {
        status == "succeeded" || status == "failed"
    }

    var isSuccessful: Bool {
        status == "succeeded"
    }

    var progressFraction: Double {
        min(max(progress, 0), 1)
    }
}

private struct SingleTrackResponse: Decodable {
    var item: ServerTrackPayload

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)

        if let item = container.decodeTrackPayload(forKeyNames: ["track", "item", "song", "data", "result"]) {
            self.item = item
            return
        }

        let nestedData = container.nestedContainerIfPresent(forKeyNames: ["data", "payload", "response"])
        if let item = nestedData?.decodeTrackPayload(forKeyNames: ["track", "item", "song", "result"]) {
            self.item = item
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a nested track metadata object."
            )
        )
    }
}

private struct TracksPage: Decodable {
    var items: [ServerTrackPayload]
    var total: Int?
    var offset: Int
    var limit: Int
    var hasMore: Bool

    var tracks: [ServerTrackPayload] {
        items
    }

    var identitySignature: String {
        items.map(\.identitySeed).joined(separator: "|")
    }

    init(from decoder: Decoder) throws {
        if let items = try? [ServerTrackPayload](from: decoder) {
            self.items = items
            self.total = items.count
            self.offset = 0
            self.limit = max(items.count, 1)
            self.hasMore = false
            return
        }

        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        let nestedData = container.nestedContainerIfPresent(forKeyNames: ["data", "payload", "response"])

        guard
            let decodedItems = container.decodeTrackArray(forKeyNames: ["items", "tracks", "songs", "results", "data"])
                ?? nestedData?.decodeTrackArray(forKeyNames: ["items", "tracks", "songs", "results"])
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a track array or a paged track response."
                )
            )
        }

        self.items = decodedItems
        self.total = container.decodeLossyInt(forKeyNames: ["total", "count", "totalCount", "total_count"])
            ?? nestedData?.decodeLossyInt(forKeyNames: ["total", "count", "totalCount", "total_count"])
        self.offset = container.decodeLossyInt(forKeyNames: ["offset", "skip", "start"])
            ?? nestedData?.decodeLossyInt(forKeyNames: ["offset", "skip", "start"])
            ?? 0
        self.limit = container.decodeLossyInt(forKeyNames: ["limit", "pageSize", "page_size"])
            ?? nestedData?.decodeLossyInt(forKeyNames: ["limit", "pageSize", "page_size"])
            ?? max(decodedItems.count, 1)

        let explicitHasMore = container.decodeLossyBool(forKeyNames: ["hasMore", "has_more", "hasNextPage", "has_next_page"])
            ?? nestedData?.decodeLossyBool(forKeyNames: ["hasMore", "has_more", "hasNextPage", "has_next_page"])
        let nextToken = container.decodeLossyString(forKeyNames: ["next", "nextPage", "next_page"])
            ?? nestedData?.decodeLossyString(forKeyNames: ["next", "nextPage", "next_page"])

        if let explicitHasMore {
            self.hasMore = explicitHasMore
        } else if let total = self.total {
            self.hasMore = self.offset + decodedItems.count < total
        } else if let nextToken {
            self.hasMore = !nextToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            self.hasMore = decodedItems.count >= self.limit
        }
    }

    func tracks(resolvingAgainst baseURL: URL) -> [Track] {
        items.map { $0.track(resolvingAgainst: baseURL) }
    }
}

enum AriaServerError: LocalizedError {
    case invalidURL
    case invalidResponse
    case badStatus(Int)
    case emptyCatalog
    case decoding(Error)
    case unreachable([String])

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The song server URL is not valid."
        case .invalidResponse:
            "The song server returned an invalid response."
        case .badStatus(let statusCode):
            "The song server returned HTTP \(statusCode)."
        case .emptyCatalog:
            "The song server did not find any songs."
        case .decoding(let error):
            "The song server response could not be read: \(error.localizedDescription)"
        case .unreachable(let failures):
            "Tried \(failures.joined(separator: "\n"))"
        }
    }
}

private struct ServerTrackPayload: Decodable {
    var idSeed: String?
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    var year: Int?
    var trackNumber: Int?
    var streamURLString: String?
    var artworkURLString: String?
    var isExplicit: Bool
    var artwork: ArtworkPalette?

    var identitySeed: String {
        idSeed ?? streamURLString ?? "\(artist ?? "")-\(album ?? "")-\(title ?? "")-\(trackNumber ?? 0)"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)

        idSeed = container.decodeLossyString(forKeyNames: ["id", "uuid", "trackId", "track_id"])
        title = container.decodeLossyString(forKeyNames: ["title", "name", "trackTitle", "track_title"])
        artist = container.decodeLossyString(forKeyNames: ["artist", "artistName", "artist_name", "albumArtist", "album_artist"])
        album = container.decodeLossyString(forKeyNames: ["album", "albumName", "album_name", "collection"])
        duration = container.decodeDuration()
        year = container.decodeLossyInt(forKeyNames: ["year", "releaseYear", "release_year"])
        trackNumber = container.decodeLossyInt(forKeyNames: ["trackNumber", "track_number", "track", "number"])
        streamURLString = container.decodeLossyString(
            forKeyNames: ["streamURL", "streamUrl", "stream_url", "stream", "audioURL", "audioUrl", "audio_url", "audio", "url", "src", "path", "fileURL", "fileUrl", "file_url"]
        )
        artworkURLString = container.decodeLossyString(
            forKeyNames: ["artworkURL", "artworkUrl", "artwork_url", "coverURL", "coverUrl", "cover_url", "imageURL", "imageUrl", "image_url", "artwork", "cover", "image"]
        )

        if streamURLString == nil {
            streamURLString = container
                .nestedContainerIfPresent(forKeyNames: ["stream", "audio", "file"])
                .flatMap { $0.decodeLossyString(forKeyNames: ["url", "src", "href", "path"]) }
        }

        if artworkURLString == nil {
            artworkURLString = container
                .nestedContainerIfPresent(forKeyNames: ["artwork", "cover", "image"])
                .flatMap { $0.decodeLossyString(forKeyNames: ["url", "src", "href", "path"]) }
        }

        isExplicit = container.decodeLossyBool(forKeyNames: ["isExplicit", "explicit", "is_explicit"]) ?? false
        artwork = container.decodeArtworkPalette()
    }

    func track(resolvingAgainst baseURL: URL, fallbackID: UUID? = nil) -> Track {
        let resolvedStreamURL = resolvedURL(from: streamURLString, baseURL: baseURL)
        let resolvedArtworkURL = resolvedURL(from: artworkURLString, baseURL: baseURL)
        let cleanTitle = cleaned(title) ?? titleFromURL(resolvedStreamURL) ?? "Untitled Track"
        let cleanArtist = cleaned(artist) ?? "Unknown Artist"
        let cleanAlbum = cleaned(album) ?? "Unknown Album"
        let seed = idSeed ?? resolvedStreamURL?.absoluteString ?? "\(cleanArtist)|\(cleanAlbum)|\(cleanTitle)|\(trackNumber ?? 0)"

        return Track(
            id: UUID(uuidString: seed) ?? fallbackID ?? StableID.uuid(from: seed),
            serverID: cleaned(idSeed),
            title: cleanTitle,
            artist: cleanArtist,
            album: cleanAlbum,
            duration: max(duration ?? 0, 0),
            year: year ?? 0,
            trackNumber: trackNumber,
            artwork: artwork ?? ArtworkFactory.palette(for: seed),
            streamURL: resolvedStreamURL,
            artworkURL: resolvedArtworkURL,
            isExplicit: isExplicit
        )
    }

    private func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func titleFromURL(_ url: URL?) -> String? {
        guard let url else { return nil }
        let filename = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
        return cleaned(filename.replacingOccurrences(of: "_", with: " "))
    }

    private func resolvedURL(from rawValue: String?, baseURL: URL) -> URL? {
        guard let value = cleaned(rawValue) else { return nil }

        if let url = URL(string: value), url.scheme != nil {
            return url
        }

        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? value
        if let url = URL(string: encodedValue), url.scheme != nil {
            return url
        }

        if value.hasPrefix("/") {
            return URL(string: encodedValue, relativeTo: baseURL)?.absoluteURL
        }

        return baseURL.appendingPathComponent(value).absoluteURL
    }
}

private struct FlexibleCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == FlexibleCodingKey {
    func decodeTrackPayload(forKeyNames names: [String]) -> ServerTrackPayload? {
        for name in names {
            let key = FlexibleCodingKey(name)
            if let value = try? decode(ServerTrackPayload.self, forKey: key) {
                return value
            }
        }

        return nil
    }

    func decodeTrackArray(forKeyNames names: [String]) -> [ServerTrackPayload]? {
        for name in names {
            let key = FlexibleCodingKey(name)
            if let value = try? decode([ServerTrackPayload].self, forKey: key) {
                return value
            }
        }

        return nil
    }

    func nestedContainerIfPresent(forKeyNames names: [String]) -> KeyedDecodingContainer<FlexibleCodingKey>? {
        for name in names {
            let key = FlexibleCodingKey(name)
            if let value = try? nestedContainer(keyedBy: FlexibleCodingKey.self, forKey: key) {
                return value
            }
        }

        return nil
    }

    func decodeDuration() -> TimeInterval? {
        if let milliseconds = decodeLossyDouble(forKeyNames: ["durationMS", "durationMs", "duration_ms", "lengthMS", "lengthMs", "length_ms"]) {
            return milliseconds / 1_000
        }

        return decodeLossyDouble(forKeyNames: ["duration", "durationSeconds", "duration_seconds", "length", "seconds"])
    }

    func decodeArtworkPalette() -> ArtworkPalette? {
        if let direct = try? decode(ArtworkPalette.self, forKey: FlexibleCodingKey("artworkPalette")) {
            return direct
        }

        if let direct = try? decode(ArtworkPalette.self, forKey: FlexibleCodingKey("artwork")) {
            return direct
        }

        guard let nested = nestedContainerIfPresent(forKeyNames: ["palette", "artworkPalette", "artwork_palette", "artwork"]) else {
            return nil
        }

        guard
            let topHex = nested.decodeLossyString(forKeyNames: ["topHex", "top", "primary", "primaryHex"]),
            let bottomHex = nested.decodeLossyString(forKeyNames: ["bottomHex", "bottom", "secondary", "secondaryHex"])
        else {
            return nil
        }

        return ArtworkPalette(
            topHex: topHex,
            bottomHex: bottomHex,
            symbolName: nested.decodeLossyString(forKeyNames: ["symbolName", "symbol", "icon"]) ?? "music.note"
        )
    }

    func decodeLossyString(forKeyNames names: [String]) -> String? {
        for name in names {
            let key = FlexibleCodingKey(name)

            if let value = try? decodeIfPresent(String.self, forKey: key) {
                return value
            }

            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }

            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return String(value)
            }

            if let value = try? decodeIfPresent(Bool.self, forKey: key) {
                return String(value)
            }
        }

        return nil
    }

    func decodeLossyInt(forKeyNames names: [String]) -> Int? {
        for name in names {
            let key = FlexibleCodingKey(name)

            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value
            }

            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }

            if let value = try? decodeIfPresent(String.self, forKey: key), let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return intValue
            }
        }

        return nil
    }

    func decodeLossyDouble(forKeyNames names: [String]) -> Double? {
        for name in names {
            let key = FlexibleCodingKey(name)

            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return value
            }

            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }

            if let value = try? decodeIfPresent(String.self, forKey: key), let parsed = Self.parseDoubleOrClock(value) {
                return parsed
            }
        }

        return nil
    }

    func decodeLossyBool(forKeyNames names: [String]) -> Bool? {
        for name in names {
            let key = FlexibleCodingKey(name)

            if let value = try? decodeIfPresent(Bool.self, forKey: key) {
                return value
            }

            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value != 0
            }

            if let value = try? decodeIfPresent(String.self, forKey: key) {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase {
                case "true", "yes", "1":
                    return true
                case "false", "no", "0":
                    return false
                default:
                    break
                }
            }
        }

        return nil
    }

    static func parseDoubleOrClock(_ value: String) -> Double? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")

        if let seconds = Double(normalized) {
            return seconds
        }

        let parts = normalized.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2:
            return parts[0] * 60 + parts[1]
        case 3:
            return parts[0] * 3_600 + parts[1] * 60 + parts[2]
        default:
            return nil
        }
    }
}

private enum StableID {
    static func uuid(from seed: String) -> UUID {
        let first = fnv1a(seed, offset: 14_695_981_039_346_656_037)
        let second = fnv1a(seed.reversedString, offset: 10_995_116_282_211)
        let bytes = bytes(from: first) + bytes(from: second)

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func fnv1a(_ value: String, offset: UInt64) -> UInt64 {
        var hash = offset
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return hash
    }

    private static func bytes(from value: UInt64) -> [UInt8] {
        (0..<8).map { shift in
            UInt8((value >> UInt64((7 - shift) * 8)) & 0xFF)
        }
    }
}

private enum ArtworkFactory {
    private static let palettes = [
        ("1DB954", "0B3D2E", "music.note"),
        ("57C7FF", "102A43", "waveform"),
        ("F6C85F", "33270A", "opticaldisc"),
        ("FF6B6B", "351515", "music.quarternote.3"),
        ("A3E635", "1C2A0D", "music.note.list"),
        ("C084FC", "251237", "sparkles")
    ]

    static func palette(for seed: String) -> ArtworkPalette {
        let index = Int(StableID.uuid(from: seed).uuid.0) % palettes.count
        let palette = palettes[index]
        return ArtworkPalette(topHex: palette.0, bottomHex: palette.1, symbolName: palette.2)
    }
}

private extension String {
    var reversedString: String {
        String(reversed())
    }
}
