import Foundation
import AVFoundation
import UIKit

/// Configures the shared audio session for background / screen-off playback
/// and republishes interruption + route-change events.
enum AudioSessionManager {

    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: [])
        } catch {
            NSLog("Curator Studio: audio session setup failed — \(error.localizedDescription)")
        }
    }

    static func activate() {
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    static var isHeadphonesConnected: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains {
            [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay, .usbAudio]
                .contains($0.portType)
        }
    }

    static var routeName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "iPhone"
    }
}

/// Small helper for the in-app "screen off" listening mode: dims the display
/// to zero and keeps the app awake so audio keeps flowing while the panel is
/// effectively dark. Locking the phone works too — background audio is on —
/// this is for when you want the phone unlocked but the screen dark.
@MainActor
final class ScreenDimmer {

    static let shared = ScreenDimmer()

    private var savedBrightness: CGFloat?

    var isDimmed: Bool { savedBrightness != nil }

    func dim() {
        guard savedBrightness == nil else { return }
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0.0
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func restore() {
        if let saved = savedBrightness {
            UIScreen.main.brightness = saved
        }
        savedBrightness = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
