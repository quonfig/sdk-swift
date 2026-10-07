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

    /// Per-request (idle) timeout. Applied to `sessionConfiguration` if non-nil.
    /// The default session uses 10s.
    public var requestTimeout: TimeInterval?

    /// Resource (end-to-end) timeout. Applied to `sessionConfiguration` if
    /// non-nil. The default session uses 30s. It applies to telemetry POSTs
    /// too, so keep it above `telemetryTimeout`.
    public var resourceTimeout: TimeInterval?

    /// Extra headers recomputed **per request** (proxy auth tokens rotate —
    /// Flagsmith #103). Marked `@Sendable` so the config can cross concurrency
    /// domains. Returns an empty dictionary by default.
    public var customHeaders: @Sendable () -> [String: String]

    /// Telemetry flush interval: one evaluation-summary window per tick.
    /// Default 60s (transport policy, uniform across SDKs).
    public var telemetryFlushInterval: TimeInterval

    /// Overall deadline for one telemetry POST while in the foreground,
    /// covering connect, TLS and the response. Default 15s (policy P1, mobile).
    /// The background final flush uses the shorter ~5s background-task budget.
    public var telemetryTimeout: TimeInterval

    /// Cap on the on-disk retained telemetry queue, in batches. Oldest is
    /// dropped past the cap. Default 5 (policy P5).
    public var telemetryMaxRetainedBatches: Int

    /// Cap on the on-disk retained telemetry queue, in bytes. Oldest is dropped
    /// past the cap; a single batch larger than this is never retained.
    /// Default 524,288 (512KB, policy P5 mobile).
    public var telemetryMaxRetainedBytes: Int

    /// A retained telemetry batch older than this is discarded at send time.
    /// Default 300s (5 min, policy P5).
    public var telemetryMaxRetainedAge: TimeInterval

    /// Cap on distinct `{key, type}` evaluation-summary counters in one window.
    /// New keys past the cap are not recorded; existing keys keep counting.
    /// Default 10,000 (policy P6).
    public var telemetryMaxEvaluationSummaries: Int

    /// Where the SDK writes its own diagnostic log lines (telemetry transport
    /// state changes and data loss). `nil` (default) logs through `os.Logger`
    /// (subsystem `com.quonfig.sdk`, category `Telemetry`), where DEBUG lines
    /// are not persisted unless you enable them.
    public var logSink: QuonfigLogSink?

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
        telemetryFlushInterval: TimeInterval = SummaryAggregator.defaultFlushInterval,
        telemetryTimeout: TimeInterval = SummaryAggregator.defaultTimeout,
        telemetryMaxRetainedBatches: Int = SummaryAggregator.defaultMaxRetainedBatches,
        telemetryMaxRetainedBytes: Int = SummaryAggregator.defaultMaxRetainedBytes,
        telemetryMaxRetainedAge: TimeInterval = SummaryAggregator.defaultMaxRetainedAge,
        telemetryMaxEvaluationSummaries: Int = SummaryAggregator.defaultMaxKeys,
        logSink: QuonfigLogSink? = nil,
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
        self.telemetryFlushInterval = telemetryFlushInterval
        self.telemetryTimeout = telemetryTimeout
        self.telemetryMaxRetainedBatches = telemetryMaxRetainedBatches
        self.telemetryMaxRetainedBytes = telemetryMaxRetainedBytes
        self.telemetryMaxRetainedAge = telemetryMaxRetainedAge
        self.telemetryMaxEvaluationSummaries = telemetryMaxEvaluationSummaries
        self.logSink = logSink
    }

    /// Default idle timeout for a request on the default session: how long a
    /// task waits for more data. Bounds how long a blackholed primary holds a
    /// poll before failover to the next API URL.
    static let defaultRequestTimeout: TimeInterval = 10

    /// Default end-to-end limit for a task on the default session, so a
    /// slow-drip response cannot hold the poller's single in-flight fetch
    /// forever. It caps telemetry POSTs too (same session), so it stays above
    /// the telemetry deadline (`SummaryAggregator.defaultTimeout`, 15s).
    static let defaultResourceTimeout: TimeInterval = 30

    /// Ephemeral session config with the URL cache disabled, per §2.3 — the
    /// eval URL carries the (possibly PII-bearing) context in its path, so it
    /// must never be persisted by `URLCache`. Request and resource timeouts are
    /// bounded (URLSession's own defaults are 60s idle and 7 days per task);
    /// `requestTimeout` / `resourceTimeout` override them.
    static func defaultSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = defaultRequestTimeout
        config.timeoutIntervalForResource = defaultResourceTimeout
        return config
    }
}

/// The longest sleep `sleepNanoseconds` returns: about 100 years.
///
/// It must stay well inside `Int64`, not just `UInt64`. Older Darwin
/// concurrency runtimes (the macOS 15 one, for example) hand the count to
/// `dispatch_time`'s signed delta, so `UInt64.max` became -1 ns and an
/// "infinite" sleep woke at once. 100 years plus the current uptime is far
/// from that overflow.
let maxSleepNanoseconds: UInt64 = 100 * 365 * 86_400 * 1_000_000_000

/// Seconds to `Task.sleep` nanoseconds, clamped so a configured interval can
/// never trap the conversion or overflow the runtime's deadline: NaN or a
/// non-positive value is 0, and anything longer than `maxSleepNanoseconds`
/// (`.infinity`, used to mean "effectively never") is `maxSleepNanoseconds`.
func sleepNanoseconds(_ seconds: TimeInterval) -> UInt64 {
    guard seconds > 0 else { return 0 }
    let nanos = seconds * 1_000_000_000
    guard nanos < Double(maxSleepNanoseconds) else { return maxSleepNanoseconds }
    return UInt64(nanos)
}
