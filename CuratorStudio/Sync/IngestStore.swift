import Foundation
import Combine
import UIKit

enum MacConnection: Equatable {
    case notConfigured
    case searching
    case offline(String)
    case online(String)

    var isOnline: Bool { if case .online = self { return true }; return false }

    var label: String {
        switch self {
        case .notConfigured: return "Not connected"
        case .searching: return "Looking for your Mac…"
        case .offline(let reason): return reason
        case .online(let name): return name
        }
    }

    var symbol: String {
        switch self {
        case .notConfigured: return "desktopcomputer.trianglebadge.exclamationmark"
        case .searching: return "antenna.radiowaves.left.and.right"
        case .offline: return "wifi.slash"
        case .online: return "checkmark.circle.fill"
        }
    }
}

struct TransferProgress: Equatable {
    var fraction: Double
    var received: Int64
    var total: Int64
}

/// Owns the connection to the Mac daemon: pairing, polling the job queue,
/// submitting new links, and pulling finished files into the library folder.
@MainActor
final class IngestStore: ObservableObject {

    @Published private(set) var connection: MacConnection = .notConfigured
    @Published private(set) var jobs: [RemoteJob] = []
    @Published private(set) var shelf: [ShelfItem] = []
    @Published private(set) var macFolders: [String] = []
    @Published private(set) var transfers: [String: TransferProgress] = [:]
    @Published private(set) var recentlyImported: [String] = []
    @Published var lastMessage: String?

    @Published var host: MacHost? {
        didSet { persist() }
    }
    @Published var token: String = "" {
        didSet { persist() }
    }
    @Published var autoPull: Bool = true {
        didSet { UserDefaults.standard.set(autoPull, forKey: Keys.autoPull) }
    }
    /// Queued links entered while the Mac was unreachable.
    @Published private(set) var pendingRequests: [PendingRequest] = []

    struct PendingRequest: Codable, Identifiable, Hashable {
        var id: UUID = UUID()
        var url: String
        var quality: DownloadQuality
        var folder: String
        var created: Date = Date()
    }

    private enum Keys {
        static let host = "ingest.host"
        static let token = "ingest.token"
        static let autoPull = "ingest.autoPull"
        static let pending = "ingest.pending"
    }

