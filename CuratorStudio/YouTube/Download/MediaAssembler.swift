import Foundation
import AVFoundation
import UIKit

/// Turns the raw files off googlevideo into one finished, playable file.
///
/// This is the job ffmpeg used to do on the Mac, done with AVFoundation on the phone instead:
///
/// 1. **Mux** — anything above 720p only exists as separate video-only and audio-only streams, so
///    the two are laid into one `AVMutableComposition`.
/// 2. **Trim** — SponsorBlock segments are simply never inserted into the composition.
/// 3. **Tag** — title, channel, description and the poster frame go in as metadata.
/// 4. **Export** — passthrough, so H.264/AAC is copied rather than re-encoded. A phone re-encoding
///    a 40-minute lecture would take longer than the download did and cost a chunk of battery.
enum MediaAssembler {

    struct Output {
        let url: URL
        let trimmedSeconds: Double
    }

    enum AssemblyError: LocalizedError {
        case noTracks
        case exportUnavailable

        var errorDescription: String? {
            switch self {
            case .noTracks: return "The downloaded file had no audio or video in it."
            case .exportUnavailable: return "Couldn't start the merge — the file may be corrupt."
            }
        }
    }

    /// - Parameters:
    ///   - files: the staged parts, in any order — video-only + audio-only, or a single muxed file.
    ///   - audioOnly: drop the picture and write an `.m4a`.
    ///   - segments: SponsorBlock ranges to cut out.
    static func assemble(
        files: [URL],
        audioOnly: Bool,
        segments: [SponsorSegment],
        title: String,
        channel: String,
        description: String?,
        artwork: Data?,
        outputURL: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> Output {

        let assets = files.map { AVURLAsset(url: $0, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }

        var videoTrack: AVAssetTrack?
        var audioTrack: AVAssetTrack?
        var duration: CMTime = .zero

        for asset in assets {
            let assetDuration = try await asset.load(.duration)
            if assetDuration > duration { duration = assetDuration }
            if !audioOnly, videoTrack == nil {
                videoTrack = try await asset.loadTracks(withMediaType: .video).first
            }
            if audioTrack == nil {
                audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            }
        }

        guard videoTrack != nil || audioTrack != nil else { throw AssemblyError.noTracks }

        // The two halves of an adaptive pair are never exactly the same length — a video stream
        // routinely runs a fraction of a second longer than its audio. Asking a track for a range
        // that runs past its end produces a composition the exporter refuses outright, so every
        // insertion is clamped to what that particular track actually has.
        let videoRange = try await videoTrack?.load(.timeRange)
        let audioRange = try await audioTrack?.load(.timeRange)

        let composition = AVMutableComposition()
        let compositionVideo = videoTrack.flatMap { _ in
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        let compositionAudio = audioTrack.flatMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        let ranges = keptRanges(duration: duration, cutting: segments)
        var cursor = CMTime.zero
        for range in ranges {
            if let compositionVideo, let videoTrack, let videoRange {
                let clamped = range.intersection(videoRange)
                if clamped.duration.seconds > 0.01 {
                    try compositionVideo.insertTimeRange(clamped, of: videoTrack, at: cursor)
                }
            }
            if let compositionAudio, let audioTrack, let audioRange {
                let clamped = range.intersection(audioRange)
                if clamped.duration.seconds > 0.01 {
                    try compositionAudio.insertTimeRange(clamped, of: audioTrack, at: cursor)
                }
            }
            // Always advance by the full range, even if one track ran out early — otherwise the
            // shorter track drags the other out of sync for the rest of the file.
            cursor = CMTimeAdd(cursor, range.duration)
        }

        // Keep the source orientation — YouTube Shorts and phone-shot footage carry a transform.
        if let compositionVideo, let videoTrack {
            compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        }

        let (preset, fileType) = await exportConfiguration(for: composition, audioOnly: audioOnly)
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw AssemblyError.exportUnavailable
        }
        session.metadata = metadataItems(
            title: title, channel: channel, description: description, artwork: artwork
        )
        session.shouldOptimizeForNetworkUse = true

        try? FileManager.default.removeItem(at: outputURL)

        let progressTask = Task {
            for await state in session.states(updateInterval: 0.4) {
                if case .exporting(let progress) = state {
                    onProgress(progress.fractionCompleted)
                }
            }
        }
        defer { progressTask.cancel() }

        try await session.export(to: outputURL, as: fileType)

        let trimmed = segments.reduce(0) { $0 + $1.duration }
        return Output(url: outputURL, trimmedSeconds: trimmed)
    }

    /// Passthrough is what makes this cheap — H.264 and AAC are copied rather than re-encoded —
    /// but it can't write every composition into every container. Verified live: an audio-only
    /// composition with SponsorBlock cuts in it is refused for `.m4a` under passthrough, though
    /// the same composition uncut is fine. So ask first, and only fall back to a re-encoding
    /// preset when there's no passthrough route.
    private static func exportConfiguration(
        for composition: AVComposition, audioOnly: Bool
    ) async -> (preset: String, fileType: AVFileType) {
        let fileType: AVFileType = audioOnly ? .m4a : .mp4
        let canPassthrough = await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetPassthrough,
            with: composition,
            outputFileType: fileType
        )
        if canPassthrough { return (AVAssetExportPresetPassthrough, fileType) }
        return (audioOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality, fileType)
    }

    /// The complement of the cut list: everything worth keeping, in order.
    static func keptRanges(duration: CMTime, cutting segments: [SponsorSegment]) -> [CMTimeRange] {
        let total = duration.seconds
        guard total > 0 else { return [CMTimeRange(start: .zero, duration: duration)] }

        let cuts = SponsorBlock.merge(segments)
            .filter { $0.start < total && $0.duration > 0.5 }
        guard !cuts.isEmpty else {
            return [CMTimeRange(start: .zero, duration: duration)]
        }

        var ranges: [CMTimeRange] = []
        var cursor: Double = 0
        for cut in cuts {
            if cut.start > cursor + 0.05 {
                ranges.append(range(from: cursor, to: min(cut.start, total)))
            }
            cursor = max(cursor, min(cut.end, total))
        }
        if cursor < total - 0.05 {
            ranges.append(range(from: cursor, to: total))
        }
        return ranges.filter { $0.duration.seconds > 0.05 }
    }

    private static func range(from start: Double, to end: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: max(0, end - start), preferredTimescale: 600)
        )
    }

    // MARK: Tagging

    private static func metadataItems(
        title: String, channel: String, description: String?, artwork: Data?
    ) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func add(_ identifier: AVMetadataIdentifier, _ value: (any NSCopying & NSObjectProtocol)?) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            item.extendedLanguageTag = "und"
            items.append(item)
        }

        add(.commonIdentifierTitle, title as NSString)
        add(.commonIdentifierArtist, channel.isEmpty ? nil : channel as NSString)
        add(.commonIdentifierAlbumName, channel.isEmpty ? nil : channel as NSString)
        add(.commonIdentifierDescription, description.map { NSString(string: String($0.prefix(2000))) })
        add(.commonIdentifierSoftware, "Curator Studio" as NSString)
        if let artwork {
            let item = AVMutableMetadataItem()
            item.identifier = .commonIdentifierArtwork
            item.dataType = kCMMetadataBaseDataType_JPEG as String
            item.value = artwork as NSData
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        return items
    }

    /// Fetches the poster frame to embed. Best effort — a missing thumbnail must not fail a job.
    static func artworkData(from url: URL?) async -> Data? {
        guard let url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        // Re-encode to JPEG so WebP thumbnails don't end up in an MP4 atom nothing can read.
        guard let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.85) ?? data
    }
}
