import Foundation
import Combine

struct Bookmark: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var time: Double
    var label: String
    var created: Date = Date()
}

struct ItemState: Codable, Hashable {
    var position: Double = 0
    var duration: Double = 0
    var finished: Bool = false
    var favorite: Bool = false
    var lastPlayed: Date? = nil
    var bookmarks: [Bookmark] = []
    /// Per-item overrides remembered between sessions.
    var speed: Double? = nil
    var semitones: Int? = nil

    var progressFraction: Double {
        guard duration > 1 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var isInProgress: Bool {
        !finished && position > 15 && progressFraction < 0.97
    }
}

/// Resume positions, bookmarks, favourites and per-item playback overrides.
/// Persisted as one small JSON file in Application Support.
@MainActor
final class PlaybackStateStore: ObservableObject {

    static let shared = PlaybackStateStore()

    @Published private(set) var states: [String: ItemState] = [:]

    private var saveTask: Task<Void, Never>?

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("playback-state.json")
    }

    private init() {
        load()
    }

    // MARK: Access

    func state(for path: String) -> ItemState {
        states[path] ?? ItemState()
    }

    func update(_ path: String, _ mutate: (inout ItemState) -> Void) {
        var current = states[path] ?? ItemState()
        mutate(&current)
        states[path] = current
        scheduleSave()
    }

    func recordProgress(path: String, position: Double, duration: Double) {
        guard duration > 0 else { return }
        update(path) { s in
            s.position = position
            s.duration = duration
            s.lastPlayed = Date()
            if duration > 0 && position / duration > 0.97 {
                s.finished = true
            } else if position / duration < 0.9 {
                s.finished = false
            }
        }
    }

    func resumePosition(for path: String) -> Double {
        let s = state(for: path)
        guard s.isInProgress else { return 0 }
        // Rewind slightly so you re-hear the last few seconds of context.
        return max(0, s.position - 5)
    }

    func toggleFavorite(_ path: String) {
        update(path) { $0.favorite.toggle() }
    }

    func markFinished(_ path: String, _ finished: Bool) {
        update(path) { s in
            s.finished = finished
            if finished { s.position = s.duration }
            else { s.position = 0 }
        }
    }

    func addBookmark(_ path: String, time: Double, label: String) {
        update(path) { s in
            s.bookmarks.append(Bookmark(time: time, label: label))
            s.bookmarks.sort { $0.time < $1.time }
        }
    }

    func removeBookmark(_ path: String, id: UUID) {
        update(path) { s in s.bookmarks.removeAll { $0.id == id } }
    }

    func clearAll() {
        states = [:]
        scheduleSave()
    }

    // MARK: Derived collections

    func continueListening(from items: [MediaItem], limit: Int = 12) -> [MediaItem] {
        items
            .filter { state(for: $0.relativePath).isInProgress }
            .sorted {
                (state(for: $0.relativePath).lastPlayed ?? .distantPast)
                    > (state(for: $1.relativePath).lastPlayed ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    func recentlyPlayed(from items: [MediaItem], limit: Int = 30) -> [MediaItem] {
        items
            .filter { state(for: $0.relativePath).lastPlayed != nil }
            .sorted {
                (state(for: $0.relativePath).lastPlayed ?? .distantPast)
                    > (state(for: $1.relativePath).lastPlayed ?? .distantPast)
            }
            .prefix(limit)
            .map { $0 }
    }

    func favorites(from items: [MediaItem]) -> [MediaItem] {
        items.filter { state(for: $0.relativePath).favorite }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: ItemState].self, from: data) {
            states = decoded
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = states
        let url = fileURL
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            _ = self
            await Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(snapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }.value
        }
    }

    func saveNow() {
        let snapshot = states
        let url = fileURL
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
