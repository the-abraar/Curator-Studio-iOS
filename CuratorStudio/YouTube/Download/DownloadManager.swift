import Foundation
import Combine
import UIKit

/// The queue. Everything the Mac daemon used to do — take a link, pick a format, download it,
/// merge, strip sponsors, tag it and file it in the right folder — happens here, on the phone.
///
/// Jobs are persisted, so killing the app mid-download loses nothing: transfers keep running in a
/// background `URLSession`, and whatever was interrupted is picked up again on the next launch.
@MainActor
final class DownloadManager: ObservableObject {

    @Published private(set) var jobs: [DownloadJob] = []
    @Published var lastMessage: String?
    @Published private(set) var recentlyImported: [String] = []

    // MARK: Settings (the old config.json, now on the phone)

    @Published var defaultQuality: DownloadQuality {
        didSet { defaults.set(defaultQuality.rawValue, forKey: Keys.quality) }
    }
    @Published var defaultFolder: String {
        didSet { defaults.set(defaultFolder, forKey: Keys.folder) }
    }
    @Published var sponsorBlockEnabled: Bool {
        didSet { defaults.set(sponsorBlockEnabled, forKey: Keys.sponsorBlock) }
    }
    @Published var sponsorBlockCategories: [String] {
        didSet { defaults.set(sponsorBlockCategories, forKey: Keys.sponsorCategories) }
    }
    @Published var embedMetadata: Bool {
        didSet { defaults.set(embedMetadata, forKey: Keys.metadata) }
    }
    @Published var writeSidecar: Bool {
        didSet { defaults.set(writeSidecar, forKey: Keys.sidecar) }
    }
    @Published var maxConcurrent: Int {
        didSet {
            defaults.set(maxConcurrent, forKey: Keys.concurrency)
            pump()
        }
    }

    private enum Keys {
        static let quality = "download.quality"
        static let folder = "download.folder"
        static let sponsorBlock = "download.sponsorblock"
        static let sponsorCategories = "download.sponsorblock.categories"
        static let metadata = "download.metadata"
        static let sidecar = "download.sidecar"
        static let concurrency = "download.concurrency"
    }

    private let defaults = UserDefaults.standard
    private weak var library: LibraryStore?
    private let youtube = YouTubeService.shared
    private let fetcher = StreamFetcher.shared

    /// Details fetched while resolving, kept for the sidecar and for tagging.
    private var resolvedDetails: [String: VideoDetails] = [:]
    /// Progress is written to disk now and then, so a job picked up by a fresh launch shows what
    /// it actually reached rather than whatever it was at when a stage last changed.
    private var lastProgressSave = Date.distantPast
    private var sponsorSegments: [String: [SponsorSegment]] = [:]
    private var assembling: Set<String> = []

