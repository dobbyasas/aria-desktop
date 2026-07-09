import SwiftUI

enum LibrarySection: String, CaseIterable, Identifiable {
    case songs
    case albums
    case playlists
    case queue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .songs:
            "Songs"
        case .albums:
            "Albums"
        case .playlists:
            "Playlists"
        case .queue:
            "Queue"
        }
    }

    var systemImage: String {
        switch self {
        case .songs:
            "music.note.list"
        case .albums:
            "square.stack"
        case .playlists:
            "music.note.list"
        case .queue:
            "text.line.first.and.arrowtriangle.forward"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @State private var selectedSection: LibrarySection = .songs
    @State private var searchText = ""

    private var activeSection: LibrarySection {
        selectedSection
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                LinearGradient(
                    colors: [Color.ariaPanel.opacity(0.58), Color.ariaBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    if let error = player.catalogErrorMessage, !player.catalog.isEmpty {
                        InlineStatusBanner(
                            message: error,
                            systemImage: "wifi.exclamationmark",
                            actionTitle: "Retry"
                        ) {
                            Task { await player.refreshCatalog() }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                    }

                    content
                    PlayerBar()
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(
            isPresented: Binding(
                get: { player.metadataEditorSession != nil },
                set: { isPresented in
                    if !isPresented {
                        player.cancelMetadataEditing()
                    }
                }
            )
        ) {
            if let session = player.metadataEditorSession {
                MetadataEditorSheet(session: session)
                    .environmentObject(player)
            }
        }
    }

    private var sidebar: some View {
        List {
            Section("Library") {
                ForEach(LibrarySection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        SidebarNavigationRow(
                            section: section,
                            isSelected: activeSection == section
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(activeSection == section ? Color.ariaAccent.opacity(0.18) : Color.clear)
                            .padding(.vertical, 1)
                    )
                }
            }

            Section("Server") {
                Label(serverStatusTitle, systemImage: serverStatusImage)
                    .foregroundStyle(serverStatusColor)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Aria")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(activeSection.title)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color.ariaTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.ariaTextSecondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer()

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.ariaTextSecondary)

                TextField("Search songs, artists, albums", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.ariaTextPrimary)

                if isSearching {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.ariaTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 190, idealWidth: 280, maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ariaSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.ariaDivider, lineWidth: 1)
                    )
            )

            Button {
                Task { await player.refreshCatalog() }
            } label: {
                if player.isCatalogLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 82)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(player.isCatalogLoading)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var content: some View {
        if player.catalog.isEmpty && player.isCatalogLoading {
            EmptyStateView(
                title: "Loading your library",
                message: "Pulling songs from the Aria server.",
                systemImage: "music.note"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = player.catalogErrorMessage, player.catalog.isEmpty {
            ServerErrorState(message: error)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch activeSection {
            case .songs:
                SongsView(tracks: filteredTracks, isSearching: isSearching)
            case .albums:
                AlbumsView(albums: filteredAlbums, isSearching: isSearching)
            case .playlists:
                PlaylistsView(playlists: player.playlists)
            case .queue:
                QueueView()
            }
        }
    }

    private var filteredTracks: [Track] {
        guard isSearching else { return player.catalog }

        let tokens = searchText.casefoldedTokens
        return player.catalog.filter { track in
            let text = "\(track.title) \(track.artist) \(track.album)".localizedLowercase
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    private var filteredAlbums: [AriaAlbum] {
        guard isSearching else { return player.albums }

        let tokens = searchText.casefoldedTokens
        return player.albums.filter { album in
            let text = "\(album.title) \(album.artist)".localizedLowercase
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    private var subtitle: String {
        switch activeSection {
        case .songs:
            return "\(filteredTracks.count) songs"
        case .albums:
            return "\(filteredAlbums.count) albums"
        case .playlists:
            return "\(player.playlists.count) playlists"
        case .queue:
            return "\(player.upNext.count) upcoming"
        }
    }

    private var serverStatusTitle: String {
        if player.isCatalogLoading {
            return "Syncing"
        }

        if player.catalogErrorMessage != nil {
            return "Offline"
        }

        return player.catalog.isEmpty ? "Waiting" : "Connected"
    }

    private var serverStatusImage: String {
        if player.isCatalogLoading {
            return "arrow.triangle.2.circlepath"
        }

        return player.catalogErrorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var serverStatusColor: Color {
        player.catalogErrorMessage == nil ? Color.ariaTextSecondary : Color.orange
    }
}

struct SidebarNavigationRow: View {
    let section: LibrarySection
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: section.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.ariaAccent : Color.ariaTextSecondary)

            Text(section.title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.ariaTextPrimary : Color.ariaTextSecondary)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SongsView: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    let tracks: [Track]
    let isSearching: Bool

    var body: some View {
        if tracks.isEmpty {
            EmptyStateView(
                title: isSearching ? "No songs found" : "No songs yet",
                message: isSearching ? "Try a different search." : "Refresh after adding songs to your server.",
                systemImage: "music.note.list"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                let showsAlbum = proxy.size.width >= 760

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        LibraryOverviewCard(
                            tracks: tracks,
                            title: isSearching ? "Search Results" : "Your Music",
                            subtitle: "\(tracks.count) songs ready to play"
                        )

                        VStack(spacing: 0) {
                            TrackListHeader(showAlbum: showsAlbum)

                            LazyVStack(spacing: 2) {
                                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRow(
                                        track: track,
                                        source: tracks,
                                        index: index + 1,
                                        showAlbum: showsAlbum
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

struct AlbumsView: View {
    let albums: [AriaAlbum]
    let isSearching: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 174, maximum: 220), spacing: 16)
    ]

    var body: some View {
        if albums.isEmpty {
            EmptyStateView(
                title: isSearching ? "No albums found" : "No albums yet",
                message: isSearching ? "Try a different search." : "Albums appear after Aria loads songs with album metadata.",
                systemImage: "square.stack"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(albums) { album in
                        AlbumCard(album: album)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

struct PlaylistsView: View {
    let playlists: [AriaPlaylist]

    var body: some View {
        if playlists.isEmpty {
            EmptyStateView(
                title: "No playlists yet",
                message: "Aria will show server playlists here when they are available.",
                systemImage: "music.note.list"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(playlists) { playlist in
                        PlaylistCard(playlist: playlist)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

struct QueueView: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    var body: some View {
        if player.currentTrack == nil && player.queue.isEmpty {
            EmptyStateView(
                title: "Queue is empty",
                message: "Start a song, album, or playlist to build the queue.",
                systemImage: "text.line.first.and.arrowtriangle.forward"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                let showsAlbum = proxy.size.width >= 760

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let currentTrack = player.currentTrack {
                            NowPlayingPanel(track: currentTrack)
                        }

                        VStack(spacing: 0) {
                            TrackListHeader(title: "Up Next", showAlbum: showsAlbum)

                            if player.upNext.isEmpty {
                                EmptyStateView(
                                    title: "Nothing up next",
                                    message: "Add songs with Play Next or start another album.",
                                    systemImage: "list.bullet.rectangle"
                                )
                                .frame(maxWidth: .infinity, minHeight: 220)
                            } else {
                                LazyVStack(spacing: 2) {
                                    ForEach(Array(player.upNext.enumerated()), id: \.element.id) { index, track in
                                        TrackRow(
                                            track: track,
                                            source: player.queue,
                                            index: index + 1,
                                            showAlbum: showsAlbum,
                                            canRemoveFromQueue: true
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

struct LibraryOverviewCard: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    let tracks: [Track]
    var title: String
    var subtitle: String

    private var artworkTrack: Track? {
        player.currentTrack ?? tracks.first
    }

    var body: some View {
        HStack(spacing: 18) {
            if let artworkTrack {
                ArtworkView(track: artworkTrack, size: 104, cornerRadius: 10)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.ariaPanelRaised)
                    .frame(width: 104, height: 104)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(Color.ariaAccent)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.ariaTextPrimary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.ariaTextSecondary)

                if let currentTrack = player.currentTrack {
                    Text("Now playing: \(currentTrack.title)")
                        .font(.caption)
                        .foregroundStyle(Color.ariaAccent)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    if let firstTrack = tracks.first {
                        player.play(firstTrack, from: tracks)
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.ariaAccent)

                Button {
                    if !player.isShuffleEnabled {
                        player.toggleShuffle()
                    }

                    if let firstTrack = tracks.randomElement() ?? tracks.first {
                        player.play(firstTrack, from: tracks)
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.ariaSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.ariaDivider, lineWidth: 1)
                )
        )
    }
}

struct NowPlayingPanel: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    let track: Track

    var body: some View {
        HStack(spacing: 18) {
            ArtworkView(track: track, size: 118, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Now Playing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ariaAccent)
                    .textCase(.uppercase)

                Text(track.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.ariaTextPrimary)
                    .lineLimit(2)

                Text("\(track.artist) - \(track.album)")
                    .font(.subheadline)
                    .foregroundStyle(Color.ariaTextSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                player.playPause()
            } label: {
                Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.ariaAccent)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.ariaSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.ariaDivider, lineWidth: 1)
                )
        )
    }
}

struct TrackListHeader: View {
    var title: String = "Tracks"
    var showAlbum = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .frame(width: 44, alignment: .leading)

                Text("Title")
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showAlbum {
                    Text("Album")
                        .frame(width: 220, alignment: .leading)
                }

                Text("Time")
                    .frame(width: 58, alignment: .trailing)

                Spacer()
                    .frame(width: 28)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.ariaTextSecondary)
            .textCase(.uppercase)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .overlay(Color.ariaDivider)
        }
    }
}

struct TrackRow: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @State private var isHovering = false

    let track: Track
    let source: [Track]
    var index: Int?
    var showAlbum = true
    var canRemoveFromQueue = false

    private var isCurrentTrack: Bool {
        player.currentTrack?.id == track.id
    }

    private var playableSource: [Track] {
        source.isEmpty ? [track] : source
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                player.play(track, from: playableSource)
            } label: {
                ZStack {
                    if isHovering || isCurrentTrack {
                        Image(systemName: isCurrentTrack && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                    } else if let index {
                        Text(String(index))
                            .font(.caption.monospacedDigit())
                    }
                }
                .frame(width: 30, height: 30)
                .foregroundStyle(isCurrentTrack ? Color.black : Color.ariaTextSecondary)
                .background(
                    Circle()
                        .fill(isCurrentTrack ? Color.ariaAccent : Color.white.opacity(isHovering ? 0.11 : 0.04))
                )
            }
            .buttonStyle(.plain)
            .help("Play")

            ArtworkView(track: track, size: 44, cornerRadius: 7)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 14, weight: isCurrentTrack ? .semibold : .medium))
                        .foregroundStyle(isCurrentTrack ? Color.ariaAccent : Color.ariaTextPrimary)
                        .lineLimit(1)

                    if track.isExplicit {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.ariaBackground)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.ariaTextSecondary)
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }

                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(Color.ariaTextSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showAlbum {
                Text(track.album)
                    .font(.caption)
                    .foregroundStyle(Color.ariaTextSecondary)
                    .lineLimit(1)
                    .frame(width: 220, alignment: .leading)
            }

            Text(track.duration.ariaDurationText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.ariaTextSecondary)
                .frame(width: 58, alignment: .trailing)

            if canRemoveFromQueue {
                Button {
                    player.removeFromQueue(track)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ariaTextSecondary)
                .help("Remove from queue")
            } else {
                Button {
                    player.playNext(track)
                } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isHovering ? Color.ariaTextSecondary : Color.clear)
                .help("Play next")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            player.play(track, from: playableSource)
        }
        .contextMenu {
            Button("Play") {
                player.play(track, from: playableSource)
            }

            Button("Play Next") {
                player.playNext(track)
            }

            Divider()

            Button("Edit Metadata") {
                player.editMetadata(for: track)
            }
        }
    }

    private var rowBackground: Color {
        if isCurrentTrack {
            return Color.ariaAccent.opacity(0.13)
        }

        return isHovering ? Color.white.opacity(0.07) : Color.clear
    }
}

struct AlbumCard: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    let album: AriaAlbum

    var body: some View {
        Button {
            if let firstTrack = album.tracks.first {
                player.play(firstTrack, from: album.tracks)
            }
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                if let artworkTrack = album.artworkTrack {
                    ArtworkView(track: artworkTrack, size: 158, cornerRadius: 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title)
                        .font(.headline)
                        .foregroundStyle(Color.ariaTextPrimary)
                        .lineLimit(2)

                    Text(album.artist)
                        .font(.subheadline)
                        .foregroundStyle(Color.ariaTextSecondary)
                        .lineLimit(1)

                    Text(albumSubtitle)
                        .font(.caption)
                        .foregroundStyle(Color.ariaTextSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ariaSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.ariaDivider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play Album") {
                if let firstTrack = album.tracks.first {
                    player.play(firstTrack, from: album.tracks)
                }
            }
        }
    }

    private var albumSubtitle: String {
        let yearText = album.year > 0 ? "\(album.year) - " : ""
        let countText = album.tracks.count == 1 ? "1 song" : "\(album.tracks.count) songs"
        return "\(yearText)\(countText) - \(album.duration.ariaDurationText)"
    }
}

struct PlaylistCard: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    let playlist: AriaPlaylist

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.ariaPanelRaised)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: "music.note.list")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.ariaAccent)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.headline)
                    .foregroundStyle(Color.ariaTextPrimary)

                Text(playlist.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.ariaTextSecondary)
            }

            Spacer()

            Button {
                if let firstTrack = playlist.tracks.first {
                    player.play(firstTrack, from: playlist.tracks)
                }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.ariaAccent)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.ariaSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.ariaDivider, lineWidth: 1)
        )
    }
}

struct MetadataEditorSheet: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @ObservedObject var session: TrackMetadataEditorSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Edit Metadata")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.ariaTextPrimary)

                Text(session.originalTrack.serverID.map { "Server ID: \($0)" } ?? "Local ID: \(session.originalTrack.id.uuidString)")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.ariaTextSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()
                .overlay(Color.ariaDivider)

            if session.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Loading metadata from the server")
                        .font(.caption)
                        .foregroundStyle(Color.ariaTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 14)
            }

            if let errorMessage = session.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)

                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.ariaTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
                .padding(.horizontal, 22)
                .padding(.top, 14)
            }

            Form {
                Section("Song") {
                    TextField("Title", text: $session.draft.title)
                    TextField("Artist", text: $session.draft.artist)
                    TextField("Album", text: $session.draft.album)
                    Toggle("Explicit", isOn: $session.draft.isExplicit)
                }

                Section("Details") {
                    TextField("Year", text: $session.draft.year)
                    TextField("Track Number", text: $session.draft.trackNumber)
                    TextField("Duration", text: $session.draft.duration)
                        .help("Use seconds, M:SS, or H:MM:SS")
                }

                Section("Server URLs") {
                    TextField("Stream URL", text: $session.draft.streamURL)
                    TextField("Artwork URL", text: $session.draft.artworkURL)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 14)
            .padding(.top, 4)

            Divider()
                .overlay(Color.ariaDivider)

            HStack(spacing: 10) {
                Button("Cancel") {
                    player.cancelMetadataEditing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task {
                        await player.reloadMetadata(for: session)
                    }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .disabled(session.isLoading || session.isSaving)

                Button {
                    Task {
                        await player.saveMetadata(for: session)
                    }
                } label: {
                    if session.isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 48)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.ariaAccent)
                .disabled(session.isLoading || session.isSaving)
            }
            .padding(18)
        }
        .frame(width: 560, height: 640)
        .background(Color.ariaBackground)
    }
}

struct InlineStatusBanner: View {
    var message: String
    var systemImage: String
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.orange)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.ariaTextSecondary)
                .lineLimit(2)

            Spacer()

            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.orange.opacity(0.22), lineWidth: 1)
                )
        )
    }
}

struct ServerErrorState: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    var message: String

    var body: some View {
        VStack(spacing: 16) {
            EmptyStateView(
                title: "Can’t reach the song server",
                message: message,
                systemImage: "wifi.exclamationmark"
            )

            Button {
                Task { await player.refreshCatalog() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.ariaAccent)
        }
    }
}

struct EmptyStateView: View {
    var title: String
    var message: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.ariaAccent)

            Text(title)
                .font(.headline)
                .foregroundStyle(Color.ariaTextPrimary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(Color.ariaTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(36)
    }
}

private extension String {
    var casefoldedTokens: [String] {
        localizedLowercase
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }
}
