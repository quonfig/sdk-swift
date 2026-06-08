import Foundation

/// The public Quonfig client — the `LDClient`/`StatsigClient` analog (plan §2.4).
///
/// Assembles the already-built, independently-tested components into the single
/// surface a consumer touches:
///
///   - `Loader` — fetches the `eval-with-context` envelope over HTTP with
///     ETag/304 and API-URL failover (qfg-2t2d.4).
///   - `Store` (actor) — owns the resolved snapshot; serves synchronous,
///     never-blocking typed getters; diffs-before-notify on subscribe
///     (qfg-2t2d.3).
///   - `Poller` — `DispatchSourceTimer` poll loop with dedup/coalesce +
///     generation counter (qfg-2t2d.6).
///   - `LifecycleCoordinator` — foreground-refresh / background-suspend seam
///     (qfg-2t2d.6).
///   - `Persistence` — versioned no-flicker cache served on cold start and on
///     error (qfg-2t2d.5).
///   - `SummaryAggregator` + `TelemetryUploader` — per-flag read counters
///     flushed on a backoff cadence and on background (qfg-2t2d.8).
///
/// `initialize` is `async throws` and **resolves once the first envelope is
/// available** — from the network, or, after a bounded `initTimeout`, from the
/// cold-start cache / empty defaults (the LD `startWaitSeconds` pattern,
/// §2.11). Reads are synchronous and never block (served from the in-memory
/// `Store` snapshot, §2.4).
public final class Quonfig: @unchecked Sendable {
    private let configuration: Configuration
    private let loader: Loader
    private let store: Store
    private let poller: Poller
    private let lifecycle: LifecycleCoordinator
    private let persistence: Persistence?
    private let aggregator: SummaryAggregator?
    private let fingerprintFn: ContextFingerprintFn

    /// The cache key + fingerprint the poller's persist step writes under. Updated
    /// by `updateContext` so a post-switch poll persists under the NEW context's
    /// fingerprint, not the old one. Shared by reference with the poller's fetch
    /// closure built in `initialize`.
    private let fingerprintBox: FingerprintBox

    /// Cache namespace for `(envKey, contextFingerprint)` — distinguishes this
    /// client's SDK key / environment so two clients in one process never collide.
    private let envKey: String

    /// The current context, behind a lock-guarded box so reads/writes are tear-free
    /// across threads without calling `NSLock.lock()` from an async context (a hard
    /// error in Swift 6 mode). Mirrors the `SnapshotBox` pattern in `Store`.
    private let contextBox: ContextBox

    /// The exposed `Store` so callers can hold the same actor for advanced use
    /// (e.g. a SwiftUI wrapper); the typed getters below forward to it.
    public var configStore: Store { store }

    /// Designated initializer used internally by `initialize`. Consumers should
    /// call `Quonfig.initialize(...)` rather than this directly.
    init(
        configuration: Configuration,
        context: QuonfigContext,
        loader: Loader,
        store: Store,
        poller: Poller,
        lifecycle: LifecycleCoordinator,
        persistence: Persistence?,
        aggregator: SummaryAggregator?,
        fingerprintFn: @escaping ContextFingerprintFn,
        fingerprintBox: FingerprintBox
    ) {
        self.configuration = configuration
        self.contextBox = ContextBox(context)
        self.loader = loader
        self.store = store
        self.poller = poller
        self.lifecycle = lifecycle
        self.persistence = persistence
        self.aggregator = aggregator
        self.fingerprintFn = fingerprintFn
        self.fingerprintBox = fingerprintBox
        self.envKey = Quonfig.envKey(for: configuration)
    }

    /// A stable per-(key,domain) namespace for the persistence cache. Hashed so an
    /// SDK key never lands on disk in cleartext as a cache key.
    static func envKey(for configuration: Configuration) -> String {
        sha256Hex("\(configuration.sdkKey)|\(configuration.domain)")
    }

    // MARK: - Initialization

