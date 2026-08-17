import Foundation

// MARK: - Media kinds

enum MediaKind: String, Codable, Hashable {
    case video
    case audio

    /// Container formats AVFoundation can open natively on iOS.
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "3gp", "3g2", "mpg", "mpeg", "m2v", "ts"
    ]

    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "adts", "wav", "aif", "aiff", "aifc",
        "caf", "flac", "au", "mp2"
    ]

    /// Common formats iOS cannot decode. We still list them so the UI can
    /// explain *why* a file will not play instead of failing silently.
    static let unsupportedExtensions: Set<String> = [
        "mkv", "webm", "avi", "wmv", "flv", "ogg", "ogv", "opus", "rmvb", "divx"
    ]

    static func kind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return nil
    }

    var symbolName: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        }
    }
}

// MARK: - Media item

struct MediaItem: Identifiable, Hashable, Codable {
    /// Path relative to the library root. Stable identity across rescans.
    var relativePath: String
    var displayName: String
    var fileName: String
    var kind: MediaKind
    var fileSize: Int64
    var modified: Date
    /// Relative path of the containing folder ("" when the file sits at the root).
    var folderPath: String

    var id: String { relativePath }

    var folderDisplayName: String {
        folderPath.isEmpty ? "Library root" : (folderPath as NSString).lastPathComponent
    }

    /// Human readable breadcrumb, e.g. "Learn Stuff › German".
    var breadcrumb: String {
        folderPath.isEmpty ? "Library root"
            : folderPath.split(separator: "/").joined(separator: " › ")
    }
}

// MARK: - Folder tree

struct FolderNode: Identifiable, Hashable, Codable {
    var relativePath: String
    var name: String
    var folders: [FolderNode]
    var items: [MediaItem]
    /// Number of playable files in this folder and everything beneath it.
    var deepItemCount: Int
    /// Files present but not playable by AVFoundation.
    var skippedFileCount: Int

    var id: String { relativePath }

    var isEmpty: Bool { folders.isEmpty && items.isEmpty }

    /// Every playable item under this node, depth first, folders before files.
    var flattenedItems: [MediaItem] {
        var result = items
        for folder in folders {
            result.append(contentsOf: folder.flattenedItems)
        }
        return result
    }

    func node(at path: String) -> FolderNode? {
        if path == relativePath { return self }
        for folder in folders {
            if path == folder.relativePath || path.hasPrefix(folder.relativePath + "/") {
                return folder.node(at: path)
            }
        }
        return nil
    }
}

// MARK: - Sorting

enum SortOrder: String, CaseIterable, Identifiable, Codable {
    case name
    case dateAdded
    case size
    case duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date modified"
        case .size: return "File size"
        case .duration: return "Recently played"
        }
    }
}

@MainActor
func sortItems(_ items: [MediaItem], by order: SortOrder, ascending: Bool, states: PlaybackStateStore) -> [MediaItem] {
    let sorted: [MediaItem]
    switch order {
    case .name:
        sorted = items.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    case .dateAdded:
        sorted = items.sorted { $0.modified < $1.modified }
    case .size:
        sorted = items.sorted { $0.fileSize < $1.fileSize }
    case .duration:
        sorted = items.sorted {
            let a = states.state(for: $0.relativePath).lastPlayed ?? .distantPast
            let b = states.state(for: $1.relativePath).lastPlayed ?? .distantPast
            return a < b
        }
    }
    return ascending ? sorted : sorted.reversed()
}
