import SwiftUI
import AVKit
import UIKit

struct PlayerScreen: View {

    @EnvironmentObject private var player: PlayerModel
    @EnvironmentObject private var states: PlaybackStateStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var controlsVisible = true
    @State private var activeSheet: PlayerSheet?
    @State private var screenOff = false
    @State private var fillScreen = false
    @State private var pipController: AVPictureInPictureController?
    @State private var hideTask: Task<Void, Never>?

    enum PlayerSheet: String, Identifiable {
        case speed, key, queue, bookmarks, sleep, info
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if player.hasVideoTrack && !screenOff {
                VideoSurface(
                    player: player.player,
                    gravity: fillScreen ? .resizeAspectFill : .resizeAspect,
                    onPiPController: { pipController = $0 }
                )
                .ignoresSafeArea()
            } else if !screenOff {
                AudioBackdrop()
            }

            GestureOverlay(controlsVisible: $controlsVisible)
                .ignoresSafeArea()

            if controlsVisible && !screenOff {
                controlsLayer
                    .transition(.opacity)
            }

            if screenOff {
                ScreenOffOverlay(onWake: {
                    screenOff = false
                    ScreenDimmer.shared.restore()
                })
                .ignoresSafeArea()
            }

            if player.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .allowsHitTesting(false)
            }
        }
        .statusBarHidden(!controlsVisible || screenOff)
        .persistentSystemOverlays(.hidden)
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
                .presentationDetents(sheet == .queue ? [.large] : [.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .alert("Playback problem", isPresented: Binding(
            get: { player.loadError != nil },
            set: { if !$0 { player.loadError = nil } }
        )) {
            Button("OK") { player.loadError = nil }
        } message: {
            Text(player.loadError ?? "")
        }
        .onAppear { scheduleHide() }
        .onChange(of: controlsVisible) { _, visible in
            if visible { scheduleHide() }
        }
        .onDisappear {
            ScreenDimmer.shared.restore()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: player.isPlaying) { _, playing in
            UIApplication.shared.isIdleTimerDisabled = playing && player.hasVideoTrack && !screenOff
        }
    }

    // MARK: Controls

    private var controlsLayer: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            centerTransport
            Spacer(minLength: 0)
            bottomStack
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
                player.isPresentingPlayer = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.displayName ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(player.current?.breadcrumb ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let path = player.current?.relativePath {
                Button {
                    states.toggleFavorite(path)
                } label: {
                    Image(systemName: states.state(for: path).favorite ? "star.fill" : "star")
                }
            }

            Menu {
                Button { activeSheet = .info } label: { Label("File info", systemImage: "info.circle") }
                Button { fillScreen.toggle() } label: {
                    Label(fillScreen ? "Fit to screen" : "Fill screen",
                          systemImage: fillScreen ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward")
                }
                if player.hasVideoTrack, AVPictureInPictureController.isPictureInPictureSupported() {
                    Button {
                        pipController?.startPictureInPicture()
                    } label: {
                        Label("Picture in Picture", systemImage: "pip.enter")
                    }
                }
                Button {
                    ScreenDimmer.shared.dim()
                    screenOff = true
                } label: {
                    Label("Screen off (keep listening)", systemImage: "moon.stars")
                }
                Divider()
                Toggle("Autoplay next", isOn: $player.autoplayNext)
                Button { activeSheet = .sleep } label: {
                    Label(player.sleepTimerOption == .off ? "Sleep timer" : "Sleep: \(player.sleepTimerOption.label)",
                          systemImage: "moon.zzz")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .foregroundStyle(.white)
    }

    private var centerTransport: some View {
        HStack(spacing: 40) {
            Button { player.playPrevious() } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            .disabled(!player.canGoPrevious)

            Button { player.skip(by: -10) } label: {
                Image(systemName: "gobackward.10").font(.system(size: 34))
            }

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 66))
            }

            Button { player.skip(by: 10) } label: {
                Image(systemName: "goforward.10").font(.system(size: 34))
            }

            Button { player.playNext() } label: {
                Image(systemName: "forward.end.fill").font(.title2)
            }
            .disabled(!player.canGoNext)
        }
        .foregroundStyle(.white)
    }

    private var bottomStack: some View {
        VStack(spacing: 14) {
            ScrubBar()

            HStack(spacing: 10) {
                chip(title: Fmt.speed(player.speed), symbol: "speedometer",
                     active: player.speed != 1.0) { activeSheet = .speed }

                chip(title: Fmt.semitonesShort(player.semitones), symbol: "tuningfork",
                     active: player.semitones != 0) { activeSheet = .key }

                chip(title: player.isLooping ? "A–B" : "Loop", symbol: "repeat.circle",
                     active: player.isLooping) { activeSheet = .bookmarks }

                chip(title: "\(player.queueIndex + 1)/\(max(player.queue.count, 1))",
                     symbol: "list.bullet", active: false) { activeSheet = .queue }

                Spacer(minLength: 0)

                AirPlayButton()
                    .frame(width: 34, height: 34)
            }
        }
    }

    private func chip(title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption)
                Text(title).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(active ? Theme.accent.opacity(0.85) : Color.white.opacity(0.14)))
            .foregroundStyle(active ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .speed: SpeedSheet()
        case .key: KeySheet()
        case .queue: QueueSheet()
        case .bookmarks: LoopAndBookmarksSheet()
        case .sleep: SleepSheet()
        case .info: FileInfoSheet()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard player.hasVideoTrack else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard !Task.isCancelled else { return }
            if player.isPlaying {
                withAnimation(.easeIn(duration: 0.25)) { controlsVisible = false }
            }
        }
    }
}

