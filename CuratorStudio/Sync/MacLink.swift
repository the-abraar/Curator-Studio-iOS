import Foundation

// MARK: - Models

struct MacHost: Codable, Hashable, Identifiable {
    var name: String
    var host: String
    var port: Int

    var id: String { "\(host):\(port)" }
    var baseURL: URL? { URL(string: "http://\(host):\(port)") }
    var display: String { "\(name) · \(host):\(port)" }
}

struct MacHealth: Decodable {
    let service: String
    let api: Int
    let name: String
    let libraryRoot: String
    let queued: Int
    let ready: Int

    enum CodingKeys: String, CodingKey {
        case service, api, name, queued, ready
        case libraryRoot = "library_root"
    }
}

struct RemoteJob: Decodable, Identifiable, Hashable {
    let id: String
    let url: String
    var quality: String
    var folder: String?
    var title: String?
    var status: String
    var progress: Double
    var stage: String?
    var speed: String?
    var eta: String?
    var error: String?
    var file: String?
    var filename: String?
    var size: Int64
    var source: String?
    var created: Double
    var delivered: Bool?

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return url
    }

    var isActive: Bool {
        status == "queued" || status == "downloading" || status == "processing"
    }

    var isReady: Bool { status == "ready" && delivered != true }
    var isFailed: Bool { status == "failed" }

    var symbol: String {
        switch status {
        case "queued": return "clock"
        case "downloading": return "arrow.down.circle"
        case "processing": return "gearshape.2"
        case "ready": return "tray.and.arrow.down"
        case "delivered": return "iphone"
        case "failed": return "exclamationmark.triangle"
        default: return "circle"
        }
    }
}

struct ShelfItem: Decodable, Identifiable, Hashable {
    let path: String
    let name: String
    let size: Int64
    let modified: Double

    var id: String { path }
    var folder: String {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
    }
}

enum DownloadQuality: String, CaseIterable, Identifiable, Codable {
    case best, high, mid, low, audio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .best: return "Best"
        case .high: return "1080p"
        case .mid: return "720p"
        case .low: return "480p"
        case .audio: return "Audio only"
        }
    }

    var detail: String {
        switch self {
        case .best: return "Up to 4K — big files, best for the TV"
        case .high: return "Full HD — the sweet spot for most things"
        case .mid: return "Comfortable on a phone, half the size"
        case .low: return "Tiny — lectures and talking heads"
        case .audio: return "M4A only — podcasts, music, listening on the move"
        }
    }

    var symbol: String {
        switch self {
        case .best: return "4k.tv"
        case .high: return "sparkles.tv"
        case .mid: return "tv"
        case .low: return "rectangle.compress.vertical"
        case .audio: return "waveform"
        }
    }
}

enum MacLinkError: LocalizedError {
    case notConfigured
    case badResponse(Int)
    case unauthorised
    case notCuratorHost

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No Mac connected yet."
        case .unauthorised: return "That pairing token was rejected."
        case .notCuratorHost: return "Something answered, but it isn't the Curator Studio daemon."
        case .badResponse(let code): return "The Mac replied with HTTP \(code)."
        }
    }
}

// MARK: - Client

/// Thin HTTP client for the Mac daemon. Everything is plain JSON over the
/// local network; the shared token goes in a header.
struct MacLink {

    var host: MacHost
    var token: String

    private var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.waitsForConnectivity = false
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config)
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let base = host.baseURL, let url = URL(string: path, relativeTo: base) else {
            throw MacLinkError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Curator-Token")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MacLinkError.badResponse(0) }
        if http.statusCode == 401 { throw MacLinkError.unauthorised }
        guard (200..<300).contains(http.statusCode) else {
            throw MacLinkError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Calls

    func health() async throws -> MacHealth {
        let health = try await send(try request("/health"), as: MacHealth.self)
        guard health.service == "curator-studio" else { throw MacLinkError.notCuratorHost }
        return health
    }

    func jobs() async throws -> [RemoteJob] {
        struct Envelope: Decodable { let jobs: [RemoteJob] }
        return try await send(try request("/jobs"), as: Envelope.self).jobs
    }

    func folders() async throws -> [String] {
        struct Envelope: Decodable { let folders: [String] }
        return try await send(try request("/folders"), as: Envelope.self).folders
    }

    func shelf() async throws -> [ShelfItem] {
        struct Envelope: Decodable { let items: [ShelfItem] }
        return try await send(try request("/shelf"), as: Envelope.self).items
    }

    @discardableResult
    func submit(url: String, quality: DownloadQuality, folder: String) async throws -> [RemoteJob] {
        struct Envelope: Decodable { let created: [RemoteJob] }
        let payload: [String: Any] = [
            "text": url,
            "quality": quality.rawValue,
            "folder": folder,
            "source": "app",
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        return try await send(try request("/jobs", method: "POST", body: body),
                              as: Envelope.self).created
    }

    func acknowledge(jobID: String) async {
        struct Ok: Decodable { let ok: Bool }
        _ = try? await send(try request("/jobs/\(jobID)/ack", method: "POST", body: Data("{}".utf8)),
                            as: Ok.self)
    }

    func retry(jobID: String) async throws {
        struct Ok: Decodable { let ok: Bool }
        _ = try await send(try request("/jobs/\(jobID)/retry", method: "POST", body: Data("{}".utf8)),
                           as: Ok.self)
    }

    func delete(jobID: String) async throws {
        struct Ok: Decodable { let ok: Bool }
        _ = try await send(try request("/jobs/\(jobID)", method: "DELETE"), as: Ok.self)
    }

    // MARK: File transfer

    func fileRequest(jobID: String) throws -> URLRequest {
        try request("/files/\(jobID)")
    }

    func shelfRequest(path: String) throws -> URLRequest {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? path
        return try request("/shelf/file?path=\(encoded)")
    }

    /// The Mac is a relay, not an archive — once a shelf item has been
    /// copied to the phone, its copy on the Mac is deleted (logged first).
    func deleteShelfItem(path: String) async {
        struct Ok: Decodable { let ok: Bool }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? path
        _ = try? await send(try request("/shelf/file?path=\(encoded)", method: "DELETE"), as: Ok.self)
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?#")
        return set
    }()
}

// MARK: - Download with progress

/// URLSession download task wrapped for async/await, reporting progress.
final class FileDownloader: NSObject, URLSessionDownloadDelegate {

    private var continuation: CheckedContinuation<URL, Error>?
    private var onProgress: ((Double, Int64, Int64) -> Void)?
    private var destination: URL?
    private var task: URLSessionDownloadTask?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func download(
        _ request: URLRequest,
        progress: @escaping (Double, Int64, Int64) -> Void
    ) async throws -> URL {
        onProgress = progress
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        onProgress?(fraction, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file disappears when this method returns, so move it now.
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: target)
            destination = target
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse,
                  !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: MacLinkError.badResponse(http.statusCode))
        } else if let destination {
            continuation?.resume(returning: destination)
        } else {
            continuation?.resume(throwing: MacLinkError.badResponse(0))
        }
        continuation = nil
    }
}
