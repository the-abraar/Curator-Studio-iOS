import SwiftUI

struct PlaylistDetailScreen: View {

    let playlistID: UUID

    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var states: PlaybackStateStore

    @State private var editMode: EditMode = .inactive
    @State private var showingAdd = false
    @State private var renaming = false
    @State private var draftName = ""

    private var playlist: Playlist? { playlists.playlist(playlistID) }

    var body: some View {
        Group {
            if let playlist {
                let items = playlists.items(for: playlist, in: library)
                List {
                    Section {
                        HStack(spacing: 12) {
                            PillButton(title: "Play", systemImage: "play.fill", prominent: true) {
                                player.shuffleEnabled = false
                                player.playQueue(items, startAt: 0, title: playlist.name)
                            }
                            PillButton(title: "Shuffle", systemImage: "shuffle") {
                                player.shuffleEnabled = true
                                player.playQueue(items.shuffled(), startAt: 0, title: playlist.name)
                            }
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }

                    Section("\(items.count) item\(items.count == 1 ? "" : "s")") {
                        ForEach(items) { item in
                            MediaRow(item: item, showBreadcrumb: true)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    let index = items.firstIndex(of: item) ?? 0
                                    player.playQueue(items, startAt: index, title: playlist.name)
                                }
                        }
                        .onDelete { offsets in
                            let paths = offsets.map { items[$0].relativePath }
                            playlists.remove(paths: Set(paths), from: playlistID)
                        }
                        .onMove { source, destination in
                            playlists.move(in: playlistID, from: source, to: destination)
                        }
                    }

                    let missing = playlists.missingCount(for: playlist, in: library)
                    if missing > 0 {
                        Section {
                            Label("\(missing) file\(missing == 1 ? "" : "s") in this playlist are no longer in your library.",
                                  systemImage: "questionmark.folder")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Remove missing entries") {
                                let known = Set(library.allItems.map { $0.relativePath })
                                let gone = Set(playlist.entries.filter { !known.contains($0) })
                                playlists.remove(paths: gone, from: playlistID)
                            }
                            .font(.footnote)
                        }
                    }

                    Color.clear.frame(height: 70).listRowBackground(Color.clear)
                }
                .listStyle(.insetGrouped)
                .environment(\.editMode, $editMode)
                .navigationTitle(playlist.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showingAdd = true
                            } label: {
                                Label("Add items", systemImage: "plus")
                            }
                            Button {
                                editMode = editMode == .active ? .inactive : .active
                            } label: {
                                Label(editMode == .active ? "Done" : "Reorder",
                                      systemImage: "arrow.up.arrow.down")
                            }
                            Button {
                                draftName = playlist.name
                                renaming = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Menu("Icon") {
                                ForEach(Self.symbolChoices, id: \.self) { symbol in
                                    Button {
                                        playlists.setSymbol(playlistID, symbol: symbol)
                                    } label: {
                                        Label(symbol, systemImage: symbol)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showingAdd) {
                    PickItemsSheet { paths in
                        playlists.add(paths: paths, to: playlistID)
                    }
                }
                .alert("Rename playlist", isPresented: $renaming) {
                    TextField("Name", text: $draftName)
                    Button("Save") {
                        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { playlists.rename(playlistID, to: trimmed) }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            } else {
                EmptyStateView(symbol: "music.note.list", title: "Playlist gone",
                               message: "This playlist no longer exists.")
            }
        }
    }

    static let symbolChoices = [
        "music.note.list", "guitars", "graduationcap", "bicycle", "brain",
        "chevron.left.forwardslash.chevron.right", "character.book.closed",
        "popcorn", "mic", "star", "flame", "moon.zzz"
    ]
}

// MARK: - Add-to-playlist sheets

/// Compact sheet used from multi-select: choose which playlist to add to.
struct AddToPlaylistSheet: View {

    let paths: [String]
    var onDone: () -> Void

    @EnvironmentObject private var playlists: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Add \(paths.count) item\(paths.count == 1 ? "" : "s") to") {
                    ForEach(playlists.playlists) { list in
                        Button {
                            playlists.add(paths: paths, to: list.id)
                            onDone()
                            dismiss()
                        } label: {
                            Label(list.name, systemImage: list.symbol)
                        }
                    }
                }
                Section("Or create") {
                    HStack {
                        TextField("New playlist name", text: $newName)
                        Button("Create") {
                            let trimmed = newName.trimmingCharacters(in: .whitespaces)
                            let list = playlists.create(name: trimmed.isEmpty ? "Untitled" : trimmed)
                            playlists.add(paths: paths, to: list.id)
                            onDone()
                            dismiss()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Full library browser in picker mode — this is how you pull files from
/// several different folders into one playlist.
struct PickItemsSheet: View {

    var onAdd: ([String]) -> Void

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var expanded: Set<String> = []

    private enum PickRow: Identifiable {
        case folder(FolderNode, Int)
        case media(MediaItem, Int)

        var id: String {
            switch self {
            case .folder(let f, _): return "f:" + f.relativePath
            case .media(let m, _): return "m:" + m.relativePath
            }
        }
    }

    /// Flattened outline rows. The recursion happens on plain data, never on
    /// view types — a recursive `some View` would not compile.
    private func rows(for folder: FolderNode, depth: Int) -> [PickRow] {
        var result: [PickRow] = []
        for sub in folder.folders {
            result.append(.folder(sub, depth))
            if expanded.contains(sub.relativePath) {
                result.append(contentsOf: rows(for: sub, depth: depth + 1))
            }
        }
        for item in folder.items {
            result.append(.media(item, depth))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    ForEach(library.root.map { rows(for: $0, depth: 0) } ?? []) { row in
                        switch row {
                        case .folder(let folder, let depth):
                            folderRow(folder, depth: depth)
                        case .media(let item, let depth):
                            pickerRow(item, showPath: false)
                                .padding(.leading, CGFloat(depth) * 14)
                        }
                    }
                } else {
                    ForEach(library.search(search)) { item in
                        pickerRow(item, showPath: true)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Search your library")
            .navigationTitle("Pick items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add \(selection.count)") {
                        onAdd(Array(selection))
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func folderRow(_ folder: FolderNode, depth: Int) -> some View {
        let isOpen = expanded.contains(folder.relativePath)
        return HStack(spacing: 8) {
            Button {
                if isOpen { expanded.remove(folder.relativePath) }
                else { expanded.insert(folder.relativePath) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Image(systemName: Theme.symbol(forFolder: folder.name))
                        .foregroundStyle(Theme.tint(for: folder.name))
                    Text(folder.name).lineLimit(1)
                    Spacer()
                    Text("\(folder.deepItemCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                let paths = folder.flattenedItems.map { $0.relativePath }
                if paths.allSatisfy({ selection.contains($0) }) {
                    paths.forEach { selection.remove($0) }
                } else {
                    paths.forEach { selection.insert($0) }
                }
            } label: {
                Image(systemName: "checklist")
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    private func pickerRow(_ item: MediaItem, showPath: Bool) -> some View {
        Button {
            if selection.contains(item.relativePath) {
                selection.remove(item.relativePath)
            } else {
                selection.insert(item.relativePath)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selection.contains(item.relativePath)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(item.relativePath) ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName).lineLimit(1)
                    if showPath {
                        Text(item.breadcrumb)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: item.kind.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
