import Foundation
import XCTest

@testable import Quonfig

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The native logging integration (qfg-1h38): the `QuonfigLogLevel` ladder, the
/// `Quonfig.shouldLog` gate (the frontend analog of sdk-go's `Client.ShouldLog`),
/// and the `QuonfigLogger` that gates emission through a pluggable sink.
///
/// This is the SDK-side half of the locked test/HANDOFF.md "probe 5" contract:
/// a record at a given level emits iff its severity rank is >= the configured
/// threshold's, so the survivors of "emit at every level" form a contiguous tail
/// of the ladder at/above the threshold.
final class LoggingTests: XCTestCase {
    // MARK: - Level ladder

    func testLevelOrderingMatchesGoLadder() {
        // TRACE(0) < DEBUG(1) < INFO(2) < WARN(3) < ERROR(4) < FATAL(5), the same
        // ranks as sdk-go logLevelOrder — the cross-SDK contract.
        XCTAssertEqual(
            QuonfigLogLevel.allCases,
            [.trace, .debug, .info, .warn, .error, .fatal])
        XCTAssertTrue(QuonfigLogLevel.trace < QuonfigLogLevel.debug)
        XCTAssertTrue(QuonfigLogLevel.info < QuonfigLogLevel.warn)
        XCTAssertTrue(QuonfigLogLevel.error < QuonfigLogLevel.fatal)
    }

    func testWireParsingIsCaseInsensitiveAndLenient() {
        XCTAssertEqual(QuonfigLogLevel(wire: "WARN"), .warn)
        XCTAssertEqual(QuonfigLogLevel(wire: "warn"), .warn)
        XCTAssertEqual(QuonfigLogLevel(wire: "  Info "), .info)
        XCTAssertEqual(QuonfigLogLevel(wire: "WARNING"), .warn)
        XCTAssertEqual(QuonfigLogLevel(wire: "FATAL"), .fatal)
        // Unknown → nil (caller treats as "no threshold" → log everything).
        XCTAssertNil(QuonfigLogLevel(wire: "loud"))
        XCTAssertNil(QuonfigLogLevel(wire: ""))
    }

    // MARK: - Gate against a resolved config

    func testShouldLogGatesAtConfiguredThreshold() async {
        // Threshold WARN → suppress TRACE/DEBUG/INFO, emit WARN/ERROR/FATAL.
        let q = await makeClient(logLevel: "WARN")

        XCTAssertFalse(q.shouldLog(.trace, loggerKey: Self.loggerKey))
        XCTAssertFalse(q.shouldLog(.debug, loggerKey: Self.loggerKey))
        XCTAssertFalse(q.shouldLog(.info, loggerKey: Self.loggerKey))
        XCTAssertTrue(q.shouldLog(.warn, loggerKey: Self.loggerKey))
        XCTAssertTrue(q.shouldLog(.error, loggerKey: Self.loggerKey))
        XCTAssertTrue(q.shouldLog(.fatal, loggerKey: Self.loggerKey))

        XCTAssertEqual(q.logLevelThreshold(for: Self.loggerKey), .warn)
    }

    func testShouldLogIsPermissiveWhenConfigAbsent() async {
        // No log-level config resolved → log everything (sdk-go: !ok → return true).
        let q = await makeClient(logLevel: nil)

        XCTAssertNil(q.logLevelThreshold(for: Self.loggerKey))
        for level in QuonfigLogLevel.allCases {
            XCTAssertTrue(
                q.shouldLog(level, loggerKey: Self.loggerKey),
                "absent config must permit \(level)")
        }
    }

    func testShouldLogIsPermissiveWhenConfiguredLevelIsUnknown() async {
        // A garbage value on the wire → unparseable → permissive (Go's rank == -1).
        let q = await makeClient(logLevel: "loud")
        XCTAssertNil(q.logLevelThreshold(for: Self.loggerKey))
        XCTAssertTrue(q.shouldLog(.trace, loggerKey: Self.loggerKey))
    }

    // MARK: - QuonfigLogger emits the contiguous tail (probe-5 shape)

