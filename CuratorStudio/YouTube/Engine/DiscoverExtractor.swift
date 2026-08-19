import Foundation

/// Stand-in for YouTube's now-defunct anonymous Trending feed: its logged-out `FEtrending` /
/// `FEwhat_to_watch` browse requests return a sign-in nudge, and there is no anonymous
/// replacement. Discover runs a handful of broad searches in parallel and presents them as
/// topic shelves instead.
struct DiscoverExtractor {

    private let client: InnertubeClient

    static let defaultTopics = ["Music", "Guitar lessons", "Technology", "Science", "News"]

    init(client: InnertubeClient) {
        self.client = client
    }

    func discover(topics: [String] = defaultTopics) async throws -> [(topic: String, items: [StreamInfoItem])] {
        let search = SearchExtractor(client: client)
        return await withTaskGroup(of: (Int, String, [StreamInfoItem]).self) { group in
            for (index, topic) in topics.enumerated() {
                group.addTask {
                    let results = try? await search.search(query: topic, filter: .videos)
                    return (index, topic, Array((results?.videos ?? []).prefix(12)))
                }
            }
            var shelves = [(topic: String, items: [StreamInfoItem])?](repeating: nil, count: topics.count)
            for await (index, topic, items) in group where !items.isEmpty {
                shelves[index] = (topic, items)
            }
            return shelves.compactMap { $0 }
        }
    }

    /// The subscriptions feed: the newest uploads across every channel the user follows.
    /// YouTube's own feed needs an account, so this fans out over the locally stored channels.
    ///
    /// The rows carry no machine-readable upload date (just "3 days ago"), so there is nothing to
    /// sort the merged list by — instead the channels are interleaved round-robin, newest-first
    /// within each, which keeps one prolific channel from burying everyone else.
    func subscriptionFeed(channelIds: [String]) async throws -> [StreamInfoItem] {
        let extractor = ChannelExtractor(client: client)
        let perChannel = await withTaskGroup(of: (Int, [StreamInfoItem]).self) { group in
            for (index, id) in channelIds.enumerated() {
                group.addTask {
                    guard let channel = try? await extractor.channel(id: id) else { return (index, []) }
                    return (index, Array(channel.videos.prefix(8)))
                }
            }
            var buckets = [[StreamInfoItem]](repeating: [], count: channelIds.count)
            for await (index, videos) in group {
                buckets[index] = videos
            }
            return buckets
        }

        var merged: [StreamInfoItem] = []
        let deepest = perChannel.map(\.count).max() ?? 0
        for position in 0..<deepest {
            for bucket in perChannel where position < bucket.count {
                merged.append(bucket[position])
            }
        }
        return merged
    }
}
