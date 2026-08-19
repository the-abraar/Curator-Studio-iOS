import Foundation

// MARK: - List items

/// A single video row as shown in search results, channel lists, playlists or the Discover feed.
struct StreamInfoItem: Identifiable, Hashable, Sendable {
    let id: String // videoId
    let title: String
    let channelName: String
    let channelId: String?
    let thumbnailURL: URL?
    let duration: String?
    let viewCountText: String?
    let publishedTimeText: String?

    var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(id)") }
}

/// A channel as it appears in search results — enough to subscribe without opening it first.
struct ChannelInfoItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let avatarURL: URL?
    let subscriberText: String?
    let videoCountText: String?
}

/// A playlist as it appears in search results.
struct PlaylistInfoItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let channelName: String?
    let thumbnailURL: URL?
    let videoCount: Int?
}

/// One page of search results: videos, channels and playlists, plus the token for the next page.
struct SearchResults: Sendable {
    var videos: [StreamInfoItem] = []
    var channels: [ChannelInfoItem] = []
    var playlists: [PlaylistInfoItem] = []
    var continuation: String?

    var isEmpty: Bool { videos.isEmpty && channels.isEmpty && playlists.isEmpty }
}

struct ChannelInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let avatarURL: URL?
    let bannerURL: URL?
    let subscriberText: String?
    let description: String?
    var videos: [StreamInfoItem]
    var continuation: String?
}

struct PlaylistInfo: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let channelName: String?
    let thumbnailURL: URL?
    var videos: [StreamInfoItem]
    var continuation: String?
}

// MARK: - Streams

/// One downloadable/playable format out of `streamingData`. YouTube serves three useful shapes:
/// muxed progressive MP4 (audio+video, capped low), video-only adaptive, and audio-only adaptive.
struct StreamFormat: Hashable, Sendable {
    enum Content: Hashable, Sendable {
        case muxed      // video + audio in one file
        case videoOnly
        case audioOnly
    }

    let itag: Int
    let url: URL
    let content: Content
    let mimeType: String
    let bitrate: Int
    let height: Int?
    let fps: Int?
    let qualityLabel: String?
    let audioQuality: String?
    /// Byte size when YouTube declares it — used for progress and for the size estimate in the UI.
    let contentLength: Int64?

    /// The codec string out of `mimeType`, e.g. "avc1.640028" or "mp4a.40.2".
    var codecs: String {
        guard let range = mimeType.range(of: "codecs=\"") else { return "" }
        let rest = mimeType[range.upperBound...]
        return String(rest.prefix { $0 != "\"" })
    }

    var container: String {
        if mimeType.hasPrefix("audio/mp4") { return "m4a" }
        if mimeType.hasPrefix("video/mp4") { return "mp4" }
        if mimeType.contains("webm") { return "webm" }
        return "bin"
    }

    /// H.264 and AAC are the only codecs AVFoundation will put in an MP4 and play everywhere on
    /// iOS. VP9/AV1/Opus formats are parsed but never chosen — see `FormatSelector`.
    var isAppleFriendly: Bool {
        let c = codecs.lowercased()
        return c.hasPrefix("avc1") || c.hasPrefix("mp4a")
    }
}

/// A chapter marker parsed out of the player response, mirrored into the `.curator.json` sidecar.
struct VideoChapter: Hashable, Codable, Sendable {
    let title: String
    let startSeconds: Double
}

struct VideoDetails: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let channelName: String
    let channelId: String?
    let channelAvatarURL: URL?
    let lengthSeconds: Int?
    let viewCount: String?
    let description: String?
    let publishDate: String?
    let thumbnailURL: URL?
    let isLive: Bool
    let formats: [StreamFormat]
    let chapters: [VideoChapter]
    /// Videos suggested alongside this one, from `/next` — NewPipe's "related" list.
    var related: [StreamInfoItem]

    var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(id)") }

    /// Best single-file stream for immediate playback — no muxing, plays straight in AVPlayer.
    var streamableURL: URL? {
        formats
            .filter { $0.content == .muxed && $0.isAppleFriendly }
            .max { $0.bitrate < $1.bitrate }?
            .url
    }
}

// MARK: - Renderer parsing

extension StreamInfoItem {
    /// YouTube renders video rows in several JSON shapes depending on the surface: the classic
    /// `videoRenderer` (search), `compactVideoRenderer` (/next sidebar), `playlistVideoRenderer`
    /// (playlists) and the newer `lockupViewModel` (channel tabs, increasingly search too).
    init?(rendererContainer json: JSONValue) {
        guard case .object(let dict) = json else { return nil }
        if let vr = dict["videoRenderer"] ?? dict["compactVideoRenderer"] ?? dict["playlistVideoRenderer"] {
            self.init(videoRenderer: vr)
        } else if let lvm = dict["lockupViewModel"] {
            self.init(lockupViewModel: lvm)
        } else if let rich = dict["richItemRenderer"] {
            self.init(rendererContainer: rich["content"])
        } else {
            return nil
        }
    }

