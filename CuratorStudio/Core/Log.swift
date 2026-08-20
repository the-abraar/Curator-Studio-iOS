import Foundation
import os

/// Somewhere to look when a download goes wrong on a phone that isn't attached to anything.
///
/// Every line goes two places. `os_log` is there for a live view when the phone *is* attached, and
/// survives a Release build. The file matters more in practice: a download that fails at 2am on
/// cellular leaves a record that can be pulled off the device afterwards with
///
///     xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///       --domain-identifier com.blankframe.curatorstudio --user mobile \
///       --source "Library/Application Support/CuratorStudio/diagnostics.log" --destination .
///
/// `Logger` interpolation is private by default and prints `<private>` for every string, which is
/// useless for reading a title or a path back, so these are all marked public deliberately.
enum Log {
    private static let subsystem = "com.blankframe.curatorstudio"

    /// The queue: enqueue, resolve, stage changes, merge, import.
    static let downloads = Trace(category: "downloads")
    /// The chunk loop: every request, every status code, every retry.
    static let fetch = Trace(category: "fetch")
    /// The library root and what a scan found.
    static let library = Trace(category: "library")

    struct Trace {
        let category: String
        private let logger: Logger

        init(category: String) {
            self.category = category
            self.logger = Logger(subsystem: Log.subsystem, category: category)
        }

        func notice(_ message: String) {
            logger.notice("\(message, privacy: .public)")
            DiagnosticsFile.shared.append(category: category, level: "   ", message: message)
        }

        func error(_ message: String) {
            logger.error("\(message, privacy: .public)")
            DiagnosticsFile.shared.append(category: category, level: "ERR", message: message)
        }

        func debug(_ message: String) {
            logger.debug("\(message, privacy: .public)")
            DiagnosticsFile.shared.append(category: category, level: "dbg", message: message)
        }
    }
}

/// The file half of `Log`. Appends are serialised onto one queue so lines never interleave, and the
/// file is capped — a diagnostics log that fills the phone is worse than no diagnostics log.
final class DiagnosticsFile {

    static let shared = DiagnosticsFile()

    /// Trimmed back to the most recent half when it grows past this.
    private static let sizeLimit = 1024 * 1024

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CuratorStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.log")
    }()

    private let queue = DispatchQueue(label: "com.blankframe.curatorstudio.diagnostics")
    private lazy var formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    func append(category: String, level: String, message: String) {
        let stamp = formatter.string(from: Date())
        queue.async {
            let line = "\(stamp) \(level) [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: Self.url.path) {
                fm.createFile(atPath: Self.url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: Self.url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            if (try? handle.offset()).map({ $0 > UInt64(Self.sizeLimit) }) == true {
                try? handle.close()
                Self.trim()
            }
        }
    }

    /// Keeps the back half of the file, which is the half with the failure in it.
    private static func trim() {
        guard let data = try? Data(contentsOf: url) else { return }
        let keep = data.suffix(sizeLimit / 2)
        // Start at a line boundary so the first entry isn't half a line.
        let start = keep.firstIndex(of: 0x0A).map { keep.index(after: $0) } ?? keep.startIndex
        try? Data(keep[start...]).write(to: url, options: .atomic)
    }
}
