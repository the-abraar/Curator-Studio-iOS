import Foundation

enum PlaylistExtractionError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound: return "Couldn't open this playlist."
        }
    }
}

/// Playlists are what make "grab the whole course" work — the Mac daemon used to fan a playlist
/// out into one job per video, and `DownloadManager.enqueue(playlist:)` does the same on-device.
struct PlaylistExtractor {

    private let client: InnertubeClient

    init(client: InnertubeClient) {
        self.client = client
    }

    func playlist(id: String) async throws -> PlaylistInfo {
        let browseId = id.hasPrefix("VL") ? id : "VL" + id
        let response = try await client.post(
            endpoint: "browse", client: .web, body: ["browseId": browseId]
        )
        return try Self.parse(response: response, playlistId: id)
    }

    /// Walks every continuation page so a playlist download queues the whole thing, not page one.
    func allVideos(in playlist: PlaylistInfo, limit: Int = 400) async throws -> [StreamInfoItem] {
        var videos = playlist.videos
        var token = playlist.continuation
        while let continuation = token, videos.count < limit {
            let response = try await client.post(
                endpoint: "browse", client: .web, body: ["continuation": continuation]
            )
            let items = response["onResponseReceivedActions"].arrayValue
                .flatMap { $0["appendContinuationItemsAction"]["continuationItems"].arrayValue }
            let page = items.compactMap { row -> StreamInfoItem? in
                guard let video = StreamInfoItem(rendererContainer: row) else { return nil }
                guard let owner = playlist.channelName, video.channelName.isEmpty else { return video }
                return video.withChannel(name: owner, id: nil)
            }
            if page.isEmpty { break }
            videos.append(contentsOf: page)
            token = items.compactMap {
                $0["continuationItemRenderer"].firstValue(forKey: "token").stringValue
            }.first
        }
        return videos
    }

    /// Verified live: a playlist browse comes back as `sectionListRenderer.contents[]` holding one
    /// `itemSectionRenderer` of `lockupViewModel` rows, with the next-page token in a *sibling*
    /// section rather than inside the item list. The older `playlistVideoListRenderer` shape is
    /// still accepted in case YouTube serves it to some clients.
    static func parse(response: JSONValue, playlistId id: String) throws -> PlaylistInfo {
        let sections = response["contents"]["twoColumnBrowseResultsRenderer"]["tabs"].arrayValue
            .first?["tabRenderer"]["content"]["sectionListRenderer"]["contents"].arrayValue ?? []

        let rows = sections.flatMap { section -> [JSONValue] in
            let items = section["itemSectionRenderer"]["contents"].arrayValue
            let legacy = items.flatMap { $0["playlistVideoListRenderer"]["contents"].arrayValue }
            return legacy.isEmpty ? items : legacy
        }

        let owner = ownerName(in: response)
        let videos = rows.compactMap { row -> StreamInfoItem? in
            guard let video = StreamInfoItem(rendererContainer: row) else { return nil }
            // lockup rows on a playlist page carry no byline — the playlist's owner is the best
            // stand-in, and it's what the download's "artist" tag ends up as.
            return video.channelName.isEmpty && owner != nil
                ? video.withChannel(name: owner!, id: nil)
                : video
        }

        // The next-page token turns up in two places depending on the playlist: as a sibling
        // section (curated playlists) or as the last row of the item list (channel uploads).
        let continuation = (sections + rows).compactMap {
            $0["continuationItemRenderer"].firstValue(forKey: "token").stringValue
        }.first

        let title = response["metadata"].firstValue(forKey: "title").stringValue
            ?? response["header"].firstValue(forKey: "pageHeaderViewModel")["title"]
                .firstValue(forKey: "content").stringValue
        guard let title, !title.isEmpty else { throw PlaylistExtractionError.notFound }

        return PlaylistInfo(
            id: id,
            title: title,
            channelName: owner,
            thumbnailURL: videos.first?.thumbnailURL,
            videos: videos,
            continuation: continuation
        )
    }

    /// Where the owner's name lives depends on the playlist. Channel-uploads playlists still carry
    /// an `ownerText`; curated ones only have the page header's metadata rows, whose first entry is
    /// a type label ("Playlist", "Podcast", "Course") rather than a name.
    private static func ownerName(in response: JSONValue) -> String? {
        if let owner = response.firstValue(forKey: "ownerText").runText, !owner.isEmpty {
            return owner
        }
        let labels: Set<String> = ["playlist", "podcast", "course", "album", "single", "mix"]
        let rows = response["header"].firstValue(forKey: "pageHeaderViewModel")
            .firstValue(forKey: "contentMetadataViewModel")["metadataRows"].arrayValue
        for row in rows {
            let parts = row["metadataParts"].arrayValue.compactMap { $0["text"]["content"].stringValue }
            if let name = parts.first(where: {
                !labels.contains($0.lowercased())
                    && !$0.localizedCaseInsensitiveContains("video")
                    && !$0.localizedCaseInsensitiveContains("view")
                    && !$0.localizedCaseInsensitiveContains("episode")
            }) {
                return name
            }
        }
        // "Uploads from Veritasium" is the last resort, and better than nothing on the shelf.
        return response["microformat"].firstValue(forKey: "title").stringValue
            .flatMap { $0.hasPrefix("Uploads from ") ? String($0.dropFirst(13)) : nil }
    }
}
