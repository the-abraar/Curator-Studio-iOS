import SwiftUI
import UIKit

struct PlaylistsScreen: View {

    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel

    @State private var newName = ""
    @State private var showingNew = false
    @State private var showingImporter = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            List {
                if playlists.playlists.isEmpty {
                    EmptyStateView(
                        symbol: "music.note.list",
                        title: "No playlists yet",
                        message: "Playlists can mix files from any folder — pull three guitar lessons, a German podcast and two songs into one queue.",
                        actionTitle: "Create a playlist",
                        action: { showingNew = true }
                    )
                    .listRowBackground(Color.clear)
                }

                ForEach(playlists.playlists) { list in
                    NavigationLink {
                        PlaylistDetailScreen(playlistID: list.id)
                    } label: {
                        row(list)
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        playlists.delete(playlists.playlists[index].id)
                    }
                }

                Color.clear.frame(height: 70).listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingNew = true
                        } label: {
                            Label("New playlist", systemImage: "plus")
                        }
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import from JSON", systemImage: "square.and.arrow.down")
                        }
                        if !playlists.playlists.isEmpty {
                            Button {
                                exportPlaylists()
                            } label: {
                                Label("Export all", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                }
            }
            .alert("New playlist", isPresented: $showingNew) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let trimmed = newName.trimmingCharacters(in: .whitespaces)
                    playlists.create(name: trimmed.isEmpty ? "Untitled" : trimmed)
                    newName = ""
                }
                Button("Cancel", role: .cancel) { newName = "" }
            }
            .sheet(isPresented: $showingImporter) {
                JSONFilePicker { data in
                    _ = playlists.importJSON(data)
                }
                .ignoresSafeArea()
            }
            .sheet(item: Binding(
                get: { exportURL.map { ShareItem(url: $0) } },
                set: { _ in exportURL = nil }
            )) { item in
                ShareSheet(items: [item.url])
            }
        }
    }

    private func row(_ list: Playlist) -> some View {
        let items = playlists.items(for: list, in: library)
        let missing = playlists.missingCount(for: list, in: library)
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.tint(for: list.name).opacity(0.22))
                Image(systemName: list.symbol)
                    .foregroundStyle(Theme.tint(for: list.name))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(list.name).font(.body.weight(.medium)).lineLimit(1)
                Text(missing > 0
                     ? "\(items.count) items · \(missing) missing"
                     : "\(items.count) item\(items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !items.isEmpty {
                Button {
                    player.playQueue(items, startAt: 0, title: list.name)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }

    private func exportPlaylists() {
        guard let data = playlists.exportJSON() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mediahouse-playlists.json")
        try? data.write(to: url, options: .atomic)
        exportURL = url
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
