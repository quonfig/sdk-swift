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
///     flushed every 60s and on background, retained on disk (qfg-2t2d.8,
///     transport policy qfg-y8je.12).
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

    /// Serializes `updateContext` calls, so two overlapping switches cannot leave
    /// the loader on one context and the store tagged with another.
    private let contextSwitchLock = AsyncSerialLock()

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
        fingerprintFn: @escaping ContextFingerprintFn
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
            // The 0.0.1 single-file queue is superseded by the per-batch queue.
            TelemetryFileQueueStore.removeLegacyQueue()
            // A fresh instanceHash per launch is fine: retained batches are
            // resent byte-for-byte, carrying the hash they were built with.
            aggregator = SummaryAggregator(
                uploader: TelemetryUploader(configuration: configuration),
                instanceHash: UUID().uuidString,
                maxKeys: configuration.telemetryMaxEvaluationSummaries,
                policy: TelemetryTransportPolicy(configuration: configuration),
                queueStore: TelemetryFileQueueStore(directory: TelemetryFileQueueStore.directory(for: configuration)),
                logSink: configuration.logSink)
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
        fingerprint: @escaping ContextFingerprintFn,
        backgroundTaskRunner: BackgroundTaskRunner = ExpiringActivityRunner()
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
        await store.setContextTag(initialFingerprint)

        // 1. Cold-start: serve the cached envelope for this context synchronously
        //    (no flicker) before the network returns (§2.7).
        if let cached = persistence?.load(envKey: envKey, fingerprint: initialFingerprint) {
            await store.apply(cached)
        }

        // The poller's fetch closure pulls one envelope through the loader for
        // the loader's current context (never a captured snapshot, so
        // updateContext is honored, Unleash #68), then applies + persists it only
        // if that context is still current (qfg-goi1.2.3).
        let fetch: Poller.Fetch = { [weak store, weak persistence] in
            guard let store else { return }
            try await fetchApplyPersist(
                loader: loader, store: store, persistence: persistence, envKey: envKey,
                fingerprint: fingerprint)
        }

        let poller = Poller(fetch: fetch)

        // Background flush hook (policy P8): inside a ~5s background task, write
        // the live telemetry window to disk, then POST it once (disk before
        // network, §2.8 / Statsig 1.56.0). The retained queue is not drained.
        let lifecycle = LifecycleCoordinator(
            provider: lifecycleProvider,
            poller: poller,
            pollInterval: configuration.pollInterval,
            onBackground: { [weak aggregator] in
                guard let aggregator else { return }
                await backgroundTaskRunner.run(
                    reason: "Quonfig telemetry flush", budget: SummaryAggregator.backgroundFlushBudget
                ) {
                    await aggregator.flushOnBackground()
                }
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
            fingerprintFn: fingerprint
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
            timeout: initTimeout
        )

        // 3. Start the poll cadence (lifecycle assumes foreground at launch) and
        //    the telemetry flush loop.
        lifecycle.start()
        await aggregator?.start()

        return client
    }

    /// Fetch one envelope for the loader's current context, then apply it and
    /// persist it under that context's fingerprint, but only while that context
    /// is still the client's current one (qfg-goi1.2.3). A result for a context
    /// that `updateContext` has since switched away from is discarded: it is
    /// neither served nor written to any cache. Returns `false` for such a
    /// discarded result. A current-context result is persisted even when the
    /// store's reject-older guard refuses it; `Persistence.save` applies the same
    /// generation watermark, so the disk cache never moves backwards.
    @discardableResult
    static func fetchApplyPersist(
        loader: Loader,
        store: Store,
        persistence: Persistence?,
        envKey: String,
        fingerprint: ContextFingerprintFn
    ) async throws -> Bool {
        let (context, result) = try await loader.loadForCurrentContext()
        let fp = fingerprint(context)
        guard await store.applyIfCurrent(result, contextTag: fp) else { return false }
        // Persist the fresh (or 304-confirmed) envelope under the fingerprint of
        // the context it was fetched for, so a later cold start / serve-on-error
        // has it.
        persistence?.save(envelope: result.envelope, envKey: envKey, fingerprint: fp)
        return true
    }

    /// Race the first network fetch against a bounded timeout. Returns when either
    /// completes; never throws (the cache / empty defaults are the fallback).
    private func firstFetchOrTimeout(
        loader: Loader,
        store: Store,
        persistence: Persistence?,
        envKey: String,
        timeout: TimeInterval
    ) async {
        let fingerprint = fingerprintFn
        let fetchTask = Task { () -> Bool in
            do {
                // Same context check as the poll: if this fetch outlives
                // initialize and the app switches context, it is discarded.
                return try await Quonfig.fetchApplyPersist(
                    loader: loader, store: store, persistence: persistence, envKey: envKey,
                    fingerprint: fingerprint)
            } catch {
                return false
            }
        }

        let timeoutTask = Task { () -> Void in
            try? await Task.sleep(nanoseconds: sleepNanoseconds(timeout))
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
            await store.apply(
                EvalEnvelope(
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

    /// String-list value, or the caller-supplied default if absent / wrong type.
    public func stringList(_ key: String, default def: [String], logExposure: Bool = true) -> [String] {
        store.stringList(key, default: def, logExposure: logExposure)
    }

    /// Duration value in seconds, or the caller-supplied default if absent, not a
    /// duration config, or a value outside the ISO-8601 grammar (`PT30S`,
    /// `P1DT6H`, `PT1.5S`, ...). A malformed value logs one warning per key.
    public func duration(_ key: String, default def: TimeInterval, logExposure: Bool = true) -> TimeInterval {
        store.duration(key, default: def, logExposure: logExposure)
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
    /// Hold the token for as long as you want updates: a discarded token
    /// unsubscribes at once, so the compiler warns on an unused result.
    public func subscribe(_ listener: @escaping @Sendable () -> Void) async -> SubscriptionToken {
        await store.subscribe(listener)
    }

    // MARK: - updateContext

    /// Switch identity: point the loader at the new context, immediately refetch
    /// its evaluated envelope, and resume the poll cadence (Unleash's stop +
    /// refetch + restart; PostHog auto-refetch-on-identify).
    ///
    /// The previous context's values stop being served at once: the store
    /// switches to the new context's cached envelope (no flicker for a
    /// previously-seen context), or to caller defaults when there is none, until
    /// the refetch lands. A fetch for the previous context that is still in
    /// flight is discarded when it lands, never served or persisted under the
    /// new context (qfg-goi1.2.3).
    public func updateContext(_ context: QuonfigContext) async throws {
        let fp = fingerprintFn(context)

        // The switch itself (context, loader, store) is serialized, so two
        // overlapping calls cannot leave the loader on one context and the store
        // tagged with another. The lock covers only these in-memory steps, never
        // the network refetch below: a second switch (a logout, say) must not
        // wait behind the first switch's slow fetch.
        await contextSwitchLock.withLock {
            self.contextBox.value = context

            // Point the loader at the new context BEFORE refetching.
            await self.loader.updateContext(context)

            // Serve the new context's cached envelope, or caller defaults, right
            // away (§2.7). Unconditional: the held generation watermark belongs to
            // the previous context, so the reject-older guard must not compare
            // against it. A no-op when `fp` is already the current context.
            await self.store.resetForContextSwitch(
                to: self.persistence?.load(envKey: self.envKey, fingerprint: fp), contextTag: fp)
        }

        // Immediate refetch for the new context. If a fetch for the old context
        // is in flight, the refetch runs as soon as it lands. The fetch closure
        // reads the loader's current context and checks the store's tag itself,
        // so it needs no lock, and persists the freshly-resolved envelope.
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

    /// Stop polling, stop the telemetry loop, give the live telemetry window one
    /// final POST (written to disk first, ~5s budget; the retained queue is not
    /// drained), and remove the lifecycle observers. Idempotent.
    public func shutdown() async {
        lifecycle.stop()
        await poller.stop()
        await aggregator?.stop()
        await aggregator?.flushOnBackground()
    }
}

/// Errors thrown by `Quonfig.initialize`.
public enum QuonfigInitError: Error, Sendable, Equatable {
    /// Neither an `sdkKey` nor an `options` carrying one was supplied.
    case missingSDKKey
}

/// A FIFO async mutex. Actors are reentrant across `await`, so an actor method
/// alone cannot keep a multi-step `updateContext` atomic; callers run the steps
/// inside `withLock`, which always releases, even when the body throws.
final actor AsyncSerialLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Run `body` while holding the lock. The lock is released on every exit
    /// path, including a throw.
    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    func release() {
        if waiters.isEmpty {
            held = false
        } else {
            // Ownership passes straight to the next waiter; `held` stays true.
            waiters.removeFirst().resume()
        }
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
