import SwiftUI
import AVKit

/// Watch and download. Streaming uses the muxed progressive format straight from YouTube; the
/// download button is what turns it into a real file in your library, playable with the app's own
/// player (speed, transpose, A–B loop) and with the screen off.
struct VideoScreen: View {

    let videoId: String
    let preview: StreamInfoItem?

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var store: YouTubeStore

    @State private var details: VideoDetails?
    @State private var error: String?
    @State private var isLoading = true
    @State private var player: AVPlayer?
    @State private var showingDownload = false
    @State private var descriptionExpanded = false

    private var job: DownloadJob? {
        downloads.jobs.first { $0.videoId == videoId && $0.stage != .cancelled }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                playerArea

                VStack(alignment: .leading, spacing: 10) {
                    Text(details?.title ?? preview?.title ?? "Loading…")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if let views = details?.viewCount.flatMap(Self.formatViews) ?? preview?.viewCountText {
                            Text(views)
                        }
                        if let date = details?.publishDate ?? preview?.publishedTimeText {
                            Text("·")
                            Text(date.prefix(10))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    channelBar
                    actionBar

                    if let job, job.stage.isActive {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressPill(fraction: job.fraction)
                            Text(job.stage.label + (job.totalBytes > 0
                                 ? " · \(Fmt.fileSize(job.receivedBytes)) of \(Fmt.fileSize(job.totalBytes))"
                                 : ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let description = details?.description, !description.isEmpty {
                        descriptionBlock(description)
                    }

                    if let chapters = details?.chapters, !chapters.isEmpty {
                        chaptersBlock(chapters)
                    }
                }
                .padding(.horizontal, 16)

                if let related = details?.related, !related.isEmpty {
                    relatedBlock(related)
                }

                Color.clear.frame(height: 70)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let url = details?.watchURL ?? preview?.watchURL {
                        ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                    }
                    if details?.isLive != true {
                        Button {
                            showingDownload = true
                        } label: { Label("Download…", systemImage: "arrow.down.circle") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingDownload) {
            DownloadSheet(
                video: streamItem,
                availableQualities: details.map { FormatSelector.availableQualities(in: $0.formats) }
            )
        }
        .task(id: videoId) { await load() }
        .onDisappear { player?.pause() }
    }

    private var streamItem: StreamInfoItem {
        if let details {
            return StreamInfoItem(
                id: details.id, title: details.title, channelName: details.channelName,
                channelId: details.channelId, thumbnailURL: details.thumbnailURL,
                duration: nil, viewCountText: nil, publishedTimeText: nil
            )
        }
        return preview ?? StreamInfoItem(
            id: videoId, title: "Video", channelName: "", channelId: nil,
            thumbnailURL: nil, duration: nil, viewCountText: nil, publishedTimeText: nil
        )
    }

    // MARK: Pieces

    @ViewBuilder
    private var playerArea: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let player {
                VideoPlayer(player: player)
            } else if isLoading {
                ProgressView()
            } else {
                VStack(spacing: 10) {
                    RemoteThumbnail(
                        url: details?.thumbnailURL ?? preview?.thumbnailURL,
                        size: CGSize(width: 200, height: 112)
                    )
                    Text(error == nil ? "Can't stream this one — downloading may still work."
                                      : "Streaming unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var channelBar: some View {
        let name = details?.channelName ?? preview?.channelName ?? ""
        let channelId = details?.channelId ?? preview?.channelId
        if !name.isEmpty {
            HStack(spacing: 10) {
                if let channelId {
                    NavigationLink(value: YouTubeRoute.channel(channelId)) {
                        HStack(spacing: 8) {
                            ChannelAvatar(url: details?.channelAvatarURL, diameter: 34)
                            Text(name).font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(name).font(.subheadline.weight(.medium))
                }

                Spacer(minLength: 0)

                if let channelId {
                    Button {
                        store.toggleSubscription(
                            id: channelId, name: name, avatarURL: details?.channelAvatarURL
                        )
                    } label: {
                        Text(store.isSubscribed(channelId) ? "Subscribed" : "Subscribe")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(
                                store.isSubscribed(channelId) ? Color.white.opacity(0.12) : Theme.accent
                            ))
                            .foregroundStyle(store.isSubscribed(channelId) ? Color.white : Color.black)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if details?.isLive == true {
                // A live stream has no finished file to fetch — only a rolling manifest.
                Label("Live — downloading isn't possible until it ends", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let job, job.stage == .done {
                PillButton(title: "In your library", systemImage: "checkmark.circle.fill") {}
                    .disabled(true)
            } else if let job, job.stage.isActive {
                PillButton(title: "Downloading…", systemImage: "arrow.down.circle") {}
                    .disabled(true)
            } else {
                PillButton(title: "Download", systemImage: "arrow.down.circle.fill", prominent: true) {
                    showingDownload = true
                }
            }

            if details?.isLive != true {
                PillButton(title: downloads.defaultQuality == .audio ? "Quick audio" : "Quick \(downloads.defaultQuality.label)",
                           systemImage: "bolt.fill") {
                    downloads.enqueue(video: streamItem)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func descriptionBlock(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(descriptionExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            Button(descriptionExpanded ? "Show less" : "Show more") {
                withAnimation(.snappy) { descriptionExpanded.toggle() }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.top, 4)
    }

    private func chaptersBlock(_ chapters: [VideoChapter]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chapters").font(.subheadline.weight(.semibold))
            ForEach(chapters, id: \.startSeconds) { chapter in
                Button {
                    player?.seek(to: CMTime(seconds: chapter.startSeconds, preferredTimescale: 600))
                } label: {
                    HStack(spacing: 8) {
                        Text(Fmt.time(chapter.startSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.accent)
                        Text(chapter.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
    }

    private func relatedBlock(_ related: [StreamInfoItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up next")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
            ForEach(related) { video in
                NavigationLink(value: YouTubeRoute.video(video)) {
                    YouTubeVideoRow(video: video) {
                        downloads.enqueue(video: video)
                    }
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        error = nil
        do {
            let fetched = try await YouTubeService.shared.streamDetails(videoId: videoId)
            details = fetched
            store.recordWatch(fetched)
            if let url = fetched.streamableURL {
                player = AVPlayer(url: url)
            } else {
                error = "YouTube wouldn't hand over a stream this iPhone can play directly. Downloading merges the separate audio and video streams, so try that."
            }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private static func formatViews(_ raw: String) -> String? {
        guard let count = Int(raw) else { return nil }
        return Fmt.count(count) + " views"
    }
}
