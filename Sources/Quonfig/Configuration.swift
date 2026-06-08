import Foundation

/// Context-upload mode appended to the eval request as `?collectContextMode=`.
///
/// The server (api-delivery) observes the context already in the URL and POSTs
/// shapes/examples to api-telemetry itself — the client uploads none of this
/// (§2.8). UPPER_SNAKE_CASE on the wire, mirroring
/// `sdk-javascript`'s `CollectContextMode`.
public enum CollectContextMode: String, Sendable {
    case none = "NONE"
    case shapeOnly = "SHAPE_ONLY"
    case periodicExample = "PERIODIC_EXAMPLE"
}

/// Init options for a `Quonfig` client.
///
/// All configuration is supplied here at init time — there is **no**
/// `process.env`/`QUONFIG_DOMAIN` runtime lookup on-device (§4.8). Env vars
/// only meaningfully exist in tests/CI.
public struct Configuration: Sendable {
    /// The client/frontend SDK key (`qf_ck_…`). Sent as HTTP Basic with
    /// username `"u"` (see `Auth.swift`).
    public var sdkKey: String

    /// Single knob that flips api + telemetry hosts in lockstep
    /// (`primary.<domain>` / `secondary.<domain>` / `telemetry.<domain>`).
    /// Defaults to `quonfig.com`.
    public var domain: String

    /// Escape hatch: explicit ordered list of API base URLs (failover order).
    /// When set, wins over `domain`. Mirrors `sdk-javascript`'s `apiUrls`.
    public var apiURLs: [URL]?

    /// Escape hatch: explicit telemetry base URL. When set, wins over `domain`.
    public var telemetryURL: URL?

    /// Foreground poll interval. A sensible default (mobile callers shouldn't
    /// have to know a good value); an interval of `0` disables polling
    /// (handled by the poller — Unleash #101). Default 60s (§2.11 drift table).
    public var pollInterval: TimeInterval

    /// Whether the client uploads per-flag evaluation summaries. On by default,
    /// matching `sdk-javascript`'s `collectEvaluationSummaries = true` (§2.8).
    public var collectEvaluationSummaries: Bool

    /// Server-side context-collection mode. Default `PERIODIC_EXAMPLE`,
    /// matching `sdk-javascript`.
    public var collectContextMode: CollectContextMode

    /// The `URLSessionConfiguration` used to build the eval/telemetry sessions.
    /// Customers always want to tune this (Flagsmith #94). Defaults to a
    /// `.ephemeral` config with `urlCache = nil` so the context-bearing eval
    /// URLs are never written to an on-device URL cache (§2.3 privacy, LD's
    /// pattern).
    public var sessionConfiguration: URLSessionConfiguration

    /// Per-request timeout. Applied to `sessionConfiguration` if non-nil.
    public var requestTimeout: TimeInterval?

    /// Resource timeout. Applied to `sessionConfiguration` if non-nil.
    public var resourceTimeout: TimeInterval?

    /// Extra headers recomputed **per request** (proxy auth tokens rotate —
    /// Flagsmith #103). Marked `@Sendable` so the config can cross concurrency
    /// domains. Returns an empty dictionary by default.
    public var customHeaders: @Sendable () -> [String: String]

    public init(
        sdkKey: String,
        domain: String = quonfigDefaultDomain,
        apiURLs: [URL]? = nil,
        telemetryURL: URL? = nil,
        pollInterval: TimeInterval = 60,
        collectEvaluationSummaries: Bool = true,
        collectContextMode: CollectContextMode = .periodicExample,
        sessionConfiguration: URLSessionConfiguration? = nil,
        requestTimeout: TimeInterval? = nil,
        resourceTimeout: TimeInterval? = nil,
        customHeaders: @escaping @Sendable () -> [String: String] = { [:] }
    ) {
        self.sdkKey = sdkKey
        self.domain = domain
        self.apiURLs = apiURLs
        self.telemetryURL = telemetryURL
        self.pollInterval = pollInterval
        self.collectEvaluationSummaries = collectEvaluationSummaries
        self.collectContextMode = collectContextMode

        let session = sessionConfiguration ?? Configuration.defaultSessionConfiguration()
        if let requestTimeout {
            session.timeoutIntervalForRequest = requestTimeout
        }
        if let resourceTimeout {
            session.timeoutIntervalForResource = resourceTimeout
        }
        self.sessionConfiguration = session
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.customHeaders = customHeaders
    }

    /// Ephemeral session config with the URL cache disabled, per §2.3 — the
    /// eval URL carries the (possibly PII-bearing) context in its path, so it
    /// must never be persisted by `URLCache`.
    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }
}
