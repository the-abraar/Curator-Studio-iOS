import Foundation

// MARK: - Client identities

/// A YouTube "InnerTube" client identity. YouTube's `/youtubei/v1/*` endpoints behave differently
/// per declared client — anonymous `/player` requests from the ordinary `WEB` client come back
/// `UNPLAYABLE` ("The page needs to be reloaded") because they want a proof-of-origin token
/// (poToken/BotGuard challenge) that isn't practical to solve without an embedded JS engine.
/// `ANDROID_VR` still returns direct, unciphered stream URLs — but only when the request carries a
/// visitor identity; see `VisitorIdentity`. `WEB` remains right for search and browse.
///
/// This is the first file to revisit if extraction stops working — YouTube changes these rules
/// without notice, and the client versions below age.
struct InnertubeClientContext {
    let clientName: String
    /// The numeric id YouTube uses for this client in `X-Youtube-Client-Name`.
    let clientID: Int
    let clientVersion: String
    let userAgent: String
    let extraClientFields: [String: JSONEncodable]

    /// Used for /search, /browse, /next. No stream-URL restrictions observed.
    static let web = InnertubeClientContext(
        clientName: "WEB",
        clientID: 1,
        clientVersion: "2.20240101.00.00",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        extraClientFields: [:]
    )

    /// The /player client. Verified live: with a visitor id it returns direct, unciphered muxed and
    /// adaptive URLs for ordinary videos; without one, every request comes back `LOGIN_REQUIRED`
    /// ("Sign in to confirm you're not a bot").
    static let androidVR = InnertubeClientContext(
        clientName: "ANDROID_VR",
        clientID: 28,
        clientVersion: "1.65.10",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        extraClientFields: [
            "deviceMake": .string("Oculus"),
            "deviceModel": .string("Quest 3"),
            "osName": .string("Android"),
            "osVersion": .string("12L"),
            "androidSdkVersion": .int(32),
            "timeZone": .string("UTC"),
            "utcOffsetMinutes": .int(0),
        ]
    )

    func contextJSON(hl: String = "en", gl: String = "US", visitorData: String?) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": clientName,
            "clientVersion": clientVersion,
            "hl": hl,
            "gl": gl,
            "userAgent": userAgent,
        ]
        for (key, value) in extraClientFields {
            client[key] = value.jsonValue
        }
        if let visitorData {
            client["visitorData"] = visitorData
        }
        return ["context": ["client": client]]
    }
}

/// Minimal helper so `extraClientFields` can hold mixed string/int values without reaching for `Any`.
enum JSONEncodable {
    case string(String)
    case int(Int)

    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        }
    }
}

// MARK: - Visitor identity

/// The thing that makes anonymous extraction work at all.
///
/// YouTube gates `/player` behind a bot check for requests with no session history. A real client
/// gets past it because it has first loaded youtube.com and been handed a `visitorData` blob, which
/// it then echoes back in `X-Goog-Visitor-Id`. Verified live: identical `/player` requests return
/// `LOGIN_REQUIRED` without that header and `OK` with it — cookies make no difference either way.
///
/// So: fetch the homepage once, scrape the blob out of the embedded config, and reuse it. It's
/// refreshed lazily, and `refresh()` forces a new one when YouTube starts refusing an old one.
actor VisitorIdentity {

    static let shared = VisitorIdentity()

    private var cached: String?
    private var fetchedAt: Date?
    private var inFlight: Task<String?, Never>?

    /// Long enough that a session's worth of browsing costs one homepage fetch, short enough that
    /// a stale blob doesn't linger for days.
    private let lifetime: TimeInterval = 6 * 60 * 60

    func current() async -> String? {
        if let cached, let fetchedAt, Date().timeIntervalSince(fetchedAt) < lifetime {
            return cached
        }
        return await fetch()
    }

    /// Throws the current blob away and gets a new one — used when a request is refused despite
    /// having sent one.
    func refresh() async -> String? {
        cached = nil
        fetchedAt = nil
        return await fetch()
    }

    private func fetch() async -> String? {
        // Coalesce: a screen full of thumbnails must not trigger a homepage fetch each.
        if let inFlight { return await inFlight.value }
        let task = Task<String?, Never> {
            var request = URLRequest(url: URL(string: "https://www.youtube.com/")!)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let html = String(data: data, encoding: .utf8) else { return nil }
            return Self.scrapeVisitorData(from: html)
        }
        inFlight = task
        let value = await task.value
        inFlight = nil
        if let value {
            cached = value
            fetchedAt = Date()
        }
        return value
    }

    /// The homepage embeds `"visitorData":"Cgt…"` in its ytcfg blob, JSON-escaped.
    static func scrapeVisitorData(from html: String) -> String? {
        guard let range = html.range(of: "\"visitorData\":\"") else { return nil }
        let raw = String(html[range.upperBound...].prefix(while: { $0 != "\"" }))
        guard !raw.isEmpty else { return nil }
        return raw
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\/", with: "/")
    }
}

// MARK: - Transport

enum InnertubeError: LocalizedError {
    case http(Int, body: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            return "YouTube returned HTTP \(code): \(body.prefix(200))"
        case .invalidResponse:
            return "YouTube returned a response we couldn't parse."
        }
    }
}

/// Thin POST wrapper around `https://www.youtube.com/youtubei/v1/*`, YouTube's unofficial internal
/// API that its own web and mobile clients use. No API key is sent — the endpoints stopped needing
/// one, and YouTube's own clients no longer send it either.
struct InnertubeClient {

    private let session: URLSession
    private let baseURL = URL(string: "https://www.youtube.com/youtubei/v1/")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// - Parameters:
    ///   - endpoint: e.g. "search", "browse", "player", "next".
    ///   - client: which InnerTube client identity to present.
    ///   - body: additional top-level fields merged into the request (e.g. `["query": "…"]`).
    ///   - freshVisitor: ask for a brand-new visitor id first, for retrying a refused request.
    func post(
        endpoint: String,
        client: InnertubeClientContext,
        body: [String: Any],
        freshVisitor: Bool = false
    ) async throws -> JSONValue {
        let visitorData = freshVisitor
            ? await VisitorIdentity.shared.refresh()
            : await VisitorIdentity.shared.current()

        var url = baseURL.appendingPathComponent(endpoint)
        url.append(queryItems: [URLQueryItem(name: "prettyPrint", value: "false")])

        var payload = client.contextJSON(visitorData: visitorData)
        for (key, value) in body {
            payload[key] = value
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(String(client.clientID), forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw InnertubeError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw InnertubeError.http(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONValue(data: data)
    }
}
