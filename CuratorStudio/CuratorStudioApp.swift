import SwiftUI
import AVFoundation

@main
struct CuratorStudioApp: App {

    @StateObject private var library = LibraryStore()
    @StateObject private var states = PlaybackStateStore.shared
    @StateObject private var playlists = PlaylistStore.shared
    @StateObject private var player = PlayerModel.shared
    @StateObject private var ingest = IngestStore()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        AudioSessionManager.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(states)
                .environmentObject(playlists)
                .environmentObject(player)
                .environmentObject(ingest)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    player.attach(library: library)
                    ingest.attach(library: library)
                    await library.restoreSavedRoot()
                    await ingest.refresh()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                player.handleEnteredBackground()
                states.saveNow()
            case .active:
                AudioSessionManager.activate()
                Task { await ingest.refresh() }
            default:
                break
            }
        }
    }
}
