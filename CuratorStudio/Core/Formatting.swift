import Foundation

enum Fmt {

    /// 0:07 · 4:31 · 1:12:09
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// "-2:14" style remaining time.
    static func remaining(_ current: Double, _ duration: Double) -> String {
        let left = max(0, duration - current)
        return "-" + time(left)
    }

    static func fileSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB, .useKB]
        // Otherwise a download that hasn't moved yet reads "Zero KB of 6.7 MB".
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }

    /// 1.2M · 43K · 907 — for view counts, which arrive as a raw integer string.
    static func count(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        switch value {
        case 1_000_000_000...:
            return (f.string(from: NSNumber(value: Double(value) / 1_000_000_000)) ?? "") + "B"
        case 1_000_000...:
            return (f.string(from: NSNumber(value: Double(value) / 1_000_000)) ?? "") + "M"
        case 1_000...:
            return (f.string(from: NSNumber(value: Double(value) / 1_000)) ?? "") + "K"
        default:
            return "\(value)"
        }
    }

    static func speed(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.001 {
            return String(format: "%.0f×", value)
        }
        if abs(value * 100 - (value * 100).rounded()) < 0.001 && (value * 100).truncatingRemainder(dividingBy: 10) != 0 {
            return String(format: "%.2f×", value)
        }
        return String(format: "%.2f×", value).replacingOccurrences(of: "0×", with: "×")
    }

    static func semitones(_ value: Int) -> String {
        if value == 0 { return "Original key" }
        let sign = value > 0 ? "+" : "−"
        let magnitude = abs(value)
        let unit = magnitude == 1 ? "semitone" : "semitones"
        return "\(sign)\(magnitude) \(unit)"
    }

    static func semitonesShort(_ value: Int) -> String {
        if value == 0 { return "0" }
        return value > 0 ? "+\(value)" : "\(value)"
    }

    /// Note name reached if you transpose C by n semitones — a quick sanity
    /// reference when re-keying a guitar lesson.
    static func transposedFrom(_ root: String, by value: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        guard let base = names.firstIndex(of: root) else { return "" }
        let idx = ((base + value) % 12 + 12) % 12
        return names[idx]
    }

    static func relativeDate(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
