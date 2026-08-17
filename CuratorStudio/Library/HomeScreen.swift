import SwiftUI

/// "What was I in the middle of?" — resume shelf, favourites, recents and
/// quick jumps into the top-level collections.
struct HomeScreen: View {

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var states: PlaybackStateStore
    @EnvironmentObject private var player: PlayerModel

    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    let all = library.allItems
                    let continuing = states.continueListening(from: all)
                    let favorites = states.favorites(from: all)
                    let recents = states.recentlyPlayed(from: all, limit: 20)

                    if !continuing.isEmpty {
                        shelf(title: "Pick up where you left off",
                              subtitle: "Resumes a few seconds before you stopped",
                              items: continuing, queueTitle: "Continue")
                    }

                    if let root = library.root, !root.folders.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Collections")
                                .padding(.horizontal, 16)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                                ForEach(root.folders) { folder in
                                    NavigationLink(value: folder.relativePath) {
                                        collectionTile(folder)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    if !favorites.isEmpty {
                        shelf(title: "Starred", subtitle: nil,
                              items: favorites, queueTitle: "Starred")
                    }

                    if !recents.isEmpty {
                        shelf(title: "Recently played", subtitle: nil,
                              items: recents, queueTitle: "Recent")
                    }

                    if library.allItems.isEmpty {
                        EmptyStateView(
                            symbol: "sparkles",
                            title: "Your shelves fill up as you watch",
                            message: "Play something from the Library tab and it will show up here."
                        )
                    }

                    Color.clear.frame(height: 80)
                }
                .padding(.top, 6)
            }
            .navigationTitle("Home")
            .navigationDestination(for: String.self) { relativePath in
                FolderScreen(folderPath: relativePath)
            }
            .refreshable { await library.rescan() }
        }
    }

    private func shelf(title: String, subtitle: String?, items: [MediaItem], queueTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, subtitle: subtitle)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        Button {
                            player.play(item: item, in: items, title: queueTitle)
                        } label: {
                            GridCell(item: item)
                                .frame(width: 170)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { MediaItemMenu(item: item) }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func collectionTile(_ folder: FolderNode) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.tint(for: folder.name).opacity(0.22))
                Image(systemName: Theme.symbol(forFolder: folder.name))
                    .foregroundStyle(Theme.tint(for: folder.name))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(folder.deepItemCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
    }
}
