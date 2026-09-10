import SwiftUI

struct MiniPlayerBar: View {

    @EnvironmentObject private var player: PlayerModel

    var body: some View {
        if let item = player.current {
            VStack(spacing: 0) {
                ProgressPill(fraction: player.progressFraction)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)

                HStack(spacing: 12) {
                    MediaThumbnail(item: item, size: CGSize(width: 48, height: 30))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(Fmt.time(player.currentTime))
                                .monospacedDigit()
                            if player.speed != 1.0 {
                                Text(Fmt.speed(player.speed)).foregroundStyle(Theme.accent)
                            }
                            if player.semitones != 0 {
                                Text(Fmt.semitonesShort(player.semitones))
                                    .foregroundStyle(Theme.accent)
                            }
                            if player.isLooping {
                                Image(systemName: "repeat").foregroundStyle(Theme.accent)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Button { player.skip(by: -10) } label: {
                        Image(systemName: "gobackward.10").font(.title3)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button { player.playNext() } label: {
                        Image(systemName: "forward.end.fill").font(.subheadline)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.canGoNext)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )
            .contentShape(Rectangle())
            .onTapGesture { player.isPresentingPlayer = true }
            .contextMenu {
                Button { player.stop() } label: {
                    Label("Stop and close", systemImage: "stop.fill")
                }
            }
        }
    }
}
