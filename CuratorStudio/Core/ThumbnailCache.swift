import UIKit
import AVFoundation

/// Generates and caches poster frames for video files so the library grid
/// does not have to decode the same frame over and over.
actor ThumbnailCache {

    static let shared = ThumbnailCache()

    private var memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private var diskDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    init() {
        memory.countLimit = 300
    }

    private func diskURL(for key: String) -> URL {
        let safe = String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
        let trimmed = String(safe.suffix(120)) + "-\(abs(key.hashValue))"
        return diskDirectory.appendingPathComponent(trimmed + ".jpg")
    }

    func thumbnail(for url: URL, key: String, maxSize: CGFloat = 480) async -> UIImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }

        if let existing = inFlight[key] { return await existing.value }

        let task = Task<UIImage?, Never> { [diskURL = diskURL(for: key)] in
            if let data = try? Data(contentsOf: diskURL), let image = UIImage(data: data) {
                return image
            }
            let generated = await Self.generate(url: url, maxSize: maxSize)
            if let generated, let data = generated.jpegData(compressionQuality: 0.7) {
                try? data.write(to: diskURL, options: .atomic)
            }
            return generated
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    private static func generate(url: URL, maxSize: CGFloat) async -> UIImage? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        // Try 10% in; fall back to the very start for very short clips.
        let duration = (try? await asset.load(.duration)) ?? .zero
        let seconds = CMTimeGetSeconds(duration)
        let target = seconds.isFinite && seconds > 4 ? min(seconds * 0.1, 60) : 0.2

        for candidate in [target, 0.2] {
            let time = CMTime(seconds: candidate, preferredTimescale: 600)
            if let cg = try? await generator.image(at: time).image {
                return UIImage(cgImage: cg)
            }
        }
        return nil
    }

    func purge() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDirectory)
    }
}