    private static let stateURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CuratorStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }()

    init() {
        defaultQuality = DownloadQuality(rawValue: defaults.string(forKey: Keys.quality) ?? "") ?? .mid
        defaultFolder = defaults.string(forKey: Keys.folder) ?? "Randoms"
        sponsorBlockEnabled = defaults.object(forKey: Keys.sponsorBlock) as? Bool ?? true
        sponsorBlockCategories = defaults.stringArray(forKey: Keys.sponsorCategories)
            ?? ["sponsor", "selfpromo", "interaction"]
        embedMetadata = defaults.object(forKey: Keys.metadata) as? Bool ?? true
        writeSidecar = defaults.object(forKey: Keys.sidecar) as? Bool ?? true
        maxConcurrent = defaults.object(forKey: Keys.concurrency) as? Int ?? 2

        if let data = try? Data(contentsOf: Self.stateURL),
           let decoded = try? JSONDecoder().decode([DownloadJob].self, from: data) {
            jobs = decoded
        }
        fetcher.delegate = self
    }

    func attach(library: LibraryStore) {
        self.library = library
    }

    // MARK: Launch reconciliation

    /// Re-attaches to whatever the background session is still carrying, finishes anything that
    /// completed while the app was dead, and requeues the rest.
    func resume() async {
        fetcher.reconnect()
        let live = await fetcher.liveJobIDs()
        Log.downloads.notice("resume: \(self.jobs.count) jobs, \(self.activeJobs.count) active, live=\(live.count)")

        for jobID in jobs.map(\.id) {
            guard let index = jobIndex(of: jobID) else { continue }
            let job = jobs[index]
            guard job.stage.isActive else { continue }

            switch job.stage {
            case .downloading where live.contains(job.id):
                continue                                  // still going, nothing to do
            case .downloading, .assembling, .importing:
                // Staged parts survive until the finished file is safely in the library, so a merge
                // the app was killed in the middle of carries on from what is on disk instead of
                // pulling the whole video down a second time. A part only counts as done if the
                // fetcher said so before we were killed *and* the file is still there — anything
                // else may be half a run of chunks, so it starts over.
                if job.hasAllParts, Self.stagedPartsExist(for: job) {
                    Task { await self.resumeAssembly(jobID: job.id) }
                } else {
                    StreamFetcher.clearStaging(jobID: job.id)
                    jobs[index].stagedFiles = [:]
                    jobs[index].partProgress = [:]
                    jobs[index].receivedBytes = 0
                    jobs[index].stage = .queued            // start the interrupted parts over
                }
            case .resolving:
                jobs[index].stage = .queued
            default:
                break
            }
        }
        save()
        pump()
    }

    private static func stagedPartsExist(for job: DownloadJob) -> Bool {
        !job.expectedParts.isEmpty && job.expectedParts.allSatisfy {
            FileManager.default.fileExists(atPath: StreamFetcher.stagedURL(jobID: job.id, part: $0).path)
        }
    }

    /// Picks a job back up at the merge, re-fetching the context that only ever lived in memory:
    /// the sponsor segments to cut and the details that go into the tags and the sidecar. Both are
    /// best effort — neither is worth re-downloading a few hundred megabytes for.
    private func resumeAssembly(jobID: String) async {
        guard let index = jobIndex(of: jobID) else { return }
        let job = jobs[index]

        if sponsorBlockEnabled, sponsorSegments[job.id] == nil {
            sponsorSegments[job.id] = await SponsorBlock.segments(
                for: job.videoId, categories: sponsorBlockCategories
            )
        }
        if resolvedDetails[job.videoId] == nil {
            resolvedDetails[job.videoId] = try? await youtube.streamDetails(
                videoId: job.videoId, includeRelated: false
            )
        }
        await finish(jobID: jobID)
    }

    // MARK: Enqueuing

    @discardableResult
    func enqueue(video: StreamInfoItem, quality: DownloadQuality? = nil, folder: String? = nil) -> DownloadJob {
        let job = DownloadJob(
            video: video,
            quality: quality ?? defaultQuality,
            folder: folder ?? defaultFolder
        )
        add(job)
        return job
    }

    @discardableResult
    func enqueue(details: VideoDetails, quality: DownloadQuality? = nil, folder: String? = nil) -> DownloadJob {
        let job = DownloadJob(
            details: details,
            quality: quality ?? defaultQuality,
            folder: folder ?? defaultFolder
        )
        resolvedDetails[job.videoId] = details
        add(job)
        return job
    }

    func enqueue(videos: [StreamInfoItem], quality: DownloadQuality? = nil, folder: String) {
        for video in videos {
            let job = DownloadJob(video: video, quality: quality ?? defaultQuality, folder: folder)
            add(job, pumpAfter: false)
        }
        lastMessage = "Queued \(videos.count) videos → \(folder.isEmpty ? "library root" : folder)."
        pump()
    }

    /// Takes anything pasted or shared in: a video, a playlist, or a channel link.
    func enqueue(link raw: String, quality: DownloadQuality? = nil, folder: String? = nil) async {
        guard let parsed = YouTubeService.parse(link: raw) else {
            lastMessage = "That doesn't look like a YouTube link."
            return
        }
        let destination = folder ?? defaultFolder

        switch parsed {
        case .video(let id):
            do {
                let details = try await youtube.streamDetails(videoId: id, includeRelated: false)
                enqueue(details: details, quality: quality, folder: destination)
                lastMessage = "Queued “\(details.title)” → \(destination.isEmpty ? "library root" : destination)."
            } catch {
                lastMessage = "Couldn't read that video: \(error.localizedDescription)"
            }

        case .playlist(let id):
            do {
                let playlist = try await youtube.playlist(id: id)
                let videos = try await youtube.allPlaylistVideos(in: playlist)
                guard !videos.isEmpty else {
                    lastMessage = "That playlist came back empty."
                    return
                }
                enqueue(videos: videos, quality: quality, folder: destination)
            } catch {
                lastMessage = "Couldn't open that playlist: \(error.localizedDescription)"
            }

        case .channel:
            lastMessage = "That's a channel link — open it to pick videos, or subscribe to follow it."
        }
    }

    private func add(_ job: DownloadJob, pumpAfter: Bool = true) {
        Log.downloads.notice("enqueued \(job.title) [\(job.id)] \(job.quality.rawValue) → \(job.folder)")
        jobs.insert(job, at: 0)
        save()
        if pumpAfter { pump() }
    }

    // MARK: Job control

    func retry(_ job: DownloadJob) {
        guard let index = jobIndex(of: job.id) else { return }
        StreamFetcher.clearStaging(jobID: job.id)
        jobs[index].stage = .queued
        jobs[index].errorMessage = nil
        jobs[index].receivedBytes = 0
        jobs[index].partProgress = [:]
        jobs[index].stagedFiles = [:]
        jobs[index].expectedParts = []
        save()
        pump()
    }

    func cancel(_ job: DownloadJob) {
        guard let index = jobIndex(of: job.id) else { return }
        fetcher.cancel(jobID: job.id)
        StreamFetcher.clearStaging(jobID: job.id)
        jobs[index].stage = .cancelled
        save()
        pump()
    }

    func remove(_ job: DownloadJob) {
        fetcher.cancel(jobID: job.id)
        StreamFetcher.clearStaging(jobID: job.id)
        jobs.removeAll { $0.id == job.id }
        save()
        pump()
    }

    func clearFinished() {
        jobs.removeAll { $0.stage == .done || $0.stage == .cancelled }
        save()
    }

    // MARK: Queue

    var activeJobs: [DownloadJob] { jobs.filter { $0.stage.isActive } }
    var failedJobs: [DownloadJob] { jobs.filter { $0.stage == .failed } }
    var finishedJobs: [DownloadJob] { jobs.filter { $0.stage == .done } }
    var badgeCount: Int { activeJobs.count }

    /// Starts as many queued jobs as the concurrency limit allows.
    private func pump() {
        let running = jobs.filter { $0.stage == .resolving || $0.stage == .downloading || $0.stage == .assembling }
        var slots = max(0, maxConcurrent - running.count)
        guard slots > 0 else { return }

        for job in jobs.reversed() where job.stage == .queued {   // oldest first
            guard slots > 0 else { break }
            slots -= 1
            Task { await start(jobID: job.id) }
        }
    }

    /// Resolves stream URLs and kicks off the transfers.
    private func start(jobID: String) async {
        guard let index = jobIndex(of: jobID) else { return }
        // Check this now rather than after spending a few hundred megabytes of someone's data.
        guard library?.hasRoot == true else {
            fail(jobID: jobID, message: "Pick your media folder first — there's nowhere to put it.")
            return
        }
        jobs[index].stage = .resolving
        jobs[index].errorMessage = nil
        save()
        Log.downloads.notice("resolving \(self.jobs[index].videoId) [\(jobID)]")

        let job = jobs[index]

        do {
            let details: VideoDetails
            if let cached = resolvedDetails[job.videoId], !cached.formats.isEmpty {
                details = cached
            } else {
                details = try await youtube.streamDetails(videoId: job.videoId, includeRelated: false)
                resolvedDetails[job.videoId] = details
            }

            let selection = try FormatSelector.select(quality: job.quality, from: details.formats)

            if sponsorBlockEnabled {
                sponsorSegments[job.id] = await SponsorBlock.segments(
                    for: job.videoId, categories: sponsorBlockCategories
                )
            }

            guard let liveIndex = jobIndex(of: jobID), jobs[liveIndex].stage == .resolving else { return }

            let parts = Self.parts(of: selection)

            jobs[liveIndex].expectedParts = parts.map(\.role)
            jobs[liveIndex].partTotals = Dictionary(
                uniqueKeysWithValues: parts.map { ($0.role, $0.format.contentLength ?? 0) }
            )
            jobs[liveIndex].totalBytes = selection.expectedBytes
            jobs[liveIndex].title = jobs[liveIndex].title.isEmpty ? details.title : jobs[liveIndex].title
            if jobs[liveIndex].channelName.isEmpty {
                // Playlist rows carry no byline; the player response always does.
                jobs[liveIndex].channelName = details.channelName
                jobs[liveIndex].channelId = jobs[liveIndex].channelId ?? details.channelId
            }
            jobs[liveIndex].durationSeconds = details.lengthSeconds
            jobs[liveIndex].stage = .downloading
            save()
            Log.downloads.notice("downloading [\(jobID)] parts=\(parts.map { "\($0.role.rawValue):itag\($0.format.itag):\($0.format.contentLength ?? -1)" }.joined(separator: ",")) total=\(selection.expectedBytes)")

            for part in parts {
                fetcher.start(
                    jobID: jobID, part: part.role, url: part.format.url,
                    expectedBytes: part.format.contentLength ?? 0
                )
            }
        } catch {
            fail(jobID: jobID, message: error.localizedDescription)
        }
    }

    /// Which file goes in which slot. An audio-only download and a muxed fallback both produce a
    /// single part, so the roles are derived from the container rather than assumed.
    private static func parts(of selection: FormatSelector.Selection)
        -> [(role: DownloadJob.Part, format: StreamFormat)] {
        var parts: [(role: DownloadJob.Part, format: StreamFormat)] = []
        if let video = selection.video {
            parts.append((video.container == "m4a" ? .audio : .video, video))
        }
        if let audio = selection.audio {
            parts.append((audio.container == "m4a" ? .audio : .video, audio))
        }
        // A muxed fallback can land in either slot; make sure the two roles differ.
        if parts.count == 2, parts[0].role == parts[1].role {
            parts[0].role = .video
            parts[1].role = .audio
        }
        return parts
    }

    // MARK: Assembling and importing

    private func finish(jobID: String) async {
        guard let index = jobIndex(of: jobID) else { return }
        guard !assembling.contains(jobID) else { return }
        assembling.insert(jobID)
        defer { assembling.remove(jobID) }

        var job = jobs[index]
        job.stage = .assembling
        jobs[index] = job
        save()
        Log.downloads.notice("assembling [\(jobID)] parts=\(job.expectedParts.map(\.rawValue).joined(separator: ",")) audioOnly=\(job.quality.isAudioOnly)")

        let files = job.expectedParts.map { StreamFetcher.stagedURL(jobID: job.id, part: $0) }
        let details = resolvedDetails[job.videoId]
        let segments = sponsorSegments[job.id] ?? []
        let audioOnly = job.quality.isAudioOnly

        let artwork = embedMetadata ? await MediaAssembler.artworkData(from: job.thumbnailURL) : nil
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(job.id).\(audioOnly ? "m4a" : "mp4")")

        do {
            let output = try await MediaAssembler.assemble(
                files: files,
                audioOnly: audioOnly,
                segments: segments,
                title: job.title,
                channel: job.channelName,
                description: embedMetadata ? details?.description : nil,
                artwork: artwork,
                outputURL: outputURL
            ) { [weak self] fraction in
                Task { @MainActor in self?.reportAssembly(jobID: jobID, fraction: fraction) }
            }

            guard let library, library.hasRoot else {
                fail(jobID: jobID, message: "Pick your media folder first — there's nowhere to put it.")
                return
            }

            guard let importIndex = jobIndex(of: jobID) else {
                Log.downloads.error("job vanished before import [\(jobID)]")
                return
            }
            jobs[importIndex].stage = .importing
            save()

            let filename = job.filename(extension: audioOnly ? "m4a" : "mp4")
            Log.downloads.notice("importing [\(jobID)] \(filename) → \(job.folder)")
            let relative = try library.adoptFile(at: output.url, folder: job.folder, filename: filename)
            Log.downloads.notice("imported [\(jobID)] at \(relative)")

            if writeSidecar {
                writeSidecarFile(for: job, relativePath: relative, details: details, segments: segments)
            }

            StreamFetcher.clearStaging(jobID: job.id)
            resolvedDetails[job.videoId] = nil
            sponsorSegments[job.id] = nil

            guard let doneIndex = jobIndex(of: jobID) else { return }
            jobs[doneIndex].stage = .done
            jobs[doneIndex].relativePath = relative
            jobs[doneIndex].trimmedSeconds = output.trimmedSeconds
            jobs[doneIndex].receivedBytes = jobs[doneIndex].totalBytes
            save()

            recentlyImported.insert(relative, at: 0)
            recentlyImported = Array(recentlyImported.prefix(20))
            await library.rescan()
            Log.downloads.notice("done [\(jobID)] library now has \(library.allItems.count) items")

            let where_ = job.folder.isEmpty ? "your library" : job.folder
            lastMessage = output.trimmedSeconds > 1
                ? "Added “\(job.title)” to \(where_) — \(Int(output.trimmedSeconds))s of sponsor cut out."
                : "Added “\(job.title)” to \(where_)."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            fail(jobID: jobID, message: error.localizedDescription)
        }

        pump()
    }

    private func reportAssembly(jobID: String, fraction: Double) {
        guard let index = jobIndex(of: jobID), jobs[index].stage == .assembling else { return }
        // Assembly progress rides the same bar as the download, in its last sliver.
        let total = max(jobs[index].totalBytes, 1)
        jobs[index].receivedBytes = Int64(Double(total) * min(1, 0.9 + fraction * 0.1))
    }

    private func writeSidecarFile(
        for job: DownloadJob, relativePath: String, details: VideoDetails?, segments: [SponsorSegment]
    ) {
        guard let library, let fileURL = library.url(forRelativePath: relativePath) else { return }
        let sidecarURL = fileURL.deletingPathExtension().appendingPathExtension("curator.json")
        let sidecar = DownloadSidecar(job: job, details: details, segments: segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sidecar) {
            try? data.write(to: sidecarURL, options: .atomic)
        }
    }

    /// Maximum number of unattended retries after a refusal, and how long to wait between them.
    private static let autoRetryLimit = 3
    private static let autoRetryDelay: TimeInterval = 10 * 60

    private func fail(jobID: String, message: String, retryable: Bool = false) {
        Log.downloads.error("failed [\(jobID)] retryable=\(retryable) \(message)")
        guard let index = jobIndex(of: jobID) else { return }
        // The other half of an adaptive pair is usually still in flight. Left running it appends
        // into staging that is about to be deleted, and then fights with the retry that follows.
        fetcher.cancel(jobID: jobID)
        StreamFetcher.clearStaging(jobID: jobID)
        jobs[index].stagedFiles = [:]
        jobs[index].partProgress = [:]
        jobs[index].receivedBytes = 0

        // A refusal is usually YouTube deciding this address has asked too often, and it passes on
        // its own. Rather than making someone come back and tap Retry, wait it out and try again.
        if retryable, jobs[index].autoRetries < Self.autoRetryLimit {
            jobs[index].autoRetries += 1
            jobs[index].stage = .failed
            jobs[index].errorMessage = "\(message) Trying again in \(Int(Self.autoRetryDelay / 60)) minutes."
            save()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.autoRetryDelay * 1_000_000_000))
                guard let self, let index = self.jobIndex(of: jobID),
                      self.jobs[index].stage == .failed else { return }
                self.retry(self.jobs[index])
            }
        } else {
            jobs[index].stage = .failed
            jobs[index].errorMessage = message
            save()
        }
        pump()
    }

    // MARK: Storage

    private func jobIndex(of jobID: String) -> Int? {
        jobs.firstIndex { $0.id == jobID }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }
}

