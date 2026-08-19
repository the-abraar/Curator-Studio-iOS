import SwiftUI

struct RootView: View {

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var downloads: DownloadManager
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if library.hasRoot {
                mainInterface
            } else {
                OnboardingView()
            }
        }
        .fullScreenCover(isPresented: $player.isPresentingPlayer) {
            PlayerScreen()
        }
    }

    private var mainInterface: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                LibraryScreen()
                    .tabItem { Label("Library", systemImage: "square.stack") }
                    .tag(0)

                HomeScreen()
                    .tabItem { Label("Home", systemImage: "house") }
                    .tag(1)

                PlaylistsScreen()
                    .tabItem { Label("Playlists", systemImage: "music.note.list") }
                    .tag(2)

                YouTubeScreen()
                    .tabItem { Label("YouTube", systemImage: "play.rectangle.on.rectangle") }
                    .badge(downloads.badgeCount)
                    .tag(3)

                SettingsScreen()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(4)
            }

            if player.current != nil && !player.isPresentingPlayer {
                MiniPlayerBar()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 52)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: player.current)
    }
}

// MARK: - Onboarding

struct OnboardingView: View {

    @EnvironmentObject private var library: LibraryStore
    @State private var showingPicker = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Theme.accentDeep.opacity(0.25), Color.black],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                Image(systemName: "rectangle.stack.badge.play")
                    .font(.system(size: 62, weight: .thin))
                    .foregroundStyle(Theme.accent)

                Text("Curator Studio")
                    .font(.largeTitle.weight(.bold))

                Text("Point Curator Studio at one folder in Files.\nEverything inside it — songs, guitar lessons, bike stuff, learn stuff — becomes your library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                VStack(alignment: .leading, spacing: 12) {
                    bullet("folder", "Pick any folder — On My iPhone, iCloud Drive, or an external drive")
                    bullet("play.rectangle.on.rectangle", "Search YouTube and download straight to this iPhone — no Mac, no account, no cable")
                    bullet("lock.iphone", "Audio keeps playing with the screen off")
                }
                .padding(.horizontal, 34)
                .padding(.top, 6)

                Spacer()

                Button {
                    showingPicker = true
                } label: {
                    Label("Choose your media folder", systemImage: "folder.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundStyle(.black)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 30)
            }
        }
        .sheet(isPresented: $showingPicker) {
            FolderPicker { url in
                Task { await library.chooseRoot(url: url) }
            }
            .ignoresSafeArea()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
