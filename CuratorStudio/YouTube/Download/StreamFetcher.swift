import Foundation

protocol StreamFetcherDelegate: AnyObject {
    func fetcher(didProgress jobID: String, part: DownloadJob.Part, received: Int64, total: Int64)
    func fetcher(didFinish jobID: String, part: DownloadJob.Part, at url: URL)
    func fetcher(didFail jobID: String, part: DownloadJob.Part, error: Error)
    /// The stream URL has started being refused — extract a fresh one for the same part.
    func fetcherNeedsFreshURL(jobID: String, part: DownloadJob.Part) async -> URL?
}

enum FetchError: LocalizedError {
    case refused(Int)
    case gaveUp(String)

    var errorDescription: String? {
        switch self {
        case .refused(let code):
            return "YouTube refused the download (HTTP \(code))."
        case .gaveUp(let detail):
            return detail
        }
    }
}

/// Pulls the raw streams off googlevideo.
///
/// Two things make this more than a `downloadTask` one-liner:
///
/// **Two fetch modes.** Given the chance, googlevideo will serve a whole file in one ranged
/// request, which is by far the most reliable way to get it. When it refuses that, it will often
/// still serve small ranges from the start of the file, so the fetcher drops into chunked mode and
/// walks the file in pieces, appending each into one staged file the way yt-dlp does.
///
/// **Expiry and refusal.** A stream URL is signed, IP-bound and short-lived, and YouTube refuses
/// requests liberally — mid-file offsets especially, and everything at all when it decides an
/// address is asking too often. So a refusal is treated as routine: back off, ask for a smaller
/// bite, periodically re-extract a fresh URL via `fetcherNeedsFreshURL`, and — when even that keeps
/// being turned down — start the part over from byte zero, which is the offset most likely to be
/// served. Only after all of that does a part actually fail.
///
/// It's a *background* session on purpose. A 1080p lecture is a few hundred megabytes, and the
/// point of dropping the Mac step is that the phone does the work — so transfers have to survive
/// the app being backgrounded or the screen locking.
final class StreamFetcher: NSObject {

    static let shared = StreamFetcher()

    weak var delegate: StreamFetcherDelegate?

    /// Set by the app delegate when iOS wakes the app specifically to finish background transfers.
    var backgroundCompletionHandler: (() -> Void)?

    private static let sessionIdentifier = "com.blankframe.curatorstudio.streams"

    /// Measured against the live service: ranges up to about 3MB are served, 4MB and above are
    /// refused outright. 2MB leaves headroom without making the request count silly.
    private static let initialChunkSize: Int64 = 2 * 1024 * 1024
    private static let minimumChunkSize: Int64 = 512 * 1024
    private static let failureLimit = 8

