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
/// conditional GETs and ordered API-URL failover.
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
        let encoded = try context.encodedPathSegment()
        // Trim a trailing slash on the base (loader.ts does `.replace(/\/$/, "")`).
        var base = apiURL.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        let s = "\(base)/api/v2/configs/eval-with-context/\(encoded)"
            + "?collectContextMode=\(collectContextMode.rawValue)"
        guard let u = URL(string: s) else {
            throw QuonfigContextError.encodingFailed
        }
        return u
    }

    /// Load the envelope, trying each API URL in order (failover) and returning
    /// the first success. Mirrors `loader.ts` `loadWithFailover`.
    public func load() async throws -> LoaderResult {
        var lastError: Error?
        for apiURL in apiURLs {
            do {
                return try await fetch(from: apiURL)
            } catch {
                lastError = error
            }
        }
        let message = lastError.map { "\($0)" } ?? "All API URLs failed"
        throw QuonfigLoaderError.allURLsFailed(message)
    }

    private func fetch(from apiURL: URL) async throws -> LoaderResult {
        let url = try url(apiURL: apiURL)
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
