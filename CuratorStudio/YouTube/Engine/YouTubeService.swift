import Foundation

/// Public facade over the extraction engine — the only type the rest of the app talks to.
///
/// This is a from-scratch, native-Swift reimplementation of the subset of YouTube's unofficial
/// "InnerTube" API that NewPipe's `NewPipeExtractor` (Android/JVM) also scrapes. No official
/// YouTube Data API key, no account, and no bridge to the Java library — which couldn't run here
/// anyway. See `InnertubeClientContext` for why different client identities are used per endpoint.
struct YouTubeService: Sendable {

    static let shared = YouTubeService()

    private let client: InnertubeClient

    init() {
        self.client = InnertubeClient()
    }

    // MARK: Browsing

    func search(query: String, filter: SearchFilter = .all) async throws -> SearchResults {
        try await SearchExtractor(client: client).search(query: query, filter: filter)
    }

    func moreSearchResults(continuation: String) async throws -> SearchResults {
        try await SearchExtractor(client: client).more(continuation: continuation)
    }

    func suggestions(for query: String) async throws -> [String] {
        try await SearchExtractor.suggestions(for: query)
    }

    func discover(topics: [String] = DiscoverExtractor.defaultTopics) async throws
        -> [(topic: String, items: [StreamInfoItem])] {
        try await DiscoverExtractor(client: client).discover(topics: topics)
    }

    func subscriptionFeed(channelIds: [String]) async throws -> [StreamInfoItem] {
        try await DiscoverExtractor(client: client).subscriptionFeed(channelIds: channelIds)
    }

    func channel(id: String) async throws -> ChannelInfo {
        try await ChannelExtractor(client: client).channel(id: id)
    }

    func moreChannelVideos(continuation: String, channelName: String, channelId: String) async throws
        -> (videos: [StreamInfoItem], continuation: String?) {
        try await ChannelExtractor(client: client)
            .more(continuation: continuation, channelName: channelName, channelId: channelId)
    }

    func playlist(id: String) async throws -> PlaylistInfo {
        try await PlaylistExtractor(client: client).playlist(id: id)
    }

    func allPlaylistVideos(in playlist: PlaylistInfo) async throws -> [StreamInfoItem] {
        try await PlaylistExtractor(client: client).allVideos(in: playlist)
    }

    // MARK: Streams

    func streamDetails(videoId: String, includeRelated: Bool = true) async throws -> VideoDetails {
        try await StreamExtractor(client: client)
            .streamDetails(videoId: videoId, includeRelated: includeRelated)
    }

    // MARK: Link parsing

    enum Link: Equatable, Sendable {
        case video(String)
        case playlist(String)
        case channel(String)
    }

    /// Understands everything a share sheet is likely to hand over: `youtu.be/ID`,
    /// `youtube.com/watch?v=ID&list=…`, `/shorts/ID`, `/live/ID`, `/embed/ID`,
    /// `/playlist?list=ID`, `/channel/UC…`, `/@handle`.
    static func parse(link raw: String) -> Link? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else { return nil }
        let host = (components.host ?? "").replacingOccurrences(of: "www.", with: "")
        let query = components.queryItems ?? []
        let path = components.path
        let segments = path.split(separator: "/").map(String.init)

        // A bare 11-character id pasted on its own.
        if components.host == nil, isVideoID(trimmed) { return .video(trimmed) }

        guard host.hasSuffix("youtube.com") || host == "youtu.be" || host == "youtube-nocookie.com" else {
            return nil
        }

        if host == "youtu.be", let id = segments.first, isVideoID(id) { return .video(id) }

        if let v = query.first(where: { $0.name == "v" })?.value, isVideoID(v) { return .video(v) }

        if let first = segments.first {
            switch first {
            case "shorts", "live", "embed", "v":
                if segments.count > 1, isVideoID(segments[1]) { return .video(segments[1]) }
            case "playlist":
                if let list = query.first(where: { $0.name == "list" })?.value { return .playlist(list) }
            case "channel":
                if segments.count > 1 { return .channel(segments[1]) }
            case "c", "user":
                if segments.count > 1 { return .channel(segments[1]) }
            default:
                if first.hasPrefix("@") { return .channel(first) }
            }
        }

        if let list = query.first(where: { $0.name == "list" })?.value { return .playlist(list) }
        return nil
    }

    static func isVideoID(_ candidate: String) -> Bool {
        candidate.count == 11 && candidate.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
        }
    }

    /// Handles (`@veritasium`) aren't browse ids — resolve them through search before browsing.
    func resolveChannel(handleOrId raw: String) async throws -> ChannelInfo {
        if raw.hasPrefix("UC") || raw.hasPrefix("HC") {
            return try await channel(id: raw)
        }
        let query = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        let results = try await search(query: query, filter: .channels)
        guard let first = results.channels.first else { throw ChannelExtractionError.notFound }
        return try await channel(id: first.id)
    }
}
