import Foundation

/// The polling loop that drives periodic `eval-with-context` refreshes.
///
/// Mirrors `sdk-javascript/src/quonfig.ts`'s `poll`/`doPolling`, but bakes in the
/// iOS-specific hardening the browser SDK doesn't need (plan §2.6, §2.10, §2.11):
///
///   - **`DispatchSourceTimer`, never `Timer.scheduledTimer`** — a `Timer` is
///     bound to the runloop of whatever thread scheduled it and silently dies
///     when that runloop tears down (e.g. `start()` called inside an async task).
///     A dispatch-source timer fires off a queue we own. (Unleash #88, #125)
///   - **`start()` is idempotent**: it cancels any existing timer *before*
///     scheduling a new one, all serialized on the actor, so an external `start`
///     racing an internal `updateContext` (which is stop+start) can never leave
///     two timers running with different context snapshots. (Unleash #68/#72/#74)
///   - **`interval == 0` short-circuits** before scheduling — callers pass 0 to
///     mean "disable polling," and a 0-interval dispatch timer pegs the CPU.
///     (Unleash #101)
///   - The timer handler **reads the fetch closure fresh from the actor** each
///     tick rather than capturing a context snapshot, so `updateContext` actually
///     takes effect. (Unleash #68)
///   - **`cancel()` runs on the scheduling queue** — the dispatch source is only
///     ever cancelled from the actor's executor / its own queue. (Statsig #29)
///   - **Dedup + coalesce** (PostHog-style, §2.11 drift): at most one fetch is in
///     flight; ticks that fire while a fetch runs do **not** stack — they set a
///     single "pending follow-up" flag that runs exactly one more fetch after the
///     current one completes, folding any number of coalesced ticks into one.
///   - **Generation counter**: `updateContext` and `stop` bump a generation, so
///     timer ticks scheduled before the bump are ignored and `stop` drops any
///     armed follow-up. The poller does not judge fetch *results*: the client's
///     fetch closure discards a result built for a context that is no longer
///     current (qfg-goi1.2.3), so a slow in-flight request for the *old* context
///     can't clobber the new one. (Statsig #1/#36)
///
///   - **Auth-failure rule** (qfg-goi1.10.30, plan
///     2026-10-07-sdk-auth-failure-rule.md R1-R5): a poll cycle the loader
///     rejects as `AuthRejectedError` swaps the cadence for one probe every
///     max(T in [150s, 300s], interval), logs one ERROR, and the first accepted
///     fetch logs one INFO and resumes the normal cadence.
///
/// The poller is transport-agnostic: it's handed a `@Sendable` async `fetch`
/// closure (the `Quonfig` client wires this to a context-checked
/// fetch-apply-persist step), so this file has no knowledge of `Loader`/`Store`
/// wiring and is trivially testable.
public actor Poller {
    /// The work one tick performs. Supplied by the client; throwing is tolerated
    /// (a failed poll is logged-and-skipped, the timer keeps running).
    public typealias Fetch = @Sendable () async throws -> Void

    private let fetch: Fetch
    /// Schedules the poll cadence and the auth-failed probe. Production is a
    /// `DispatchPollScheduler` on a dedicated serial queue (Statsig #29 —
    /// schedule and cancel on the same queue); tests inject a manual one.
    private let scheduler: PollScheduler
    /// Where the auth-failure rule's ERROR / DEBUG / INFO lines go.
    private let log: QuonfigLogSink
    /// Draws the auth-failed probe period T (uniform in [150s, 300s]).
    private let authProbeDelay: @Sendable () -> TimeInterval

    private var timer: PollTimer?
    /// The interval the timer is currently scheduled at (`nil` => not running).
    private var interval: TimeInterval?

    /// Bumped by `updateContext`/`stop`/`start`; a timer tick tagged with an
    /// older generation is ignored (Statsig #1/#36).
    private var generation: UInt64 = 0

    /// Exactly one fetch in flight at a time (dedup).
    private var fetching = false
    /// A tick arrived while a fetch was in flight — run one more after it
    /// finishes. Coalesces any number of overlapping ticks into a single
    /// follow-up (PostHog-style coalesce, §2.11).
    private var pendingFollowUp = false

    /// Auth-failed regime (qfg-goi1.10.30): a poll cycle was rejected with an
    /// auth-class status on the primary and no leg accepted. While set, the
    /// cadence is one probe per max(T, interval) instead of the poll timer.
    /// `stop()` does not clear it, so a background/foreground or a context
    /// switch keeps probing slowly; only an accepted fetch clears it.
    private var authFailed = false

    /// Test/inspection hook: how many fetches have actually been dispatched.
    private(set) var fetchCount = 0

    public init(
        fetch: @escaping Fetch,
        queue: DispatchQueue = DispatchQueue(label: "com.quonfig.sdk.poller")
    ) {
        self.init(fetch: fetch, scheduler: DispatchPollScheduler(queue: queue))
    }

    init(
        fetch: @escaping Fetch,
        scheduler: PollScheduler,
        logSink: QuonfigLogSink? = nil,
        authProbeDelay: @escaping @Sendable () -> TimeInterval = { Poller.randomAuthProbeDelay() }
    ) {
        self.fetch = fetch
        self.scheduler = scheduler
        self.log = logSink ?? OSLogSink()
        self.authProbeDelay = authProbeDelay
    }

    /// Bounds of the auth-failed probe period T (plan
    /// 2026-10-07-sdk-auth-failure-rule.md R3).
    static let authProbeMin: TimeInterval = 150
    static let authProbeMax: TimeInterval = 300

    /// T uniform in [150s, 300s], re-drawn for every probe.
    static func randomAuthProbeDelay() -> TimeInterval {
        TimeInterval.random(in: authProbeMin...authProbeMax)
    }

    /// Whether a poll timer is currently scheduled.
    public var isRunning: Bool { timer != nil }

    /// The interval the timer is currently scheduled at, or `nil` if stopped.
    public var currentInterval: TimeInterval? { interval }

    // MARK: - Lifecycle

    /// Start (or restart) polling at `interval` seconds.
    ///
    /// Idempotent: always cancels any existing timer first, so calling `start`
    /// twice never leaves two timers running (Unleash #68/#72/#74). An interval of
    /// `0` (or negative) disables polling entirely — the existing timer is torn
    /// down and nothing is scheduled (Unleash #101).
    ///
    /// Does **not** fire an immediate fetch — the immediate catch-up is the
    /// lifecycle seam's job (`refreshNow`, called by `Lifecycle` on foreground).
    public func start(interval: TimeInterval) {
        stop()  // cancel-before-schedule; also bumps generation
        guard interval > 0 else { return }  // 0 == "disable polling"
        self.interval = interval
        if authFailed {
            armProbe(interval: interval)
        } else {
            armPoll(interval: interval)
        }
    }

    /// Schedule the normal cadence. Leading edge one interval out (matches JS
    /// setTimeout-then-reschedule: the first tick is one frequency after start,
    /// not immediate).
    private func armPoll(interval: TimeInterval) {
        let gen = generation
        // The handler captures only `self` + the generation, never a context
        // snapshot, so updateContext is honored (Unleash #68).
        timer = scheduler.schedule(after: interval, repeating: true) { [weak self] in
            await self?.tick(generation: gen)
        }
    }

    /// Schedule one auth-failed probe at max(T, interval), T re-drawn each time
    /// (R3: no doubling, never gives up). The probe re-arms itself while the
    /// cycle is still rejected.
    private func armProbe(interval: TimeInterval) {
        let gen = generation
        let delay = max(authProbeDelay(), interval)
        timer = scheduler.schedule(after: delay, repeating: false) { [weak self] in
            await self?.probe(generation: gen)
        }
    }

    /// Replace the live timer (if polling is running) with `arm`, under a new
    /// generation so a tick of the old timer is ignored. Does not touch an armed
    /// follow-up: that belongs to a `refreshNow` and must still run.
    private func rearm(_ arm: (TimeInterval) -> Void) {
        guard let interval else { return }
        generation &+= 1
        timer?.cancel()
        timer = nil
        arm(interval)
    }

    /// `start(interval:)` only if `shouldStart` still holds when this runs on the
    /// actor, so the check and the start cannot be split by another lifecycle
    /// event (qfg-goi1.10.13).
    func start(interval: TimeInterval, if shouldStart: @Sendable () -> Bool) {
        guard shouldStart() else { return }
        start(interval: interval)
    }

    /// `stop()` only if `shouldStop` still holds when this runs on the actor.
    func stop(if shouldStop: @Sendable () -> Bool) {
        guard shouldStop() else { return }
        stop()
    }

    /// Stop polling. Cancels the dispatch source on its own queue (Statsig #29),
    /// bumps the generation so timer ticks scheduled before the stop are
    /// ignored, and drops any armed follow-up. An in-flight fetch still runs to
    /// completion; judging its result is the fetch closure's job.
    public func stop() {
        generation &+= 1
        pendingFollowUp = false
        interval = nil
        timer?.cancel()
        timer = nil
    }

    /// Switch the polled context: bump the generation, resume the timer at the
    /// same interval, and run one immediate refetch for the new context.
    ///
    /// If a fetch for the OLD context is still in flight, the refetch is armed as
    /// the follow-up and runs as soon as that fetch lands (qfg-goi1.2.3); this
    /// call then returns without waiting for it. The timer is restarted first, so
    /// its own generation bump can't drop the follow-up armed here.
    ///
    /// `updateContext` itself does NOT mutate the fetch closure — the closure
    /// reads context fresh from whatever it's bound to (the `Loader` actor, whose
    /// `updateContext` the client calls before this). This just resets the timing
    /// + generation and kicks an immediate catch-up. (Statsig #1/#36)
    public func updateContext() async {
        let resumeInterval = interval
        stop()  // bumps generation, tears down the timer, drops any follow-up
        if let resumeInterval {
            start(interval: resumeInterval)
        }
        await refreshNow()  // immediate refetch (or follow-up) for the new context
    }

    /// Run a single fetch right now (the foreground catch-up, §2.6), respecting
    /// the dedup/coalesce invariant: if a fetch is already in flight, this just
    /// arms the single pending follow-up rather than launching a parallel fetch.
    public func refreshNow() async {
        await runFetch(generation: generation, pollCycle: false)
    }

    // MARK: - Tick / fetch plumbing

    /// One timer tick. Discards immediately if its generation is stale (a
    /// stop/updateContext happened after it was scheduled).
    private func tick(generation gen: UInt64) async {
        guard gen == generation else { return }
        await runFetch(generation: gen, pollCycle: true)
    }

    /// One auth-failed probe: a full fetch cycle across every leg. A rejected
    /// probe arms the next one; an accepted one has already resumed polling.
    private func probe(generation gen: UInt64) async {
        guard gen == generation else { return }
        await runFetch(generation: gen, pollCycle: true)
        if authFailed, gen == generation, let interval {
            armProbe(interval: interval)
        }
    }

    /// The dedup+coalesce core. At most one fetch runs at a time; concurrent
    /// callers (a tick firing while `refreshNow` runs, or two ticks racing) fold
    /// into a single pending follow-up that runs once after the current fetch.
    ///
    /// `pollCycle` marks a timer-driven cycle (a poll tick or a probe). Only a
    /// poll cycle can enter auth-failed (R2); a foreground catch-up or a context
    /// switch refetch never does. Any accepted fetch exits it.
    private func runFetch(generation gen: UInt64, pollCycle: Bool) async {
        guard gen == generation else { return }

        if fetching {
            // A fetch is already in flight — coalesce: arm exactly one follow-up.
            pendingFollowUp = true
            return
        }

        fetching = true
        var isPollCycle = pollCycle
        repeat {
            pendingFollowUp = false
            fetchCount += 1
            do {
                try await fetch()
                if authFailed { exitAuthFailed() }
            } catch let rejected as AuthRejectedError where isPollCycle && !authFailed {
                enterAuthFailed(rejected)
            } catch {
                // A failed poll is non-fatal: the store keeps serving the last
                // good (or cached) envelope and the timer keeps ticking. Swallow
                // exactly as sdk-javascript's poll catch does.
                if authFailed {
                    let detail =
                        (error as? AuthRejectedError).map { " status=\($0.status) host=\($0.host)" } ?? ""
                    log.emit(level: .debug, message: "quonfig: auth-failed probe rejected; retrying later\(detail)")
                }
            }
            // A coalesced follow-up is a refreshNow, not a poll cycle.
            isPollCycle = false
            // `stop()` clears `pendingFollowUp`, so a follow-up still armed here
            // was armed after the last generation bump: it belongs to the
            // current generation (e.g. updateContext's refetch for the new
            // context) and must run. Dropping it on a generation change is what
            // left the new context unfetched (qfg-goi1.2.3).
        } while pendingFollowUp
        fetching = false
    }

    // MARK: - Auth-failure rule (qfg-goi1.10.30)

    /// Enter auth-failed: swap the poll timer for the slow probe, then log the
    /// one config ERROR (status + primary host, never the key).
    private func enterAuthFailed(_ rejected: AuthRejectedError) {
        authFailed = true
        rearm { armProbe(interval: $0) }
        log.emit(
            level: .error,
            message: "quonfig: config fetch rejected: the SDK key is invalid or revoked (check the SDK key)"
                + " status=\(rejected.status) host=\(rejected.host)")
    }

    /// Exit auth-failed after an accepted fetch: one INFO, then resume polling at
    /// the interval (no immediate fetch; this fetch just ran).
    private func exitAuthFailed() {
        authFailed = false
        log.emit(level: .info, message: "quonfig: config fetch accepted; leaving auth-failed and resuming polling")
        rearm { armPoll(interval: $0) }
    }

    // MARK: - Test hooks

    /// Test hook: is the poller in the auth-failed regime?
    var isAuthFailed: Bool { authFailed }
    /// Test hook: is a fetch currently in flight?
    var isFetching: Bool { fetching }
    /// Test hook: is a follow-up armed?
    var hasPendingFollowUp: Bool { pendingFollowUp }
    /// Test hook: current generation.
    var currentGeneration: UInt64 { generation }
}