    /// Initialize a client and resolve once the first envelope is available.
    ///
    /// Mirrors the §2.4 sketch:
    /// ```swift
    /// let quonfig = try await Quonfig.initialize(
    ///     sdkKey: "qf_ck_…",
    ///     context: QuonfigContext(["user": ["key": .string("u_123")]]),
    ///     options: .init(sdkKey: "qf_ck_…", domain: "quonfig.com")
    /// )
    /// ```
    ///
    /// Behavior:
    ///   1. Serve any **cold-start cache** for this context synchronously, so reads
    ///      return last-known values before the first network round-trip (§2.7).
    ///   2. Race the first network fetch against `initTimeout`. On success, apply
    ///      the fresh envelope and persist it. On timeout/failure, fall back to the
    ///      cache (already applied) or empty defaults — `initialize` still resolves
    ///      (the LD `startWaitSeconds` pattern; a hung init blocks the UI, §2.11).
    ///   3. Start the lifecycle-driven poll loop and the telemetry flush loop.
    ///
    /// - Parameters:
    ///   - sdkKey: convenience — if `options` is omitted, a default `Configuration`
    ///     is built from this key. If `options` is supplied, its `sdkKey` wins.
    ///   - context: the multi-namespace evaluation context.
    ///   - options: full init options. Defaults to `Configuration(sdkKey:)`.
    ///   - initTimeout: bounded wait for the first network envelope (default 5s).
    ///   - fingerprint: injectable context→cache-key function (Statsig's
    ///     `customCacheKey` lesson). Defaults to SHA256-of-canonical-JSON.
    @discardableResult
    public static func initialize(
        sdkKey: String? = nil,
        context: QuonfigContext,
        options: Configuration? = nil,
        initTimeout: TimeInterval = 5,
        fingerprint: @escaping ContextFingerprintFn = defaultContextFingerprint
    ) async throws -> Quonfig {
        let configuration: Configuration
        if let options {
            configuration = options
        } else if let sdkKey {
            configuration = Configuration(sdkKey: sdkKey)
        } else {
            throw QuonfigInitError.missingSDKKey
        }

        // Build the production collaborators (real URLSession-backed loader +
        // telemetry uploader, real UserDefaults/file persistence) and delegate to
        // the injectable `make`. Tests call `make` directly with mocks.
        let loader = Loader(configuration: configuration, context: context)
        let persistence: Persistence? = Persistence()
        var aggregator: SummaryAggregator?
        if configuration.collectEvaluationSummaries {
            aggregator = SummaryAggregator(
                uploader: TelemetryUploader(configuration: configuration),
                instanceHash: UUID().uuidString)
        }

        return await make(
            configuration: configuration,
            context: context,
            loader: loader,
            persistence: persistence,
            aggregator: aggregator,
            lifecycleProvider: SystemLifecycleProvider(),
            initTimeout: initTimeout,
            fingerprint: fingerprint
        )
    }

