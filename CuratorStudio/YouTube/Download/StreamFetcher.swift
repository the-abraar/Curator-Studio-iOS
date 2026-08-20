import Foundation

protocol StreamFetcherDelegate: AnyObject {
    func fetcher(didProgress jobID: String, part: DownloadJob.Part, received: Int64, total: Int64)
    func fetcher(didFinish jobID: String, part: DownloadJob.Part, at url: URL)
    func fetcher(didFail jobID: String, part: DownloadJob.Part, error: Error)
    /// A delegate event came back for a transfer this launch knows nothing about — iOS replaced
    /// the app process and the chunk loop's offset died with it. There is nothing to resume from.
    func fetcherLostTransfer(jobID: String, part: DownloadJob.Part)
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
    /// Consecutive refusals tolerated before a part is abandoned.
    private static let failureLimit = 8
    /// Refusals tolerated across the whole part, however many good chunks land in between.
    private static let totalFailureLimit = 40
    /// How many times a part may throw away its progress and begin again from byte zero.
    private static let restartLimit = 2
    /// How long a part may go without a single delegate callback before the queue stops believing
    /// it is still running. Chunks are 2MB and the backoff tops out at 16 seconds, so a transfer
    /// that has said nothing for five minutes is not coming back on its own.
    private static let stallWindow: TimeInterval = 5 * 60

    /// The media request has to look like the client the URL was minted for.
    ///
    /// googlevideo checks the request identity against the `/player` call that produced the URL,
    /// and these URLs come from `ANDROID_VR` (see `StreamExtractor`). Asking for an Android
    /// client's URL with a desktop browser User-Agent is served for a moment and then cut off —
    /// which is what "it never got past 1MB" was: a megabyte of chunks, then every request after
    /// refused, however fresh the URL.
    ///
    /// `Accept-Encoding: identity` matters for a second reason: a re-encoded body would not line
    /// up with the byte offsets the chunk loop is counting.
    private static let downloadHeaders: [String: String] = [
        "User-Agent": InnertubeClientContext.androidVR.userAgent,
        "Accept": "*/*",
        "Accept-Language": "en-US,en;q=0.9",
        "Accept-Encoding": "identity",
    ]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false          // the user asked for this now, not "sometime"
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 60 * 60 * 12
        config.waitsForConnectivity = true
        // Same reason as the per-request policy: a media range must always come off the wire.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
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
        /// Consecutive refusals — drives the backoff and how far the chunk size is cut.
        var failures = 0
        /// Every refusal this part has ever seen. Never reset, because `failures` is: a part that
        /// alternates one good chunk with a handful of refusals would otherwise retry forever.
        var totalFailures = 0
        /// How many times progress has been thrown away to restart from byte zero.
        var restarts = 0
        /// Always true now. Verified against the live service, six trials on freshly extracted
        /// URLs: `Range: bytes=0-` is refused 403 every single time, while the same URL serves a
        /// closed `bytes=0-262143` immediately afterwards. Asking for the whole file in one
        /// request — the old optimistic path — could therefore never succeed; it only burned a
        /// retry and taught the loop to give up early.
        var chunked = true
        /// When this part last showed a sign of life. What tells a transfer that is slowly working
        /// through a big file from one that has quietly died.
        var lastActivity = Date()

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
        Log.fetch.notice("start [\(jobID)] \(part.rawValue) expect=\(expectedBytes) host=\(url.host() ?? "?") signedFor=\(Self.signedIP(of: url))")
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
        // A task that has already finished or been cancelled — which is what a force-quit leaves
        // behind — can still be listed for a moment. Counting those as live is what let a job sit
        // at "Downloading" forever: `resume` saw a healthy download and left it alone, and the
        // callback that followed had no transfer to attach to and went in the bin.
        let running = tasks
            .filter { $0.state == .running || $0.state == .suspended }
            .compactMap { Self.decode($0.taskDescription)?.jobID }
        // Transfers between chunks are live too, but only while they are actually moving.
        let now = Date()
        let waiting = lock.withLock {
            transfers.values
                .filter { now.timeIntervalSince($0.lastActivity) < Self.stallWindow }
                .map(\.jobID)
        }
        return Set(running).union(waiting)
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
        transfer.lastActivity = Date()
        var request = URLRequest(url: transfer.url)
        for (field, value) in Self.downloadHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let end = transfer.total > 0
            ? min(transfer.offset + transfer.chunkSize - 1, transfer.total - 1)
            : transfer.offset + transfer.chunkSize - 1
        request.setValue("bytes=\(transfer.offset)-\(end)", forHTTPHeaderField: "Range")