    private weak var library: LibraryStore?
    private var pollTask: Task<Void, Never>?
    private var activeDownloads: [String: FileDownloader] = [:]

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.host),
           let decoded = try? JSONDecoder().decode(MacHost.self, from: data) {
            host = decoded
        }
        token = defaults.string(forKey: Keys.token) ?? ""
        autoPull = defaults.object(forKey: Keys.autoPull) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.pending),
           let decoded = try? JSONDecoder().decode([PendingRequest].self, from: data) {
            pendingRequests = decoded
        }
        if host != nil && !token.isEmpty {
            connection = .offline("Not checked yet")
        }
    }

    func attach(library: LibraryStore) {
        self.library = library
    }

    private var link: MacLink? {
        guard let host, !token.isEmpty else { return nil }
        return MacLink(host: host, token: token)
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let host, let data = try? JSONEncoder().encode(host) {
            defaults.set(data, forKey: Keys.host)
        } else {
            defaults.removeObject(forKey: Keys.host)
        }
        defaults.set(token, forKey: Keys.token)
    }

    private func persistPending() {
        if let data = try? JSONEncoder().encode(pendingRequests) {
            UserDefaults.standard.set(data, forKey: Keys.pending)
        }
    }

    // MARK: Pairing

    func pair(host: MacHost, token: String) async {
        self.host = host
        self.token = token
        await refresh()
    }

    func disconnect() {
        stopPolling()
        host = nil
        token = ""
        jobs = []
        shelf = []
        connection = .notConfigured
    }

    // MARK: Polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 3_500_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard let link else {
            connection = .notConfigured
            return
        }
        do {
            let health = try await link.health()
            connection = .online(health.name)
            jobs = try await link.jobs().sorted { $0.created > $1.created }
            macFolders = (try? await link.folders()) ?? macFolders
            await flushPending()
            if autoPull { await pullAllReady() }
        } catch {
            connection = .offline(friendly(error))
        }
    }

    func refreshShelf() async {
        guard let link else { return }
        shelf = (try? await link.shelf()) ?? []
    }

    private func friendly(_ error: Error) -> String {
        if let macError = error as? MacLinkError { return macError.localizedDescription }
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
            return "Mac not reachable — is it awake and on this Wi-Fi?"
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "No local network right now."
        default:
            return ns.localizedDescription
        }
    }

    // MARK: Submitting links

    func submit(url: String, quality: DownloadQuality, folder: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let link, connection.isOnline else {
            pendingRequests.append(PendingRequest(url: trimmed, quality: quality, folder: folder))
            persistPending()
            lastMessage = "Saved — it'll go to the Mac the moment you're back on your Wi-Fi."
            return
        }

        do {
            let created = try await link.submit(url: trimmed, quality: quality, folder: folder)
            lastMessage = created.count > 1
                ? "Queued \(created.count) videos on your Mac."
                : "Queued on your Mac → \(folder.isEmpty ? "library root" : folder)"
            await refresh()
        } catch {
            pendingRequests.append(PendingRequest(url: trimmed, quality: quality, folder: folder))
            persistPending()
            lastMessage = "Couldn't reach the Mac — saved for later. (\(friendly(error)))"
        }
    }

    private func flushPending() async {
        guard let link, !pendingRequests.isEmpty else { return }
        var remaining: [PendingRequest] = []
        for request in pendingRequests {
            do {
                _ = try await link.submit(url: request.url, quality: request.quality,
                                          folder: request.folder)
            } catch {
                remaining.append(request)
            }
        }
        if remaining.count != pendingRequests.count {
            lastMessage = "Sent \(pendingRequests.count - remaining.count) saved link(s) to the Mac."
        }
        pendingRequests = remaining
        persistPending()
    }

    func removePending(_ id: UUID) {
        pendingRequests.removeAll { $0.id == id }
        persistPending()
    }

    // MARK: Job actions

    func retry(_ job: RemoteJob) async {
        try? await link?.retry(jobID: job.id)
        await refresh()
    }

    func delete(_ job: RemoteJob) async {
        try? await link?.delete(jobID: job.id)
        await refresh()
    }

    // MARK: Pulling files

    func pullAllReady() async {
        let ready = jobs.filter { $0.isReady && transfers[$0.id] == nil }
        for job in ready {
            await pull(job)
        }
    }

    func pull(_ job: RemoteJob) async {
        guard let link, let library, library.hasRoot else { return }
        guard transfers[job.id] == nil else { return }
        guard let request = try? link.fileRequest(jobID: job.id) else { return }

        let downloader = FileDownloader()
        activeDownloads[job.id] = downloader
        transfers[job.id] = TransferProgress(fraction: 0, received: 0, total: job.size)

        do {
            let temporaryURL = try await downloader.download(request) { [weak self] fraction, received, total in
                Task { @MainActor in
                    self?.transfers[job.id] = TransferProgress(
                        fraction: fraction, received: received,
                        total: total > 0 ? total : job.size
                    )
                }
            }

            let folder = job.folder ?? ""
            let filename = job.filename
                ?? (job.file.map { ($0 as NSString).lastPathComponent })
                ?? "\(job.displayTitle).mp4"

            let relative = try library.adoptFile(at: temporaryURL, folder: folder, filename: filename)
            recentlyImported.insert(relative, at: 0)
            recentlyImported = Array(recentlyImported.prefix(20))

            await link.acknowledge(jobID: job.id)
            await library.rescan()
            lastMessage = "Added “\(job.displayTitle)” to \(folder.isEmpty ? "your library" : folder)."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            lastMessage = "Transfer failed: \(friendly(error))"
        }

        transfers[job.id] = nil
        activeDownloads[job.id] = nil
    }

    func cancelTransfer(_ jobID: String) {
        activeDownloads[jobID]?.cancel()
        activeDownloads[jobID] = nil
        transfers[jobID] = nil
    }

    /// Pulls an arbitrary file the Mac already has, chosen from the shelf.
    func pullShelfItem(_ item: ShelfItem, into folder: String) async {
        guard let link, let library, library.hasRoot else { return }
        guard let request = try? link.shelfRequest(path: item.path) else { return }

        let key = "shelf:" + item.path
        guard transfers[key] == nil else { return }

        let downloader = FileDownloader()
        activeDownloads[key] = downloader
        transfers[key] = TransferProgress(fraction: 0, received: 0, total: item.size)

        do {
            let temporaryURL = try await downloader.download(request) { [weak self] fraction, received, total in
                Task { @MainActor in
                    self?.transfers[key] = TransferProgress(
                        fraction: fraction, received: received,
                        total: total > 0 ? total : item.size
                    )
                }
            }
            let destination = folder.isEmpty ? item.folder : folder
            _ = try library.adoptFile(at: temporaryURL, folder: destination, filename: item.name)
            await library.rescan()
            await link.deleteShelfItem(path: item.path)
            shelf.removeAll { $0.path == item.path }
            lastMessage = "Copied “\(item.name)” across — removed from your Mac."
        } catch {
            lastMessage = "Transfer failed: \(friendly(error))"
        }

        transfers[key] = nil
        activeDownloads[key] = nil
    }

    // MARK: Convenience

    var activeJobs: [RemoteJob] { jobs.filter { $0.isActive } }
    var readyJobs: [RemoteJob] { jobs.filter { $0.isReady } }
    var failedJobs: [RemoteJob] { jobs.filter { $0.isFailed } }
    var historyJobs: [RemoteJob] { jobs.filter { $0.status == "delivered" } }

    var badgeCount: Int { activeJobs.count + readyJobs.count + pendingRequests.count }
}
