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

/// The outcome of one telemetry POST that got an HTTP response.
struct TelemetryPostResult: Sendable, Equatable {
    var status: Int
    /// Raw `Retry-After` header, if the server sent one.
    var retryAfter: String?
    /// First 200 bytes of the response body (for the rejected-batch ERROR).
    var bodySnippet: String
}

/// A telemetry POST that got no HTTP response.
enum TelemetryTransportError: Error, Sendable, Equatable {
    /// The overall request deadline passed (P1).
    case timeout
    /// The request was cancelled (the flush loop was stopped).
    case aborted
    /// Connection, DNS, TLS or other transport failure.
    case network(String)
}

/// POSTs serialized telemetry batches to api-telemetry.
///
/// Mirrors `sdk-javascript/src/telemetry/uploader.ts`:
///   `POST {telemetryUrl}/api/v1/telemetry/` with HTTP Basic (same client key),
///   `Content-Type: application/json`. The Apple SDK additionally sends the
///   `User-Agent` it sends on every request (Flagsmith #88) and uses the same
///   Basic header as the loader (frontend key, see `Auth.swift`).
///
/// The uploader sends opaque bytes: the aggregator serializes a window exactly
/// once and resends those same bytes on a retry (transport policy P5), so the
/// server's payload-derived dedup token matches. It holds no state.
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

    /// Serialize one window into the POST body. Called once per window; the
    /// result is what gets retained and resent.
    static func encode(_ events: TelemetryEvents) throws -> Data {
        try JSONEncoder().encode(events)
    }

    /// POST `body` with an overall deadline of `timeout` seconds (P1). Returns
    /// the status for any HTTP response (the caller classifies it); throws a
    /// `TelemetryTransportError` when there is no response.
    ///
    /// URLSession has no whole-request deadline (`timeoutIntervalForRequest` is
    /// an idle timeout) and no separate connect-timeout knob, so the deadline is
    /// a race against a sleep that cancels the request; it bounds connect, TLS
    /// and the response together.
    func send(_ body: Data, timeout: TimeInterval) async throws -> TelemetryPostResult {
        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = max(timeout, 0.001)
        request.setValue(authHeaderValue(sdkKey: sdkKey), forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let client = self.client
        let finalRequest = request
        let deadline = UInt64(max(timeout, 0) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: TelemetryPostResult.self) { group in
            group.addTask {
                try await TelemetryUploader.perform(finalRequest, client: client)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: deadline)
                throw TelemetryTransportError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TelemetryTransportError.aborted }
            return first
        }
    }

    private static func perform(_ request: URLRequest, client: HTTPClient) async throws -> TelemetryPostResult {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await client.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw TelemetryTransportError.timeout
            case .cancelled: throw TelemetryTransportError.aborted
            default: throw TelemetryTransportError.network("URLError \(error.code.rawValue)")
            }
        } catch is CancellationError {
            throw TelemetryTransportError.aborted
        } catch let error as TelemetryTransportError {
            throw error
        } catch {
            throw TelemetryTransportError.network(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw TelemetryTransportError.network("non-HTTP response")
        }
        let snippet = String(decoding: data.prefix(200), as: UTF8.self)
        return TelemetryPostResult(
            status: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            bodySnippet: snippet
        )
    }
}
