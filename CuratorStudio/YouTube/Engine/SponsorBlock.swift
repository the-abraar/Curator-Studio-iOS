import Foundation

/// Segments the community has marked as skippable, fetched from the public SponsorBlock API.
/// The Mac daemon used to hand these to ffmpeg; now `MediaAssembler` cuts them out of the
/// composition on the phone instead.
struct SponsorSegment: Hashable, Codable, Sendable {
    let category: String
    let start: Double
    let end: Double

    var duration: Double { max(0, end - start) }
}

enum SponsorBlock {

    static let allCategories = ["sponsor", "selfpromo", "interaction", "intro", "outro", "music_offtopic"]

    static func label(for category: String) -> String {
        switch category {
        case "sponsor": return "Sponsors"
        case "selfpromo": return "Self promotion"
        case "interaction": return "Subscribe reminders"
        case "intro": return "Intros"
        case "outro": return "Outros"
        case "music_offtopic": return "Non-music sections"
        default: return category.capitalized
        }
    }

    /// Returns the segments to cut, merged and sorted. Never throws — a SponsorBlock outage must
    /// not fail a download, it just means nothing gets trimmed.
    static func segments(for videoId: String, categories: [String]) async -> [SponsorSegment] {
        guard !categories.isEmpty else { return [] }
        let categoryJSON = "[" + categories.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")
        components?.queryItems = [
            URLQueryItem(name: "videoID", value: videoId),
            URLQueryItem(name: "categories", value: categoryJSON),
        ]
        guard let url = components?.url else { return [] }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            // 404 simply means "nobody has submitted segments for this video".
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let root = try JSONValue(data: data)
            let parsed: [SponsorSegment] = root.arrayValue.compactMap { entry in
                let bounds = entry["segment"].arrayValue.compactMap { $0.doubleValue }
                guard bounds.count == 2, bounds[1] > bounds[0] else { return nil }
                return SponsorSegment(
                    category: entry["category"].stringValue ?? "sponsor",
                    start: bounds[0],
                    end: bounds[1]
                )
            }
            return merge(parsed)
        } catch {
            return []
        }
    }

    /// Overlapping submissions are common; collapse them so the composition maths stays simple.
    static func merge(_ segments: [SponsorSegment]) -> [SponsorSegment] {
        let sorted = segments.sorted { $0.start < $1.start }
        var merged: [SponsorSegment] = []
        for segment in sorted {
            if let last = merged.last, segment.start <= last.end {
                merged[merged.count - 1] = SponsorSegment(
                    category: last.category,
                    start: last.start,
                    end: max(last.end, segment.end)
                )
            } else {
                merged.append(segment)
            }
        }
        return merged
    }
}
