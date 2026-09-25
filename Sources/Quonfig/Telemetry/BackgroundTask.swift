import Foundation

/// Runs the background-entry telemetry flush with extra execution time from the
/// OS (policy P8: iOS background task, ~5s). Behind a protocol so tests can
/// observe it without a real app lifecycle.
protocol BackgroundTaskRunner: Sendable {
    func run(reason: String, budget: TimeInterval, _ work: @escaping @Sendable () async -> Void) async
}

/// Default runner: `ProcessInfo.performExpiringActivity`, which asks the OS to
/// keep the process running while `work` finishes. Unlike
/// `UIApplication.beginBackgroundTask` it is available in app extensions. It
/// does not exist on macOS, where a resigned-active app is not suspended, so
/// there the work simply runs. If the OS refuses or expires the activity,
/// `work` still runs; its own budget (the aggregator's POST deadline) bounds it.
struct ExpiringActivityRunner: BackgroundTaskRunner {
    func run(reason: String, budget: TimeInterval, _ work: @escaping @Sendable () async -> Void) async {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            let done = DispatchSemaphore(value: 0)
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
                // Called once with `false` (hold the activity until the work is
                // done, bounded by the budget plus slack) and, if the OS reclaims
                // the time early, again with `true` (nothing to do: the work is
                // bounded by its own deadline).
                guard !expired else { return }
                _ = done.wait(timeout: .now() + budget + 1)
            }
            await work()
            done.signal()
        #else
            await work()
        #endif
    }
}
