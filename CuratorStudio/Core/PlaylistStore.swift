import Foundation
import Combine

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var note: String = ""
    /// Relative paths into the library root. Files can come from any folder.
    var entries: [String] = []
    var created: Date = Date()
    var modified: Date = Date()
    /// SF Symbol shown in the list.
    var symbol: String = "music.note.list"
}

@MainActor
final class PlaylistStore: ObservableObject {

    static let shared = PlaylistStore()

    @Published private(set) var playlists: [Playlist] = []

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("playlists.json")
    }

    private init() { load() }

    // MARK: Mutations

    @discardableResult
    func create(name: String, symbol: String = "music.note.list", entries: [String] = []) -> Playlist {
        let list = Playlist(name: name, entries: entries, symbol: symbol)
        playlists.append(list)
        save()
        return list
    }

    func rename(_ id: UUID, to name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = name
        playlists[idx].modified = Date()
        save()
    }

    func setSymbol(_ id: UUID, symbol: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].symbol = symbol
        save()
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func add(paths: [String], to id: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        for path in paths where !playlists[idx].entries.contains(path) {
            playlists[idx].entries.append(path)
        }
        playlists[idx].modified = Date()
        save()
    }

    func remove(paths: Set<String>, from id: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].entries.removeAll { paths.contains($0) }
        playlists[idx].modified = Date()
        save()
    }

    func move(in id: UUID, from source: IndexSet, to destination: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].entries.move(fromOffsets: source, toOffset: destination)
        playlists[idx].modified = Date()
        save()
    }

    func playlist(_ id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// Resolves stored paths to items that still exist in the library.
    func items(for playlist: Playlist, in library: LibraryStore) -> [MediaItem] {
        let index = Dictionary(uniqueKeysWithValues: library.allItems.map { ($0.relativePath, $0) })
        return playlist.entries.compactMap { index[$0] }
    }

    func missingCount(for playlist: Playlist, in library: LibraryStore) -> Int {
        let known = Set(library.allItems.map { $0.relativePath })
        return playlist.entries.filter { !known.contains($0) }.count
    }

    // MARK: Import / export

    func exportJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(playlists)
    }

    func importJSON(_ data: Data) -> Int {
        guard let incoming = try? JSONDecoder().decode([Playlist].self, from: data) else { return 0 }
        var added = 0
        for var list in incoming where !playlists.contains(where: { $0.id == list.id }) {
            list.modified = Date()
            playlists.append(list)
            added += 1
        }
        save()
        return added
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = decoded
    }

    private func save() {
        let snapshot = playlists
        let url = fileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
