import Foundation

#if canImport(FoundationNetworking)
    // Linux-Swift splits URLSession into FoundationNetworking (plan §2.10: cheap
    // insurance for Swift-on-server test harnesses — Flagsmith #21).
    import FoundationNetworking
#endif

/// The slice of `URLSession` the loader depends on, behind a protocol so tests
/// can inject a mock (plan §2.10 "Inject URLSession via a protocol").
///
/// `URLSession` conforms to this in an extension below. The method mirrors the
/// async `data(for:)` API: it returns the raw `Data` and the `URLResponse` so the
/// loader can read the status code and headers itself.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {
    #if canImport(FoundationNetworking)
        // On Linux the async `data(for:)` is not always available; bridge the
        // completion-handler API so the same protocol method works everywhere.
        public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                let task = self.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: QuonfigLoaderError.noResponse)
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                task.resume()
            }
        }
    #endif
}

/// Errors surfaced by the loader.
public enum QuonfigLoaderError: Error, Sendable, Equatable {
    /// The response was not an `HTTPURLResponse` (no status code available).
    case nonHTTPResponse
    /// No response/data came back from the transport (Linux bridge guard).
    case noResponse
    /// A non-2xx / non-304 / non-204 status. Carries the status code.
    case httpStatus(Int)
    /// All configured API URLs failed; carries the last underlying error string.
    case allURLsFailed(String)
    /// A 304/204 arrived but the loader had no cached payload to return (should
    /// be impossible — we only send `If-None-Match` when we hold a cache entry).
    case notModifiedWithoutCache
}

/// One failover leg's outcome: its index in `apiURLs` and the HTTP status it
/// returned (`0` when no HTTP response came back: a transport error or timeout).
struct LegStatus: Sendable, Equatable {
    let index: Int
    let status: Int
}

/// A fetch cycle in which every leg failed and the primary (first) leg answered
/// with an auth-class status (401/403/404/410), with no 2xx or 304 on any leg
/// (qfg-goi1.10.30, plan 2026-10-07-sdk-auth-failure-rule.md R1). Thrown only
/// by `loadForCurrentContext`, for the poller's auth-failure rule; the public
/// `load()` rethrows `underlying`, so its error is unchanged. The init decides
/// "unauthorized" only when `everyLegRejected` (decision D1).
struct AuthRejectedError: Error, Sendable {
    /// The primary leg's status.
    let status: Int
    /// The primary API host as `host:port`. Never the SDK key.
    let host: String
    /// Every leg's outcome, in order.
    let legs: [LegStatus]
    /// Every configured leg answered auth-class (not just the primary).
    let everyLegRejected: Bool
    /// The error `load()` throws for the same cycle.
    let underlying: QuonfigLoaderError
}

/// Result of a `Loader.load`.
///
/// `envelope` ALWAYS holds the evaluations for the context that was just
/// requested — a fresh body on a 200, or the body cached from this context's
/// previous 200 on a 304/204. Mirrors `sdk-javascript/src/loader.ts`
/// `LoaderResult`: a 304 that returned no payload would leave the caller serving
/// the WRONG context's values, so we return the matching cached envelope.
///
/// `notModified` is the optimization hint: `true` means the server confirmed this
/// exact (context, version) is unchanged.
public struct LoaderResult: Sendable, Equatable {
    public let notModified: Bool
    public let envelope: EvalEnvelope

    public init(notModified: Bool, envelope: EvalEnvelope) {
        self.notModified = notModified
        self.envelope = envelope
    }
}

