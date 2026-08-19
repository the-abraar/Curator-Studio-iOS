import SwiftUI

/// Remote thumbnail with the same rounded, elevated look as `MediaThumbnail` uses for local files.
struct RemoteThumbnail: View {
    let url: URL?
    var size: CGSize = CGSize(width: 132, height: 76)
    var symbol: String = "play.rectangle"
    var corner: CGFloat = 9

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Theme.surfaceElevated)
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Image(systemName: symbol).foregroundStyle(Theme.accent.opacity(0.8))
                default:
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct ChannelAvatar: View {
    let url: URL?
    var diameter: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Circle().fill(Theme.surfaceElevated)
                .overlay(Image(systemName: "person").foregroundStyle(.secondary))
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }
}

/// One video in a list, with the download button on the right — the button is the whole point of
/// this app, so it never hides behind a menu.
struct YouTubeVideoRow: View {

    let video: StreamInfoItem
    var showChannel: Bool = true
    var onDownload: (() -> Void)?

    @EnvironmentObject private var downloads: DownloadManager

    private var jobForVideo: DownloadJob? {
        downloads.jobs.first { $0.videoId == video.id }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                RemoteThumbnail(url: video.thumbnailURL)
                if let duration = video.duration, !duration.isEmpty {
                    Text(duration)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.black.opacity(0.75)))
                        .padding(4)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if showChannel, !video.channelName.isEmpty {
                    Text(video.channelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if let views = video.viewCountText { Text(views) }
                    if let published = video.publishedTimeText {
                        if video.viewCountText != nil { Text("·") }
                        Text(published)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            downloadButton
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var downloadButton: some View {
        if let job = jobForVideo, job.stage.isActive {
            ProgressView(value: max(0.03, job.fraction))
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 30)
        } else if let job = jobForVideo, job.stage == .done {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 30)
        } else if let onDownload {
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
        }
    }
}

struct YouTubeChannelRow: View {
    let channel: ChannelInfoItem

    var body: some View {
        HStack(spacing: 12) {
            ChannelAvatar(url: channel.avatarURL, diameter: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.subheadline.weight(.medium)).lineLimit(1)
                if let subscribers = channel.subscriberText {
                    Text(subscribers).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct YouTubePlaylistRow: View {
    let playlist: PlaylistInfoItem

    var body: some View {
        HStack(spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                RemoteThumbnail(url: playlist.thumbnailURL, symbol: "list.and.film")
                Image(systemName: "square.stack.fill")
                    .font(.caption)
                    .padding(4)
                    .background(Capsule().fill(.black.opacity(0.75)))
                    .padding(4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title).font(.subheadline.weight(.medium)).lineLimit(2)
                if let channel = playlist.channelName {
                    Text(channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let count = playlist.videoCount {
                    Text("\(count) videos").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Navigation

/// One enum for everything the YouTube tab can push, so every list can route the same way.
enum YouTubeRoute: Hashable {
    case video(StreamInfoItem)
    case videoID(String)
    case channel(String)
    case playlist(String)
    case downloads
}

extension View {
    /// Shared destinations for every list in the YouTube tab.
    func youTubeDestinations() -> some View {
        navigationDestination(for: YouTubeRoute.self) { route in
            switch route {
            case .video(let video): VideoScreen(videoId: video.id, preview: video)
            case .videoID(let id): VideoScreen(videoId: id, preview: nil)
            case .channel(let id): ChannelScreen(channelId: id)
            case .playlist(let id): PlaylistScreen(playlistId: id)
            case .downloads: DownloadsScreen()
            }
        }
    }
}
