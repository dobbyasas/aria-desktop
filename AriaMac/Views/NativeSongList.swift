import AppKit
import SwiftUI

/// A native, reusable row pool keeps scrolling independent of the library size.
/// Only the page header is hosted in SwiftUI; song cells use fixed AppKit geometry.
struct NativeSongList<Header: View>: NSViewRepresentable {
    @Environment(MacPlayerViewModel.self) private var player
    let tracks: [Track]
    var showAlbum = true
    var playlist: AriaPlaylist?
    @ViewBuilder var header: () -> Header

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = SongTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 60
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("song"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.playSelection)
        table.playSelection = { [weak coordinator = context.coordinator] in coordinator?.playSelection() }
        let document = SongDocumentView(table: table)
        scroll.documentView = document
        document.autoresizingMask = [.width]
        context.coordinator.document = document
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.tracks != tracks
        coordinator.player = player
        coordinator.playlist = playlist
        coordinator.tracks = tracks
        coordinator.showAlbum = showAlbum
        coordinator.currentID = player.currentTrack?.id
        coordinator.isPlaying = player.isPlaying
        guard let document = coordinator.document else { return }
        document.updateHeader(AnyView(header().environment(player).padding(.horizontal, 24)), width: scroll.contentSize.width)
        if changed { document.table.reloadData() }
        document.resizeRows(count: tracks.count)
        // Playback and metadata updates affect visible cells only. Clock ticks are
        // deliberately not read here, so they cannot invalidate the table.
        document.table.enumerateAvailableRowViews { _, row in
            if let cell = document.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? SongCellView {
                coordinator.configure(cell, row: row)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var player: MacPlayerViewModel?
        weak var document: SongDocumentView?
        var tracks: [Track] = []
        var playlist: AriaPlaylist?
        var showAlbum = true
        var currentID: UUID?
        var isPlaying = false

        func numberOfRows(in tableView: NSTableView) -> Int { tracks.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("song")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SongCellView ?? SongCellView()
            cell.identifier = id
            configure(cell, row: row)
            return cell
        }
        func configure(_ cell: SongCellView, row: Int) {
            guard tracks.indices.contains(row) else { return }
            let track = tracks[row]
            cell.configure(track: track, index: row + 1, showAlbum: showAlbum,
                           current: currentID == track.id, playing: isPlaying)
            cell.play = { [weak self] in self?.play(track) }
            cell.openArtist = { [weak self] in self?.player?.presentArtist(named: track.artist) }
            cell.buildMenu = { [weak self] in self?.menu(for: track) }
        }
        func play(_ track: Track) {
            if let playlist { player?.play(track, from: playlist) }
            else { player?.play(track, from: tracks) }
        }
        @objc func playSelection() {
            guard let table = document?.table else { return }
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard tracks.indices.contains(row) else { return }
            play(tracks[row])
        }
        func menu(for track: Track) -> NSMenu {
            let menu = NSMenu()
            guard let player else { return menu }
            menu.addItem(SongMenuItem("Play") { [weak self] in self?.play(track) })
            menu.addItem(SongMenuItem("Play Next") { player.playNext(track) })
            menu.addItem(SongMenuItem("Add to Queue") { player.addToQueue(track) })
            let playlists = NSMenu()
            playlists.addItem(SongMenuItem("New Playlist with Song") {
                let playlist = player.createPlaylist()
                player.add(track, to: playlist)
            })
            if !player.playlists.isEmpty { playlists.addItem(.separator()) }
            for playlist in player.playlists {
                let item = SongMenuItem(playlist.title) { player.add(track, to: playlist) }
                item.isEnabled = !playlist.tracks.contains { $0.id == track.id }
                playlists.addItem(item)
            }
            playlists.autoenablesItems = false
            let item = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
            item.submenu = playlists
            menu.addItem(item)
            menu.addItem(.separator())
            menu.addItem(SongMenuItem("Edit Metadata") { player.editMetadata(for: track) })
            return menu
        }
    }
}

final class SongDocumentView: NSView {
    override var isFlipped: Bool { true }
    let table: SongTableView
    private let header = NSHostingView(rootView: AnyView(EmptyView()))
    private var headerContent = AnyView(EmptyView())
    private var rowCount = 0
    private var measuredWidth: CGFloat = -1
    private var headerHeight: CGFloat = 0

    init(table: SongTableView) {
        self.table = table
        super.init(frame: .zero)
        header.sizingOptions = []
        addSubview(header)
        addSubview(table)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateHeader(_ content: AnyView, width: CGFloat) {
        headerContent = content
        measuredWidth = -1
        setFrameSize(NSSize(width: width, height: frame.height))
        measureHeader()
    }
    func resizeRows(count: Int) {
        rowCount = count
        arrange()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if newSize.width != measuredWidth { measureHeader() }
    }
    private func measureHeader() {
        guard frame.width > 0, frame.width != measuredWidth else { return }
        measuredWidth = frame.width
        header.rootView = AnyView(headerContent.frame(width: frame.width).fixedSize(horizontal: false, vertical: true))
        headerHeight = ceil(header.fittingSize.height)
        arrange()
    }
    private func arrange() {
        header.frame = NSRect(x: 0, y: 0, width: frame.width, height: headerHeight)
        table.frame = NSRect(x: 0, y: headerHeight, width: frame.width, height: CGFloat(rowCount) * 60)
        table.tableColumns.first?.width = frame.width
        super.setFrameSize(NSSize(width: frame.width, height: headerHeight + CGFloat(rowCount) * 60 + 24))
    }
}

final class SongTableView: NSTableView {
    var playSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { playSelection?() }
        else { super.keyDown(with: event) }
    }
}

final class SongMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

/// Cells retain no model observations or layout constraints. Reuse cancels the
/// old artwork task and verifies its URL before assigning the new thumbnail.
final class SongCellView: NSTableCellView {
    override var isFlipped: Bool { true }
    let playButton = NSButton()
    let cover = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let artistButton = NSButton()
    let albumLabel = NSTextField(labelWithString: "")
    let durationLabel = NSTextField(labelWithString: "")
    let moreButton = NSButton()
    private var track: Track?
    private var index = 0
    private var current = false
    private var playing = false
    private var hovering = false
    private var showAlbum = true
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var tracking: NSTrackingArea?
    var play: (() -> Void)?
    var openArtist: (() -> Void)?
    var buildMenu: (() -> NSMenu?)?
    private static let accent = NSColor(Color.ariaAccent)
    private static let secondary = NSColor(Color.ariaTextSecondary)
    private static let ellipsis = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
    private static let placeholder = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
    private static let playImage = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
    private static let speakerImage = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)

