import Foundation

/// YouTube's internal "InnerTube" JSON responses are large, sparsely-documented, and change shape
/// over time. Rather than modelling every renderer as a strict `Codable` struct (which breaks the
/// instant a single field goes missing), we decode into this loosely-typed tree and pull out the
/// handful of fields each extractor actually needs — the same pragmatic approach NewPipeExtractor
/// itself takes with dynamic JSON access.
enum JSONValue {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(data: Data) throws {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSONValue(any: raw)
    }

    init(any: Any) {
        switch any {
        case let dict as [String: Any]:
            self = .object(dict.mapValues { JSONValue(any: $0) })
        case let arr as [Any]:
            self = .array(arr.map { JSONValue(any: $0) })
        case let str as String:
            self = .string(str)
        case let num as NSNumber:
            // Distinguish bools from numbers (NSNumber conflates them).
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                self = .bool(num.boolValue)
            } else {
                self = .number(num.doubleValue)
            }
        default:
            self = .null
        }
    }

    subscript(key: String) -> JSONValue {
        if case let .object(dict) = self, let value = dict[key] {
            return value
        }
        return .null
    }

    subscript(index: Int) -> JSONValue {
        if case let .array(arr) = self, index >= 0, index < arr.count {
            return arr[index]
        }
        return .null
    }

    var arrayValue: [JSONValue] {
        if case let .array(arr) = self { return arr }
        return []
    }

    var objectValue: [String: JSONValue] {
        if case let .object(dict) = self { return dict }
        return [:]
    }

    var stringValue: String? {
        if case let .string(str) = self { return str }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var intValue: Int? {
        doubleValue.map { Int($0) }
    }

    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Finds the first descendant object (depth-first) that contains `key`, and returns that
    /// object's value for `key`. Handy for pulling a field out of a renderer without walking its
    /// exact path — YouTube nests things differently across surfaces (search vs. channel vs. home).
    func firstValue(forKey key: String) -> JSONValue {
        if case let .object(dict) = self {
            if let value = dict[key] {
                return value
            }
            for (_, child) in dict {
                let found = child.firstValue(forKey: key)
                if !found.isNull { return found }
            }
        } else if case let .array(arr) = self {
            for child in arr {
                let found = child.firstValue(forKey: key)
                if !found.isNull { return found }
            }
        }
        return .null
    }

    /// Extracts YouTube's common `{"runs": [{"text": "..."}]}` / `{"simpleText": "..."}` text shape.
    var runText: String? {
        if let simple = self["simpleText"].stringValue {
            return simple
        }
        let runs = self["runs"].arrayValue
        if !runs.isEmpty {
            return runs.compactMap { $0["text"].stringValue }.joined()
        }
        if case .string = self {
            return stringValue
        }
        return nil
    }

    /// Picks the highest-resolution URL out of a `{"thumbnails": [{"url","width","height"}, ...]}`
    /// or a `{"sources": [...]}` (lockupViewModel) shape, both used across surfaces.
    var bestThumbnailURL: String? {
        let candidates = self["thumbnails"].arrayValue + self["sources"].arrayValue
        guard !candidates.isEmpty else { return nil }
        let best = candidates.max { a, b in
            (a["width"].intValue ?? 0) < (b["width"].intValue ?? 0)
        }
        return best?["url"].stringValue
    }
}
