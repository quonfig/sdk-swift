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
///   - **Generation counter**: `updateContext` and `stop` bump a generation; a
///     fetch that completes for a superseded generation is discarded rather than
///     applied, so a slow in-flight request for the *old* context can't clobber
///     the new one. (Statsig #1/#36)
///
/// The poller is transport-agnostic: it's handed a `@Sendable` async `fetch`
/// closure (the `Quonfig` client wires this to `Store.refresh(using:)`), so this
/// file has no knowledge of `Loader`/`Store` wiring and is trivially testable.
public actor Poller {
    /// The work one tick performs. Supplied by the client; throwing is tolerated
    /// (a failed poll is logged-and-skipped, the timer keeps running).
    public typealias Fetch = @Sendable () async throws -> Void

    private let fetch: Fetch
    /// Dedicated serial queue the dispatch source fires on and is cancelled on
    /// (Statsig #29 — schedule and cancel on the same queue).
    private let queue: DispatchQueue

    private var timer: DispatchSourceTimer?
    /// The interval the timer is currently scheduled at (`nil` => not running).
    private var interval: TimeInterval?

    /// Bumped by `updateContext`/`stop`; a fetch tagged with an older generation
    /// is discarded on completion (Statsig #1/#36).
    private var generation: UInt64 = 0

    /// Exactly one fetch in flight at a time (dedup).
    private var fetching = false
    /// A tick arrived while a fetch was in flight — run one more after it
    /// finishes. Coalesces any number of overlapping ticks into a single
    /// follow-up (PostHog-style coalesce, §2.11).
    private var pendingFollowUp = false

    /// Test/inspection hook: how many fetches have actually been dispatched.
    private(set) var fetchCount = 0

    public init(
        fetch: @escaping Fetch,
        queue: DispatchQueue = DispatchQueue(label: "com.quonfig.sdk.poller")
    ) {
        self.fetch = fetch
        self.queue = queue
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

        let t = DispatchSource.makeTimerSource(queue: queue)
        // Leading edge one interval out (matches JS setTimeout-then-reschedule:
        // the first tick is one frequency after start, not immediate).
        t.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(200)
        )
        let gen = generation
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Hop back onto the actor; the handler captures only `self` + the
            // generation, never a context snapshot, so updateContext is honored
            // (Unleash #68).
            Task { await self.tick(generation: gen) }
        }
        timer = t
        t.resume()
    }

    /// Stop polling. Cancels the dispatch source on its own queue (Statsig #29)
    /// and bumps the generation so any in-flight fetch's result is discarded.
    public func stop() {
        generation &+= 1
        pendingFollowUp = false
        interval = nil
        // `DispatchSource.cancel()` is thread-safe to call from anywhere; the
        // event handler fires on `queue`, so cancellation is observed there.
        timer?.cancel()
        timer = nil
    }

    /// Switch the polled context: bump the generation (so a slow in-flight fetch
    /// for the OLD context is discarded), run one immediate refetch for the new
    /// context, and resume the timer at the same interval.
    ///
    /// `updateContext` itself does NOT mutate the fetch closure — the closure
    /// reads context fresh from whatever it's bound to (the `Loader` actor, whose
    /// `updateContext` the client calls before this). This just resets the timing
    /// + generation and kicks an immediate catch-up. (Statsig #1/#36)
    public func updateContext() async {
        let resumeInterval = interval
        stop()  // bumps generation, tears down the timer
        await refreshNow()  // immediate refetch under the NEW generation
        if let resumeInterval {
            start(interval: resumeInterval)
        }
    }

    /// Run a single fetch right now (the foreground catch-up, §2.6), respecting
    /// the dedup/coalesce invariant: if a fetch is already in flight, this just
    /// arms the single pending follow-up rather than launching a parallel fetch.
    public func refreshNow() async {
        await runFetch(generation: generation)
    }

    // MARK: - Tick / fetch plumbing

    /// One timer tick. Discards immediately if its generation is stale (a
    /// stop/updateContext happened after it was scheduled).
    private func tick(generation gen: UInt64) async {
        guard gen == generation else { return }
        await runFetch(generation: gen)
    }

    /// The dedup+coalesce core. At most one fetch runs at a time; concurrent
    /// callers (a tick firing while `refreshNow` runs, or two ticks racing) fold
    /// into a single pending follow-up that runs once after the current fetch.
    private func runFetch(generation gen: UInt64) async {
        guard gen == generation else { return }

        if fetching {
            // A fetch is already in flight — coalesce: arm exactly one follow-up.
            pendingFollowUp = true
            return
        }

        fetching = true
        repeat {
            pendingFollowUp = false
            let runGen = generation
            fetchCount += 1
            do {
                try await fetch()
            } catch {
                // A failed poll is non-fatal: the store keeps serving the last
                // good (or cached) envelope and the timer keeps ticking. Swallow
                // exactly as sdk-javascript's poll catch does.
            }
            // If the generation moved while we were fetching (stop/updateContext),
            // drop any follow-up — the new generation drives its own fetches.
            if runGen != generation {
                pendingFollowUp = false
                break
            }
        } while pendingFollowUp
        fetching = false
    }

    // MARK: - Test hooks

    /// Test hook: is a fetch currently in flight?
    var isFetching: Bool { fetching }
    /// Test hook: is a follow-up armed?
    var hasPendingFollowUp: Bool { pendingFollowUp }
    /// Test hook: current generation.
    var currentGeneration: UInt64 { generation }
}