// MARK: - Transfer callbacks

extension DownloadManager: StreamFetcherDelegate {

    nonisolated func fetcher(didProgress jobID: String, part: DownloadJob.Part,
                             received: Int64, total: Int64) {
        Task { @MainActor in
            guard let index = self.jobIndex(of: jobID) else { return }
            var job = self.jobs[index]
            job.partProgress[part] = received
            if total > 0 { job.partTotals[part] = total }
            job.receivedBytes = job.partProgress.values.reduce(0, +)
            let known = job.partTotals.values.reduce(0, +)
            if known > job.totalBytes { job.totalBytes = known }
            self.jobs[index] = job

            if Date().timeIntervalSince(self.lastProgressSave) > 5 {
                self.lastProgressSave = Date()
                self.save()
            }
        }
    }

    nonisolated func fetcher(didFinish jobID: String, part: DownloadJob.Part, at url: URL) {
        Task { @MainActor in
            guard let index = self.jobIndex(of: jobID) else { return }
            Log.downloads.notice("part finished [\(jobID)] \(part.rawValue)")
            self.jobs[index].stagedFiles[part] = url.lastPathComponent
            self.save()
            if self.jobs[index].hasAllParts {
                await self.finish(jobID: jobID)
            }
        }
    }

    /// The app was replaced while this part was downloading, so the chunk loop that knew where it
    /// had got to is gone. Nothing can be resumed from here — but leaving the job alone is what
    /// stranded it at "Downloading" with no error and no file, so put it back in the queue.
    nonisolated func fetcherLostTransfer(jobID: String, part: DownloadJob.Part) {
        Log.downloads.error("lost transfer [\(jobID)] \(part.rawValue) — requeueing")
        Task { @MainActor in
            guard let index = self.jobIndex(of: jobID),
                  self.jobs[index].stage == .downloading else { return }
            self.fetcher.cancel(jobID: jobID)
            StreamFetcher.clearStaging(jobID: jobID)
            self.jobs[index].stagedFiles = [:]
            self.jobs[index].partProgress = [:]
            self.jobs[index].receivedBytes = 0
            self.jobs[index].stage = .queued
            self.save()
            self.pump()
        }
    }