    func testLoggerEmitsContiguousTailAboveThreshold() async {
        let q = await makeClient(logLevel: "WARN")
        let sink = CaptureSink()
        let logger = QuonfigLogger(quonfig: q, loggerKey: Self.loggerKey, sink: sink)

        // Emit one record at EVERY level of the ladder, in order.
        logger.trace("t")
        logger.debug("d")
        logger.info("i")
        logger.warn("w")
        logger.error("e")
        logger.fatal("f")

        // Survivors are exactly the tail at/above WARN.
        XCTAssertEqual(sink.emitted, [.warn, .error, .fatal])
        // ...and they are a contiguous suffix of the full ladder.
        let ladder = QuonfigLogLevel.allCases
        XCTAssertEqual(sink.emitted, Array(ladder.suffix(sink.emitted.count)))
    }

    func testLoggerDoesNotEvaluateSuppressedMessages() async {
        // Laziness: a suppressed record must not build its (autoclosure) message.
        let q = await makeClient(logLevel: "ERROR")
        let sink = CaptureSink()
        let logger = QuonfigLogger(quonfig: q, loggerKey: Self.loggerKey, sink: sink)

        let built = Counter()
        logger.debug(built.tick("debug"))  // suppressed → must NOT evaluate
        logger.error(built.tick("error"))  // emitted → evaluates once

        XCTAssertEqual(sink.emitted, [.error])
        XCTAssertEqual(built.value, 1, "only the surviving record's message is built")
    }

    // MARK: - Harness

    static let loggerKey = "log-level.test"

    /// Build a real `Quonfig` whose store holds (optionally) a `log_level` config
    /// at `loggerKey`. Network is forced to fail so `make` resolves instantly to an
    /// empty store; we then apply a hand-built envelope directly (public inits).
    private func makeClient(logLevel: String?) async -> Quonfig {
        let config = Configuration(
            sdkKey: "qf_ck_test",
            apiURLs: [URL(string: "https://primary.quonfig.com")!],
            telemetryURL: URL(string: "https://telemetry.quonfig.com")!,
            pollInterval: 0)
        let ctx = QuonfigContext(["user": ["key": .string("u")]])
        let mock = ThrowingClient()
        let loader = Loader(
            sdkKey: config.sdkKey, context: ctx, apiURLs: [config.apiURLs!.first!],
            collectContextMode: config.collectContextMode, client: mock)
        let q = await Quonfig.make(
            configuration: config, context: ctx, loader: loader,
            persistence: nil, aggregator: nil,
            lifecycleProvider: NoopLifecycleProvider(), initTimeout: 0.1,
            fingerprint: defaultContextFingerprint)

        if let logLevel {
            let env = EvalEnvelope(
                evaluations: [
                    Self.loggerKey: Evaluation(
                        value: WireValue(type: "log_level", value: .string(logLevel)),
                        configId: "c1", configType: "log_level", valueType: "log_level",
                        reason: .static, ruleIndex: nil, weightedValueIndex: nil)
                ],
                meta: EvalMeta(version: "v1", environment: "production"))
            await q.configStore.apply(env)
        }
        return q
    }
}

/// An `HTTPClient` that always fails, so `Quonfig.make` resolves to an empty store
/// without a real network round-trip.
private final class ThrowingClient: HTTPClient, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

/// A `LifecycleProvider` that never fires — no UIKit/AppKit notifications in tests.
private struct NoopLifecycleProvider: LifecycleProvider {
    let notificationCenter = NotificationCenter()
    let foregroundNotification: Notification.Name? = nil
    let backgroundNotification: Notification.Name? = nil
}

/// A sink that records the levels of surviving records (the probe-5 capture shape).
private final class CaptureSink: QuonfigLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _emitted: [QuonfigLogLevel] = []
    func emit(level: QuonfigLogLevel, message: String) {
        lock.lock()
        _emitted.append(level)
        lock.unlock()
    }
    var emitted: [QuonfigLogLevel] {
        lock.lock(); defer { lock.unlock() }
        return _emitted
    }
}

/// Counts how many autoclosure messages actually got built (laziness assertion).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func tick(_ s: String) -> String {
        lock.lock(); _value += 1; lock.unlock()
        return s
    }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
