import SwiftUI
import UIKit
import AVKit
import AVFoundation

/// A plain AVPlayerLayer host. We deliberately avoid AVPlayerViewController so
/// every gesture and control is ours.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }
}

struct VideoSurface: UIViewRepresentable {

    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    var onPiPController: ((AVPictureInPictureController?) -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.player = player
        view.playerLayer.videoGravity = gravity

        if AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(playerLayer: view.playerLayer)
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
            context.coordinator.pip = controller
            onPiPController?(controller)
        }
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.player !== player { uiView.player = player }
        uiView.playerLayer.videoGravity = gravity
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var pip: AVPictureInPictureController?
    }
}