    private init?(videoRenderer vr: JSONValue) {
        guard let videoId = vr["videoId"].stringValue,
              let title = vr["title"].runText else {
            return nil
        }
        self.init(
            id: videoId,
            title: title,
            channelName: vr["ownerText"].runText ?? vr["shortBylineText"].runText
                ?? vr["longBylineText"].runText ?? "",
            channelId: vr["ownerText"].firstValue(forKey: "browseId").stringValue
                ?? vr["shortBylineText"].firstValue(forKey: "browseId").stringValue
                ?? vr["longBylineText"].firstValue(forKey: "browseId").stringValue,
            thumbnailURL: vr["thumbnail"].bestThumbnailURL.flatMap(URL.init(string:)),
            duration: vr["lengthText"].runText,
            viewCountText: vr["viewCountText"].runText ?? vr["shortViewCountText"].runText,
            publishedTimeText: vr["publishedTimeText"].runText
        )
    }

    private init?(lockupViewModel lvm: JSONValue) {
        guard lvm["contentType"].stringValue == "LOCKUP_CONTENT_TYPE_VIDEO",
              let videoId = lvm["contentId"].stringValue else {
            return nil
        }
        let metadata = lvm["metadata"]["lockupMetadataViewModel"]
        let title = metadata["title"]["content"].stringValue ?? ""
        let rows = metadata["metadata"]["contentMetadataViewModel"]["metadataRows"].arrayValue
        let parts = rows.first?["metadataParts"].arrayValue ?? []
        let texts = parts.compactMap { $0["text"]["content"].stringValue }
        let duration = lvm.firstValue(forKey: "thumbnailBottomOverlayViewModel")
            .firstValue(forKey: "text").stringValue

        // lockupViewModel rows in a channel's own Videos tab don't repeat the channel per item
        // (you're already on that channel) — callers fill it in with `withChannel(name:id:)`.
        self.init(
            id: videoId,
            title: title,
            channelName: "",
            channelId: nil,
            thumbnailURL: lvm["contentImage"]["thumbnailViewModel"]["image"].bestThumbnailURL
                .flatMap(URL.init(string:)),
            duration: duration,
            viewCountText: texts.first,
            publishedTimeText: texts.count > 1 ? texts[1] : nil
        )
    }

    /// Returns a copy with channel identity filled in, for renderer shapes that don't carry a
    /// per-row byline.
    func withChannel(name: String, id: String?) -> StreamInfoItem {
        StreamInfoItem(
            id: self.id, title: title, channelName: name, channelId: id,
            thumbnailURL: thumbnailURL, duration: duration,
            viewCountText: viewCountText, publishedTimeText: publishedTimeText
        )
    }
}

extension ChannelInfoItem {
    init?(rendererContainer json: JSONValue) {
        let renderer = json["channelRenderer"]
        guard !renderer.isNull,
              let id = renderer["channelId"].stringValue,
              let name = renderer["title"].runText else { return nil }
        self.init(
            id: id,
            name: name,
            avatarURL: renderer["thumbnail"].bestThumbnailURL
                .flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) },
            subscriberText: renderer["videoCountText"].runText,
            videoCountText: renderer["subscriberCountText"].runText
        )
    }
}

extension PlaylistInfoItem {
    init?(rendererContainer json: JSONValue) {
        if case .object(let dict) = json, let renderer = dict["playlistRenderer"] {
            guard let id = renderer["playlistId"].stringValue,
                  let title = renderer["title"].runText else { return nil }
            self.init(
                id: id,
                title: title,
                channelName: renderer["shortBylineText"].runText,
                thumbnailURL: renderer.firstValue(forKey: "thumbnails").arrayValue
                    .last?["url"].stringValue.flatMap(URL.init(string:)),
                videoCount: renderer["videoCount"].stringValue.flatMap(Int.init)
            )
            return
        }
        // Newer surfaces wrap playlists in the same lockup shape used for videos.
        if case .object(let dict) = json, let lvm = dict["lockupViewModel"],
           lvm["contentType"].stringValue == "LOCKUP_CONTENT_TYPE_PLAYLIST",
           let id = lvm["contentId"].stringValue {
            let metadata = lvm["metadata"]["lockupMetadataViewModel"]
            let parts = metadata.firstValue(forKey: "metadataRows").arrayValue
                .flatMap { $0["metadataParts"].arrayValue }
                .compactMap { $0["text"]["content"].stringValue }
            self.init(
                id: id,
                title: metadata["title"]["content"].stringValue ?? "Playlist",
                channelName: parts.first { !$0.localizedCaseInsensitiveContains("video") },
                thumbnailURL: lvm["contentImage"].firstValue(forKey: "sources").arrayValue
                    .first?["url"].stringValue.flatMap(URL.init(string:)),
                videoCount: (lvm.firstValue(forKey: "thumbnailOverlayBadgeViewModel")
                    .firstValue(forKey: "text").stringValue
                    ?? parts.first { $0.localizedCaseInsensitiveContains("video") })
                    .flatMap { Int($0.filter(\.isNumber)) }
            )
            return
        }
        return nil
    }
}
