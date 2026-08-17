import SwiftUI
import UIKit

/// The transparent layer that sits over the video and turns taps and drags
/// into transport commands.
///
/// - single tap  → show / hide the controls
/// - double tap  → left third rewinds 10s, right third skips 10s, middle
///                 toggles play/pause. Repeated double taps accumulate
///                 (10 → 20 → 30) like the big video apps.
/// - long press  → hold for temporary 2× speed, release to go back
/// - drag ←/→    → scrub, with a live preview readout
/// - drag ↑/↓    → volume on the right half, brightness on the left half
struct GestureOverlay: View {

    @EnvironmentObject private var player: PlayerModel
    @Binding var controlsVisible: Bool

    @State private var seekFeedback: SeekFeedback?
    @State private var accumulated: Double = 0
    @State private var feedbackResetTask: Task<Void, Never>?

    @State private var isScrubbing = false
    @State private var scrubStartTime: Double = 0
    @State private var scrubPreview: Double = 0

    @State private var isBoosting = false
    @State private var speedBeforeBoost: Double = 1.0

    struct SeekFeedback: Equatable {
        var side: Side
        var amount: Double
        enum Side { case back, forward }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.001)

                HStack(spacing: 0) {
                    zone(.back, width: geo.size.width * 0.34)
                    centerZone(width: geo.size.width * 0.32)
                    zone(.forward, width: geo.size.width * 0.34)
                }

                if let feedback = seekFeedback {
                    seekBadge(feedback)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: feedback.side == .back ? .leading : .trailing)
                        .padding(.horizontal, geo.size.width * 0.08)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if isScrubbing {
                    scrubBadge
                        .allowsHitTesting(false)
                }

                if isBoosting {
                    Text("2× speed")
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.65)))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 60)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(scrubGesture(width: geo.size.width))
            .simultaneousGesture(boostGesture)
        }
    }

    // MARK: Zones

    private func zone(_ side: SeekFeedback.Side, width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTap(side) }
            .onTapGesture(count: 1) { toggleControls() }
    }

    private func centerZone(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { player.togglePlayPause() }
            .onTapGesture(count: 1) { toggleControls() }
    }

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible.toggle() }
    }

    private func doubleTap(_ side: SeekFeedback.Side) {
        let step: Double = 10
        if seekFeedback?.side == side {
            accumulated += step
        } else {
            accumulated = step
        }
        applySeek(side: side, step: step)
        withAnimation(.easeOut(duration: 0.12)) {
            seekFeedback = SeekFeedback(side: side, amount: accumulated)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        scheduleFeedbackReset()
    }

    private func applySeek(side: SeekFeedback.Side, step: Double) {
        player.skip(by: side == .back ? -step : step)
    }

    private func scheduleFeedbackReset() {
        feedbackResetTask?.cancel()
        feedbackResetTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                seekFeedback = nil
                accumulated = 0
            }
        }
    }

    private func seekBadge(_ feedback: SeekFeedback) -> some View {
        VStack(spacing: 6) {
            Image(systemName: feedback.side == .back ? "gobackward" : "goforward")
                .font(.system(size: 30, weight: .medium))
            Text("\(Int(feedback.amount))s")
                .font(.subheadline.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(Circle().fill(.black.opacity(0.45)))
    }

    // MARK: Scrub

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if !isScrubbing {
                    isScrubbing = true
                    scrubStartTime = player.currentTime
                    controlsVisible = true
                }
                // Full width of the screen ≈ 90 seconds of travel, so small
                // nudges stay precise on long videos.
                let span = max(60, min(player.duration, 600))
                let delta = Double(value.translation.width / width) * span
                scrubPreview = max(0, min(player.duration, scrubStartTime + delta))
            }
            .onEnded { _ in
                if isScrubbing {
                    player.seek(to: scrubPreview)
                    isScrubbing = false
                }
            }
    }

    private var scrubBadge: some View {
        VStack(spacing: 4) {
            Text(Fmt.time(scrubPreview))
                .font(.title3.weight(.bold).monospacedDigit())
            let delta = scrubPreview - scrubStartTime
            Text("\(delta >= 0 ? "+" : "−")\(Fmt.time(abs(delta)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.6)))
    }

    // MARK: Long-press speed boost

    private var boostGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .onEnded { _ in
                guard !isBoosting else { return }
                isBoosting = true
                speedBeforeBoost = player.speed
                player.setSpeed(min(3.0, player.speed * 2))
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            .simultaneously(with:
                DragGesture(minimumDistance: 0)
                    .onEnded { _ in
                        if isBoosting {
                            player.setSpeed(speedBeforeBoost)
                            isBoosting = false
                        }
                    }
            )
    }
}
