import SwiftUI
import AppKit

private enum MacSidebarDestination: Hashable {
    case player
    case songs
    case albums
    case playlist(UUID)
}

struct ArtistNameLink: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @State private var isHovering = false

    let name: String

    var body: some View {
        Text(name)
            .foregroundStyle(isHovering ? Color.ariaAccent : Color.ariaTextSecondary)
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    player.presentArtist(named: name)
                }
            )
            .accessibilityAddTraits(.isLink)
            .accessibilityAction {
                player.presentArtist(named: name)
            }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.16), value: isHovering)
    }
}

struct ContentView: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @State private var selectedDestination: MacSidebarDestination = .player
    @State private var selectedAlbumID: String?
    @State private var selectedArtistName: String?
    @State private var artistReturnDestination: MacSidebarDestination?
    @State private var artistReturnAlbumID: String?
    @State private var searchText = ""
    @State private var isDownloadSheetPresented = false
    @State private var isSidebarVisible = true
    @State private var playerBarHeight: CGFloat = 96

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    sidebar
                        .frame(width: 220)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Group {
                    if selectedDestination == .player && selectedArtistName == nil {
                        FullscreenPlayerView()
                    } else {
                        libraryDetail
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !isSidebarVisible {
                sidebarToggleButton
                    .padding(.leading, 12)
                    .padding(.top, 12)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .background(Color.ariaBackground)
        .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
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
        .sheet(isPresented: $isDownloadSheetPresented) {
            DownloadMusicSheet()
                .environmentObject(player)
        }
        .onPreferenceChange(PlayerBarHeightPreferenceKey.self) { height in
            playerBarHeight = height
        }
        .onChange(of: selectedDestination) { _, destination in
            if destination == .player {
                player.hideLyrics()
            }
        }
        .onChange(of: player.presentedArtist) { _, artist in
            guard let artist else { return }
            if selectedArtistName == nil {
                artistReturnDestination = selectedDestination
                artistReturnAlbumID = selectedAlbumID
            }
            selectedDestination = .albums
            selectedAlbumID = nil
            selectedArtistName = artist.name
            player.dismissArtist()
        }
    }

    private var libraryDetail: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color.ariaPanel.opacity(0.58), Color.ariaBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
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
                    }

                    if player.isLyricsPresented, let track = player.currentTrack {
                        MacKaraokeLyricsView(track: track)
                            .transition(.opacity.combined(with: .scale(scale: 0.995)))
                            .zIndex(4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.22), value: player.isLyricsPresented)

                PlayerBar()
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: PlayerBarHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
            }

            if player.isAudioVisualizerEnabled, !player.isLyricsPresented {
                floatingAudioVisualizer
            }
        }
    }

    private var floatingAudioVisualizer: some View {
        AudioVisualizer(
            levels: player.spectrumLevels,
            hasTrack: player.currentTrack != nil
        )
        .frame(height: 85)
        .padding(.horizontal, 14)
        .padding(.bottom, playerBarHeight + 6)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio visualizer")
        .accessibilityValue(player.isPlaying ? "Playing" : "Paused")
        .zIndex(3)
    }

    private var sidebar: some View {
        ZStack(alignment: .trailing) {
            Color.ariaPanel
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .accessibilityLabel("Aria")

                    HStack {
                        Spacer()
                        sidebarToggleButton
                    }
                }
                .frame(height: 64)
                .padding(.horizontal, 10)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        sidebarNavigationButton(
                            title: "Player",
                            systemImage: "play.square.fill",
                            destination: .player
                        )

                        sidebarNavigationButton(
                            title: "Songs",
                            systemImage: "music.note.list",
                            destination: .songs
                        )

                        sidebarNavigationButton(
                            title: "Albums",
                            systemImage: "square.stack.fill",
                            destination: .albums
                        )

                        Button {
                            isDownloadSheetPresented = true
                        } label: {
                            SidebarNavigationRow(
                                title: "Download Music",
                                systemImage: "arrow.down.circle",
                                isSelected: false,
                                usesAccent: true
                            )
                        }
                        .buttonStyle(.plain)

                        if !player.downloadQueue.isEmpty {
                            SidebarDownloadStatus(
                                activeItem: player.activeDownloadItem,
                                totalETA: player.downloadQueueEstimatedRemaining,
                                waitingCount: player.waitingDownloadCount
                            )
                            .padding(.horizontal, 9)
                            .padding(.top, 4)
                        }

                        Text("Playlists")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.ariaTextSecondary.opacity(0.68))
                            .padding(.horizontal, 9)
                            .padding(.top, 18)
                            .padding(.bottom, 4)

                        Button {
                            let playlist = player.createPlaylist()
                            selectedAlbumID = nil
                            selectedArtistName = nil
                            selectedDestination = .playlist(playlist.id)
                        } label: {
                            SidebarNavigationRow(
                                title: "New Playlist",
                                systemImage: "plus",
                                isSelected: false,
                                usesAccent: true
                            )
                        }
                        .buttonStyle(.plain)

                        ForEach(sortedPlaylists) { playlist in
                            let destination = MacSidebarDestination.playlist(playlist.id)

                            Button {
                                selectedAlbumID = nil
                                selectedArtistName = nil
                                selectedDestination = destination
                            } label: {
                                SidebarPlaylistRow(
                                    playlist: playlist,
                                    isSelected: selectedDestination == destination
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 16)
                }

                Divider()
                    .overlay(Color.ariaDivider)

                HStack(spacing: 10) {
                    Text(AriaRelease.displayText)
                        .monospacedDigit()

                    Spacer()

                    Label(serverStatusTitle, systemImage: serverStatusImage)
                        .foregroundStyle(serverStatusColor)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.ariaTextSecondary.opacity(0.78))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Aria \(AriaRelease.displayText), \(serverStatusTitle)")
            }

            Rectangle()
                .fill(Color.ariaDivider)
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private var sidebarToggleButton: some View {
        Button {
            isSidebarVisible.toggle()
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.ariaTextPrimary)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
    }

    private func sidebarNavigationButton(
        title: String,
        systemImage: String,
        destination: MacSidebarDestination
    ) -> some View {
        let isSelected = selectedDestination == destination

        return Button {
            selectedAlbumID = nil
            selectedArtistName = nil
            selectedDestination = destination
        } label: {
            SidebarNavigationRow(
                title: title,
                systemImage: systemImage,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            if selectedArtistName != nil {
                Button(action: closeArtistPage) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ariaTextPrimary)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Back")
                .accessibilityLabel("Back")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(detailTitle)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.ariaTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Group {
                    if selectedDestination == .albums, let artist = selectedAlbum?.artist {
                        ArtistNameLink(name: artist)
                    } else {
                        Text(subtitle)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.ariaTextSecondary)
                .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer()

            if selectedArtistName == nil
                && (selectedDestination == .songs || (selectedDestination == .albums && selectedAlbumID == nil)) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.ariaTextSecondary)

                    TextField(
                        selectedDestination == .songs ? "Search songs or artists" : "Search albums or artists",
                        text: $searchText
                    )
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
            }

            Button {
                Task { await player.refreshCatalog() }
            } label: {
                if player.isCatalogLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 30, height: 30)
                }
            }
            .disabled(player.isCatalogLoading)
            .buttonStyle(.plain)
            .foregroundStyle(Color.ariaTextSecondary)
            .help("Refresh library")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var content: some View {
        if let selectedArtistName {
            ArtistPageView(artistName: selectedArtistName)
        } else if player.catalog.isEmpty && player.isCatalogLoading {
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
            switch selectedDestination {
            case .player:
                EmptyView()
            case .songs:
                SongsView(
                    tracks: filteredSongs,
                    isSearching: isSearching
                )
            case .albums:
                if let selectedAlbum {
                    MacAlbumDetailView(album: selectedAlbum) {
                        selectedAlbumID = nil
                    }
                } else {
                    AlbumsView(
                        albums: filteredAlbums,
                        isSearching: isSearching
                    ) { album in
                        selectedAlbumID = album.id
                    }
                }
            case .playlist:
                if let selectedPlaylist {
                    MacPlaylistDetailView(playlist: selectedPlaylist)
                } else {
                    EmptyStateView(
                        title: "Playlist unavailable",
                        message: "Refresh the library to load this playlist again.",
                        systemImage: "music.note.list"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
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

    private var filteredSongs: [Track] {
        let tracks = player.catalog.sorted {
            let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleOrder == .orderedSame {
                return $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
            }
            return titleOrder == .orderedAscending
        }
        guard isSearching else { return tracks }
        let tokens = searchText.casefoldedTokens
        return tracks.filter { track in
            let text = "\(track.title) \(track.artist) \(track.album)".localizedLowercase
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    private var selectedAlbum: AriaAlbum? {
        guard let selectedAlbumID else { return nil }
        return player.albums.first { $0.id == selectedAlbumID }
    }

    private var selectedPlaylist: AriaPlaylist? {
        guard case .playlist(let playlistID) = selectedDestination else { return nil }
        return player.playlists.first { $0.id == playlistID }
    }

    private func closeArtistPage() {
        selectedArtistName = nil
        selectedDestination = artistReturnDestination ?? .albums
        selectedAlbumID = artistReturnAlbumID
        artistReturnDestination = nil
        artistReturnAlbumID = nil
    }

    private var sortedPlaylists: [AriaPlaylist] {
        player.playlists.enumerated().sorted { left, right in
            let leftRecency = player.playlistRecency(for: left.element.id)
            let rightRecency = player.playlistRecency(for: right.element.id)

            if leftRecency == rightRecency {
                return left.offset < right.offset
            }

            return leftRecency > rightRecency
        }.map(\.element)
    }

    private var detailTitle: String {
        if let selectedArtistName {
            return selectedArtistName
        }
        switch selectedDestination {
        case .songs:
            return "Songs"
        case .albums:
            return selectedAlbum?.title ?? "Albums"
        case .playlist:
            return selectedPlaylist?.title ?? "Playlist"
        case .player:
            return "Player"
        }
    }

    private var subtitle: String {
        if selectedArtistName != nil {
            return "Artist"
        }
        switch selectedDestination {
        case .songs:
            return "\(filteredSongs.count) songs"
        case .albums:
            return selectedAlbum?.artist ?? "\(filteredAlbums.count) albums"
        case .playlist:
            return selectedPlaylist?.subtitle ?? "Shared playlist"
        case .player:
            return "Now playing"
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
        if player.catalogErrorMessage != nil {
            return .orange
        }

        return player.catalog.isEmpty ? Color.ariaTextSecondary : Color.ariaAccent
    }
}

private struct PlayerBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 96

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct SidebarNavigationRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var usesAccent = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 20)
                .foregroundStyle(isSelected || usesAccent ? Color.ariaAccent : Color.ariaTextSecondary)

            Text(title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected || usesAccent ? Color.ariaTextPrimary : Color.ariaTextSecondary)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(sidebarSelectionBackground)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var sidebarSelectionBackground: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Color.ariaAccent.opacity(0.13) : Color.clear)

            if isSelected {
                Rectangle()
                    .fill(Color.ariaAccent)
                    .frame(width: 2)
            }
        }
    }
}

struct SidebarPlaylistRow: View {
    let playlist: AriaPlaylist
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            PlaylistArtworkView(playlist: playlist, size: 30, cornerRadius: 5)

            Text(playlist.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.ariaTextPrimary : Color.ariaTextSecondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(isSelected ? Color.ariaAccent.opacity(0.13) : Color.clear)

                if isSelected {
                    Rectangle()
                        .fill(Color.ariaAccent)
                        .frame(width: 2)
                }
            }
        }
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
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

struct ArtistPageView: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @State private var artistProfile: YouTubeMusicArtistResult?
    @State private var availableAlbums: [YouTubeMusicAlbumResult] = []
    @State private var isLoading = true
    @State private var showsSkeleton = false
    @State private var loadError: String?

    let artistName: String
    private let searchClient = YouTubeMusicSearchClient()

    private var downloadedSongs: [Track] {
        player.songs(byArtist: artistName)
    }

    private var downloadedAlbums: [AriaAlbum] {
        player.albums(byArtist: artistName)
    }

    private var downloadableAlbums: [YouTubeMusicAlbumResult] {
        availableAlbums.filter {
            player.albumResult($0, belongsToArtist: artistName) && !player.isAlbumDownloaded($0)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                artistHeader

                LazyVStack(alignment: .leading, spacing: 28) {
                    if !downloadedAlbums.isEmpty {
                        downloadedAlbumsSection
                    }

                    availableAlbumsSection

                    if !downloadedSongs.isEmpty {
                        downloadedSongsSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
        }
        .background(Color.ariaBackground)
        .task(id: artistName) {
            await loadArtist()
        }
    }

    private var artistHeader: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: artistProfile?.artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    if showsSkeleton {
                        Color.white.opacity(0.09)
                    } else {
                        artistPlaceholder
                    }
                case .failure:
                    artistPlaceholder
                @unknown default:
                    artistPlaceholder
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 410)
            .clipped()

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.03), location: 0),
                    .init(color: Color.black.opacity(0.13), location: 0.42),
                    .init(color: Color.ariaBackground.opacity(0.74), location: 0.78),
                    .init(color: Color.ariaBackground, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("ARTIST")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.ariaAccent)

                Text(artistProfile?.name ?? artistName)
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(Color.ariaTextPrimary)
                    .lineLimit(2)

                Text("\(downloadedSongs.count) downloaded \(downloadedSongs.count == 1 ? "song" : "songs") • \(downloadedAlbums.count) downloaded \(downloadedAlbums.count == 1 ? "album" : "albums")")
                    .font(.subheadline)
                    .foregroundStyle(Color.ariaTextSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 410)
        .background(Color.ariaPanel)
        .clipped()
    }

    private var downloadedAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloaded Albums")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.ariaTextPrimary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 14)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(downloadedAlbums) { album in
                    Button {
                        guard let firstTrack = album.tracks.first else { return }
                        player.play(firstTrack, from: album.tracks)
                    } label: {
                        HStack(spacing: 12) {
                            if let track = album.artworkTrack {
                                ArtworkView(track: track, size: 70, cornerRadius: 8)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(album.title)
                                    .font(.headline)
                                    .foregroundStyle(Color.ariaTextPrimary)
                                    .lineLimit(2)
                                Text("\(album.year) • \(album.tracks.count) \(album.tracks.count == 1 ? "song" : "songs")")
                                    .font(.caption)
                                    .foregroundStyle(Color.ariaTextSecondary)
                            }
                            Spacer()
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.ariaAccent)
                        }
                        .padding(12)
                        .background(Color.ariaSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.ariaDivider, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Play \(album.title)")
                }
            }
        }
    }

    private var downloadedSongsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloaded Songs")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.ariaTextPrimary)
            TrackListHeader(showAlbum: true)
            ForEach(Array(downloadedSongs.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, source: downloadedSongs, index: index + 1, showAlbum: true)
            }
        }
    }

    @ViewBuilder
    private var availableAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("More Albums")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.ariaTextPrimary)

            if isLoading {
                if showsSkeleton {
                    albumSkeleton
                } else {
                    ProgressView().tint(Color.ariaAccent)
                }
            } else if let loadError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(loadError).foregroundStyle(Color.ariaTextSecondary)
                    Button("Try Again") { Task { await loadArtist() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.ariaAccent)
                }
            } else if downloadableAlbums.isEmpty {
                Text("No additional albums were found.")
                    .foregroundStyle(Color.ariaTextSecondary)
            } else {
                ForEach(downloadableAlbums) { result in
                    YouTubeMusicAlbumResultRow(result: result)
                }
            }
        }
    }

    private var artistPlaceholder: some View {
        ZStack {
            Color.ariaPanel
            Image(systemName: "person.fill")
                .font(.system(size: 104, weight: .medium))
                .foregroundStyle(Color.ariaTextSecondary.opacity(0.7))
        }
    }

    private var albumSkeleton: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.09))
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 220, height: 13)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.07))
                            .frame(width: 145, height: 10)
                    }
                    Spacer()
                }
                .padding(.vertical, 3)
            }
        }
        .accessibilityLabel("Loading albums")
    }

    private func loadArtist() async {
        isLoading = true
        showsSkeleton = false
        loadError = nil
        let skeletonTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            showsSkeleton = true
        }
        do {
            let result = try await searchClient.artistPage(named: artistName, albumLimit: 60)
            artistProfile = result.artist
            availableAlbums = result.albums
        } catch {
            loadError = error.localizedDescription
        }
        skeletonTask.cancel()
        showsSkeleton = false
        isLoading = false
    }
}