    /// Injectable assembly seam — builds the client from pre-constructed
    /// collaborators so tests can supply a mock `HTTPClient`-backed `Loader`, an
    /// in-memory `Persistence`, and a synthetic `LifecycleProvider` without any
    /// network or filesystem. The public `initialize` is a thin wrapper that
    /// builds the production collaborators and calls this.
    static func make(
        configuration: Configuration,
        context: QuonfigContext,
        loader: Loader,
        persistence: Persistence?,
        aggregator: SummaryAggregator?,
        lifecycleProvider: LifecycleProvider,
        initTimeout: TimeInterval,
        fingerprint: @escaping ContextFingerprintFn
    ) async -> Quonfig {
        let store = Store()

        // Wire telemetry (the only client-side telemetry component is the
        // evaluation-summary aggregator — context shapes/examples are server-side
        // via collectContextMode, §2.8). Disabled when the toggle is off / nil.
        if let aggregator {
            // Each EXPOSED read fans an exposure to the aggregator via a detached
            // Task so a read never blocks on telemetry (§2.8). The store stores
            // this closure behind a lock; setting it is actor-isolated.
            await store.setExposureRecorder { key, details in
                Task { await aggregator.record(key: key, details: details) }
            }
        }

        let envKey = Quonfig.envKey(for: configuration)
        let initialFingerprint = fingerprint(context)

        // 1. Cold-start: serve the cached envelope for this context synchronously
        //    (no flicker) before the network returns (§2.7).
        if let cached = persistence?.load(envKey: envKey, fingerprint: initialFingerprint) {
            await store.apply(cached)
        }

        // The poller's fetch closure pulls one envelope through the loader and
        // applies + persists it. It reads context/fingerprint fresh from the
        // client each tick (never captures a snapshot) so updateContext is honored
        // (Unleash #68). Built before `client` exists, so it captures the
        // collaborators directly and re-derives the fingerprint via the loader's
        // current context through a boxed reference set just below.
        let fingerprintBox = FingerprintBox(envKey: envKey, fingerprint: initialFingerprint)
        let fetch: Poller.Fetch = { [weak store, weak persistence] in
            guard let store else { return }
            let result = try await loader.load()
            await store.apply(loaderResult: result)
            // Persist the fresh (or 304-confirmed) envelope under the CURRENT
            // fingerprint so a later cold start / serve-on-error has it.
            persistence?.save(
                envelope: result.envelope,
                envKey: fingerprintBox.envKey,
                fingerprint: fingerprintBox.fingerprint
            )
        }

        let poller = Poller(fetch: fetch)

        // Background flush hook: on background entry, force-flush + disk-persist
        // the telemetry queue (disk write before network, §2.8 / Statsig 1.56.0).
        let lifecycle = LifecycleCoordinator(
            provider: lifecycleProvider,
            poller: poller,
            pollInterval: configuration.pollInterval,
            onBackground: { [weak aggregator] in
                await aggregator?.flushOnBackground()
            }
        )

        let client = Quonfig(
            configuration: configuration,
            context: context,
            loader: loader,
            store: store,
            poller: poller,
            lifecycle: lifecycle,
            persistence: persistence,
            aggregator: aggregator,
            fingerprintFn: fingerprint,
            fingerprintBox: fingerprintBox
        )

        // 2. Race the first fetch against the bounded init timeout. Whichever
        //    finishes first lets `initialize` return; the loser is ignored. On
        //    success the envelope is applied + persisted; on timeout/failure the
        //    already-applied cache (or empty defaults) stands.
        await client.firstFetchOrTimeout(
            loader: loader,
            store: store,
            persistence: persistence,
            envKey: envKey,
            fingerprint: initialFingerprint,
            timeout: initTimeout
        )

        // 3. Start the poll cadence (lifecycle assumes foreground at launch) and
        //    the telemetry flush loop.
        lifecycle.start()
        await aggregator?.start()

        return client
    }

