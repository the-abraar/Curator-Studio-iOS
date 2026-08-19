import Foundation
import Combine

struct SubscribedChannel: Codable, Identifiable, Hashable {
    let id: String            // channel id (UC…)
    var name: String
    var avatarURLString: String?
    var subscribedAt: Date = Date()

    var avatarURL: URL? { avatarURLString.flatMap(URL.init(string:)) }
}

struct WatchedVideo: Codable, Identifiable, Hashable {
    let id: String            // video id
    var title: String
    var channelName: String
    var channelId: String?
    var thumbnailURLString: String?
    var watchedAt: Date

    var thumbnailURL: URL? { thumbnailURLString.flatMap(URL.init(string:)) }

    var asStreamItem: StreamInfoItem {
        StreamInfoItem(
            id: id, title: title, channelName: channelName, channelId: channelId,
            thumbnailURL: thumbnailURL, duration: nil, viewCountText: nil, publishedTimeText: nil
        )
    }
}

/// Subscriptions, watch history and recent searches — the account-shaped state NewPipe keeps
/// locally instead of asking you to sign in. One small JSON file; nothing leaves the phone.
@MainActor
final class YouTubeStore: ObservableObject {

    @Published private(set) var subscriptions: [SubscribedChannel] = []
    @Published private(set) var history: [WatchedVideo] = []
    @Published private(set) var recentSearches: [String] = []

    private struct Payload: Codable {
        var subscriptions: [SubscribedChannel] = []
        var history: [WatchedVideo] = []
        var recentSearches: [String] = []
    }

    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CuratorStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("youtube.json")
    }()

    init() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        subscriptions = payload.subscriptions
        history = payload.history
        recentSearches = payload.recentSearches
    }

    private func save() {
        let payload = Payload(
            subscriptions: subscriptions, history: history, recentSearches: recentSearches
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: Subscriptions

    func isSubscribed(_ channelId: String?) -> Bool {
        guard let channelId else { return false }
        return subscriptions.contains { $0.id == channelId }
    }

    func toggleSubscription(id: String, name: String, avatarURL: URL?) {
        if isSubscribed(id) {
            subscriptions.removeAll { $0.id == id }
        } else {
            subscriptions.append(SubscribedChannel(
                id: id, name: name, avatarURLString: avatarURL?.absoluteString
            ))
            subscriptions.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        save()
    }

    func unsubscribe(id: String) {
        subscriptions.removeAll { $0.id == id }
        save()
    }

    // MARK: History

    func recordWatch(_ details: VideoDetails) {
        history.removeAll { $0.id == details.id }
        history.insert(WatchedVideo(
            id: details.id,
            title: details.title,
            channelName: details.channelName,
            channelId: details.channelId,
            thumbnailURLString: details.thumbnailURL?.absoluteString,
            watchedAt: Date()
        ), at: 0)
        history = Array(history.prefix(300))
        save()
    }

    func removeFromHistory(id: String) {
        history.removeAll { $0.id == id }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    // MARK: Searches

    func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        recentSearches = Array(recentSearches.prefix(20))
        save()
    }

    func clearSearches() {
        recentSearches.removeAll()
        save()
    }
}
