import Foundation

/// What a search should return. YouTube encodes this as an opaque protobuf `params` blob; these
/// are the stable values its own web client sends for the equivalent filter chips.
enum SearchFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case videos
    case channels
    case playlists

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .videos: return "Videos"
        case .channels: return "Channels"
        case .playlists: return "Playlists"
        }
    }

    var params: String? {
        switch self {
        case .all: return nil
        case .videos: return "EgIQAQ%3D%3D"
        case .channels: return "EgIQAg%3D%3D"
        case .playlists: return "EgIQAw%3D%3D"
        }
    }
}

struct SearchExtractor {

    private let client: InnertubeClient

    init(client: InnertubeClient) {
        self.client = client
    }

    func search(query: String, filter: SearchFilter = .all) async throws -> SearchResults {
        var body: [String: Any] = ["query": query]
        if let params = filter.params {
            body["params"] = params.removingPercentEncoding ?? params
        }
        let response = try await client.post(endpoint: "search", client: .web, body: body)
        return Self.parse(response: response)
    }

    /// Page two and beyond. YouTube hands back an opaque token that is simply posted back.
    func more(continuation: String) async throws -> SearchResults {
        let response = try await client.post(
            endpoint: "search", client: .web, body: ["continuation": continuation]
        )
        return Self.parseContinuation(response: response)
    }

    /// Search-as-you-type suggestions. This one is not an InnerTube endpoint — it's the same
    /// public `suggestqueries` service the YouTube search box itself calls, returning JSONP.
    static func suggestions(for query: String) async throws -> [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&ds=yt&q=\(encoded)")
        else { return [] }

        let (data, _) = try await URLSession.shared.data(from: url)
        // Response shape: window.google.ac.h(["query",[["suggestion",0,[…]], …]])
        guard let text = String(data: data, encoding: .isoLatin1),
              let start = text.firstIndex(of: "("),
              let end = text.lastIndex(of: ")") else { return [] }
        let json = String(text[text.index(after: start)..<end])
        guard let payload = json.data(using: .utf8),
              let root = try? JSONValue(data: payload) else { return [] }
        return root[1].arrayValue.compactMap { $0[0].stringValue }
    }

    // MARK: Parsing

    /// `POST /youtubei/v1/search` (WEB) returns
    /// `contents.twoColumnSearchResultsRenderer.primaryContents.sectionListRenderer.contents[]`,
    /// a mix of `videoRenderer`, `channelRenderer`, `playlistRenderer` and `lockupViewModel` rows,
    /// with the next-page token on a trailing `continuationItemRenderer`.
    static func parse(response: JSONValue) -> SearchResults {
        let primary = response["contents"]["twoColumnSearchResultsRenderer"]["primaryContents"]
        return collect(sections: primary["sectionListRenderer"]["contents"].arrayValue)
    }

    static func parseContinuation(response: JSONValue) -> SearchResults {
        let actions = response["onResponseReceivedCommands"].arrayValue
        let sections = actions
            .flatMap { $0["appendContinuationItemsAction"]["continuationItems"].arrayValue }
        return collect(sections: sections)
    }

    private static func collect(sections: [JSONValue]) -> SearchResults {
        var results = SearchResults()
        for section in sections {
            if let token = section["continuationItemRenderer"]
                .firstValue(forKey: "token").stringValue {
                results.continuation = token
            }
            let rows = section["itemSectionRenderer"]["contents"].arrayValue
            for row in rows {
                if let video = StreamInfoItem(rendererContainer: row) {
                    results.videos.append(video)
                } else if let channel = ChannelInfoItem(rendererContainer: row) {
                    results.channels.append(channel)
                } else if let playlist = PlaylistInfoItem(rendererContainer: row) {
                    results.playlists.append(playlist)
                }
            }
        }
        return results
    }
}
