import Foundation

#if canImport(FoundationNetworking)
    // Linux-Swift splits URLSession into FoundationNetworking (plan §2.10).
    import FoundationNetworking
#endif

/// A single per-flag evaluation counter, mirroring
/// `sdk-javascript/src/types.ts` `ConfigEvaluationCounter` and the pinned wire
/// fixture (`Tests/.../Fixtures/telemetry-post.body.json`, qfg-2t2d.1).
///
/// `selectedValue` is the JS `{ [config.type]: massagedValue }` shape — a
/// single-entry object keyed by the value's wire type (`bool`/`string`/…).
/// `reason` is emitted as the wire STRING (`"STATIC"`/`"TARGETING_MATCH"`/…),
/// matching the JS aggregator (which spreads the `EvaluationMetadata.reason`
/// string straight through) and the human-reviewed fixture. Optional fields use
/// `encodeIfPresent` so the omitempty shape matches the wire exactly.
struct EvaluationCounter: Sendable, Equatable, Codable {
    var configRowIndex: Int?
    var conditionalValueIndex: Int?
    var configId: String?
    var reason: String?
    var ruleIndex: Int?
    var weightedValueIndex: Int?
    var selectedValue: QuonfigJSONValue
    var count: Int

    enum CodingKeys: String, CodingKey {
        case configRowIndex, conditionalValueIndex, configId, reason
        case ruleIndex, weightedValueIndex, selectedValue, count
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(configRowIndex, forKey: .configRowIndex)
        try c.encodeIfPresent(conditionalValueIndex, forKey: .conditionalValueIndex)
        try c.encodeIfPresent(configId, forKey: .configId)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(ruleIndex, forKey: .ruleIndex)
        try c.encodeIfPresent(weightedValueIndex, forKey: .weightedValueIndex)
        try c.encode(selectedValue, forKey: .selectedValue)
        try c.encode(count, forKey: .count)
    }
}

/// One `{ key, type, counters: [...] }` entry. `type` is the configType
/// (`feature_flag`/`config`/…). Mirrors JS `ConfigEvaluationSummary`.
struct EvaluationSummary: Sendable, Equatable, Codable {
    var key: String
    var type: String
    var counters: [EvaluationCounter]
}

/// The `{ start, end, summaries: [...] }` window. `start`/`end` are epoch
/// **milliseconds** (JS `Date.getTime()`).
struct EvaluationSummaries: Sendable, Equatable, Codable {
    var start: Int64
    var end: Int64
    var summaries: [EvaluationSummary]
}

/// A telemetry event. The frontend client only ever emits `summaries` (context
/// shapes/examples are server-side via `collectContextMode` — §2.8), so this is
/// the only populated field.
struct TelemetryEvent: Sendable, Equatable, Codable {
    var summaries: EvaluationSummaries
}

/// The full POST body: `{ instanceHash, clientName, clientVersion, events }`.
/// Mirrors `sdk-javascript`'s `TelemetryEvents`; `clientName` is `"swift"`
/// (§2.11 drift table — purely a dashboard label, server accepts any string).
struct TelemetryEvents: Sendable, Equatable, Codable {
    var instanceHash: String
    var clientName: String
    var clientVersion: String
    var events: [TelemetryEvent]
}

/// POSTs evaluation summaries to api-telemetry.
///
/// Mirrors `sdk-javascript/src/telemetry/uploader.ts`:
///   `POST {telemetryUrl}/api/v1/telemetry/` with HTTP Basic (same client key),
///   `Content-Type: application/json`. The Apple SDK additionally sends the
///   `User-Agent` it sends on every request (Flagsmith #88) and uses the same
///   `"u:"`-username Basic header as the loader (frontend key — see `Auth.swift`).
///
/// Network failure is surfaced to the caller (the aggregator), which re-queues
/// the window rather than dropping it (the offline-queue bound lives in the
/// aggregator). The uploader itself holds no state — it just builds + sends.
public final class TelemetryUploader: Sendable {
    let postURL: URL
    let sdkKey: String
    let userAgent: String
    let client: HTTPClient

    /// `postURL` is the full endpoint (`<telemetryURL>/api/v1/telemetry/`).
    init(postURL: URL, sdkKey: String, userAgent: String, client: HTTPClient) {
        self.postURL = postURL
        self.sdkKey = sdkKey
        self.userAgent = userAgent
        self.client = client
    }

    /// Resolve the endpoint from a `Configuration` (honors the telemetry-URL
    /// escape hatch / domain), building a `URLSession` from the configured
    /// session config (same privacy-hardened session as the loader).
    public convenience init(configuration: Configuration) {
        let urls = QuonfigURLs.resolve(from: configuration)
        let session = URLSession(configuration: configuration.sessionConfiguration)
        self.init(
            postURL: TelemetryUploader.endpoint(base: urls.telemetryURL),
            sdkKey: configuration.sdkKey,
            userAgent: quonfigUserAgent(),
            client: session
        )
    }

    /// Build `<base>/api/v1/telemetry/` (trailing slash, mirroring `uploader.ts`
    /// `postUrl()`), trimming a trailing slash on the base first.
    static func endpoint(base: URL) -> URL {
        var s = base.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return URL(string: "\(s)/api/v1/telemetry/") ?? base
    }

    /// POST one batch. Throws on transport error or non-2xx so the caller can
    /// re-queue. The 2xx body is ignored (JS reads `.json()` but discards it for
    /// our purposes).
    func post(_ events: TelemetryEvents) async throws {
        let body = try JSONEncoder().encode(events)

        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(authHeaderValue(sdkKey: sdkKey), forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (_, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuonfigLoaderError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuonfigLoaderError.httpStatus(http.statusCode)
        }
    }
}
