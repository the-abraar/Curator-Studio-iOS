import Foundation
import Combine

enum LibraryError: LocalizedError {
    case noRoot

    var errorDescription: String? {
        switch self {
        case .noRoot: return "No media folder has been chosen yet."
        }
    }
}

/// Owns the security-scoped bookmark to the user's chosen folder and the
/// scanned tree of folders / playable files beneath it.
@MainActor
final class LibraryStore: ObservableObject {

    @Published private(set) var root: FolderNode?
    @Published private(set) var rootDisplayName: String = ""
    @Published private(set) var isScanning = false
    @Published private(set) var hasRoot = false
    @Published var errorMessage: String?

    private(set) var rootURL: URL?
    private var isAccessing = false

    private let bookmarkKey = "CuratorStudio.rootFolderBookmark"

    // MARK: Root selection

    func restoreSavedRoot() async {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            try await adopt(url: url, persist: stale)
        } catch {
            errorMessage = "Could not reopen your media folder: \(error.localizedDescription). Pick it again."
        }
    }

    func chooseRoot(url: URL) async {
        do {
            try await adopt(url: url, persist: true)
        } catch {
            errorMessage = "Could not open that folder: \(error.localizedDescription)"
        }
    }

    func forgetRoot() {
        stopAccess()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        rootURL = nil
        root = nil
        hasRoot = false
        rootDisplayName = ""
    }

    private func adopt(url: URL, persist: Bool) async throws {
        stopAccess()
        isAccessing = url.startAccessingSecurityScopedResource()
        rootURL = url
        rootDisplayName = url.lastPathComponent
        hasRoot = true

        if persist {
            let data = try url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        await rescan()
    }

    private func stopAccess() {
        if isAccessing, let url = rootURL {
            url.stopAccessingSecurityScopedResource()
        }
        isAccessing = false
    }

    // MARK: Scanning

    func rescan() async {
        guard let rootURL else { return }
        isScanning = true
        let scanned = await Task.detached(priority: .userInitiated) { () -> FolderNode? in
            LibraryScanner.scan(directory: rootURL, relativePath: "", name: rootURL.lastPathComponent)
        }.value
        root = scanned
        isScanning = false
        if let scanned, scanned.deepItemCount == 0 {
            errorMessage = "No playable files found in “\(scanned.name)”. Copy some videos or audio in from your Mac and pull to refresh."
        }
    }

    // MARK: Lookup

    func url(for item: MediaItem) -> URL? {
        guard let rootURL else { return nil }
        return rootURL.appendingPathComponent(item.relativePath)
    }

    func url(forRelativePath path: String) -> URL? {
        guard let rootURL else { return nil }
        return rootURL.appendingPathComponent(path)
    }

    func item(forRelativePath path: String) -> MediaItem? {
        allItems.first { $0.relativePath == path }
    }

    var allItems: [MediaItem] {
        root?.flattenedItems ?? []
    }

    func folder(at path: String) -> FolderNode? {
        guard let root else { return nil }
        if path.isEmpty { return root }
        return root.node(at: path)
    }

    /// Items directly inside a folder plus, optionally, everything nested below.
    func items(in folder: FolderNode, includingSubfolders: Bool) -> [MediaItem] {
        includingSubfolders ? folder.flattenedItems : folder.items
    }

    // MARK: Writing into the library

    var allFolderPaths: [String] {
        guard let root else { return [] }
        var paths: [String] = []
        func walk(_ node: FolderNode) {
            for child in node.folders {
                paths.append(child.relativePath)
                walk(child)
            }
        }
        walk(root)
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    @discardableResult
    func createFolder(_ relativePath: String) throws -> URL {
        guard let rootURL else { throw LibraryError.noRoot }
        let target = rootURL.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// Moves a finished transfer into the library, creating the destination
    /// folder if needed and side-stepping name collisions.
    /// Returns the new relative path.
    @discardableResult
    func adoptFile(at temporaryURL: URL, folder: String, filename: String) throws -> String {
        guard let rootURL else { throw LibraryError.noRoot }
        let fm = FileManager.default

        let cleanFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let directory = cleanFolder.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(cleanFolder, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(next)
            counter += 1
        }

        try fm.moveItem(at: temporaryURL, to: candidate)

        let relative = cleanFolder.isEmpty
            ? candidate.lastPathComponent
            : cleanFolder + "/" + candidate.lastPathComponent
        return relative
    }

    func search(_ query: String) -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else { return [] }
        let needle = trimmed.lowercased()
        return allItems.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.relativePath.lowercased().contains(needle)
        }
    }

}

// MARK: - Scanner

enum LibraryScanner {

    static let ignoredNames: Set<String> = [
        ".ds_store", ".trashes", ".spotlight-v100", ".fseventsd", "__macosx", ".localized"
    ]

    static func scan(directory: URL, relativePath: String, name: String) -> FolderNode {
        let fm = FileManager.default
        var folders: [FolderNode] = []
        var items: [MediaItem] = []
        var skipped = 0

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey, .isPackageKey
        ]

        let contents = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in contents {
            let lowerName = url.lastPathComponent.lowercased()
            if ignoredNames.contains(lowerName) { continue }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let isPackage = values?.isPackage ?? false
            let childRelative = relativePath.isEmpty
                ? url.lastPathComponent
                : relativePath + "/" + url.lastPathComponent

            if isDirectory && !isPackage {
                let child = scan(directory: url, relativePath: childRelative, name: url.lastPathComponent)
                if child.deepItemCount > 0 || !child.folders.isEmpty {
                    folders.append(child)
                }
            } else if let kind = MediaKind.kind(for: url) {
                items.append(MediaItem(
                    relativePath: childRelative,
                    displayName: prettyName(from: url.deletingPathExtension().lastPathComponent),
                    fileName: url.lastPathComponent,
                    kind: kind,
                    fileSize: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? Date.distantPast,
                    folderPath: relativePath
                ))
            } else if !url.pathExtension.isEmpty {
                skipped += 1
            }
        }

        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        items.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        let deep = items.count + folders.reduce(0) { $0 + $1.deepItemCount }
        let deepSkipped = skipped + folders.reduce(0) { $0 + $1.skippedFileCount }

        return FolderNode(
            relativePath: relativePath,
            name: name,
            folders: folders,
            items: items,
            deepItemCount: deep,
            skippedFileCount: deepSkipped
        )
    }

    /// Turns "01 - My.Lesson_Two" into "01 - My Lesson Two" for readability,
    /// while leaving deliberate punctuation alone.
    static func prettyName(from raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        if !s.contains(" ") {
            s = s.replacingOccurrences(of: ".", with: " ")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