/// Fetches the `eval-with-context` envelope over HTTP with ETag/`If-None-Match`
/// conditional GETs and a hedged primary/secondary fetch.
///
/// Mirrors `sdk-javascript/src/loader.ts`, with the iOS-specific ETag/304
/// short-circuit (plan §2.11 drift table — JS has none yet; server support
/// shipped 2026-06-03) and the §2.10 hardening defenses baked in:
///   - Reads the ETag via `HTTPURLResponse.value(forHTTPHeaderField:)`
///     (case-insensitive), NOT `allHeaderFields["ETag"]` (Unleash #6).
///   - Treats HTTP 304 AND 204 identically as "no change, no body re-download"
///     (Unleash #24 — some proxies return 204 for 304).
///   - Percent-encodes the context path segment against the RFC 3986 unreserved
///     set so `+` can never reach the server's path decoder (Unleash #67 — done
///     in `Context.encodedPathSegment()`).
///   - URL cache disabled on the session config (`urlCache = nil`, §2.3 privacy)
///     — owned by `Configuration.defaultSessionConfiguration()`.
///
/// The loader is an `actor` so its per-URL ETag/payload cache is mutated safely
/// from concurrent callers under `StrictConcurrency=complete`.
public actor Loader {
    private let sdkKey: String
    private let apiURLs: [URL]
    private let collectContextMode: CollectContextMode
    private let clientVersion: String
    private let userAgent: String
    private let customHeaders: @Sendable () -> [String: String]
    private let client: HTTPClient

    /// The context the loader currently fetches for. Mutable so `updateContext`
    /// (qfg-2t2d.6) can switch identities between polls.
    private var context: QuonfigContext

    /// The last fetch cycle's per-leg failures, for the init log lines
    /// (`primary=<host:port>: <error>; secondary=...`). Hosts and short error
    /// classes only: never the SDK key or the context-carrying request URL.
    /// `nil` until a cycle fails; cleared by a successful cycle.
    private(set) var lastFailureSummary: String?

    /// Whether any leg of the current (or, between cycles, the last) fetch
    /// cycle failed fast: a refusal, an HTTP status, an undecodable body. A
    /// cycle with none hung: every leg that ended timed out, and any leg still
    /// in flight is hanging (decision D2). `false` before the first cycle.
    private(set) var cycleHadFastFailure = false

    /// How long a fetch cycle waits on the legs in flight before it also fires
    /// the next API URL (the hedge). Matches the other SDKs' 2s default.
    static let defaultHedgeDelay: TimeInterval = 2
    private(set) var hedgeDelay: TimeInterval = Loader.defaultHedgeDelay

    /// Test hook: shorten the hedge delay.
    func setHedgeDelay(_ delay: TimeInterval) { hedgeDelay = delay }

    /// Per-URL `{ etag, envelope }` cache from prior 200 responses, keyed by the
    /// FULL request URL string (which embeds the encoded context). Keying per-URL
    /// is the safety invariant (mirrors loader.ts): an ETag is only ever replayed
    /// to the exact URL that minted it, so a context switch (a different URL) can
    /// never get a wrong 304. Bounded LRU so it can't grow without limit as
    /// contexts change.
    private struct CacheEntry: Sendable {
        let etag: String
        let envelope: EvalEnvelope
    }
    private var cache: [String: CacheEntry] = [:]
    /// Insertion/recency order for the LRU (oldest first).
    private var lru: [String] = []
    private static let cacheLimit = 16

    private let decoder = JSONDecoder()

    public init(
        sdkKey: String,
        context: QuonfigContext,
        apiURLs: [URL],
        collectContextMode: CollectContextMode = .periodicExample,
        clientVersion: String = quonfigVersion,
        userAgent: String? = nil,
        customHeaders: @escaping @Sendable () -> [String: String] = { [:] },
        client: HTTPClient
    ) {
        precondition(!apiURLs.isEmpty, "apiURLs must not be empty")
        self.sdkKey = sdkKey
        self.context = context
        self.apiURLs = apiURLs
        self.collectContextMode = collectContextMode
        self.clientVersion = clientVersion
        // `quonfigUserAgent()` is internal; computing it in the body keeps it out
        // of the public default-argument expression.
        self.userAgent = userAgent ?? quonfigUserAgent()
        self.customHeaders = customHeaders
        self.client = client
    }

    /// Convenience initializer resolving URLs + session from a `Configuration`.
    public init(configuration: Configuration, context: QuonfigContext) {
        let urls = QuonfigURLs.resolve(from: configuration)
        let session = URLSession(configuration: configuration.sessionConfiguration)
        self.init(
            sdkKey: configuration.sdkKey,
            context: context,
            apiURLs: urls.apiURLs,
            collectContextMode: configuration.collectContextMode,
            clientVersion: quonfigVersion,
            userAgent: nil,
            customHeaders: configuration.customHeaders,
            client: session
        )
    }

    /// Switch the context the loader fetches for (qfg-2t2d.6 will drive this).
    public func updateContext(_ context: QuonfigContext) {
        self.context = context
    }

    /// The full request URL for a given API base:
    /// `<base>/api/v2/configs/eval-with-context/<encodedCtx>?collectContextMode=<mode>`.
    ///
    /// Mirrors `loader.ts` `url()`. The encoded context comes from
    /// `Context.encodedPathSegment()` (base64url + RFC 3986 unreserved percent
    /// encoding — `+` never passes).
    func url(apiURL: URL) throws -> URL {
        try url(apiURL: apiURL, context: context)
    }

    private func url(apiURL: URL, context: QuonfigContext) throws -> URL {
        let encoded = try context.encodedPathSegment()
        // Trim a trailing slash on the base (loader.ts does `.replace(/\/$/, "")`).
        var base = apiURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        let s =
            "\(base)/api/v2/configs/eval-with-context/\(encoded)"
            + "?collectContextMode=\(collectContextMode.rawValue)"
        guard let u = URL(string: s) else {
            throw QuonfigContextError.encodingFailed
        }
        return u
    }

    /// Load the envelope over a hedged fetch across the API URLs and return
    /// the first success (see `loadForCurrentContext`).
    public func load() async throws -> LoaderResult {
        do {
            return try await loadForCurrentContext().result
        } catch let rejected as AuthRejectedError {
            throw rejected.underlying
        }
    }

    /// One leg's event in a hedged fetch cycle.
    private enum LegEvent: Sendable {
        /// The leg finished: its status (`0` with no HTTP answer) and result.
        case done(index: Int, status: Int, result: Result<LoaderResult, Error>)
        /// The hedge delay passed: fire the next leg.
        case hedge
    }

    /// `load()`, plus the context the request was built for (qfg-goi1.2.3).
    ///
    /// One cycle is a HEDGED fetch (spec 2026-10-05-init-failure-design.md,
    /// "Where failover fits"; qfg-9p4i.17.8): the primary fires at once; the
    /// next URL fires after `hedgeDelay`, or at once when every leg in flight
    /// has failed. The primary is never cancelled by the hedge. The first
    /// 2xx/304 wins and the other legs are cancelled. So a HUNG primary no
    /// longer keeps the secondary from being tried before the init deadline.
    ///
    /// The context is read once, before the first await, and used for every
    /// leg. An `updateContext` that lands while this request is in flight
    /// therefore cannot change which identity the result belongs to, and the
    /// client compares the returned context with its current one before it
    /// installs or persists the result.
    func loadForCurrentContext() async throws -> (context: QuonfigContext, result: LoaderResult) {
        let context = self.context
        let urls = apiURLs
        let delay = hedgeDelay
        cycleHadFastFailure = false

        var continuation: AsyncStream<LegEvent>.Continuation!
        let events = AsyncStream<LegEvent> { continuation = $0 }
        let sink = continuation!
        var legTasks: [Task<Void, Never>] = []
        var hedgeTask: Task<Void, Never>?
        defer {
            for task in legTasks { task.cancel() }
            hedgeTask?.cancel()
            sink.finish()
        }

        var next = 0
        var inFlight = 0
        func launchNext() {
            let index = next
            next += 1
            inFlight += 1
            let apiURL = urls[index]
            legTasks.append(
                Task {
                    let event = await self.fetchLeg(index: index, apiURL: apiURL, context: context)
                    sink.yield(event)
                })
            hedgeTask?.cancel()
            hedgeTask = nil
            if next < urls.count {
                hedgeTask = Task {
                    try? await Task.sleep(nanoseconds: sleepNanoseconds(delay))
                    if !Task.isCancelled { sink.yield(.hedge) }
                }
            }
        }

        var failures: [(index: Int, status: Int, error: Error)] = []
        launchNext()
        // `AsyncStream` iteration ends on its own when the calling task is
        // cancelled; the `defer` then cancels every leg.
        loop: for await event in events {
            switch event {
            case .hedge:
                if next < urls.count { launchNext() }
            case .done(let index, let status, let result):
                inFlight -= 1
                switch result {
                case .success(let value):
                    lastFailureSummary = nil
                    return (context, value)
                case .failure(let error):
                    failures.append((index, status, error))
                    if !Loader.isTimeout(error) { cycleHadFastFailure = true }
                    if failures.count == urls.count { break loop }
                    if inFlight == 0, next < urls.count { launchNext() }
                }
            }
        }

        if failures.isEmpty { throw CancellationError() }
        failures.sort { $0.index < $1.index }
        let legs = failures.map { LegStatus(index: $0.index, status: $0.status) }
        lastFailureSummary = failures.map {
            "\(Loader.legName($0.index))=\(Loader.hostPort(urls[$0.index])): \(Loader.shortError($0.error, status: $0.status))"
        }.joined(separator: "; ")
        let message = failures.last.map { Loader.redactUserinfo("\($0.error)") } ?? "All API URLs failed"
        let underlying = QuonfigLoaderError.allURLsFailed(message)
        let accepted = legs.contains { (200..<300).contains($0.status) || $0.status == 304 }
        // Every configured leg answered auth-class: the init decides
        // "unauthorized" only on this (decision D1).
        let everyLeg = !accepted && legs.count == urls.count && legs.allSatisfy { Loader.isAuthClass($0.status) }
        // Auth class for the poller (R1): the primary answered 401/403/404/410
        // and no leg answered 2xx or 304 (a 2xx that failed to decode, or a 304
        // with no cached body, still proves the key was accepted).
        if let primary = legs.first, primary.index == 0, Loader.isAuthClass(primary.status), !accepted {
            throw AuthRejectedError(
                status: primary.status, host: Loader.hostPort(urls[0]), legs: legs,
                everyLegRejected: everyLeg, underlying: underlying)
        }
        throw underlying
    }

    /// One leg as an event, so the hedged cycle can race it.
    private func fetchLeg(index: Int, apiURL: URL, context: QuonfigContext) async -> LegEvent {
        var status = 0
        do {
            let result = try await fetch(from: apiURL, context: context, status: &status)
            return .done(index: index, status: status, result: .success(result))
        } catch {
            return .done(index: index, status: status, result: .failure(error))
        }
    }

    /// Whether a leg ended on a transport timeout (a hang), as opposed to a
    /// fast error such as a refusal or an HTTP status.
    static func isTimeout(_ error: Error) -> Bool {
        (error as? URLError)?.code == .timedOut
    }

    /// Strips `user:pass@` userinfo from every URL in `text` (decision D4: a
    /// raw transport error can embed the failing URL).
    static func redactUserinfo(_ text: String) -> String {
        text.replacingOccurrences(
            of: "://[^/@\\s]+@", with: "://", options: .regularExpression)
    }

    /// `primary`, `secondary`, then `url3`, `url4`, ... for the log lines.
    static func legName(_ index: Int) -> String {
        switch index {
        case 0: return "primary"
        case 1: return "secondary"
        default: return "url\(index + 1)"
        }
    }

    /// A short, credential-free description of one leg's failure. A raw
    /// `URLError` description carries the request URL, whose path encodes the
    /// context, so only its code is kept.
    static func shortError(_ error: Error, status: Int) -> String {
        let accepted = (200..<300).contains(status) || status == 304
        if status > 0, !accepted { return "HTTP \(status)" }
        if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
        if let loaderError = error as? QuonfigLoaderError { return "\(loaderError)" }
        if error is DecodingError { return "HTTP \(status): undecodable response" }
        return String(describing: type(of: error))
    }

    /// 401/403/404/410: the statuses that say the SDK key is invalid or revoked.
    static func isAuthClass(_ status: Int) -> Bool {
        status == 401 || status == 403 || status == 404 || status == 410
    }

    /// `host:port` of an API base, with the scheme's default port when the URL
    /// has none. Carries no credentials (the key travels in a header).
    static func hostPort(_ url: URL) -> String {
        let host = url.host ?? "unknown"
        let port = url.port ?? (url.scheme == "http" ? 80 : 443)
        return "\(host):\(port)"
    }

    /// One leg. `status` is set to the HTTP status as soon as a response
    /// arrives, so the caller sees it even when this throws.
    private func fetch(
        from apiURL: URL, context: QuonfigContext, status: inout Int
    ) async throws -> LoaderResult {
        let url = try url(apiURL: apiURL, context: context)
        let key = url.absoluteString

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Belt-and-braces against any session-level caching of the context URL.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Base headers: HTTP Basic (username "u" -> frontend key), UA, Accept.
        request.setValue(authHeaderValue(sdkKey: sdkKey), forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Caller-supplied headers recomputed per request (rotating proxy tokens,
        // Flagsmith #103). Applied before If-None-Match so the SDK's own header
        // always wins.
        for (k, v) in customHeaders() {
            request.setValue(v, forHTTPHeaderField: k)
        }

        // Conditional GET: replay the ETag minted by THIS url's prior 200.
        let cached = cache[key]
        if let cached {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await client.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuonfigLoaderError.nonHTTPResponse
        }
        status = http.statusCode

        // 304 AND 204 are both "no change, no body re-download" (Unleash #24).
        if http.statusCode == 304 || http.statusCode == 204 {
            guard let cached else {
                // We only ever send If-None-Match when we hold a cache entry, so
                // this should be unreachable. Drop any entry so the next poll does
                // a full GET, and surface an error so this URL fails over.
                evict(key)
                throw QuonfigLoaderError.notModifiedWithoutCache
            }
            return LoaderResult(notModified: true, envelope: cached.envelope)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw QuonfigLoaderError.httpStatus(http.statusCode)
        }

        let envelope = try decoder.decode(EvalEnvelope.self, from: data)

        // Read the ETag case-insensitively (Unleash #6 — never allHeaderFields).
        if let etag = http.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
            remember(key: key, entry: CacheEntry(etag: etag, envelope: envelope))
        } else {
            // Server stopped sending an ETag — forget any prior entry so we don't
            // keep revalidating against a header it no longer honors.
            evict(key)
        }

        return LoaderResult(notModified: false, envelope: envelope)
    }

    // MARK: - Bounded LRU cache

    private func remember(key: String, entry: CacheEntry) {
        if cache[key] != nil {
            lru.removeAll { $0 == key }
        }
        cache[key] = entry
        lru.append(key)
        while lru.count > Loader.cacheLimit {
            let oldest = lru.removeFirst()
            cache[oldest] = nil
        }
    }

    private func evict(_ key: String) {
        cache[key] = nil
        lru.removeAll { $0 == key }
    }

    /// Test hook: number of cached entries.
    var cacheCount: Int { cache.count }
}