    /// Race the first network fetch against a bounded timeout. Returns when either
    /// completes; never throws (the cache / empty defaults are the fallback).
    private func firstFetchOrTimeout(
        loader: Loader,
        store: Store,
        persistence: Persistence?,
        envKey: String,
        fingerprint: String,
        timeout: TimeInterval
    ) async {
        let fetchTask = Task { () -> Bool in
            do {
                let result = try await loader.load()
                await store.apply(loaderResult: result)
                persistence?.save(
                    envelope: result.envelope, envKey: envKey, fingerprint: fingerprint)
                return true
            } catch {
                return false
            }
        }

        let timeoutTask = Task { () -> Void in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
        }

        // Wait for whichever finishes first. We await the timeout, then check the
        // fetch; if the fetch already completed we're done immediately, otherwise
        // we let it keep running in the background (its result still applies).
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await fetchTask.value }
            group.addTask { await timeoutTask.value }
            // Return after the FIRST child finishes (init unblocks), cancel the
            // outstanding timeout but NOT the fetch (let a slow fetch still land).
            _ = await group.next()
            timeoutTask.cancel()
            group.cancelAll()
        }

        // If neither cache nor network produced an envelope, flip the store to
        // ready with an empty envelope so getters return caller defaults rather
        // than hanging on `isReady == false` (LD startWaitSeconds fallback).
        if !store.isReady {
            await store.apply(EvalEnvelope(
                evaluations: [:],
                meta: EvalMeta(version: "", environment: "", workspaceId: nil)))
        }
    }

    // MARK: - Synchronous typed getters (forward to the Store snapshot)

    /// `true` once any envelope (network or cache) has been applied.
    public var isReady: Bool { store.isReady }

    /// Whether a flag is enabled (`value === true`; `false` otherwise).
    public func isEnabled(_ key: String, logExposure: Bool = true) -> Bool {
        store.isEnabled(key, logExposure: logExposure)
    }

    /// String value, or the caller-supplied default if absent / wrong type.
    public func string(_ key: String, default def: String, logExposure: Bool = true) -> String {
        store.string(key, default: def, logExposure: logExposure)
    }

    /// Int value, or the caller-supplied default. Whole doubles coerce to int.
    public func int(_ key: String, default def: Int, logExposure: Bool = true) -> Int {
        store.int(key, default: def, logExposure: logExposure)
    }

    /// Double value, or the caller-supplied default. Ints widen to double.
    public func double(_ key: String, default def: Double, logExposure: Bool = true) -> Double {
        store.double(key, default: def, logExposure: logExposure)
    }

    /// JSON object value, or `nil` if absent / not an object.
    public func json(_ key: String) -> [String: Any]? {
        store.json(key)
    }

    /// Full resolution details (value + reason + ruleIndex + variant) for a key.
    public func details(_ key: String) -> EvaluationDetails {
        store.details(key)
    }

    // MARK: - Subscribe

    /// React to live updates (SwiftUI-friendly). The closure fires after every
    /// *change* to the resolved envelope (diff-before-notify, so unchanged polls
    /// don't churn). Returns a token; cancel it (or drop it) to unsubscribe.
    @discardableResult
    public func subscribe(_ listener: @escaping @Sendable () -> Void) async -> SubscriptionToken {
        await store.subscribe(listener)
    }

    // MARK: - updateContext

    /// Switch identity: point the loader at the new context, immediately refetch
    /// its evaluated envelope, and resume the poll cadence (Unleash's stop +
    /// refetch + restart; PostHog auto-refetch-on-identify). Serves the new
    /// context's cold cache synchronously first so the UI doesn't flicker defaults
    /// during the refetch.
    public func updateContext(_ context: QuonfigContext) async throws {
        let fp = fingerprintFn(context)

        contextBox.value = context

        // The poller's persist step writes under whatever fingerprint this box
        // holds — update it so a post-switch poll persists under the NEW context.
        fingerprintBox.fingerprint = fp

        // Point the loader at the new context BEFORE refetching.
        await loader.updateContext(context)

        // Serve the new context's cached envelope (if any) right away (§2.7).
        if let cached = persistence?.load(envKey: envKey, fingerprint: fp) {
            await store.apply(cached)
        }

        // Immediate refetch under a bumped generation; the poller discards any
        // slow in-flight fetch for the OLD context (Statsig #1/#36). The poller's
        // fetch closure persists the freshly-resolved envelope itself, so there is
        // nothing more to write here.
        await poller.updateContext()
    }

    /// The current evaluation context (thread-safe read).
    public var context: QuonfigContext {
        contextBox.value
    }

    // MARK: - Test hooks

    /// Run a single immediate poll fetch (the catch-up the lifecycle seam fires on
    /// foreground). Internal — used by tests to drive a deterministic poll without
    /// waiting on the timer cadence.
    func refreshForTesting() async {
        await poller.refreshNow()
    }

    // MARK: - Shutdown

    /// Stop polling, stop the telemetry loop (force-flushing one last window), and
    /// remove the lifecycle observers. Idempotent.
    public func shutdown() async {
        lifecycle.stop()
        await poller.stop()
        await aggregator?.flush()
        await aggregator?.stop()
    }
}

/// Errors thrown by `Quonfig.initialize`.
public enum QuonfigInitError: Error, Sendable, Equatable {
    /// Neither an `sdkKey` nor an `options` carrying one was supplied.
    case missingSDKKey
}

/// A tiny `@unchecked Sendable` box carrying the cache key + fingerprint the
/// poller's persist step writes under. Mutated only via `updateContext`'s lock on
/// the client, read on the poller's queue. (Today the fingerprint is fixed per
/// context; the box exists so a future per-tick fingerprint refresh has a seam.)
final class FingerprintBox: @unchecked Sendable {
    private let lock = NSLock()
    let envKey: String
    private var _fingerprint: String
    var fingerprint: String {
        get { lock.lock(); defer { lock.unlock() }; return _fingerprint }
        set { lock.lock(); _fingerprint = newValue; lock.unlock() }
    }
    init(envKey: String, fingerprint: String) {
        self.envKey = envKey
        self._fingerprint = fingerprint
    }
}

/// Lock-guarded holder for the client's current `QuonfigContext`. Mirrors the
/// `SnapshotBox` pattern in `Store`: a tear-free read/write across threads that
/// never calls `NSLock.lock()` from an async context (a Swift 6 hard error).
private final class ContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: QuonfigContext
    init(_ value: QuonfigContext) { self._value = value }
    var value: QuonfigContext {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
