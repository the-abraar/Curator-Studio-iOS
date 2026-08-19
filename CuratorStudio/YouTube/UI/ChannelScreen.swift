import SwiftUI

struct ChannelScreen: View {

    let channelId: String

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var store: YouTubeStore

    @State private var channel: ChannelInfo?
    @State private var error: String?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var downloadTarget: StreamInfoItem?
    @State private var showingBulkPrompt = false
    @State private var bulkFolder = ""

    var body: some View {
        List {
            if let channel {
                header(channel)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                Section("Videos") {
                    ForEach(channel.videos) { video in
                        NavigationLink(value: YouTubeRoute.video(video)) {
                            YouTubeVideoRow(video: video, showChannel: false) {
                                downloadTarget = video
                            }
                        }
                        .onAppear {
                            if video == channel.videos.last { Task { await loadMore() } }
                        }
                    }
                    if isLoadingMore {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Loading more…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Opening channel…").font(.caption).foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
            } else if let error {
                EmptyStateView(
                    symbol: "person.crop.circle.badge.exclamationmark",
                    title: "Couldn't open this channel",
                    message: error,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
                .listRowBackground(Color.clear)
            }

            Color.clear.frame(height: 70).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .navigationTitle(channel?.name ?? "Channel")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $downloadTarget) { video in
            DownloadSheet(video: video, availableQualities: nil)
        }
        .alert("Download latest videos", isPresented: $showingBulkPrompt) {
            TextField("Folder name", text: $bulkFolder)
            Button("Queue \(min(channel?.videos.count ?? 0, 10))") {
                guard let channel else { return }
                let clean = bulkFolder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
                downloads.enqueue(videos: Array(channel.videos.prefix(10)), folder: clean)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Queues this channel's 10 newest uploads at your default quality.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let channel {
                        Button {
                            store.toggleSubscription(
                                id: channel.id, name: channel.name, avatarURL: channel.avatarURL
                            )
                        } label: {
                            Label(
                                store.isSubscribed(channel.id) ? "Unsubscribe" : "Subscribe",
                                systemImage: store.isSubscribed(channel.id) ? "person.badge.minus" : "person.badge.plus"
                            )
                        }
                        Button {
                            bulkFolder = channel.name
                            showingBulkPrompt = true
                        } label: {
                            Label("Download latest 10…", systemImage: "square.and.arrow.down.on.square")
                        }
                        if let url = URL(string: "https://www.youtube.com/channel/\(channel.id)") {
                            ShareLink(item: url) { Label("Share channel", systemImage: "square.and.arrow.up") }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task(id: channelId) { await load() }
    }

    private func header(_ channel: ChannelInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let banner = channel.bannerURL {
                AsyncImage(url: banner) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Theme.surfaceElevated)
                }
                .frame(height: 84)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 12) {
                ChannelAvatar(url: channel.avatarURL, diameter: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name).font(.title3.weight(.semibold)).lineLimit(2)
                    if let subscribers = channel.subscriberText {
                        Text(subscribers).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    store.toggleSubscription(
                        id: channel.id, name: channel.name, avatarURL: channel.avatarURL
                    )
                } label: {
                    Text(store.isSubscribed(channel.id) ? "Subscribed" : "Subscribe")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(
                            store.isSubscribed(channel.id) ? Color.white.opacity(0.12) : Theme.accent
                        ))
                        .foregroundStyle(store.isSubscribed(channel.id) ? Color.white : Color.black)
                }
                .buttonStyle(.plain)

                PillButton(title: "Download latest", systemImage: "square.and.arrow.down") {
                    bulkFolder = channel.name
                    showingBulkPrompt = true
                }
                Spacer(minLength: 0)
            }

            if let description = channel.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 6)
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            channel = try await YouTubeService.shared.resolveChannel(handleOrId: channelId)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let current = channel, let continuation = current.continuation, !isLoadingMore else { return }
        isLoadingMore = true
        if let page = try? await YouTubeService.shared.moreChannelVideos(
            continuation: continuation, channelName: current.name, channelId: current.id
        ) {
            var updated = current
            updated.videos.append(contentsOf: page.videos)
            updated.continuation = page.continuation
            channel = updated
        } else {
            channel?.continuation = nil
        }
        isLoadingMore = false
    }
}

struct PlaylistScreen: View {

    let playlistId: String

    @EnvironmentObject private var downloads: DownloadManager

    @State private var playlist: PlaylistInfo?
    @State private var error: String?
    @State private var isLoading = true
    @State private var downloadTarget: StreamInfoItem?
    @State private var showingBulkPrompt = false
    @State private var bulkFolder = ""
    @State private var isExpanding = false

    var body: some View {
        List {
            if let playlist {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        RemoteThumbnail(url: playlist.thumbnailURL, symbol: "list.and.film")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playlist.title).font(.headline).lineLimit(3)
                            if let channel = playlist.channelName {
                                Text(channel).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(playlist.videos.count) videos loaded")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    PillButton(title: "Download all", systemImage: "square.and.arrow.down.on.square",
                               prominent: true) {
                        bulkFolder = playlist.title
                        showingBulkPrompt = true
                    }
                }
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

                Section("Videos") {
                    ForEach(playlist.videos) { video in
                        NavigationLink(value: YouTubeRoute.video(video)) {
                            YouTubeVideoRow(video: video) { downloadTarget = video }
                        }
                    }
                }
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Opening playlist…").font(.caption).foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
            } else if let error {
                EmptyStateView(
                    symbol: "list.bullet.rectangle",
                    title: "Couldn't open this playlist",
                    message: error,
                    actionTitle: "Try again",
                    action: { Task { await load() } }
                )
                .listRowBackground(Color.clear)
            }

            Color.clear.frame(height: 70).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .navigationTitle("Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $downloadTarget) { video in
            DownloadSheet(video: video, availableQualities: nil)
        }
        .alert("Download playlist", isPresented: $showingBulkPrompt) {
            TextField("Folder name", text: $bulkFolder)
            Button("Queue all") { Task { await queueAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every video goes into one folder in your library, at your default quality.")
        }
        .overlay {
            if isExpanding {
                ProgressView("Reading the whole playlist…")
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surfaceElevated))
            }
        }
        .task(id: playlistId) { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            playlist = try await YouTubeService.shared.playlist(id: playlistId)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Walks every continuation page first — a 200-video course shouldn't queue only the first 100.
    private func queueAll() async {
        guard let playlist else { return }
        let folder = bulkFolder.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        isExpanding = true
        let videos = (try? await YouTubeService.shared.allPlaylistVideos(in: playlist)) ?? playlist.videos
        isExpanding = false
        downloads.enqueue(videos: videos, folder: folder)
    }
}
