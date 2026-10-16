import Foundation

/// A scheduled poll wait the poller can cancel.
protocol PollTimer: AnyObject, Sendable {
    func cancel()
}

/// Where the poller schedules its waits: the poll cadence and, while
/// auth-failed, the slow probe (qfg-goi1.10.30). Production uses
/// `DispatchPollScheduler`; tests inject a manual scheduler that records each
/// requested wait and fires it on demand, so cadence assertions need no real
/// time.
protocol PollScheduler: Sendable {
    /// Run `handler` once `delay` seconds from now, and then every `delay`
    /// seconds when `repeating` is true, until the returned timer is cancelled.
    func schedule(
        after delay: TimeInterval, repeating: Bool, _ handler: @escaping @Sendable () async -> Void
    ) -> PollTimer
}

/// `DispatchSourceTimer`-backed scheduler (never `Timer.scheduledTimer`, which
/// dies with the runloop of the thread that scheduled it; Unleash #88, #125).
/// The source fires on, and is cancelled against, one serial queue we own
/// (Statsig #29).
struct DispatchPollScheduler: PollScheduler {
    let queue: DispatchQueue

    func schedule(
        after delay: TimeInterval, repeating: Bool, _ handler: @escaping @Sendable () async -> Void
    ) -> PollTimer {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + delay,
            repeating: repeating ? delay : .infinity,
            leeway: .milliseconds(200)
        )
        source.setEventHandler { Task { await handler() } }
        source.resume()
        return DispatchPollTimer(source: source)
    }
}

private final class DispatchPollTimer: PollTimer, @unchecked Sendable {
    private let source: DispatchSourceTimer
    init(source: DispatchSourceTimer) { self.source = source }
    // `DispatchSource.cancel()` is thread-safe to call from anywhere.
    func cancel() { source.cancel() }
}
