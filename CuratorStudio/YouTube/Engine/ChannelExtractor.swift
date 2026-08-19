import Foundation

enum ChannelExtractionError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound: return "Couldn't find this channel."
        }
    }
}

struct ChannelExtractor {

    private let client: InnertubeClient

    /// The "Videos" tab of any channel is addressed by this same constant `params` blob regardless
    /// of channel — it selects the newest-first tab, and the response carries
    /// `metadata.channelMetadataRenderer` too, so one call gets both header and video list.
    private static let videosTabParams = "EgZ2aWRlb3PyBgQKAjoA"

    init(client: InnertubeClient) {
        self.client = client
    }

    func channel(id: String) async throws -> ChannelInfo {
        let response = try await client.post(
            endpoint: "browse",
            client: .web,
            body: ["browseId": id, "params": Self.videosTabParams]
        )
        return try Self.parse(response: response, channelId: id)
    }

    /// Next page of a channel's Videos tab.
    func more(continuation: String, channelName: String, channelId: String) async throws
        -> (videos: [StreamInfoItem], continuation: String?) {
        let response = try await client.post(
            endpoint: "browse", client: .web, body: ["continuation": continuation]
        )
        let items = response["onResponseReceivedActions"].arrayValue
            .flatMap { $0["appendContinuationItemsAction"]["continuationItems"].arrayValue }
        let videos = items.compactMap {
            StreamInfoItem(rendererContainer: $0)?.withChannel(name: channelName, id: channelId)
        }
        let token = items.compactMap {
            $0["continuationItemRenderer"].firstValue(forKey: "token").stringValue
        }.first
        return (videos, token)
    }

    /// The header's metadata rows read like ["@veritasium"], ["21.1M subscribers", "528 videos"] —
    /// the handle row comes first, so pick the part that actually says "subscribers".
    private static func subscriberText(in header: JSONValue) -> String? {
        let rows = header.firstValue(forKey: "contentMetadataViewModel")["metadataRows"].arrayValue
        for row in rows {
            let parts = row["metadataParts"].arrayValue.compactMap { $0["text"]["content"].stringValue }
            if let subscribers = parts.first(where: { $0.localizedCaseInsensitiveContains("subscriber") }) {
                return subscribers
            }
        }
        return nil
    }

    static func parse(response: JSONValue, channelId id: String) throws -> ChannelInfo {
        let meta = response["metadata"]["channelMetadataRenderer"]
        guard let name = meta["title"].stringValue else {
            throw ChannelExtractionError.notFound
        }
        let header = response["header"].firstValue(forKey: "pageHeaderViewModel")

        let tabs = response["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].arrayValue
        let selectedTab = tabs.first { $0["tabRenderer"]["selected"].boolValue == true }
            ?? tabs.first { !$0["tabRenderer"]["content"].isNull }
        let gridItems = selectedTab?["tabRenderer"]["content"]["richGridRenderer"]["contents"].arrayValue ?? []

        let videos: [StreamInfoItem] = gridItems.compactMap { item in
            StreamInfoItem(rendererContainer: item)?.withChannel(name: name, id: id)
        }
        let continuation = gridItems.compactMap {
            $0["continuationItemRenderer"].firstValue(forKey: "token").stringValue
        }.first

        return ChannelInfo(
            id: id,
            name: name,
            avatarURL: meta["avatar"].bestThumbnailURL.flatMap(URL.init(string:)),
            bannerURL: response["header"].firstValue(forKey: "banner").bestThumbnailURL
                .flatMap(URL.init(string:)),
            subscriberText: subscriberText(in: header),
            description: meta["description"].stringValue,
            videos: videos,
            continuation: continuation
        )
    }
}