    nonisolated func fetcher(didFail jobID: String, part: DownloadJob.Part, error: Error) {
        let refused: Bool
        if case FetchError.refused = error { refused = true } else { refused = false }
        Task { @MainActor in
            self.fail(jobID: jobID, message: Self.friendly(error), retryable: refused)
        }
    }

    /// Signed stream URLs go stale mid-download. Re-extract and hand back the URL for the same
    /// format so the transfer can carry on from where it stopped.
    nonisolated func fetcherNeedsFreshURL(jobID: String, part: DownloadJob.Part) async -> URL? {
        guard let (videoId, quality) = await MainActor.run(body: { () -> (String, DownloadQuality)? in
            guard let index = self.jobIndex(of: jobID) else { return nil }
            return (self.jobs[index].videoId, self.jobs[index].quality)
        }) else { return nil }

        guard let details = try? await YouTubeService.shared
                .streamDetails(videoId: videoId, includeRelated: false),
              let selection = try? FormatSelector.select(quality: quality, from: details.formats)
        else { return nil }

        await MainActor.run { self.resolvedDetails[videoId] = details }
        let fresh = await MainActor.run { DownloadManager.parts(of: selection) }
            .first { $0.role == part }?.format.url
        if let fresh {
            Log.downloads.notice("fresh URL [\(jobID)] \(part.rawValue) signedFor=\(StreamFetcher.signedIP(of: fresh))")
        }
        return fresh
    }

    private static func friendly(_ error: Error) -> String {
        if case FetchError.refused = error {
            return "YouTube wouldn't hand over the file — it does this when it thinks a connection is asking too often."
        }
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "No internet connection."
        case NSURLErrorTimedOut: return "YouTube stopped responding — try again."
        case NSURLErrorCancelled: return "Cancelled."
        default: return error.localizedDescription
        }
    }
}

extension DownloadJob {
    var hasAllParts: Bool {
        !expectedParts.isEmpty && expectedParts.allSatisfy { stagedFiles[$0] != nil }
    }
}
