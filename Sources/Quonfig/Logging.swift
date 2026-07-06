import Foundation
import os

// Native logging integration for the Quonfig Apple SDK (qfg-1h38).
//
// The cross-SDK pattern: a Quonfig `log_level` config drives a logger's minimum
// level *live*, so an operator can raise or lower verbosity from the dashboard
// without a redeploy. sdk-go exposes this as `NewQuonfigHandler` (an slog.Handler
// backed by a log-level config); sdk-node as the winston/pino integrations. This
// is the idiomatic Apple equivalent, built on the platform's unified logging
// (`os.Logger`) with **zero external dependencies** (the SDK ships none — the
// Swift analog of "wrap the standard library's slog", not "add swift-log").
//
// Frontend model (important): Quonfig evaluates 100% server-side, so this client
// only holds the threshold the server resolved for its *global* context. Unlike
// the backend SDKs it cannot inject a per-call `quonfig-sdk-logging.key` context
// to drive per-logger overrides — one `log_level` config yields one threshold for
// the whole client. Per-logger routing is a backend-SDK capability; a frontend
// SDK gates every logger against the single resolved level.

/// The Quonfig log-level severity ladder, lowest → highest.
///
/// The ranks match sdk-go's `logLevelOrder` (`TRACE=0 … FATAL=5`) so a threshold
/// authored once in a `log_level` config means the same thing in every SDK. A
/// record emits iff its rank is `>=` the configured threshold's rank.
public enum QuonfigLogLevel: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    case trace = 0
    case debug = 1
    case info = 2
    case warn = 3
    case error = 4
    case fatal = 5

    /// Canonical upper-case wire name (matches the sdk-go `LogLevel*` constants
    /// and the `{ "type": "log_level", "value": "WARN" }` config value).
    public var wireName: String {
        switch self {
        case .trace: return "TRACE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        case .fatal: return "FATAL"
        }
    }

    public var description: String { wireName }

    /// Parse a wire value case-insensitively (also accepting the common aliases
    /// `WARNING`/`CRITICAL`). Returns `nil` for an unknown level, which callers
    /// treat as "no threshold" → log everything — the same effect as sdk-go's
    /// `logLevelOrder` returning `-1` for an unrecognized configured value.
    public init?(wire raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "TRACE": self = .trace
        case "DEBUG": self = .debug
        case "INFO": self = .info
        case "WARN", "WARNING": self = .warn
        case "ERROR": self = .error
        case "FATAL", "CRITICAL": self = .fatal
        default: return nil
        }
    }

    public static func < (lhs: QuonfigLogLevel, rhs: QuonfigLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The Apple unified-logging type this level maps to. `os.Logger` has no
    /// dedicated TRACE or WARN, so TRACE folds into `.debug` and WARN into
    /// `.default` (the "notice" level) — the Swift counterpart of sdk-go's
    /// `slogLevelToQuonfigString` level bridging.
    public var osLogType: OSLogType {
        switch self {
        case .trace, .debug: return .debug
        case .info: return .info
        case .warn: return .default
        case .error: return .error
        case .fatal: return .fault
        }
    }
}

// MARK: - The gate primitive (frontend analog of sdk-go Client.ShouldLog)

extension Quonfig {
    /// The currently-resolved log-level threshold for `loggerKey`, or `nil` when
    /// the config is absent / not-yet-ready / carries an unrecognized value.
    ///
    /// Reads through `details(_:)` (which records no exposure — reading the level
    /// is not a flag evaluation), so it reflects the latest polled envelope and
    /// updates the instant an operator flips the level live.
    public func logLevelThreshold(for loggerKey: String) -> QuonfigLogLevel? {
        let d = details(loggerKey)
        // `.error` reason is the SDK's synthesized "absent / store not ready"
        // signal (the server only emits STATIC/TARGETING_MATCH/SPLIT); a real
        // log_level config resolves with one of those and a `.string` value.
        guard d.reason != .error, case .string(let raw)? = d.value else { return nil }
        return QuonfigLogLevel(wire: raw)
    }

