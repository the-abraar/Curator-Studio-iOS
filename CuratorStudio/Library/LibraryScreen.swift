import SwiftUI

struct LibraryScreen: View {

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var states: PlaybackStateStore
    @EnvironmentObject private var player: PlayerModel

    @State private var searchText = ""
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let root = library.root {
                    content(root: root)
                } else if library.isScanning {
                    ProgressView("Scanning…")
                } else {
                    EmptyStateView(
                        symbol: "folder",
                        title: "Nothing scanned yet",
                        message: "Pull down to scan your folder again."
                    )
                }
            }
            .navigationTitle(library.rootDisplayName.isEmpty ? "Library" : library.rootDisplayName)
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { relativePath in
                FolderScreen(folderPath: relativePath)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await library.rescan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable { await library.rescan() }
            .searchable(text: $searchText, placement: .navigationBarDrawer, prompt: "Search everything")
        }
    }

    @ViewBuilder
    private func content(root: FolderNode) -> some View {
        if !searchText.isEmpty {
            SearchResultsList(query: searchText)
        } else {
            List {
                if root.folders.isEmpty && root.items.isEmpty {
                    Section {
                        EmptyStateView(
                            symbol: "tray",
                            title: "This folder is empty",
                            message: "Download something from the YouTube tab, or copy videos and audio into “\(root.name)” with Files."
                        )
                        .listRowBackground(Color.clear)
                    }
                }

                if !root.folders.isEmpty {
                    Section("Collections") {
                        ForEach(root.folders) { folder in
                            NavigationLink(value: folder.relativePath) {
                                FolderRow(folder: folder)
                            }
                        }
                    }
                }

                if !root.items.isEmpty {
                    Section("Loose files") {
                        ForEach(root.items) { item in
                            MediaRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    player.play(item: item, in: root.items, title: root.name)
                                }
                        }
                    }
                }

                if root.skippedFileCount > 0 {
                    Section {
                        Label(
                            "\(root.skippedFileCount) file\(root.skippedFileCount == 1 ? "" : "s") skipped — iOS can't decode formats like MKV, AVI or WEBM. Convert them to MP4 before copying them in.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Color.clear.frame(height: 70).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
        }
    }
}

// MARK: - Rows

struct FolderRow: View {
    let folder: FolderNode

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.tint(for: folder.name).opacity(0.22))
                Image(systemName: Theme.symbol(forFolder: folder.name))
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Theme.tint(for: folder.name))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        var parts: [String] = []
        if !folder.folders.isEmpty {
            parts.append("\(folder.folders.count) folder\(folder.folders.count == 1 ? "" : "s")")
        }
        parts.append("\(folder.deepItemCount) item\(folder.deepItemCount == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

struct MediaRow: View {
    let item: MediaItem
    var showBreadcrumb: Bool = false

    @EnvironmentObject private var states: PlaybackStateStore
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            MediaThumbnail(item: item, size: CGSize(width: 74, height: 44))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if showBreadcrumb {
                        Text(item.breadcrumb).lineLimit(1)
                        Text("·")
                    }
                    if state.duration > 0 {
                        Text(Fmt.time(state.duration))
                    } else {
                        Text(Fmt.fileSize(item.fileSize))
                    }
                    if state.favorite {
                        Image(systemName: "star.fill").foregroundStyle(Theme.accent)
                    }
                    if state.finished {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if state.isInProgress {
                    ProgressPill(fraction: state.progressFraction)
                        .padding(.trailing, 40)
                }
            }

            Spacer(minLength: 0)

            if player.current == item {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 3)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                states.toggleFavorite(item.relativePath)
            } label: {
                Label(state.favorite ? "Unstar" : "Star", systemImage: state.favorite ? "star.slash" : "star")
            }
            .tint(Theme.accentDeep)
        }
        .swipeActions(edge: .trailing) {
            Button {
                states.markFinished(item.relativePath, !state.finished)
            } label: {
                Label(state.finished ? "Unwatched" : "Watched",
                      systemImage: state.finished ? "arrow.uturn.backward" : "checkmark")
            }
            .tint(.gray)
        }
        .contextMenu {
            MediaItemMenu(item: item)
        }
    }

    private var state: ItemState { states.state(for: item.relativePath) }
}

/// Shared context-menu actions for a media item.
struct MediaItemMenu: View {
    let item: MediaItem

    @EnvironmentObject private var states: PlaybackStateStore
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var showingAdd = false

    var body: some View {
        Button {
            player.play(item: item, in: [item], title: item.folderDisplayName)
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            player.appendToQueue([item])
        } label: {
            Label("Add to queue", systemImage: "text.append")
        }

        Menu {
            if playlists.playlists.isEmpty {
                Text("No playlists yet")
            }
            ForEach(playlists.playlists) { list in
                Button(list.name) {
                    playlists.add(paths: [item.relativePath], to: list.id)
                }
            }
            Divider()
            Button {
                let list = playlists.create(name: "New playlist")
                playlists.add(paths: [item.relativePath], to: list.id)
            } label: {
                Label("New playlist", systemImage: "plus")
            }
        } label: {
            Label("Add to playlist", systemImage: "music.note.list")
        }

        Divider()

        Button {
            states.toggleFavorite(item.relativePath)
        } label: {
            Label(states.state(for: item.relativePath).favorite ? "Remove star" : "Star",
                  systemImage: "star")
        }

        Button {
            states.markFinished(item.relativePath, !states.state(for: item.relativePath).finished)
        } label: {
            Label(states.state(for: item.relativePath).finished ? "Mark unwatched" : "Mark watched",
                  systemImage: "checkmark.circle")
        }

        Button(role: .destructive) {
            states.update(item.relativePath) { $0.position = 0; $0.finished = false }
        } label: {
            Label("Reset progress", systemImage: "arrow.counterclockwise")
        }
    }
}

// MARK: - Search

struct SearchResultsList: View {
    let query: String

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        let results = library.search(query)
        List {
            if results.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "No matches",
                               message: "Nothing in your library matches “\(query)”.")
                    .listRowBackground(Color.clear)
            } else {
                Section("\(results.count) result\(results.count == 1 ? "" : "s")") {
                    ForEach(results) { item in
                        MediaRow(item: item, showBreadcrumb: true)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.play(item: item, in: results, title: "Search: \(query)")
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