        // A ranged request must never be answered from the local cache. `NSURLCache` keys on the
        // URL alone and ignores the Range header, so without this every chunk after the first can
        // be handed back whatever response the first one left behind — including a refusal.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let task = session.downloadTask(with: request)
        task.taskDescription = Self.key(transfer.jobID, transfer.part)
        task.resume()
    }

    /// A chunk landed: append it, report progress, and either ask for the next one or finish.
    ///
    /// `wholeResource` means the server answered 200 rather than 206 — it ignored the Range header
    /// and sent the entire file. That body has to replace what is staged rather than be appended to
    /// it, or the part ends up with a prefix of itself stuck on the front.
    private func appendChunk(at location: URL, for transfer: Transfer, wholeResource: Bool) {
        let staged = Self.stagedURL(jobID: transfer.jobID, part: transfer.part)
        do {
            let data = try Data(contentsOf: location, options: .mappedIfSafe)

            if wholeResource, transfer.offset > 0 {
                try? FileManager.default.removeItem(at: staged)
                FileManager.default.createFile(atPath: staged.path, contents: nil)
                transfer.offset = 0
            }

            let handle = try FileHandle(forWritingTo: staged)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)

            transfer.offset += Int64(data.count)
            // Only a chunk that carried bytes counts as progress. An empty 206 would otherwise
            // clear the failure budget every time round and loop for good without ever finishing.
            if !data.isEmpty {
                transfer.failures = 0
                transfer.lastActivity = Date()
            }

            delegate?.fetcher(didProgress: transfer.jobID, part: transfer.part,
                              received: transfer.offset, total: transfer.total)

            // A 200 is the whole file by definition, so the part is done — and its real size is
            // whatever just landed, even when YouTube never declared one.
            if wholeResource {
                transfer.total = transfer.offset
                finish(transfer)
                return
            }

            if transfer.total > 0 {
                if transfer.offset >= transfer.total {
                    finish(transfer)
                } else if data.isEmpty {
                    // Nothing came back and the file isn't finished: spend failure budget rather
                    // than ask for the same range until the end of time.
                    retry(transfer, after: 204)
                } else {
                    requestNextChunk(for: transfer)
                }
                return
            }

            // Size still unknown: the only end-of-file signals left are an empty body and a range
            // that came back shorter than the one asked for. Without them the loop keeps asking
            // past the end, collects 416s forever, and neither finishes nor fails.
            let short = transfer.chunked && Int64(data.count) < transfer.chunkSize
            if data.isEmpty || short {
                transfer.total = transfer.offset
                finish(transfer)
            } else {
                requestNextChunk(for: transfer)
            }
        } catch {
            fail(transfer, error: error)
        }
    }

    private func finish(_ transfer: Transfer) {
        Log.fetch.notice("part complete [\(transfer.jobID)] \(transfer.part.rawValue) \(transfer.offset) bytes")
        lock.withLock { transfers[Self.key(transfer.jobID, transfer.part)] = nil }
        delegate?.fetcher(didFinish: transfer.jobID, part: transfer.part,
                          at: Self.stagedURL(jobID: transfer.jobID, part: transfer.part))
    }

    /// A refused chunk is usually a signed URL going stale, not a dead download. Back off, ask for
    /// a smaller bite, and periodically get a freshly extracted URL before trying the same offset.
    ///
    /// Every route out of here has to terminate. `failures` is cleared by every chunk that lands,
    /// so on its own it never runs out on a part that makes a little progress between refusals —
    /// `totalFailures` and `restarts` are the budgets that actually end things.
    private func retry(_ transfer: Transfer, after code: Int) {
        transfer.failures += 1
        transfer.totalFailures += 1
        Log.fetch.error("retry [\(transfer.jobID)] \(transfer.part.rawValue) code=\(code) at=\(transfer.offset)/\(transfer.total) fails=\(transfer.failures)/\(transfer.totalFailures) chunk=\(transfer.chunkSize)")

        guard transfer.failures <= Self.failureLimit,
              transfer.totalFailures <= Self.totalFailureLimit else {
            giveUp(transfer, code: code)
            return
        }
        // Ask for a smaller bite: a range YouTube refuses at 2MB it will often serve at 512KB.
        transfer.chunkSize = max(Self.minimumChunkSize, transfer.chunkSize / 2)

        // A fresh URL will often serve byte zero while refusing to resume mid-file, so once half
        // the retry budget is gone, throw away what we have and start the part again — but only
        // while there is restart budget left. Restarting without a cap is how a download can run
        // all day at full bandwidth and never end.
        let restarting = transfer.failures >= Self.failureLimit / 2 && transfer.offset > 0
        if restarting {
            guard transfer.restarts < Self.restartLimit else {
                giveUp(transfer, code: code)
                return
            }
            transfer.restarts += 1
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

            if restarting {
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

    /// The end of the line for a part: no budget left, so stop and let the queue surface it rather
    /// than keep pulling bytes nobody will ever see.
    private func giveUp(_ transfer: Transfer, code: Int) {
        Log.fetch.error("gave up [\(transfer.jobID)] \(transfer.part.rawValue) code=\(code) at=\(transfer.offset)/\(transfer.total) restarts=\(transfer.restarts)")
        lock.withLock { transfers[Self.key(transfer.jobID, transfer.part)] = nil }
        let got = ByteCountFormatter.string(fromByteCount: transfer.offset, countStyle: .file)
        // Only a plain refusal is worth waiting out and retrying automatically; a part that has
        // already been restarted to death is not going to come good on its own.
        let error: FetchError = transfer.restarts >= Self.restartLimit
            ? .gaveUp("YouTube kept cutting this download off — it never got past \(got).")
            : .refused(code)
        delegate?.fetcher(didFail: transfer.jobID, part: transfer.part, error: error)
    }

    private func fail(_ transfer: Transfer, error: Error) {
        lock.withLock { transfers[Self.key(transfer.jobID, transfer.part)] = nil }
        delegate?.fetcher(didFail: transfer.jobID, part: transfer.part, error: error)
    }

    // MARK: Task identity

    /// googlevideo signs every stream URL for the public IP that asked for it — `ip=` is listed in
    /// the URL's own `sparams`, so it can't be tampered with. If this value changes from one
    /// extraction to the next, the phone's public address is moving underneath us, and a URL minted
    /// a moment ago is already refused. That is the difference between a request that gets 206 and
    /// the identical one that gets 403.
    static func signedIP(of url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "ip" }?.value ?? "?"
    }

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

    /// Bytes arrived for a part nothing is tracking any more. The offset they belong to lived in
    /// memory, so there is no carrying on from here — tell the queue, and let it start the job over
    /// rather than leave it pinned at whatever percentage it had reached.
    private func reportLost(_ description: String?) {
        Log.fetch.error("orphaned callback for \(description ?? "nil")")
        guard let (jobID, part) = Self.decode(description) else { return }
        delegate?.fetcherLostTransfer(jobID: jobID, part: part)
    }
}

// MARK: - URLSessionDownloadDelegate

extension StreamFetcher: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // No report for an orphan here — the task's terminal callback is a moment away and that is
        // where a lost transfer gets handed back to the queue.
        guard let transfer = transfer(for: downloadTask.taskDescription) else { return }
        transfer.lastActivity = Date()
        // Progress within the current chunk, on top of everything already on disk.
        delegate?.fetcher(didProgress: transfer.jobID, part: transfer.part,
                          received: transfer.offset + totalBytesWritten, total: transfer.total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let transfer = transfer(for: downloadTask.taskDescription) else {
            reportLost(downloadTask.taskDescription)
            return
        }

        let response = downloadTask.response as? HTTPURLResponse
        let code = response?.statusCode ?? 0
        Log.fetch.debug("response [\(transfer.jobID)] \(transfer.part.rawValue) code=\(code) at=\(transfer.offset)/\(transfer.total)")

        // 416 means the range asked for starts past the end of the file — which is exactly what the
        // request after the last byte gets. That is the end of the part, not a refusal, and
        // treating it as one is what left downloads running forever.
        if code == 416 {
            if transfer.offset > 0, transfer.total <= 0 || transfer.offset >= transfer.total {
                transfer.total = transfer.offset
                finish(transfer)
            } else {
                retry(transfer, after: code)
            }
            return
        }

        guard (200..<300).contains(code) else {
            // The body of a refusal is an error page — never append it to the media file.
            retry(transfer, after: code)
            return
        }

        // Learn the real size from the first Content-Range; YouTube's declared length can be absent.
        if transfer.total <= 0,
           let contentRange = response?.value(forHTTPHeaderField: "Content-Range"),
           let totalPart = contentRange.split(separator: "/").last,
           let parsed = Int64(totalPart) {
            transfer.total = parsed
        }

        // 206 is a range; any other 2xx is the server ignoring Range and handing back the lot.
        appendChunk(at: location, for: transfer, wholeResource: code != 206)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }         // success came through didFinishDownloadingTo
        guard let transfer = transfer(for: task.taskDescription) else {
            // A cancel we asked for needs no attention. Anything else reaching a transfer that no
            // longer exists means the chunk loop is gone and the job has to be started again.
            if (error as NSError).code != NSURLErrorCancelled {
                reportLost(task.taskDescription)
            }
            return
        }
        // Cancellation is a user action, not a failure — the manager already knows.
        if (error as NSError).code == NSURLErrorCancelled { return }
        retry(transfer, after: (error as NSError).code)
    }

    /// Records where each response actually came from. `.localCache` here would mean the chunk
    /// loop is being answered by `NSURLCache` rather than by googlevideo — worth knowing, because
    /// a cached refusal looks exactly like a real one from the outside.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last,
              let (jobID, part) = Self.decode(task.taskDescription) else { return }
        let code = (last.response as? HTTPURLResponse)?.statusCode ?? -1
        let source = last.resourceFetchType == .localCache ? "CACHE" : "net"
        Log.fetch.debug(
            "conn [\(jobID)] \(part.rawValue) code=\(code) \(source) "
            + "cellular=\(last.isCellular) proxy=\(last.isProxyConnection) reused=\(last.isReusedConnection) "
            + "local=\(last.localAddress ?? "?") remote=\(last.remoteAddress ?? "?") "
            + "proto=\(last.networkProtocolName ?? "?")"
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