// MARK: - Scrub bar

struct ScrubBar: View {

    @EnvironmentObject private var player: PlayerModel
    @State private var dragging = false
    @State private var draft: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let fraction = player.duration > 0
                    ? (dragging ? draft : player.currentTime) / player.duration
                    : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22)).frame(height: 5)

                    if let a = player.loopStart, let b = player.loopEnd, player.duration > 0 {
                        let x = geo.size.width * (a / player.duration)
                        let w = geo.size.width * ((b - a) / player.duration)
                        Capsule().fill(Theme.accentDeep.opacity(0.55))
                            .frame(width: max(2, w), height: 5)
                            .offset(x: x)
                    }

                    Capsule().fill(Theme.accent)
                        .frame(width: max(0, geo.size.width * fraction), height: 5)

                    Circle()
                        .fill(.white)
                        .frame(width: dragging ? 16 : 11, height: dragging ? 16 : 11)
                        .offset(x: max(0, geo.size.width * fraction - (dragging ? 8 : 5.5)))
                }
                .contentShape(Rectangle().inset(by: -14))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.duration > 0 else { return }
                            dragging = true
                            let f = min(max(value.location.x / geo.size.width, 0), 1)
                            draft = f * player.duration
                        }
                        .onEnded { _ in
                            if dragging { player.seek(to: draft) }
                            dragging = false
                        }
                )
            }
            .frame(height: 20)

            HStack {
                Text(Fmt.time(dragging ? draft : player.currentTime))
                Spacer()
                if player.speed != 1.0, player.duration > 0 {
                    Text("≈\(Fmt.time((player.duration - player.currentTime) / player.speed)) left at \(Fmt.speed(player.speed))")
                        .foregroundStyle(Theme.accent.opacity(0.9))
                }
                Spacer()
                Text(Fmt.remaining(dragging ? draft : player.currentTime, player.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
    }
}

// MARK: - Audio backdrop

struct AudioBackdrop: View {
    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.accentDeep.opacity(0.35), .black, .black],
                startPoint: .top, endPoint: .bottom
            )
            VStack(spacing: 22) {
                if let art = player.artwork {
                    Image(uiImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 260, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 92, weight: .ultraLight))
                        .foregroundStyle(Theme.accent.opacity(0.85))
                }
                Text(player.current?.displayName ?? "")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .padding(.bottom, 60)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Screen off

struct ScreenOffOverlay: View {
    var onWake: () -> Void
    @EnvironmentObject private var player: PlayerModel
    @State private var showHint = true

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                if showHint {
                    Image(systemName: "moon.stars")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.25))
                    Text("Screen off — audio keeps playing")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.22))
                    Text("Double-tap to bring it back")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.16))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onWake() }
        .task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.easeOut(duration: 1.2)) { showHint = false }
        }
    }
}

// MARK: - AirPlay

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accent)
        view.prioritizesVideoDevices = true
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
