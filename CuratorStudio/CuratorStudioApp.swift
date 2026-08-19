import SwiftUI
import AVFoundation
import UIKit

@main
struct CuratorStudioApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var library = LibraryStore()
    @StateObject private var states = PlaybackStateStore.shared
    @StateObject private var playlists = PlaylistStore.shared
    @StateObject private var player = PlayerModel.shared
    @StateObject private var downloads = DownloadManager()
    @StateObject private var youtube = YouTubeStore()

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
                .environmentObject(downloads)
                .environmentObject(youtube)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task {
                    player.attach(library: library)
                    downloads.attach(library: library)
                    await library.restoreSavedRoot()
                    await downloads.resume()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                player.handleEnteredBackground()
                states.saveNow()
            case .active:
                AudioSessionManager.activate()
                Task { await downloads.resume() }
            default:
                break
            }
        }
    }
}

/// Exists for one reason: when iOS relaunches the app in the background because a stream download
/// finished, it hands over a completion handler that must be called once the session's delegate
/// has drained its events. Without it, transfers that complete while the app is dead get stuck.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        StreamFetcher.shared.backgroundCompletionHandler = completionHandler
        StreamFetcher.shared.reconnect()
    }
}
