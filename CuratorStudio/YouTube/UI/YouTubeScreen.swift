import SwiftUI

/// The tab that replaced the Inbox. Everything the Mac used to be asked to do is here: find a
/// video, watch it, download it — plus the subscriptions and history NewPipe keeps without an
/// account.
struct YouTubeScreen: View {

    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var store: YouTubeStore
    @StateObject private var model = YouTubeBrowseModel()

    @State private var query = ""
    @State private var section: Section = .discover
    @State private var downloadTarget: StreamInfoItem?
    @State private var showingAddLink = false
    @State private var isSearchActive = false
    @State private var path = NavigationPath()

    enum Section: String, CaseIterable, Identifiable {
        case discover = "Discover"
        case subscriptions = "Subscriptions"
        case history = "History"

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.isShowingSearch {
                    searchResults
                } else {
                    browse
                }
            }
            .navigationTitle("YouTube")
            .searchable(
                text: $query,
                isPresented: $isSearchActive,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search YouTube"
            )
            .searchSuggestions { suggestions }
            .onSubmit(of: .search) { runSearch(query) }
            .onChange(of: query) { _, new in
                if new.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.clearSearch()
                } else {
                    model.suggest(new)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingAddLink = true } label: {
                        Image(systemName: "link.badge.plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: YouTubeRoute.downloads) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "arrow.down.circle")
                            if downloads.badgeCount > 0 {
                                Circle().fill(Theme.accent)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 3, y: -2)
                            }
                        }
                    }
                }
            }
            .sheet(item: $downloadTarget) { video in
                DownloadSheet(video: video, availableQualities: nil)
            }
            .sheet(isPresented: $showingAddLink) { AddLinkSheet() }
            .youTubeDestinations()
            .onChange(of: model.pendingRoute) { _, route in
                guard let route else { return }
                path.append(route)
                model.pendingRoute = nil
            }
            .task {
                if model.shelves.isEmpty { await model.loadDiscover() }
            }
            .alert("Curator Studio", isPresented: Binding(
                get: { downloads.lastMessage != nil },
                set: { if !$0 { downloads.lastMessage = nil } }
            )) {
                Button("OK") { downloads.lastMessage = nil }
            } message: {
                Text(downloads.lastMessage ?? "")
            }
        }
    }

    // MARK: Browse

    private var browse: some View {
        List {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            switch section {
            case .discover: discoverSection
            case .subscriptions: subscriptionsSection
            case .history: historySection
            }

            Color.clear.frame(height: 70).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .refreshable {
            switch section {
            case .discover: await model.loadDiscover(force: true)
            case .subscriptions: await model.loadSubscriptionFeed(store.subscriptions, force: true)
            case .history: break
            }
        }
    }

    @ViewBuilder
    private var discoverSection: some View {
        if model.isLoadingDiscover && model.shelves.isEmpty {
            loadingRow("Loading Discover…")
        } else if let error = model.discoverError, model.shelves.isEmpty {
            errorRow(error) { Task { await model.loadDiscover(force: true) } }
        } else {
            ForEach(model.shelves, id: \.topic) { shelf in
                SwiftUI.Section(shelf.topic) {
                    ForEach(shelf.items) { video in
                        NavigationLink(value: YouTubeRoute.video(video)) {
                            YouTubeVideoRow(video: video) { downloadTarget = video }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        if store.subscriptions.isEmpty {
            EmptyStateView(
                symbol: "person.2.badge.plus",
                title: "No subscriptions yet",
                message: "Open a channel and tap Subscribe. Their newest uploads land here — no account, nothing synced anywhere."
            )
            .listRowBackground(Color.clear)
        } else {
            SwiftUI.Section("Channels") {
                ForEach(store.subscriptions) { channel in
                    NavigationLink(value: YouTubeRoute.channel(channel.id)) {
                        HStack(spacing: 12) {
                            ChannelAvatar(url: channel.avatarURL, diameter: 38)
                            Text(channel.name).font(.subheadline)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.unsubscribe(id: channel.id)
                        } label: { Label("Unsubscribe", systemImage: "person.badge.minus") }
                    }
                }
            }

            SwiftUI.Section("Latest uploads") {
                if model.isLoadingFeed && model.feed.isEmpty {
                    loadingRow("Checking \(store.subscriptions.count) channels…")
                } else if model.feed.isEmpty {
                    Text("Pull to refresh").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.feed) { video in
                        NavigationLink(value: YouTubeRoute.video(video)) {
                            YouTubeVideoRow(video: video) { downloadTarget = video }
                        }
                    }
                }
            }
            .task(id: store.subscriptions.count) {
                await model.loadSubscriptionFeed(store.subscriptions)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if store.history.isEmpty {
            EmptyStateView(
                symbol: "clock.arrow.circlepath",
                title: "Nothing watched yet",
                message: "Videos you open here get remembered so you can find them again — on this phone only."
            )
            .listRowBackground(Color.clear)
        } else {
            SwiftUI.Section {
                ForEach(store.history) { watched in
                    NavigationLink(value: YouTubeRoute.video(watched.asStreamItem)) {
                        YouTubeVideoRow(video: watched.asStreamItem) {
                            downloadTarget = watched.asStreamItem
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.removeFromHistory(id: watched.id)
                        } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            } header: {
                HStack {
                    Text("Watch history")
                    Spacer()
                    Button("Clear") { store.clearHistory() }
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }

    // MARK: Search

    private var searchResults: some View {
        List {
            Picker("Filter", selection: $model.filter) {
                ForEach(SearchFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .onChange(of: model.filter) { _, _ in runSearch(model.currentQuery) }

            if model.isSearching && model.results.isEmpty {
                loadingRow("Searching…")
            } else if let error = model.searchError {
                errorRow(error) { runSearch(model.currentQuery) }
            }

            if !model.results.channels.isEmpty {
                SwiftUI.Section("Channels") {
                    ForEach(model.results.channels) { channel in
                        NavigationLink(value: YouTubeRoute.channel(channel.id)) {
                            YouTubeChannelRow(channel: channel)
                        }
                    }
                }
            }

            if !model.results.playlists.isEmpty {
                SwiftUI.Section("Playlists") {
                    ForEach(model.results.playlists) { playlist in
                        NavigationLink(value: YouTubeRoute.playlist(playlist.id)) {
                            YouTubePlaylistRow(playlist: playlist)
                        }
                    }
                }
            }

            if !model.results.videos.isEmpty {
                SwiftUI.Section("Videos") {
                    ForEach(model.results.videos) { video in
                        NavigationLink(value: YouTubeRoute.video(video)) {
                            YouTubeVideoRow(video: video) { downloadTarget = video }
                        }
                        .onAppear {
                            if video == model.results.videos.last {
                                Task { await model.loadMore() }
                            }
                        }
                    }
                    if model.isLoadingMore {
                        loadingRow("Loading more…")
                    }
                }
            }

            if !model.isSearching && model.results.isEmpty && model.searchError == nil {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "Nothing found",
                    message: "Try fewer words, or paste a link straight in with the \(Image(systemName: "link.badge.plus")) button."
                )
                .listRowBackground(Color.clear)
            }

            Color.clear.frame(height: 70).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var suggestions: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            ForEach(store.recentSearches, id: \.self) { recent in
                Label(recent, systemImage: "clock.arrow.circlepath")
                    .searchCompletion(recent)
            }
        } else {
            ForEach(model.suggestions, id: \.self) { suggestion in
                Label(suggestion, systemImage: "magnifyingglass")
                    .searchCompletion(suggestion)
            }
        }
    }

    private func runSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // A pasted link is an instruction, not a search.
        if let route = YouTubeService.parse(link: trimmed) {
            switch route {
            case .video(let id):
                query = ""
                isSearchActive = false
                model.pendingRoute = .videoID(id)
                return
            case .playlist(let id):
                query = ""
                isSearchActive = false
                model.pendingRoute = .playlist(id)
                return
            case .channel:
                break
            }
        }

        store.recordSearch(trimmed)
        Task { await model.search(trimmed) }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .listRowSeparator(.hidden)
    }

    private func errorRow(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
            PillButton(title: "Try again", systemImage: "arrow.clockwise", action: retry)
        }
        .listRowSeparator(.hidden)
    }
}

// MARK: - Model

/// Search, Discover and the subscription feed. Kept separate from the view so a tab switch
/// doesn't throw away results that took a round trip to fetch.
@MainActor
final class YouTubeBrowseModel: ObservableObject {

    @Published var shelves: [(topic: String, items: [StreamInfoItem])] = []
    @Published var isLoadingDiscover = false
    @Published var discoverError: String?

    @Published var results = SearchResults()
    @Published var currentQuery = ""
    @Published var filter: SearchFilter = .all
    @Published var isSearching = false
    @Published var isLoadingMore = false
    @Published var searchError: String?
    @Published var suggestions: [String] = []

    @Published var feed: [StreamInfoItem] = []
    @Published var isLoadingFeed = false

    /// Set when a pasted link should push a screen instead of searching.
    @Published var pendingRoute: YouTubeRoute?

    var isShowingSearch: Bool { !currentQuery.isEmpty }

    private let youtube = YouTubeService.shared
    private var suggestTask: Task<Void, Never>?
    private var feedLoadedFor: Int = -1

    func loadDiscover(force: Bool = false) async {
        guard force || shelves.isEmpty else { return }
        isLoadingDiscover = true
        discoverError = nil
        do {
            shelves = try await youtube.discover()
            if shelves.isEmpty { discoverError = "YouTube returned nothing — try again in a moment." }
        } catch {
            discoverError = error.localizedDescription
        }
        isLoadingDiscover = false
    }

    func search(_ query: String) async {
        currentQuery = query
        isSearching = true
        searchError = nil
        do {
            results = try await youtube.search(query: query, filter: filter)
        } catch {
            results = SearchResults()
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    func loadMore() async {
        guard let continuation = results.continuation, !isLoadingMore else { return }
        isLoadingMore = true
        if let page = try? await youtube.moreSearchResults(continuation: continuation) {
            results.videos.append(contentsOf: page.videos)
            results.channels.append(contentsOf: page.channels)
            results.playlists.append(contentsOf: page.playlists)
            results.continuation = page.continuation
        } else {
            results.continuation = nil
        }
        isLoadingMore = false
    }

    func clearSearch() {
        currentQuery = ""
        results = SearchResults()
        searchError = nil
        suggestions = []
    }

    func suggest(_ query: String) {
        suggestTask?.cancel()
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = (try? await youtube.suggestions(for: query)) ?? []
            guard !Task.isCancelled else { return }
            suggestions = found
        }
    }

    func loadSubscriptionFeed(_ channels: [SubscribedChannel], force: Bool = false) async {
        guard !channels.isEmpty else { feed = []; return }
        guard force || feedLoadedFor != channels.count || feed.isEmpty else { return }
        isLoadingFeed = true
        // The list JSON carries no real upload date — only "3 days ago" — so there's nothing to
        // sort by. The extractor interleaves the channels instead, newest-first within each.
        feed = (try? await youtube.subscriptionFeed(channelIds: channels.map(\.id))) ?? []
        feedLoadedFor = channels.count
        isLoadingFeed = false
    }
}
