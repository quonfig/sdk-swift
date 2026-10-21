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
/// `initialize` is `async throws` and **resolves once config is available**:
/// from the network, or, after a bounded `initTimeout`, from the cold-start
/// disk cache (a cached copy counts as config). With neither, the
/// `onInitFailure` mode decides: `.fail` (the default) throws, `.wait` keeps
/// waiting, `.continue` starts on code defaults (qfg-9p4i.11). Reads are
/// synchronous and never block (served from the in-memory `Store` snapshot,
/// §2.4).
public final class Quonfig: @unchecked Sendable {
    private let configuration: Configuration
    private let loader: Loader
    private let store: Store
    private let poller: Poller
    private let lifecycle: LifecycleCoordinator
    private let persistence: Persistence?
    private let aggregator: SummaryAggregator?
    private let fingerprintFn: ContextFingerprintFn
    private let initState: InitState

    /// Serializes `updateContext` calls, so two overlapping switches cannot leave
    /// the loader on one context and the store tagged with another.
    private let contextSwitchLock = AsyncSerialLock()

    /// Background tasks `initialize` leaves running (an init attempt still in
    /// flight when it returned, the `.continue`-with-cache confirm fetch).
    /// `shutdown()` cancels them, so none lands a config on a stopped client.
    private let initTasks = TaskBag()

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
        initState: InitState
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
        self.initState = initState
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
    ///   2. Fetch the first envelope, retrying with jittered backoff (0.5s, 1s,
    ///      2s, ... capped at 30s) until `initTimeout`. On success, apply and
    ///      persist it. When the timeout passes (or the SDK key is rejected):
    ///      - with a cached copy, start on it, in every mode (it counts as config);
    ///      - `.fail` (default), no cache: throw `QuonfigInitError` (`.timeout`,
    ///        `.unavailable` or `.unauthorized`); nothing keeps running;
    ///      - `.wait`, no cache: keep retrying, with no upper bound;
    ///      - `.continue`, no cache: return; getters serve code defaults
    ///        (`source == .defaults`, `isReady == false`) until a config lands.
    ///      Under `.continue` with a cached copy, `initialize` returns at once.
    ///   3. Start the lifecycle-driven poll loop and the telemetry flush loop. A
    ///      client that returned without a network config keeps retrying there
    ///      and heals when delivery answers.
    ///
    /// - Parameters:
    ///   - sdkKey: convenience — if `options` is omitted, a default `Configuration`
    ///     is built from this key. If `options` is supplied, its `sdkKey` wins.
    ///   - context: the multi-namespace evaluation context.
    ///   - options: full init options. Defaults to `Configuration(sdkKey:)`.
    ///   - onInitFailure: what to do when no config (network or cache) arrives
    ///     within `initTimeout`. Default `.fail`.
    ///   - initTimeout: bounded wait for the first network envelope (default 5s).
    ///     Each attempt is a hedged primary+secondary fetch. A value `<= 0`
    ///     (or NaN) runs exactly ONE attempt and then applies `onInitFailure`
    ///     (`.fail` throws, `.continue` starts on the cache or code defaults,
    ///     `.wait` keeps retrying). It never means "no deadline".
    ///     `.infinity` means no deadline.
    ///   - fingerprint: injectable context→cache-key function (Statsig's
    ///     `customCacheKey` lesson). Defaults to SHA256-of-canonical-JSON.
    @discardableResult
    public static func initialize(
        sdkKey: String? = nil,
        context: QuonfigContext,
        options: Configuration? = nil,
        onInitFailure: OnInitFailure = .fail,
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

        return try await make(
            configuration: configuration,
            context: context,
            loader: loader,
            persistence: persistence,
            aggregator: aggregator,
            lifecycleProvider: SystemLifecycleProvider(),
            onInitFailure: onInitFailure,
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
        onInitFailure: OnInitFailure = .fail,
        initTimeout: TimeInterval,
        fingerprint: @escaping ContextFingerprintFn,
        backgroundTaskRunner: BackgroundTaskRunner = ExpiringActivityRunner(),
        pollScheduler: PollScheduler = DispatchPollScheduler(
            queue: DispatchQueue(label: "com.quonfig.sdk.poller")),
        authProbeDelay: @escaping @Sendable () -> TimeInterval = { Poller.randomAuthProbeDelay() },
        initRetryBackoff: @escaping @Sendable (Int) -> TimeInterval = { InitRetry.backoff(attempt: $0) },
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> Quonfig {
        let store = Store()
        let log: QuonfigLogSink = configuration.logSink ?? OSLogSink()
        let initState = InitState(now: now, log: log)

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
        let hasCache: Bool
        if let cached = persistence?.load(envKey: envKey, fingerprint: initialFingerprint) {
            await store.apply(cached)
            initState.setSource(.cache)
            hasCache = true
        } else {
            hasCache = false
        }

        // The poller's fetch closure pulls one envelope through the loader for
        // the loader's current context (never a captured snapshot, so
        // updateContext is honored, Unleash #68), then applies + persists it only
        // if that context is still current (qfg-goi1.2.3).
        let fetch: Poller.Fetch = { [weak store, weak persistence] in
            guard let store else { return }
            do {
                try await fetchApplyPersist(
                    loader: loader, store: store, persistence: persistence, envKey: envKey,
                    fingerprint: fingerprint, initState: initState)
            } catch {
                initState.backgroundFailure(summary: await loader.lastFailureSummary)
                throw error
            }
        }

        let poller = Poller(
            fetch: fetch, scheduler: pollScheduler, logSink: configuration.logSink,
            authProbeDelay: authProbeDelay)

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
            fingerprintFn: fingerprint,
            initState: initState
        )

        // 2. Wait for the first config (spec B.3), then apply onInitFailure.
        try await client.awaitFirstConfig(
            mode: onInitFailure, hasCache: hasCache, timeout: initTimeout,
            backoff: initRetryBackoff, now: now, log: log)

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
        fingerprint: ContextFingerprintFn,
        initState: InitState? = nil
    ) async throws -> Bool {
        let (context, result) = try await loader.loadForCurrentContext()
        let fp = fingerprint(context)
        guard await store.applyIfCurrent(result, contextTag: fp) else { return false }
        initState?.networkApplied(version: result.envelope.meta.version)
        // Persist the fresh (or 304-confirmed) envelope under the fingerprint of
        // the context it was fetched for, so a later cold start / serve-on-error
        // has it.
        persistence?.save(envelope: result.envelope, envKey: envKey, fingerprint: fp)
        return true
    }

    /// Wait for the first config and apply the `onInitFailure` mode (spec
    /// B.3, logging per spec C). Returns normally when the client should be
    /// handed to the caller; throws `QuonfigInitError` under `.fail` with no
    /// config at all.
    private func awaitFirstConfig(
        mode: OnInitFailure,
        hasCache: Bool,
        timeout: TimeInterval,
        backoff: @escaping @Sendable (Int) -> TimeInterval,
        now: @escaping @Sendable () -> TimeInterval,
        log: QuonfigLogSink
    ) async throws {
        let loader = self.loader
        let store = self.store
        let persistence = self.persistence
        let envKey = self.envKey
        let fingerprint = fingerprintFn
        let state = initState
        let timeoutText = formatTimeoutSetting(timeout)
        log.emit(
            level: .debug,
            message: "[quonfig] init: fetching config (initTimeout=\(timeoutText), onInitFailure=\(mode.rawValue))")

        // `.continue` with a cached copy returns at once on the cache; one
        // background fetch confirms it, and the poll loop keeps retrying.
        if mode == .continue, hasCache {
            initTasks.add(
                Task {
                    do {
                        try await Quonfig.fetchApplyPersist(
                            loader: loader, store: store, persistence: persistence, envKey: envKey,
                            fingerprint: fingerprint, initState: state)
                    } catch {
                        state.markDegraded()
                        let errs = await loader.lastFailureSummary ?? "no response"
                        log.emit(
                            level: .warn,
                            message: "[quonfig] init: config not loaded. onInitFailure=continue: serving cached config."
                                + " Retrying in background. \(errs)")
                    }
                })
            return
        }

        let race = InitRace()
        let start = now()
        // `initTimeout <= 0` (or NaN) has no timer: exactly one attempt runs,
        // then the policy applies (decision D3).
        let oneAttempt = !(timeout > 0)

        // The deadline: `.wait` with no cache keeps going; everything else
        // ends the wait. The reason is the LAST attempt's (decision D2): a
        // timeout when it hung (no leg failed fast, including an attempt still
        // in flight) or none completed; otherwise unavailable.
        let deadline: @Sendable () async -> Void = {
            race.markPastTimeout()
            if mode == .wait, !hasCache {
                let errs = await loader.lastFailureSummary ?? "no response"
                log.emit(
                    level: .warn,
                    message: "[quonfig] init: no config after \(formatElapsed(now() - start))."
                        + " onInitFailure=wait: still blocking startup and retrying indefinitely. \(errs)."
                        + " Use onInitFailure=fail or continue to bound startup.")
                return
            }
            let hung = !(await loader.cycleHadFastFailure)
            race.finish(.timedOut(hung: hung))
        }
        // Retries until a config lands, the key is rejected (except `.wait`
        // with no cache), or the timeout ends the wait. An attempt in flight
        // when the wait ends is not cancelled (except on a throw or a later
        // `shutdown()`): it still lands through the same context check as the
        // poll.
        let attempts = Task {
            var attempt = 0
            var loggedFirstFailure = false
            var loggedAuth = false
            var lastProgress = start
            while race.outcome == nil, !Task.isCancelled {
                attempt += 1
                do {
                    _ = try await Quonfig.fetchApplyPersist(
                        loader: loader, store: store, persistence: persistence, envKey: envKey,
                        fingerprint: fingerprint, initState: state)
                    race.finish(.loaded)
                    return
                } catch let rejected as AuthRejectedError where rejected.everyLegRejected {
                    // Every leg rejected the key (decision D1); a primary-only
                    // rejection is an ordinary failed attempt.
                    if mode != .wait || hasCache {
                        race.finish(.unauthorized(status: rejected.status, host: rejected.host))
                        return
                    }
                    if !loggedAuth {
                        loggedAuth = true
                        log.emit(
                            level: .warn,
                            message: "[quonfig] init: SDK key rejected (\(rejected.status)) by \(rejected.host)."
                                + " Check the key and environment. onInitFailure=wait: retrying.")
                    }
                } catch {}
                if race.outcome != nil || Task.isCancelled { return }
                if oneAttempt, attempt == 1 {
                    await deadline()
                    if race.outcome != nil { return }
                }

                let errs = await loader.lastFailureSummary ?? "no response"
                let t = now()
                if !loggedFirstFailure, !oneAttempt {
                    loggedFirstFailure = true
                    lastProgress = t
                    log.emit(
                        level: .warn,
                        message:
                            "[quonfig] init: config not loaded yet, retrying until initTimeout (\(timeoutText)). \(errs)"
                    )
                } else if race.pastTimeout {
                    if t - lastProgress >= 30 {
                        lastProgress = t
                        log.emit(
                            level: .warn,
                            message: "[quonfig] init: still blocked waiting for config (\(formatElapsed(t - start))"
                                + " elapsed, attempt \(attempt)). \(errs)")
                    }
                } else if t - lastProgress >= 5 {
                    lastProgress = t
                    log.emit(
                        level: .warn,
                        message: "[quonfig] init: still waiting for config (\(formatElapsed(t - start)) elapsed of"
                            + " \(timeoutText), attempt \(attempt)). \(errs)")
                }
                try? await Task.sleep(nanoseconds: sleepNanoseconds(backoff(attempt)))
            }
        }

        // Resume from whichever of outcome / timeout comes first
        // (qfg-goi1.2.33): never join the attempt task, so a hung fetch cannot
        // hold initialize past initTimeout.
        let timer = Task {
            if oneAttempt { return }
            try? await Task.sleep(nanoseconds: sleepNanoseconds(timeout))
            if Task.isCancelled { return }
            await deadline()
        }
        initTasks.add(attempts)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            race.gate.arm(continuation)
        }
        timer.cancel()

        let outcome = race.outcome ?? .loaded
        if outcome == .loaded { return }

        let elapsed = formatElapsed(now() - start)
        let errs = await loader.lastFailureSummary ?? "no response"
        let why: String
        switch outcome {
        case .unauthorized(let status, let host):
            why = "SDK key rejected (\(status)) by \(host)"
        default:
            why = "no config after \(elapsed)"
        }

        if hasCache {
            // A cached copy counts as config (decision 2), in every mode.
            state.markDegraded()
            log.emit(
                level: .warn,
                message: "[quonfig] init: \(why). onInitFailure=\(mode.rawValue): STARTING ON cached config"
                    + " (a cached copy counts as config). Retrying in background. \(errs)")
            return
        }

        switch mode {
        case .fail:
            attempts.cancel()
            let error: QuonfigInitError
            switch outcome {
            case .unauthorized(let status, let host):
                error = .unauthorized
                log.emit(
                    level: .error,
                    message: "[quonfig] init FAILED: SDK key rejected (\(status)) by \(host)."
                        + " Check the key and environment. onInitFailure=fail: raising now.")
            case .timedOut(let hung):
                error = hung ? .timeout : .unavailable
                log.emit(
                    level: .error,
                    message: "[quonfig] init FAILED: no config after \(elapsed). \(errs)."
                        + " onInitFailure=fail: raising QuonfigInitError. Options: onInitFailure=wait to keep"
                        + " waiting, onInitFailure=continue to start on code defaults, or raise initTimeout.")
            case .loaded:
                return
            }
            throw error
        case .wait, .continue:
            // `.wait` with no cache only ends on `.loaded`; anything else here
            // is `.continue` (a client SDK logs this at WARN, spec C).
            state.markDegraded()
            log.emit(
                level: .warn,
                message: "[quonfig] init: \(why). onInitFailure=continue: STARTING ON CODE DEFAULTS."
                    + " This instance may disagree with the rest of your fleet. Retrying in background. \(errs)")
        }
    }

