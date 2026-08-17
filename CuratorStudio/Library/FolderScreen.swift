import SwiftUI

struct FolderScreen: View {

    let folderPath: String

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var states: PlaybackStateStore
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var playlists: PlaylistStore

    @AppStorage("folder.useGrid") private var useGrid = false
    @AppStorage("folder.includeSubfolders") private var includeSubfolders = false
    @AppStorage("folder.sortOrder") private var sortRaw = SortOrder.name.rawValue
    @AppStorage("folder.sortAscending") private var ascending = true

    @State private var selection: Set<String> = []
    @State private var isSelecting = false
    @State private var showingPlaylistPicker = false

    private var folder: FolderNode? { library.folder(at: folderPath) }

    private var visibleItems: [MediaItem] {
        guard let folder else { return [] }
        let base = library.items(in: folder, includingSubfolders: includeSubfolders)
        let order = SortOrder(rawValue: sortRaw) ?? .name
        return sortItems(base, by: order, ascending: ascending, states: states)
    }

    var body: some View {
        Group {
            if let folder {
                if folder.isEmpty {
                    EmptyStateView(symbol: "tray", title: "Empty folder",
                                   message: "Nothing playable in “\(folder.name)” yet.")
                } else if useGrid {
                    gridBody(folder: folder)
                } else {
                    listBody(folder: folder)
                }
            } else {
                EmptyStateView(symbol: "questionmark.folder", title: "Folder not found",
                               message: "It may have been renamed or moved. Refresh the library.")
            }
        }
        .navigationTitle(folder?.name ?? "Folder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if isSelecting && !selection.isEmpty {
                selectionBar
            }
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            AddToPlaylistSheet(paths: Array(selection)) {
                selection.removeAll()
                isSelecting = false
            }
        }
    }

    // MARK: List

    private func listBody(folder: FolderNode) -> some View {
        List {
            if !folder.folders.isEmpty && !includeSubfolders {
                Section("Subfolders") {
                    ForEach(folder.folders) { sub in
                        NavigationLink(value: sub.relativePath) {
                            FolderRow(folder: sub)
                        }
                    }
                }
            }

            if !visibleItems.isEmpty {
                Section(header: itemsHeader(count: visibleItems.count)) {
                    ForEach(visibleItems) { item in
                        HStack(spacing: 10) {
                            if isSelecting {
                                Image(systemName: selection.contains(item.relativePath)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(item.relativePath)
                                                     ? Theme.accent : .secondary)
                            }
                            MediaRow(item: item, showBreadcrumb: includeSubfolders)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { tap(item) }
                    }
                }
            }

            Color.clear.frame(height: 70).listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
    }

    // MARK: Grid

    private func gridBody(folder: FolderNode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !folder.folders.isEmpty && !includeSubfolders {
                    VStack(spacing: 8) {
                        ForEach(folder.folders) { sub in
                            NavigationLink(value: sub.relativePath) {
                                FolderRow(folder: sub)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Theme.surface))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 16) {
                    ForEach(visibleItems) { item in
                        GridCell(item: item, selected: selection.contains(item.relativePath),
                                 selecting: isSelecting)
                            .onTapGesture { tap(item) }
                            .contextMenu { MediaItemMenu(item: item) }
                    }
                }
                .padding(.horizontal, 14)

                Color.clear.frame(height: 70)
            }
            .padding(.top, 8)
        }
    }

    private func itemsHeader(count: Int) -> some View {
        HStack {
            Text("\(count) item\(count == 1 ? "" : "s")")
            Spacer()
            Button {
                player.playQueue(visibleItems, startAt: 0, title: folder?.name ?? "")
            } label: {
                Label("Play all", systemImage: "play.fill").font(.caption.weight(.semibold))
            }
            Button {
                player.shuffleEnabled = true
                player.playQueue(visibleItems.shuffled(), startAt: 0, title: folder?.name ?? "")
            } label: {
                Image(systemName: "shuffle").font(.caption.weight(.semibold))
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort by", selection: $sortRaw) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.label).tag(order.rawValue)
                    }
                }
                Toggle("Ascending", isOn: $ascending)
                Divider()
                Toggle("Grid view", isOn: $useGrid)
                Toggle("Include subfolders", isOn: $includeSubfolders)
                Divider()
                Button {
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                } label: {
                    Label(isSelecting ? "Done selecting" : "Select items",
                          systemImage: "checkmark.circle")
                }
                Button {
                    player.playQueue(visibleItems, startAt: 0, title: folder?.name ?? "")
                } label: {
                    Label("Play all", systemImage: "play.fill")
                }
                Button {
                    let list = playlists.create(
                        name: folder?.name ?? "Playlist",
                        symbol: Theme.symbol(forFolder: folder?.name ?? "")
                    )
                    playlists.add(paths: visibleItems.map { $0.relativePath }, to: list.id)
                } label: {
                    Label("Save folder as playlist", systemImage: "music.note.list")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected")
                .font(.footnote.weight(.medium))
            Spacer()
            PillButton(title: "Queue", systemImage: "text.append") {
                let items = visibleItems.filter { selection.contains($0.relativePath) }
                player.appendToQueue(items)
                selection.removeAll()
            }
            PillButton(title: "Playlist", systemImage: "music.note.list", prominent: true) {
                showingPlaylistPicker = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func tap(_ item: MediaItem) {
        if isSelecting {
            if selection.contains(item.relativePath) {
                selection.remove(item.relativePath)
            } else {
                selection.insert(item.relativePath)
            }
        } else {
            player.play(item: item, in: visibleItems, title: folder?.name ?? "")
        }
    }
}

// MARK: - Grid cell

struct GridCell: View {
    let item: MediaItem
    var selected: Bool = false
    var selecting: Bool = false

    @EnvironmentObject private var states: PlaybackStateStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .bottomLeading) {
                MediaThumbnail(item: item, size: CGSize(width: 170, height: 100))

                if state.isInProgress {
                    ProgressPill(fraction: state.progressFraction)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }

                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Theme.accent : .white.opacity(0.8))
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2)
            )

            Text(item.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Image(systemName: item.kind.symbolName)
                Text(state.duration > 0 ? Fmt.time(state.duration) : Fmt.fileSize(item.fileSize))
                if state.favorite { Image(systemName: "star.fill").foregroundStyle(Theme.accent) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var state: ItemState { states.state(for: item.relativePath) }
}
