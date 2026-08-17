import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.678, blue: 0.482)
    static let accentDeep = Color(red: 0.95, green: 0.45, blue: 0.30)
    static let surface = Color(white: 0.11)
    static let surfaceElevated = Color(white: 0.16)
    static let hairline = Color(white: 0.28)

    static let folderTints: [Color] = [
        Color(red: 0.98, green: 0.60, blue: 0.42),
        Color(red: 0.55, green: 0.78, blue: 0.98),
        Color(red: 0.66, green: 0.86, blue: 0.60),
        Color(red: 0.86, green: 0.68, blue: 0.98),
        Color(red: 0.98, green: 0.84, blue: 0.52),
        Color(red: 0.60, green: 0.90, blue: 0.86)
    ]

    static func tint(for name: String) -> Color {
        let hash = abs(name.lowercased().hashValue)
        return folderTints[hash % folderTints.count]
    }

    /// Folder-name based icons so "Guitar Lessons" and "Bike Stuff" look
    /// different at a glance.
    static func symbol(forFolder name: String) -> String {
        let n = name.lowercased()
        let map: [(String, String)] = [
            ("guitar", "guitars"), ("music", "music.note"), ("song", "music.note"),
            ("podcast", "mic"), ("bike", "bicycle"), ("moto", "figure.outdoor.cycle"),
            ("learn", "graduationcap"), ("course", "graduationcap"),
            ("program", "chevron.left.forwardslash.chevron.right"),
            ("code", "chevron.left.forwardslash.chevron.right"),
            ("ai", "brain"), ("ml", "brain"), ("german", "character.book.closed"),
            ("language", "character.book.closed"), ("book", "book"),
            ("random", "shuffle"), ("misc", "shuffle"),
            ("movie", "popcorn"), ("film", "popcorn"), ("show", "tv"),
            ("workout", "figure.run"), ("fitness", "figure.run"),
            ("talk", "person.wave.2"), ("lecture", "person.wave.2"),
            ("project", "hammer"), ("hardware", "cpu"), ("electronic", "cpu")
        ]
        for (needle, symbol) in map where n.contains(needle) {
            return symbol
        }
        return "folder"
    }
}

// MARK: - Reusable bits

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProgressPill: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(3, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
    }
}

struct PillButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(prominent ? Theme.accent.opacity(0.9) : Color.white.opacity(0.1))
            )
            .foregroundStyle(prominent ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                PillButton(title: actionTitle, prominent: true, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

/// Poster frame for a video, waveform glyph for audio.
struct MediaThumbnail: View {
    let item: MediaItem
    var size: CGSize = CGSize(width: 96, height: 56)
    @EnvironmentObject private var library: LibraryStore
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.surfaceElevated)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: min(size.height * 0.4, 22)))
                    .foregroundStyle(Theme.accent.opacity(0.85))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: item.relativePath) {
            guard item.kind == .video, image == nil else { return }
            guard let url = library.url(for: item) else { return }
            image = await ThumbnailCache.shared.thumbnail(
                for: url, key: item.relativePath, maxSize: max(size.width, size.height) * 3
            )
        }
    }
}