    // MARK: - Synchronous typed getters (forward to the Store snapshot)

    /// `true` once any envelope (network or cache) has been applied. `false`
    /// while a client started under `.continue` serves code defaults.
    public var isReady: Bool { store.isReady }

    /// Where the values served right now came from: `.network`, `.cache` (the
    /// disk copy from an earlier run), or `.defaults` (caller code defaults).
    public var source: QuonfigConfigSource { initState.source }

    /// Suspend until `isReady` is `true`. Returns at once when it already is.
    /// Useful after `initialize` returned under `.continue` on code defaults.
    ///
    /// Cancellation-safe: if the calling task is cancelled (or already is),
    /// this returns promptly with `isReady` still `false`, so check `isReady`
    /// afterwards. To bound the wait, run it in a task you cancel on a timer.
    public func waitForReady() async {
        if store.isReady || Task.isCancelled { return }
        let gate = ResumeOnce()
        let waiter = await store.addReadyWaiter { gate.resume() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.arm(continuation)
            }
        } onCancel: {
            gate.resume()
        }
        if let waiter { await store.removeReadyWaiter(waiter) }
    }

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
            let cached = self.persistence?.load(envKey: self.envKey, fingerprint: fp)
            if await self.store.resetForContextSwitch(to: cached, contextTag: fp) {
                self.initState.setSource(cached == nil ? .defaults : .cache)
            }
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
        initTasks.cancelAll()
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
    /// `onInitFailure: .fail`, no cached copy, and the last attempt hung at
    /// `initTimeout` (every API URL in it timed out or was still in flight),
    /// or no attempt completed.
    case timeout
    /// `onInitFailure: .fail`, no cached copy, and the last attempt within
    /// `initTimeout` failed fast on at least one API URL (refused, DNS,
    /// an HTTP error status).
    case unavailable
    /// `onInitFailure: .fail`, no cached copy, and every configured API URL
    /// rejected the SDK key (401/403/404/410). Raised at once, without waiting
    /// out `initTimeout`. A rejection from the primary alone is not enough.
    case unauthorized
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

/// Holds cancellable tasks; `cancelAll` cancels every one added so far and
/// any added later (so a task registered after `shutdown()` is cancelled too).
final class TaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var cancelled = false

    func add(_ task: Task<Void, Never>) {
        let cancelNow: Bool = lock.locked {
            if cancelled { return true }
            tasks.append(task)
            return false
        }
        if cancelNow { task.cancel() }
    }

    func cancelAll() {
        let pending: [Task<Void, Never>] = lock.locked {
            cancelled = true
            defer { tasks.removeAll() }
            return tasks
        }
        for task in pending { task.cancel() }
    }
}

/// Resumes a continuation exactly once, from whichever caller gets there first.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let alreadyResumed = resumed
        if !alreadyResumed { self.continuation = continuation }
        lock.unlock()
        if alreadyResumed { continuation.resume() }
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        resumed = true
        lock.unlock()
        pending?.resume()
    }
}
