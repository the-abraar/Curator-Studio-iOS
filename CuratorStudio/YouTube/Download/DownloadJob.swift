import Foundation

/// One queued video. Persisted verbatim to disk so a queue survives the app being killed mid-run,
/// exactly like the Mac daemon's `state.json` did — only now the queue lives on the phone.
struct DownloadJob: Identifiable, Codable, Hashable {

    enum Stage: String, Codable, Hashable {
        case queued
        case resolving      // asking YouTube for the stream URLs
        case downloading
        case assembling     // muxing video + audio, trimming sponsors
        case importing      // moving into the library folder
        case done
        case failed
        case cancelled

        var isTerminal: Bool { self == .done || self == .failed || self == .cancelled }
        var isActive: Bool { !isTerminal }

        var label: String {
            switch self {
            case .queued: return "Waiting"
            case .resolving: return "Getting stream…"
            case .downloading: return "Downloading"
            case .assembling: return "Merging audio & video"
            case .importing: return "Filing it away"
            case .done: return "In your library"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }

        var symbol: String {
            switch self {
            case .queued: return "clock"
            case .resolving: return "antenna.radiowaves.left.and.right"
            case .downloading: return "arrow.down.circle"
            case .assembling: return "wand.and.rays"
            case .importing: return "folder"
            case .done: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle"
            case .cancelled: return "slash.circle"
            }
        }
    }

    /// Which half of an adaptive pair a downloaded file is.
    enum Part: String, Codable, Hashable {
        case video
        case audio
    }

    var id: String = UUID().uuidString
    var videoId: String
    var title: String
    var channelName: String
    var channelId: String?
    var thumbnailURLString: String?
    var durationSeconds: Int?
    var quality: DownloadQuality
    var folder: String
    var stage: Stage = .queued
    var createdAt: Date = Date()

    // Progress. Adaptive downloads have two halves in flight at once, so bytes are tracked per
    // part and summed — otherwise the bar jumps backwards every time the other half reports.
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var partProgress: [Part: Int64] = [:]
    var partTotals: [Part: Int64] = [:]

    // Results
    var relativePath: String?
    var errorMessage: String?
    /// How many times the queue has quietly restarted this job after YouTube refused it.
    var autoRetries: Int = 0
    /// Staged files on disk, by part — set as each half of the pair lands.
    var stagedFiles: [Part: String] = [:]
    /// Parts this job is waiting on, decided once the stream URLs are known.
    var expectedParts: [Part] = []
    var trimmedSeconds: Double = 0

    var fraction: Double {
        guard totalBytes > 0 else { return stage == .queued ? 0 : 0.02 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    var thumbnailURL: URL? { thumbnailURLString.flatMap(URL.init(string:)) }

    var destinationDescription: String {
        folder.isEmpty ? "library root" : folder
    }

    init(video: StreamInfoItem, quality: DownloadQuality, folder: String) {
        self.videoId = video.id
        self.title = video.title
        self.channelName = video.channelName
        self.channelId = video.channelId
        self.thumbnailURLString = video.thumbnailURL?.absoluteString
        self.quality = quality
        self.folder = folder
    }

    init(details: VideoDetails, quality: DownloadQuality, folder: String) {
        self.videoId = details.id
        self.title = details.title
        self.channelName = details.channelName
        self.channelId = details.channelId
        self.thumbnailURLString = details.thumbnailURL?.absoluteString
        self.durationSeconds = details.lengthSeconds
        self.quality = quality
        self.folder = folder
    }

    /// Filename for the finished file, sanitised for a Files-app folder.
    func filename(extension ext: String) -> String {
        var name = title
        for character in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            name = name.replacingOccurrences(of: character, with: "-")
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = videoId }
        // HFS+/APFS take 255 bytes; leave room for " (2).mp4" on collisions.
        if name.count > 180 { name = String(name.prefix(180)) }
        return "\(name).\(ext)"
    }
}

/// The `.curator.json` written next to each finished file — same idea (and same filename) as the
/// sidecar the Mac daemon used to write, so nothing downstream has to change.
struct DownloadSidecar: Codable {
    let source: String
    let url: String
    let videoId: String
    let title: String
    let channel: String?
    let channelURL: String?
    let quality: String
    let durationSeconds: Int?
    let downloadedAt: Date
    let chapters: [VideoChapter]
    let removedSegments: [SponsorSegment]
    let downloadedOn: String

    init(job: DownloadJob, details: VideoDetails?, segments: [SponsorSegment]) {
        self.source = "youtube"
        self.url = "https://www.youtube.com/watch?v=\(job.videoId)"
        self.videoId = job.videoId
        self.title = job.title
        self.channel = job.channelName.isEmpty ? nil : job.channelName
        self.channelURL = job.channelId.map { "https://www.youtube.com/channel/\($0)" }
        self.quality = job.quality.rawValue
        self.durationSeconds = details?.lengthSeconds ?? job.durationSeconds
        self.downloadedAt = Date()
        self.chapters = details?.chapters ?? []
        self.removedSegments = segments
        self.downloadedOn = "iPhone"
    }
}