struct AlbumsView: View {
    let albums: [AriaAlbum]
    let isSearching: Bool
    let onOpenAlbum: (AriaAlbum) -> Void

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
                        AlbumCard(album: album, onOpen: onOpenAlbum)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }
}

struct MacAlbumDetailView: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @State private var confirmsAlbumDeletion = false
    @State private var isDeletingAlbum = false
    @State private var albumDeletionError: String?

    let album: AriaAlbum
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    onBack()
                } label: {
                    Label("Albums", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ariaTextSecondary)

                albumHeader

                VStack(spacing: 0) {
                    TrackListHeader(showAlbum: false)

                    LazyVStack(spacing: 2) {
                        ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track,
                                source: album.tracks,
                                index: index + 1,
                                showAlbum: false
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .alert("Delete \(album.title)?", isPresented: $confirmsAlbumDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Album", role: .destructive) {
                deleteAlbum()
            }
        } message: {
            Text("This permanently removes all \(album.tracks.count) song files in this album from the Aria server and removes them from shared playlists.")
        }
        .alert(
            "Couldn’t Delete Album",
            isPresented: Binding(
                get: { albumDeletionError != nil },
                set: { if !$0 { albumDeletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(albumDeletionError ?? "Unknown error")
        }
    }

    private var albumHeader: some View {
        HStack(spacing: 20) {
            if let artworkTrack = album.artworkTrack {
                ArtworkView(track: artworkTrack, size: 148, cornerRadius: 10)
                    .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 10)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Album")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ariaAccent)
                    .textCase(.uppercase)

                Text(album.title)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color.ariaTextPrimary)
                    .lineLimit(2)

                HStack(spacing: 0) {
                    ArtistNameLink(name: album.artist)
                    Text(" - \(albumSubtitle)")
                }
                    .font(.subheadline)
                    .foregroundStyle(Color.ariaTextSecondary)

                HStack(spacing: 10) {
                    Button {
                        playAlbum()
                    } label: {
                        Label("Play Album", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.ariaAccent)

                    Button {
                        shuffleAlbum()
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(album.tracks.isEmpty)

                    Button(role: .destructive) {
                        confirmsAlbumDeletion = true
                    } label: {
                        if isDeletingAlbum {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Delete Album", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeletingAlbum)
                }
            }

            Spacer()
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

    private var albumSubtitle: String {
        let yearText = album.year > 0 ? "\(album.year) - " : ""
        let countText = album.tracks.count == 1 ? "1 song" : "\(album.tracks.count) songs"
        return "\(yearText)\(countText) - \(album.duration.ariaDurationText)"
    }

    private func playAlbum() {
        guard let firstTrack = album.tracks.first else { return }
        player.play(firstTrack, from: album.tracks)
    }

    private func shuffleAlbum() {
        let shuffledTracks = album.tracks.shuffled()
        guard let firstTrack = shuffledTracks.first else { return }
        player.play(firstTrack, from: shuffledTracks)
    }

    private func deleteAlbum() {
        isDeletingAlbum = true
        albumDeletionError = nil
        Task {
            do {
                _ = try await player.deleteAlbum(album)
                isDeletingAlbum = false
                onBack()
            } catch {
                isDeletingAlbum = false
                albumDeletionError = error.localizedDescription
            }
        }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    let playlists: [AriaPlaylist]

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()

                Button {
                    player.createPlaylist()
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.ariaAccent)
            }
            .padding(.horizontal, 24)

            if playlists.isEmpty {
                EmptyStateView(
                    title: "No playlists yet",
                    message: "Create one here or on iPhone and it will appear on every Aria device.",
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
}

struct MacPlaylistDetailView: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    let playlist: AriaPlaylist

    var body: some View {
        GeometryReader { proxy in
            let showsAlbum = proxy.size.width >= 760

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    playlistHeader

                    if playlist.tracks.isEmpty {
                        EmptyStateView(
                            title: "This playlist is empty",
                            message: "Use a song's action menu to add music here.",
                            systemImage: "music.note.list"
                        )
                        .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        VStack(spacing: 0) {
                            TrackListHeader(showAlbum: showsAlbum)

                            LazyVStack(spacing: 2) {
                                ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRow(
                                        track: track,
                                        source: playlist.tracks,
                                        index: index + 1,
                                        showAlbum: showsAlbum,
                                        playlistForPlayback: playlist
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

    private var playlistHeader: some View {
        HStack(spacing: 18) {
            PlaylistArtworkView(playlist: playlist, size: 104, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 7) {
                Text("Playlist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ariaAccent)

                Text(playlist.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.ariaTextSecondary)

                Button {
                    player.play(playlist)
                } label: {
                    Label("Play Playlist", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.ariaAccent)
                .disabled(playlist.tracks.isEmpty)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.ariaSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.ariaDivider, lineWidth: 1)
        )
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
                            Text("Up Next")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.ariaTextPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 8)

                            TrackListHeader(showAlbum: showsAlbum)

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

                HStack(spacing: 0) {
                    ArtistNameLink(name: track.artist)
                    Text(" - \(track.album)")
                }
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
    var showAlbum = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("#")
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
    var playlistForPlayback: AriaPlaylist?

    private var isCurrentTrack: Bool {
        player.currentTrack?.id == track.id
    }

    private var playableSource: [Track] {
        source.isEmpty ? [track] : source
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let playlistForPlayback {
                    player.play(track, from: playlistForPlayback)
                } else {
                    player.play(track, from: playableSource)
                }
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
                        .fill(
                            isCurrentTrack
                                ? Color.ariaAccent
                                : Color.white.opacity(isHovering ? 0.11 : 0)
                        )
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

                ArtistNameLink(name: track.artist)
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
                Menu {
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        player.playNext(track)
                    }

                    Menu("Add to Playlist") {
                        Button("New Playlist with Song") {
                            let playlist = player.createPlaylist()
                            player.add(track, to: playlist)
                        }

                        ForEach(player.playlists) { playlist in
                            Button(playlist.title) {
                                player.add(track, to: playlist)
                            }
                            .disabled(playlist.tracks.contains(where: { $0.id == track.id }))
                        }
                    }

                    Divider()

                    Button("Edit Metadata", systemImage: "slider.horizontal.3") {
                        player.editMetadata(for: track)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(isHovering ? Color.ariaTextSecondary : Color.ariaTextSecondary.opacity(0.45))
                .help("More actions")
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

            Menu("Add to Playlist") {
                Button("New Playlist with Song") {
                    let playlist = player.createPlaylist()
                    player.add(track, to: playlist)
                }

                if !player.playlists.isEmpty {
                    Divider()

                    ForEach(player.playlists) { playlist in
                        Button(playlist.title) {
                            player.add(track, to: playlist)
                        }
                        .disabled(playlist.tracks.contains(where: { $0.id == track.id }))
                    }
                }
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
    let onOpen: (AriaAlbum) -> Void

    var body: some View {
        Button {
            onOpen(album)
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

                    ArtistNameLink(name: album.artist)
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
            PlaylistArtworkView(playlist: playlist, size: 64, cornerRadius: 8)

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
                player.play(playlist)
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

struct PlaylistArtworkView: View {
    let playlist: AriaPlaylist
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
        if let coverImageData = playlist.coverImageData,
           let image = NSImage(data: coverImageData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                    .frame(width: size, height: size)
        } else if let firstTrack = playlist.tracks.first {
                ArtworkView(track: firstTrack, size: size, cornerRadius: cornerRadius)
        } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.ariaPanelRaised)
                    .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note.list")
                            .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(Color.ariaAccent)
                )
        }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 1)
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

            if let artworkStatusMessage = session.artworkStatusMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.ariaAccent)

                    Text(artworkStatusMessage)
                        .font(.caption)
                        .foregroundStyle(Color.ariaTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.ariaAccent.opacity(0.12))
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

                Section("Artwork") {
                    TextField("Artwork URL", text: $session.draft.artworkURL)

                    Button {
                        Task {
                            await player.refreshArtwork(for: session)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if session.isRefreshingArtwork {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "photo.badge.arrow.down")
                            }

                            Text(session.isRefreshingArtwork ? "Refreshing Cover…" : "Refresh Cover from YouTube")
                        }
                    }
                    .disabled(session.isLoading || session.isSaving || session.isRefreshingArtwork)
                    .help("Replace the embedded cover on every song in this album with fresh artwork from YouTube Music")
                }

                Section("Server URL") {
                    TextField("Stream URL", text: $session.draft.streamURL)
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
                .disabled(session.isLoading || session.isSaving || session.isRefreshingArtwork)

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
                .disabled(session.isLoading || session.isSaving || session.isRefreshingArtwork)
            }
            .padding(18)
        }
        .frame(width: 560, height: 640)
        .background(Color.ariaBackground)
    }
}

struct DownloadMusicSheet: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var year = ""
    @State private var youtubeMusicQuery = ""
    @State private var visibleYouTubeResultCount = 3
    @State private var searchCategory: YouTubeMusicSearchCategory = .albums
    @State private var manualCategory: YouTubeMusicSearchCategory = .albums

    private var canQueueDownload: Bool {
        guard !trimmed(link).isEmpty else { return false }
        return manualCategory != .albums
            || (!trimmed(album).isEmpty && !trimmed(albumArtist).isEmpty)
    }

    private var canSearchYouTubeMusic: Bool {
        !trimmed(youtubeMusicQuery).isEmpty && !player.isSearchingYouTubeMusic
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Download Music")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.ariaTextPrimary)

                Text("Find albums, individual songs, or playlists on YouTube Music. Standalone downloads stay out of the Albums library.")
                    .font(.caption)
                    .foregroundStyle(Color.ariaTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()
                .overlay(Color.ariaDivider)

            Form {
                Section("Search YouTube Music") {
                    Picker("Type", selection: $searchCategory) {
                        ForEach(YouTubeMusicSearchCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: searchCategory) { _, _ in
                        visibleYouTubeResultCount = 3
                    }

                    HStack(spacing: 10) {
                        TextField(searchPlaceholder, text: $youtubeMusicQuery)
                            .onSubmit {
                                searchYouTubeMusic()
                            }

                        Button {
                            searchYouTubeMusic()
                        } label: {
                            if player.isSearchingYouTubeMusic {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 72)
                            } else {
                                Label("Search", systemImage: "magnifyingglass")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.ariaAccent)
                        .disabled(!canSearchYouTubeMusic)
                    }

                    if let error = player.youtubeMusicSearchError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    }

                    searchResults

                    if visibleYouTubeResultCount < resultCount {
                        HStack {
                            Text("Showing \(visibleYouTubeResultCount) of \(resultCount)")
                                .font(.caption)
                                .foregroundStyle(Color.ariaTextSecondary)

                            Spacer()

                            Button {
                                visibleYouTubeResultCount = min(
                                    visibleYouTubeResultCount + 3,
                                    resultCount
                                )
                            } label: {
                                Label("Load More", systemImage: "chevron.down")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Section("Add Link Manually") {
                    Picker("Download as", selection: $manualCategory) {
                        ForEach(YouTubeMusicSearchCategory.allCases) { category in
                            Text(category.rawValue.dropLast(category == .playlists ? 1 : 0)).tag(category)
                        }
                    }
                    TextField("YouTube Music link", text: $link)
                    if manualCategory == .albums {
                        TextField("Album name", text: $album)
                        TextField("Album artist", text: $albumArtist)
                        TextField("Year", text: $year)
                    }
                }

                Section("Queue") {
                    if player.downloadQueue.isEmpty {
                        Text("No downloads queued yet.")
                            .foregroundStyle(Color.ariaTextSecondary)
                    } else {
                        DownloadQueueSummaryView(
                            activeItem: player.activeDownloadItem,
                            totalETA: player.downloadQueueEstimatedRemaining,
                            waitingCount: player.waitingDownloadCount
                        )

                        ForEach(player.downloadQueue) { item in
                            DownloadQueueItemRow(item: item) {
                                player.removeDownloadQueueItem(item)
                            }
                        }

                        if player.downloadQueue.contains(where: { $0.isFinished }) {
                            Button("Clear Finished") {
                                player.clearFinishedDownloads()
                            }
                        }
                    }
                }

                if let error = player.downloadErrorMessage {
                    Section("Problem") {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 14)
            .padding(.top, 4)

            Divider()
                .overlay(Color.ariaDivider)

            HStack(spacing: 10) {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    addCurrentAlbumToQueue()
                } label: {
                    Text("Add to Queue")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.ariaAccent)
                .disabled(!canQueueDownload)
            }
            .padding(18)
        }
        .frame(width: 720, height: 760)
        .background(Color.ariaBackground)
    }

    private func searchYouTubeMusic() {
        guard canSearchYouTubeMusic else { return }
        let query = youtubeMusicQuery
        visibleYouTubeResultCount = 3

        Task {
            await player.searchYouTubeMusic(query: query, category: searchCategory)
        }
    }

    private func addCurrentAlbumToQueue() {
        guard canQueueDownload else { return }

        player.enqueueDownload(
            link: link,
            album: manualCategory == .albums ? album : manualCategory.rawValue.dropLast().description,
            albumArtist: manualCategory == .albums ? albumArtist : "YouTube Music",
            year: year,
            kind: manualCategory.downloadKind
        )

        link = ""
        album = ""
        albumArtist = ""
        year = ""
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resultCount: Int {
        switch searchCategory {
        case .albums: player.youtubeMusicResults.count
        case .songs: player.youtubeMusicSongResults.count
        case .playlists: player.youtubeMusicPlaylistResults.count
        }
    }

    private var searchPlaceholder: String {
        switch searchCategory {
        case .albums: "Album or artist"
        case .songs: "Song or artist"
        case .playlists: "Playlist name"
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch searchCategory {
        case .albums:
            ForEach(Array(player.youtubeMusicResults.prefix(visibleYouTubeResultCount))) { result in
                YouTubeMusicAlbumResultRow(result: result)
            }
        case .songs:
            ForEach(Array(player.youtubeMusicSongResults.prefix(visibleYouTubeResultCount))) { result in
                YouTubeMusicSongResultRow(result: result)
            }
        case .playlists:
            ForEach(Array(player.youtubeMusicPlaylistResults.prefix(visibleYouTubeResultCount))) { result in
                YouTubeMusicPlaylistResultRow(result: result)
            }
        }
    }
}

struct YouTubeMusicAlbumResultRow: View {
    @EnvironmentObject private var player: MacPlayerViewModel

    let result: YouTubeMusicAlbumResult

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    artworkPlaceholder
                case .empty:
                    ProgressView()
                        .controlSize(.small)
                @unknown default:
                    artworkPlaceholder
                }
            }
            .frame(width: 52, height: 52)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ariaTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 0) {
                    ArtistNameLink(name: result.artist)
                    if !result.year.isEmpty {
                        Text(" • \(result.year)")
                    }
                }
                    .font(.caption)
                    .foregroundStyle(Color.ariaTextSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isDownloaded {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ariaAccent)
            } else {
                Button {
                    player.enqueueDownload(result)
                } label: {
                    Label(isQueued ? "Queued" : "Download", systemImage: isQueued ? "checkmark" : "arrow.down")
                }
                .buttonStyle(.bordered)
                .tint(Color.ariaAccent)
                .disabled(isQueued)
            }
        }
        .padding(.vertical, 3)
    }

    private var artworkPlaceholder: some View {
        Image(systemName: "square.stack")
            .foregroundStyle(Color.ariaTextSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isQueued: Bool {
        player.downloadQueue.contains { item in
            guard item.request.link == result.downloadLink else { return false }
            return !item.isFinished || item.job?.isSuccessful == true
        }
    }

    private var isDownloaded: Bool {
        player.isAlbumDownloaded(result)
    }
}

struct YouTubeMusicSongResultRow: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    let result: YouTubeMusicSongResult

    var body: some View {
        YouTubeMusicDownloadResultRow(
            title: result.title,
            subtitle: result.artist,
            artistName: result.artist,
            artworkURL: result.artworkURL,
            isDownloaded: player.isSongDownloaded(result),
            isQueued: player.downloadQueue.contains { $0.request.link == result.downloadLink && !$0.isFinished }
        ) {
            player.enqueueDownload(result)
        }
    }
}

struct YouTubeMusicPlaylistResultRow: View {
    @EnvironmentObject private var player: MacPlayerViewModel
    let result: YouTubeMusicPlaylistResult

    var body: some View {
        YouTubeMusicDownloadResultRow(
            title: result.title,
            subtitle: "Playlist • \(result.curator)",
            artworkURL: result.artworkURL,
            isDownloaded: false,
            isQueued: player.downloadQueue.contains { $0.request.link == result.downloadLink && !$0.isFinished }
        ) {
            player.enqueueDownload(result)
        }
    }
}

private struct YouTubeMusicDownloadResultRow: View {
    let title: String
    let subtitle: String
    var artistName: String? = nil
    let artworkURL: URL?
    let isDownloaded: Bool
    let isQueued: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: artworkURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else if case .empty = phase {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "music.note")
                        .foregroundStyle(Color.ariaTextSecondary)
                }
            }
            .frame(width: 52, height: 52)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ariaTextPrimary)
                    .lineLimit(1)
                Group {
                    if let artistName {
                        ArtistNameLink(name: artistName)
                    } else {
                        Text(subtitle)
                    }
                }
                .font(.caption)
                .foregroundStyle(Color.ariaTextSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            if isDownloaded {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ariaAccent)
            } else {
                Button(action: onDownload) {
                    Label(isQueued ? "Queued" : "Download", systemImage: isQueued ? "checkmark" : "arrow.down")
                }
                .buttonStyle(.bordered)
                .tint(Color.ariaAccent)
                .disabled(isQueued)
            }
        }
        .padding(.vertical, 3)
    }
}

struct DownloadQueueSummaryView: View {
    let activeItem: DownloadQueueItem?
    let totalETA: TimeInterval?
    let waitingCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Label(summaryTitle, systemImage: "list.bullet.rectangle")
                .foregroundStyle(Color.ariaTextSecondary)

            Spacer()

            Text(etaTitle)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.ariaTextSecondary)
        }
    }

    private var summaryTitle: String {
        if activeItem != nil, waitingCount == 0 {
            return "Downloading now"
        }

        if activeItem != nil {
            return waitingCount == 1 ? "1 download waiting" : "\(waitingCount) downloads waiting"
        }

        return waitingCount == 1 ? "1 download waiting" : "\(waitingCount) downloads waiting"
    }

    private var etaTitle: String {
        guard let totalETA else {
            return "ETA estimating"
        }

        return "ETA \(downloadDurationText(totalETA))"
    }
}

struct DownloadQueueItemRow: View {
    let item: DownloadQueueItem
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.request.album)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ariaTextPrimary)
                        .lineLimit(1)

                    HStack(spacing: 0) {
                        if item.request.kind == "playlist" {
                            Text(item.request.albumArtist)
                        } else {
                            ArtistNameLink(name: item.request.albumArtist)
                        }
                        if !item.request.year.isEmpty {
                            Text(" - \(item.request.year)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Color.ariaTextSecondary)
                    .lineLimit(1)
                }

                Spacer()

                Text("\(Int(item.progressFraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.ariaTextSecondary)

                if !item.isActive {
                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.ariaTextSecondary)
                    .help("Remove")
                }
            }

            ProgressView(value: item.progressFraction)
                .progressViewStyle(.linear)
                .tint(statusColor)

            HStack(spacing: 8) {
                Text(item.statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)

                Text(item.detailText)
                    .font(.caption)
                    .foregroundStyle(Color.ariaTextSecondary)
                    .lineLimit(1)

                Spacer()

                if let etaText {
                    Text(etaText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.ariaTextSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusImage: String {
        switch item.status {
        case .waiting:
            "clock"
        case .starting:
            "arrow.triangle.2.circlepath"
        case .downloading:
            "arrow.down.circle.fill"
        case .succeeded:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .waiting, .starting:
            Color.ariaTextSecondary
        case .downloading:
            Color.ariaAccent
        case .succeeded:
            Color.ariaAccent
        case .failed:
            Color.orange
        }
    }

    private var etaText: String? {
        guard let estimatedRemaining = item.estimatedRemaining else { return nil }
        return "\(downloadDurationText(estimatedRemaining)) left"
    }
}

struct SidebarDownloadStatus: View {
    let activeItem: DownloadQueueItem?
    let totalETA: TimeInterval?
    let waitingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(statusTitle, systemImage: activeItem == nil ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(activeItem == nil ? Color.ariaAccent : Color.ariaTextSecondary)
                .lineLimit(1)

            ProgressView(value: activeItem?.progressFraction ?? 1)
                .progressViewStyle(.linear)
                .tint(Color.ariaAccent)

            if let totalETA {
                Text("ETA \(downloadDurationText(totalETA))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.ariaTextSecondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusTitle: String {
        if let activeItem {
            let waitingSuffix = waitingCount > 0 ? " + \(waitingCount) queued" : ""
            return "\(activeItem.statusTitle)\(waitingSuffix)"
        }

        return "Queue done"
    }
}

private func downloadDurationText(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60

    if hours > 0 {
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }

    if minutes > 0 {
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }

    return "less than 1 min"
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
