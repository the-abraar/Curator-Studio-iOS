import Foundation

/// The quality words the app has always used — they used to be passed to yt-dlp on the Mac, and
/// now drive `FormatSelector` on the phone. Same vocabulary, same meanings.
enum DownloadQuality: String, CaseIterable, Identifiable, Codable, Sendable {
    case best, high, mid, low, audio

    var id: String { rawValue }

    /// Tallest picture to accept. YouTube only serves H.264 up to 1080p (2160p is VP9/AV1, which
    /// AVFoundation won't put in an MP4), so "best" tops out there by design rather than by limit.
    var maxHeight: Int? {
        switch self {
        case .best: return nil
        case .high: return 1080
        case .mid: return 720
        case .low: return 480
        case .audio: return nil
        }
    }

    var isAudioOnly: Bool { self == .audio }

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
        case .best: return "Highest the phone can decode — usually 1080p H.264"
        case .high: return "Full HD — the sweet spot for most things"
        case .mid: return "Comfortable on a phone, half the size"
        case .low: return "Tiny — lectures and talking heads"
        case .audio: return "M4A only — podcasts, music, listening on the move"
        }
    }

    var symbol: String {
        switch self {
        case .best: return "sparkles.tv"
        case .high: return "tv"
        case .mid: return "rectangle.on.rectangle"
        case .low: return "rectangle.compress.vertical"
        case .audio: return "waveform"
        }
    }
}

/// Turns a quality word plus a video's format list into the one or two files to actually fetch.
///
/// YouTube stopped serving high-resolution muxed streams years ago: anything above 720p only
/// exists as separate video-only and audio-only renditions. yt-dlp merged those with ffmpeg on
/// the Mac; here the pair is downloaded and handed to `MediaAssembler`, which muxes them with
/// AVFoundation. Only H.264 video and AAC audio are ever chosen — VP9, AV1 and Opus are present
/// in the list but iOS can't put them in a playable MP4.
enum FormatSelector {

    struct Selection {
        var video: StreamFormat?
        var audio: StreamFormat?
        var expectedBytes: Int64 {
            (video?.contentLength ?? 0) + (audio?.contentLength ?? 0)
        }
    }

    enum SelectionError: LocalizedError {
        case nothingUsable

        var errorDescription: String? {
            "No stream this iPhone can play — YouTube only offered formats iOS can't decode."
        }
    }

    static func select(quality: DownloadQuality, from formats: [StreamFormat]) throws -> Selection {
        let usable = formats.filter(\.isAppleFriendly)
        let audio = bestAudio(in: usable)

        if quality.isAudioOnly {
            if let audio { return Selection(video: nil, audio: audio) }
            // No adaptive AAC track: fall back to a muxed file and let the assembler strip video.
            if let muxed = bestMuxed(in: usable, maxHeight: nil) {
                return Selection(video: nil, audio: muxed)
            }
            throw SelectionError.nothingUsable
        }

        // Preferred path: adaptive H.264 at the requested ceiling, muxed with the best AAC track.
        if let video = bestVideo(in: usable, maxHeight: quality.maxHeight), let audio {
            return Selection(video: video, audio: audio)
        }

        // Fallback: the progressive muxed format (360p/720p) — always plays, never needs muxing.
        if let muxed = bestMuxed(in: usable, maxHeight: quality.maxHeight)
            ?? bestMuxed(in: usable, maxHeight: nil) {
            return Selection(video: muxed, audio: nil)
        }

        throw SelectionError.nothingUsable
    }

    static func bestVideo(in formats: [StreamFormat], maxHeight: Int?) -> StreamFormat? {
        formats
            .filter { $0.content == .videoOnly && $0.codecs.hasPrefix("avc1") }
            .filter { format in
                guard let maxHeight, let height = format.height else { return true }
                return height <= maxHeight
            }
            .max { rank($0) < rank($1) }
    }

    static func bestAudio(in formats: [StreamFormat]) -> StreamFormat? {
        formats
            .filter { $0.content == .audioOnly && $0.codecs.hasPrefix("mp4a") }
            .max { $0.bitrate < $1.bitrate }
    }

    static func bestMuxed(in formats: [StreamFormat], maxHeight: Int?) -> StreamFormat? {
        formats
            .filter { $0.content == .muxed }
            .filter { format in
                guard let maxHeight, let height = format.height else { return true }
                return height <= maxHeight
            }
            .max { rank($0) < rank($1) }
    }

    /// Height first, frame rate second, bitrate last — a 1080p60 stream beats 1080p30, and both
    /// beat a fat 720p.
    private static func rank(_ format: StreamFormat) -> Int {
        (format.height ?? 0) * 1_000_000 + (format.fps ?? 30) * 1_000 + min(format.bitrate / 1_000, 999)
    }

    /// What the UI shows before you commit to a download.
    static func availableQualities(in formats: [StreamFormat]) -> [DownloadQuality] {
        DownloadQuality.allCases.filter { (try? select(quality: $0, from: formats)) != nil }
    }
}
