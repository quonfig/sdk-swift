import Foundation

// Startup-failure behavior (qfg-9p4i.11; spec
// project/plans/2026-10-05-init-failure-design.md, sections A.2, B and C).
//
// `initialize` waits up to `initTimeout` for the first config, retrying with
// jittered backoff. A cached copy on disk counts as config. When the timeout
// passes with no config at all (no network answer, no cache), the
// `onInitFailure` mode decides what happens.

/// What `Quonfig.initialize` does when no config arrives within `initTimeout`
/// and there is no cached copy for this context.
public enum OnInitFailure: String, Sendable, CaseIterable {
    /// Throw a `QuonfigInitError` (the default). A cached copy still counts as
    /// config: with one on disk, `initialize` starts on it instead of throwing.
    case fail
    /// Keep waiting and retrying with no upper bound until a config arrives
    /// (or, when a cached copy exists, start on it at the timeout).
    case wait
    /// Start anyway. With a cached copy, `initialize` returns at once on it;
    /// without one, it returns at the timeout and getters serve the caller's
    /// code defaults until a config arrives. Retries in the background.
    case `continue`

    /// The same mode as `.continue`, for call sites that would rather not
    /// backtick a keyword.
    public static let continueWithDefaults: OnInitFailure = .continue
}

/// Where the values the client is serving right now came from.
public enum QuonfigConfigSource: String, Sendable {
    /// A config fetched from Quonfig delivery in this process.
    case network
    /// The last-known-good copy persisted on disk by an earlier run.
    case cache
    /// No config: every getter returns the caller's code default.
    case defaults
}

/// Retry cadence inside `initialize`: 0.5s, 1s, 2s, 4s, ... capped at 30s,
/// each jittered by +/-20% (spec B.3).
enum InitRetry {
    static let cap: TimeInterval = 30

    static func backoff(attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, min(attempt - 1, 16)))
        let base = min(cap, 0.5 * pow(2, exponent))
        return min(cap, base * Double.random(in: 0.8...1.2))
    }
}

/// `5s`, `0.2s`, `none` for an unbounded timeout, or `0s` for a value `<= 0`
/// or NaN (one attempt, decision D3).
func formatTimeoutSetting(_ t: TimeInterval) -> String {
    guard t > 0 else { return "0s" }
    guard t.isFinite else { return "none" }
    if t == t.rounded() { return "\(Int(t))s" }
    return "\(t)s"
}

/// Seconds with one decimal (`5.0s`), or `XmYs` from one minute up.
func formatElapsed(_ t: TimeInterval) -> String {
    let t = max(0, t)
    if t < 60 { return String(format: "%.1fs", t) }
    let total = Int(t)
    return "\(total / 60)m\(total % 60)s"
}

/// Lock-guarded record of where the served values came from, plus the
/// "init ended without a network config" state that drives the background
/// retry WARN and the one recovery line (spec C).
final class InitState: @unchecked Sendable {
    private let lock = NSLock()
    private var _source: QuonfigConfigSource = .defaults
    private var degraded = false
    private var lastBackgroundLog: TimeInterval?
    let startedAt: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let log: QuonfigLogSink

    init(now: @escaping @Sendable () -> TimeInterval, log: QuonfigLogSink) {
        self.now = now
        self.startedAt = now()
        self.log = log
    }

    var source: QuonfigConfigSource { lock.locked { _source } }

    var isDegraded: Bool { lock.locked { degraded } }

    func setSource(_ source: QuonfigConfigSource) {
        lock.locked { _source = source }
    }

    /// Init returned without a network config: log the heal when one lands.
    func markDegraded() {
        lock.locked { degraded = true }
    }

    /// A current-context network result was applied.
    func networkApplied(version: String) {
        let wasDegraded: Bool = lock.locked {
            let was = degraded
            degraded = false
            _source = .network
            lastBackgroundLog = nil
            return was
        }
        guard wasDegraded else { return }
        let versionPart = version.isEmpty ? "" : " (version \(version))"
        log.emit(
            level: .info,
            message: "[quonfig] init recovered: config loaded after \(formatElapsed(now() - startedAt))"
                + "\(versionPart). Now serving live config.")
    }

    /// A background fetch failed. While degraded, logs a WARN every 30s for
    /// the first 5 minutes after start, then every 5 minutes.
    func backgroundFailure(summary: String?) {
        let line: String? = lock.locked {
            guard degraded else { return nil }
            let t = now()
            let sinceStart = t - startedAt
            let interval: TimeInterval = sinceStart < 300 ? 30 : 300
            if let last = lastBackgroundLog, t - last < interval { return nil }
            lastBackgroundLog = t
            let serving = _source == .cache ? "cache" : "defaults"
            return "[quonfig] still not connected to Quonfig delivery (\(formatElapsed(sinceStart)) since start);"
                + " serving \(serving). \(summary ?? "no response")"
        }
        if let line { log.emit(level: .warn, message: line) }
    }
}

/// How the init wait ended.
enum InitOutcome: Sendable, Equatable {
    case loaded
    /// `initTimeout` passed (or the one attempt of `initTimeout <= 0` ended).
    /// `hung`: the last attempt hung (no leg failed fast) or none completed.
    case timedOut(hung: Bool)
    /// Every API URL rejected the SDK key (401/403/404/410).
    case unauthorized(status: Int, host: String)
}

/// The shared state of one init wait: its outcome (first writer wins), whether
/// the timeout has passed, and the gate `initialize` suspends on.
final class InitRace: @unchecked Sendable {
    private let lock = NSLock()
    private var _outcome: InitOutcome?
    private var _pastTimeout = false
    let gate = ResumeOnce()

    var outcome: InitOutcome? { lock.locked { _outcome } }
    var pastTimeout: Bool { lock.locked { _pastTimeout } }
    func markPastTimeout() { lock.locked { _pastTimeout = true } }

    func finish(_ outcome: InitOutcome) {
        lock.locked { if _outcome == nil { _outcome = outcome } }
        gate.resume()
    }
}

extension NSLock {
    /// Run `body` holding the lock (`NSLocking.withLock` needs macOS 14 / iOS 17).
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