    /// Whether a record at `level` should be emitted under the `log_level` config
    /// at `loggerKey`. Mirrors sdk-go `Client.ShouldLog`: emit iff the record's
    /// severity rank is `>=` the configured threshold's. When no threshold
    /// resolves the gate is **permissive** (log everything), matching the backend
    /// SDKs' "no config found → return true".
    public func shouldLog(_ level: QuonfigLogLevel, loggerKey: String) -> Bool {
        guard let threshold = logLevelThreshold(for: loggerKey) else { return true }
        return level >= threshold
    }
}

// MARK: - Sink

/// Destination for records that survived the Quonfig level gate.
///
/// The default (`OSLogSink`) writes to Apple's unified logging via `os.Logger`.
/// Supply a custom sink to bridge to another logging backend, or to capture the
/// surviving records (the `test-swift` probe-5 validator does exactly this).
public protocol QuonfigLogSink: Sendable {
    func emit(level: QuonfigLogLevel, message: String)
}

/// Default sink — forwards each surviving record to an `os.Logger` at the level's
/// mapped `OSLogType`. The message is logged `.public` because a logging facade's
/// caller has already chosen what to put in the string; redact at the call site
/// if a value is sensitive.
public struct OSLogSink: QuonfigLogSink {
    private let logger: os.Logger

    public init(subsystem: String = "com.quonfig.sdk", category: String = "Quonfig") {
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    public func emit(level: QuonfigLogLevel, message: String) {
        logger.log(level: level.osLogType, "\(message, privacy: .public)")
    }
}

// MARK: - Logger

/// A logger whose minimum level is controlled live by a Quonfig `log_level`
/// config. Construct one per logger "path" (its `loggerKey`), then log through the
/// level methods; each record is gated by `Quonfig.shouldLog` — re-evaluated on
/// every call, so flipping the config takes effect immediately — and, if it
/// survives, forwarded to the `sink` (`os.Logger` by default).
///
/// ```swift
/// let log = QuonfigLogger(quonfig: quonfig, loggerKey: "log-level.my-app")
/// log.debug("cache warm: \(count) entries")   // suppressed unless level <= DEBUG
/// log.error("checkout failed: \(err)")
/// ```
///
/// Message arguments are autoclosures, so a suppressed record never builds its
/// string.
public struct QuonfigLogger: Sendable {
    private let quonfig: Quonfig
    private let loggerKey: String
    private let sink: QuonfigLogSink

    /// - Parameters:
    ///   - quonfig: the client whose resolved `log_level` config drives the gate.
    ///   - loggerKey: the `log_level` config key (e.g. `"log-level.my-app"`).
    ///   - sink: where surviving records go. Defaults to `OSLogSink()`.
    public init(quonfig: Quonfig, loggerKey: String, sink: QuonfigLogSink? = nil) {
        self.quonfig = quonfig
        self.loggerKey = loggerKey
        self.sink = sink ?? OSLogSink()
    }

    /// Emit `message` at `level` iff the current Quonfig threshold allows it.
    public func log(_ level: QuonfigLogLevel, _ message: @autoclosure () -> String) {
        gatedEmit(level, message)
    }

    public func trace(_ message: @autoclosure () -> String) { gatedEmit(.trace, message) }
    public func debug(_ message: @autoclosure () -> String) { gatedEmit(.debug, message) }
    public func info(_ message: @autoclosure () -> String) { gatedEmit(.info, message) }
    public func warn(_ message: @autoclosure () -> String) { gatedEmit(.warn, message) }
    public func error(_ message: @autoclosure () -> String) { gatedEmit(.error, message) }
    public func fatal(_ message: @autoclosure () -> String) { gatedEmit(.fatal, message) }

    /// Check the gate *before* building the message, so a suppressed record never
    /// evaluates its (potentially expensive) autoclosure. The public level methods
    /// forward their autoclosure here as a plain closure, un-invoked until past the
    /// guard.
    private func gatedEmit(_ level: QuonfigLogLevel, _ message: () -> String) {
        guard quonfig.shouldLog(level, loggerKey: loggerKey) else { return }
        sink.emit(level: level, message: message())
    }
}