    /// googlevideo wants to look like it's talking to a browser, not to a bot.
    private static let downloadHeaders: [String: String] = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-us,en;q=0.5",
        "Sec-Fetch-Mode": "navigate",
        "Accept-Encoding": "identity",
    ]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false          // the user asked for this now, not "sometime"
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 60 * 60 * 12
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// One stream being pulled down.
    private final class Transfer {
        let jobID: String
        let part: DownloadJob.Part
        var url: URL
        var offset: Int64 = 0
        var total: Int64
        var chunkSize: Int64
        var failures = 0
        /// Start optimistic: ask for the whole thing in one request, and only walk it in pieces
        /// once that's been refused.
        var chunked = false

        init(jobID: String, part: DownloadJob.Part, url: URL, total: Int64, chunkSize: Int64) {
            self.jobID = jobID
            self.part = part
            self.url = url
            self.total = total
            self.chunkSize = chunkSize
        }
    }

    /// Delegate callbacks arrive on the session's own queue, so all transfer state is guarded here.
    private let lock = NSLock()
    private var transfers: [String: Transfer] = [:]

    /// Where parts are staged until the assembler picks them up.
    static let stagingDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CuratorStudio/Staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Touching the lazy session re-attaches to transfers still running from a previous launch.
    func reconnect() {
        _ = session
    }

    // MARK: Starting and stopping

    func start(jobID: String, part: DownloadJob.Part, url: URL, expectedBytes: Int64) {
        let key = Self.key(jobID, part)
        let staged = Self.stagedURL(jobID: jobID, part: part)
        try? FileManager.default.removeItem(at: staged)
        FileManager.default.createFile(atPath: staged.path, contents: nil)

        let transfer = Transfer(
            jobID: jobID, part: part, url: url,
            total: expectedBytes, chunkSize: Self.initialChunkSize
        )
        lock.withLock { transfers[key] = transfer }
        requestNextChunk(for: transfer)
    }

    func cancel(jobID: String) {
        lock.withLock {
            transfers = transfers.filter { $0.value.jobID != jobID }
        }
        session.getAllTasks { tasks in
            for task in tasks where Self.decode(task.taskDescription)?.jobID == jobID {
                task.cancel()
            }
        }
    }

    /// Job ids the session is still carrying — used at launch to tell a transfer that is genuinely
    /// still running from one that was interrupted.
    func liveJobIDs() async -> Set<String> {
        let tasks = await session.allTasks
        let queued = lock.withLock { Set(transfers.values.map(\.jobID)) }
        return Set(tasks.compactMap { Self.decode($0.taskDescription)?.jobID }).union(queued)
    }

    static func stagedURL(jobID: String, part: DownloadJob.Part) -> URL {
        stagingDirectory.appendingPathComponent(
            "\(jobID)-\(part.rawValue).\(part == .audio ? "m4a" : "mp4")"
        )
    }

    static func clearStaging(jobID: String) {
        for part in [DownloadJob.Part.video, .audio] {
            try? FileManager.default.removeItem(at: stagedURL(jobID: jobID, part: part))
        }
    }

    // MARK: Chunk loop

    private func requestNextChunk(for transfer: Transfer) {
        var request = URLRequest(url: transfer.url)
        for (field, value) in Self.downloadHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        if transfer.chunked {
            let end = transfer.total > 0
                ? min(transfer.offset + transfer.chunkSize - 1, transfer.total - 1)
                : transfer.offset + transfer.chunkSize - 1
            request.setValue("bytes=\(transfer.offset)-\(end)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(transfer.offset)-", forHTTPHeaderField: "Range")
        }

        let task = session.downloadTask(with: request)
        task.taskDescription = Self.key(transfer.jobID, transfer.part)
        task.resume()
    }

    /// A chunk landed: append it, report progress, and either ask for the next one or finish.
    private func appendChunk(at location: URL, for transfer: Transfer) {
        let staged = Self.stagedURL(jobID: transfer.jobID, part: transfer.part)
        do {
            let data = try Data(contentsOf: location, options: .mappedIfSafe)
            let handle = try FileHandle(forWritingTo: staged)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)

            transfer.offset += Int64(data.count)
            transfer.failures = 0

            delegate?.fetcher(didProgress: transfer.jobID, part: transfer.part,
                              received: transfer.offset, total: transfer.total)

            let complete = transfer.total > 0
                ? transfer.offset >= transfer.total
                : data.isEmpty
            if complete {
                finish(transfer)
            } else {
                requestNextChunk(for: transfer)
            }
        } catch {
            fail(transfer, error: error)
        }
    }

    private func finish(_ transfer: Transfer) {
        lock.withLock { transfers[Self.key(transfer.jobID, transfer.part)] = nil }
        delegate?.fetcher(didFinish: transfer.jobID, part: transfer.part,
                          at: Self.stagedURL(jobID: transfer.jobID, part: transfer.part))
    }

    /// A refused chunk is usually a signed URL going stale, not a dead download. Back off, ask for
    /// a smaller bite, and periodically get a freshly extracted URL before trying the same offset.
    private func retry(_ transfer: Transfer, after code: Int) {
        transfer.failures += 1
        guard transfer.failures <= Self.failureLimit else {
            lock.withLock { transfers[Self.key(transfer.jobID, transfer.part)] = nil }
            delegate?.fetcher(didFail: transfer.jobID, part: transfer.part, error: FetchError.refused(code))
            return
        }
        // First refusal: stop asking for the whole file and start walking it in pieces.
        if !transfer.chunked {
            transfer.chunked = true
        } else {
            transfer.chunkSize = max(Self.minimumChunkSize, transfer.chunkSize / 2)
        }

        Task { [weak self] in
            guard let self else { return }
            let backoff = UInt64(1_000_000_000) << UInt64(min(transfer.failures - 1, 4))
            try? await Task.sleep(nanoseconds: backoff)

            // Every second attempt, assume the URL itself is spent and get a new one.
            if transfer.failures % 2 == 0,
               let fresh = await self.delegate?.fetcherNeedsFreshURL(
                   jobID: transfer.jobID, part: transfer.part
               ) {
                transfer.url = fresh
            }

            // A fresh URL will often serve byte zero while refusing to resume mid-file, so once
            // half the retry budget is gone, throw away what we have and start the part again.
            if transfer.failures >= Self.failureLimit / 2, transfer.offset > 0 {
                let staged = Self.stagedURL(jobID: transfer.jobID, part: transfer.part)
                try? FileManager.default.removeItem(at: staged)
                FileManager.default.createFile(atPath: staged.path, contents: nil)
                transfer.offset = 0
                self.delegate?.fetcher(didProgress: transfer.jobID, part: transfer.part,
                                       received: 0, total: transfer.total)
            }
            guard self.lock.withLock({ self.transfers[Self.key(transfer.jobID, transfer.part)] != nil })
            else { return }   // cancelled while we waited
            self.requestNextChunk(for: transfer)
        }
    }

    private func fail(_ transfer: Transfer, error: Error) {
        lock.withLock { transfers[Self.key(transfer.jobID, transfer.part)] = nil }
        delegate?.fetcher(didFail: transfer.jobID, part: transfer.part, error: error)
    }

    // MARK: Task identity

    private static func key(_ jobID: String, _ part: DownloadJob.Part) -> String {
        "\(jobID)|\(part.rawValue)"
    }

    private static func decode(_ description: String?) -> (jobID: String, part: DownloadJob.Part)? {
        guard let description else { return nil }
        let pieces = description.split(separator: "|")
        guard pieces.count == 2, let part = DownloadJob.Part(rawValue: String(pieces[1])) else {
            return nil
        }
        return (String(pieces[0]), part)
    }

    private func transfer(for description: String?) -> Transfer? {
        guard let description else { return nil }
        return lock.withLock { transfers[description] }
    }
}

// MARK: - URLSessionDownloadDelegate

extension StreamFetcher: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let transfer = transfer(for: downloadTask.taskDescription) else { return }
        // Progress within the current chunk, on top of everything already on disk.
        delegate?.fetcher(didProgress: transfer.jobID, part: transfer.part,
                          received: transfer.offset + totalBytesWritten, total: transfer.total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let transfer = transfer(for: downloadTask.taskDescription) else { return }

        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // The body of a refusal is an error page — never append it to the media file.
            retry(transfer, after: code)
            return
        }

        // Learn the real size from the first Content-Range; YouTube's declared length can be absent.
        if transfer.total <= 0,
           let contentRange = (downloadTask.response as? HTTPURLResponse)?
               .value(forHTTPHeaderField: "Content-Range"),
           let totalPart = contentRange.split(separator: "/").last,
           let parsed = Int64(totalPart) {
            transfer.total = parsed
        }

        appendChunk(at: location, for: transfer)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let transfer = transfer(for: task.taskDescription) else { return }
        // Cancellation is a user action, not a failure — the manager already knows.
        if (error as NSError).code == NSURLErrorCancelled { return }
        retry(transfer, after: (error as NSError).code)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
