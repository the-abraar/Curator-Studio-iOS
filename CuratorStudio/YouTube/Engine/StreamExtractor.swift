import Foundation

enum StreamExtractionError: LocalizedError {
    /// YouTube's playabilityStatus wasn't OK (age restriction, region block, private, …).
    case notPlayable(reason: String)
    /// No usable direct (unciphered) stream URL. Signature-cipher deobfuscation isn't implemented,
    /// so this is a known failure mode for a minority of videos rather than a bug.
    case noPlayableStream
    case missingVideoDetails

    var errorDescription: String? {
        switch self {
        case .notPlayable(let reason): return reason
        case .noPlayableStream: return "Couldn't find a directly playable stream for this video."
        case .missingVideoDetails: return "YouTube didn't return details for this video."
        }
    }
}

struct StreamExtractor {

    private let client: InnertubeClient

    init(client: InnertubeClient) {
        self.client = client
    }

    /// Asks `ANDROID_VR`, which hands back direct, unciphered muxed *and* adaptive URLs. If the
    /// bot check refuses the request anyway, the visitor id we're carrying has gone stale — get a
    /// fresh one and ask once more before giving up.
    func streamDetails(videoId: String, includeRelated: Bool = true) async throws -> VideoDetails {
        let body: [String: Any] = [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            // Mirrors what a real player sends; without it some videos come back HLS-only.
            "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
        ]

        var response = try await client.post(endpoint: "player", client: .androidVR, body: body)
        if Self.isBotCheck(response) {
            response = try await client.post(
                endpoint: "player", client: .androidVR, body: body, freshVisitor: true
            )
        }

        var result = try Self.parse(response: response)
        if includeRelated, let related = try? await self.related(videoId: videoId) {
            result.related = related
        }
        return result
    }

    /// `LOGIN_REQUIRED` here means "sign in to confirm you're not a bot", not that the video is
    /// private — the difference matters, because one is worth retrying and the other isn't.
    private static func isBotCheck(_ response: JSONValue) -> Bool {
        response["playabilityStatus"]["status"].stringValue == "LOGIN_REQUIRED"
    }

    /// The `/next` endpoint powers the "up next" list under a video — NewPipe's related streams.
    func related(videoId: String) async throws -> [StreamInfoItem] {
        let response = try await client.post(
            endpoint: "next", client: .web, body: ["videoId": videoId]
        )
        let secondary = response["contents"]["twoColumnWatchNextResults"]["secondaryResults"]
        return secondary.firstValue(forKey: "results").arrayValue
            .compactMap { StreamInfoItem(rendererContainer: $0) }
    }

    // MARK: Parsing

    /// Pure parsing, split from the network call so it can be reasoned about (and tested) on a
    /// recorded response. `streamingData.formats[]` holds muxed progressive MP4;
    /// `streamingData.adaptiveFormats[]` holds the video-only and audio-only renditions that carry
    /// everything above 720p — those are what `FormatSelector` muxes back together on the phone.
    static func parse(response: JSONValue) throws -> VideoDetails {
        let status = response["playabilityStatus"]["status"].stringValue ?? "UNKNOWN"
        guard status == "OK" else {
            let reason = response["playabilityStatus"]["reason"].runText
                ?? response["playabilityStatus"]["messages"][0].stringValue
                ?? "This video isn't playable."
            throw StreamExtractionError.notPlayable(reason: reason)
        }

        let details = response["videoDetails"]
        guard let id = details["videoId"].stringValue, let title = details["title"].stringValue else {
            throw StreamExtractionError.missingVideoDetails
        }

        let streaming = response["streamingData"]
        let formats = streaming["formats"].arrayValue.compactMap { format(from: $0, muxed: true) }
            + streaming["adaptiveFormats"].arrayValue.compactMap { format(from: $0, muxed: false) }

        let microformat = response["microformat"].firstValue(forKey: "playerMicroformatRenderer")

        return VideoDetails(
            id: id,
            title: title,
            channelName: details["author"].stringValue ?? "",
            channelId: details["channelId"].stringValue,
            channelAvatarURL: nil,
            lengthSeconds: details["lengthSeconds"].stringValue.flatMap(Int.init)
                ?? details["lengthSeconds"].intValue,
            viewCount: details["viewCount"].stringValue,
            description: details["shortDescription"].stringValue,
            publishDate: microformat["publishDate"].stringValue,
            thumbnailURL: details["thumbnail"].bestThumbnailURL.flatMap(URL.init(string:)),
            isLive: details["isLiveContent"].boolValue ?? false,
            formats: formats,
            chapters: chapters(from: details["shortDescription"].stringValue),
            related: []
        )
    }

    private static func format(from json: JSONValue, muxed: Bool) -> StreamFormat? {
        // Ciphered formats need signature deobfuscation, which isn't implemented — skip them
        // rather than hand the downloader a URL that 403s.
        guard json["signatureCipher"].isNull, json["cipher"].isNull,
              let urlString = json["url"].stringValue,
              let url = URL(string: urlString),
              let itag = json["itag"].intValue,
              let mime = json["mimeType"].stringValue else {
            return nil
        }

        let content: StreamFormat.Content
        if muxed {
            content = .muxed
        } else if mime.hasPrefix("audio/") {
            content = .audioOnly
        } else {
            content = .videoOnly
        }

        return StreamFormat(
            itag: itag,
            url: url,
            content: content,
            mimeType: mime,
            bitrate: json["bitrate"].intValue ?? json["averageBitrate"].intValue ?? 0,
            height: json["height"].intValue,
            fps: json["fps"].intValue,
            qualityLabel: json["qualityLabel"].stringValue,
            audioQuality: json["audioQuality"].stringValue,
            contentLength: json["contentLength"].stringValue.flatMap(Int64.init)
                ?? json["contentLength"].doubleValue.map(Int64.init)
        )
    }

    /// YouTube exposes chapters as an overlay renderer on the watch page, but the timestamps in
    /// the description are what creators actually author and are present in the player response —
    /// good enough for the sidecar file.
    static func chapters(from description: String?) -> [VideoChapter] {
        guard let description else { return [] }
        var chapters: [VideoChapter] = []

        for line in description.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = String(line)
            guard let match = text.firstMatch(ofTimestamp: ()) else { continue }
            let title = text
                .replacingOccurrences(of: match.raw, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:•*[]()"))
            guard !title.isEmpty else { continue }
            chapters.append(VideoChapter(title: title, startSeconds: match.seconds))
        }
        // A single stray timestamp in a description isn't a chapter list.
        return chapters.count >= 2 ? chapters : []
    }
}

private extension String {
    /// Finds a leading `m:ss`, `mm:ss` or `h:mm:ss` timestamp and converts it to seconds.
    func firstMatch(ofTimestamp _: Void) -> (raw: String, seconds: Double)? {
        let pattern = #"(?<!\d)(\d{1,2}:)?\d{1,2}:\d{2}(?!\d)"#
        guard let range = self.range(of: pattern, options: .regularExpression) else { return nil }
        let raw = String(self[range])
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        let seconds = parts.count == 3
            ? parts[0] * 3600 + parts[1] * 60 + parts[2]
            : parts[0] * 60 + parts[1]
        return (raw, seconds)
    }
}