    init() {
        super.init(frame: .zero)
        for view in [playButton, cover, titleLabel, artistButton, albumLabel, durationLabel, moreButton] { addSubview(view) }
        for label in [titleLabel, albumLabel, durationLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        albumLabel.font = .systemFont(ofSize: 12)
        albumLabel.textColor = Self.secondary
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = Self.secondary
        durationLabel.alignment = .right
        for button in [playButton, artistButton, moreButton] {
            button.isBordered = false
            button.target = self
            button.setButtonType(.momentaryChange)
        }
        playButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        playButton.action = #selector(playClicked)
        playButton.toolTip = "Play"
        artistButton.font = .systemFont(ofSize: 12)
        artistButton.alignment = .left
        artistButton.lineBreakMode = .byTruncatingTail
        artistButton.contentTintColor = Self.secondary
        artistButton.action = #selector(artistClicked)
        moreButton.image = Self.ellipsis
        moreButton.action = #selector(menuClicked)
        moreButton.setAccessibilityLabel("More actions")
        moreButton.toolTip = "More actions"
        cover.imageScaling = .scaleProportionallyUpOrDown
        cover.wantsLayer = true
        cover.layer?.cornerRadius = 7
        cover.layer?.masksToBounds = true
        cover.layer?.backgroundColor = NSColor(Color.ariaSurface).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { artworkTask?.cancel() }

    func configure(track: Track, index: Int, showAlbum: Bool, current: Bool, playing: Bool) {
        self.track = track
        self.index = index
        self.showAlbum = showAlbum
        self.current = current
        self.playing = playing
        titleLabel.stringValue = track.title + (track.isExplicit ? "  ▪ E" : "")
        titleLabel.textColor = current ? Self.accent : NSColor(Color.ariaTextPrimary)
        artistButton.title = track.artist
        artistButton.setAccessibilityLabel("Artist: \(track.artist)")
        albumLabel.stringValue = track.album
        albumLabel.isHidden = !showAlbum
        durationLabel.stringValue = track.duration.ariaDurationText
        playButton.setAccessibilityLabel("Play \(track.title)")
        cover.setAccessibilityLabel("\(track.title) artwork")
        updatePlayButton()
        if artworkURL != track.artworkURL || cover.image == nil {
            artworkTask?.cancel()
            artworkURL = track.artworkURL
            let url = track.artworkURL
            cover.image = url.flatMap { AriaArtworkCache.shared.cachedImage(for: $0, maxPixelSize: 96) } ?? Self.placeholder
            if let url, AriaArtworkCache.shared.cachedImage(for: url, maxPixelSize: 96) == nil {
                artworkTask = Task { [weak self] in
                    let image = await AriaArtworkCache.shared.image(for: url, maxPixelSize: 96)
                    guard !Task.isCancelled, let self, self.artworkURL == url else { return }
                    self.cover.image = image ?? Self.placeholder
                }
            }
        }
        needsLayout = true
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        let left: CGFloat = 36
        let right = bounds.width - 36
        playButton.frame = NSRect(x: left, y: 14, width: 30, height: 30)
        cover.frame = NSRect(x: left + 42, y: 7, width: 44, height: 44)
        moreButton.frame = NSRect(x: right - 28, y: 15, width: 28, height: 28)
        durationLabel.frame = NSRect(x: right - 98, y: 21, width: 58, height: 17)
        let titleEnd = right - (showAlbum ? 342 : 110)
        albumLabel.frame = NSRect(x: right - 330, y: 21, width: 220, height: 17)
        titleLabel.frame = NSRect(x: left + 98, y: 9, width: max(0, titleEnd - left - 98), height: 20)
        artistButton.frame = NSRect(x: left + 98, y: 31, width: max(0, titleEnd - left - 98), height: 18)
    }
    override func draw(_ dirtyRect: NSRect) {
        if current || hovering {
            (current ? Self.accent.withAlphaComponent(0.13) : NSColor.white.withAlphaComponent(0.07)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 24, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updatePlayButton(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; updatePlayButton(); needsDisplay = true }
    private func updatePlayButton() {
        playButton.image = current && playing ? Self.speakerImage : hovering || current ? Self.playImage : nil
        playButton.title = playButton.image == nil ? String(index) : ""
        playButton.contentTintColor = current ? Self.accent : Self.secondary
        moreButton.contentTintColor = Self.secondary.withAlphaComponent(hovering ? 1 : 0.5)
    }
    override func menu(for event: NSEvent) -> NSMenu? { buildMenu?() }
    @objc private func playClicked() { play?() }
    @objc private func artistClicked() { openArtist?() }
    @objc private func menuClicked() {
        buildMenu?()?.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY), in: moreButton)
    }
}
