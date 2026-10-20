import Foundation
import XCTest

@testable import Quonfig

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Startup-failure behavior (qfg-9p4i.11; spec
/// project/plans/2026-10-05-init-failure-design.md A.2, B, C).
final class InitFailureTests: XCTestCase {
    /// Scripted HTTP client: `handler` decides each call by its 1-based index.
    final class ScriptedClient: HTTPClient, @unchecked Sendable {
        enum Step {
            case ok(Data)
            case status(Int)
            case offline
            case hang
        }
        private let lock = NSLock()
        private var _count = 0
        private var _handler: @Sendable (Int) -> Step
        init(_ handler: @escaping @Sendable (Int) -> Step) { self._handler = handler }

        var count: Int { lock.locked { _count } }
        func setHandler(_ h: @escaping @Sendable (Int) -> Step) { lock.locked { _handler = h } }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let step: Step = lock.locked {
                _count += 1
                return _handler(_count)
            }
            switch step {
            case .ok(let body):
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            case .status(let s):
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: s, httpVersion: nil, headerFields: [:])!)
            case .offline:
                throw URLError(.notConnectedToInternet)
            case .hang:
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw URLError(.timedOut)
            }
        }
    }

    static let body = Data(
        """
        {"evaluations":{
          "greeting":{"value":{"type":"string","value":"live"},"configId":"c1",
            "configType":"config","valueType":"string","reason":"STATIC"}
        },"meta":{"version":"1","environment":"production"}}
        """.utf8)

    static let cachedBody = Data(
        """
        {"evaluations":{
          "greeting":{"value":{"type":"string","value":"cached"},"configId":"c1",
            "configType":"config","valueType":"string","reason":"STATIC"}
        },"meta":{"version":"1","environment":"production"}}
        """.utf8)

    let ctx = QuonfigContext(["user": ["key": .string("u_1")]])

    func config(logs: CapturingLogSink? = nil) -> Configuration {
        Configuration(
            sdkKey: "qf_ck_test", apiURLs: [URL(string: "https://primary.quonfig.com")!],
            telemetryURL: URL(string: "https://telemetry.quonfig.com")!,
            pollInterval: 0, collectEvaluationSummaries: false, logSink: logs)
    }

    func loader(_ client: HTTPClient, _ config: Configuration) -> Loader {
        Loader(
            sdkKey: config.sdkKey, context: ctx, apiURLs: config.apiURLs!,
            collectContextMode: config.collectContextMode, client: client)
    }

    func seededPersistence() throws -> Persistence {
        let p = Persistence(store: InMemoryFallbackStore())
        let env = try JSONDecoder().decode(EvalEnvelope.self, from: Self.cachedBody)
        p.save(
            envelope: env, envKey: Quonfig.envKey(for: config()),
            fingerprint: defaultContextFingerprint(ctx))
        return p
    }

    // MARK: Default mode is fail (red repro: today it resolves on empty defaults)

    /// The default `onInitFailure` is now `.fail`: with no cache and delivery
    /// down, `initialize` throws instead of resolving on code defaults.
    func testDefaultModeThrowsWithNoCacheAndNoNetwork() async throws {
        let client = ScriptedClient { _ in .offline }
        let cfg = config()
        do {
            let q = try await Quonfig.make(
                configuration: cfg, context: ctx, loader: loader(client, cfg),
                persistence: Persistence(store: InMemoryFallbackStore()), aggregator: nil,
                lifecycleProvider: QuonfigClientTests.ManualLifecycleProvider(center: NotificationCenter()),
                initTimeout: 0.2, fingerprint: defaultContextFingerprint)
            XCTFail("expected initialize to throw; it resolved with isReady=\(q.isReady) on code defaults")
        } catch {
            XCTAssertEqual(error as? QuonfigInitError, .unavailable, "\(error)")
        }
    }

    // MARK: Helpers

    /// `make` with injectable mode and a fast retry backoff (the mocked clock:
    /// every backoff is 10ms instead of 0.5s, 1s, 2s, ...).
    func make(
        _ client: HTTPClient,
        mode: OnInitFailure? = nil,
        persistence: Persistence? = nil,
        initTimeout: TimeInterval = 0.3,
        logs: CapturingLogSink? = nil,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> Quonfig {
        let cfg = config(logs: logs)
        let provider = QuonfigClientTests.ManualLifecycleProvider(center: NotificationCenter())
        let persistence = persistence ?? Persistence(store: InMemoryFallbackStore())
        if let mode {
            return try await Quonfig.make(
                configuration: cfg, context: ctx, loader: loader(client, cfg),
                persistence: persistence, aggregator: nil, lifecycleProvider: provider,
                onInitFailure: mode, initTimeout: initTimeout, fingerprint: defaultContextFingerprint,
                initRetryBackoff: { _ in 0.01 }, now: now)
        }
        return try await Quonfig.make(
            configuration: cfg, context: ctx, loader: loader(client, cfg),
            persistence: persistence, aggregator: nil, lifecycleProvider: provider,
            initTimeout: initTimeout, fingerprint: defaultContextFingerprint,
            initRetryBackoff: { _ in 0.01 }, now: now)
    }

    func expectInitError(
        _ expected: QuonfigInitError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Quonfig
    ) async {
        do {
            let q = try await body()
            XCTFail("expected \(expected); resolved with source=\(q.source)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? QuonfigInitError, expected, "\(error)", file: file, line: line)
        }
    }

    // MARK: .fail

    func testFailLogsErrorWithHostsAndOptions() async throws {
        let logs = CapturingLogSink()
        await expectInitError(.unavailable) {
            try await make(ScriptedClient { _ in .offline }, logs: logs)
        }
        XCTAssertEqual(
            logs.count(.error, "^\\[quonfig\\] init FAILED: no config after .*onInitFailure=wait"), 1, "\(logs.all)")
        XCTAssertEqual(logs.count(.error, "primary=primary.quonfig.com:443: URLError -1009"), 1, "\(logs.all)")
        XCTAssertEqual(logs.count(.warn, "init: config not loaded yet, retrying until initTimeout"), 1, "\(logs.all)")
        XCTAssertEqual(logs.count(.debug, "init: fetching config \\(initTimeout=0.3s, onInitFailure=fail\\)"), 1)
        XCTAssertFalse(logs.all.joined().contains("qf_ck_test"), "the SDK key is never logged")
    }

    /// A hang (first attempt still in flight at the timeout) is `.timeout`,
    /// and initialize still returns at the bound.
    func testFailOnHangThrowsTimeoutAtTheBound() async throws {
        let started = Date()
        await expectInitError(.timeout) {
            try await make(ScriptedClient { _ in .hang }, initTimeout: 0.2)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// Blocks and retries before the timeout: two refusals, then a 200.
    func testFailRetriesWithinTheTimeout() async throws {
        let client = ScriptedClient { n in n < 3 ? .offline : .ok(InitFailureTests.body) }
        let q = try await make(client, initTimeout: 2)
        XCTAssertEqual(client.count, 3)
        XCTAssertEqual(q.source, .network)
        XCTAssertTrue(q.isReady)
        XCTAssertEqual(q.string("greeting", default: "code"), "live")
        await q.shutdown()
    }

    /// 401 from the primary (no leg accepting): raise now, not at the timeout.
    func testFailOnRejectedKeyThrowsUnauthorizedImmediately() async throws {
        let logs = CapturingLogSink()
        let started = Date()
        await expectInitError(.unauthorized) {
            try await make(ScriptedClient { _ in .status(401) }, initTimeout: 5, logs: logs)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(logs.count(.error, "init FAILED: SDK key rejected \\(401\\).*raising now"), 1, "\(logs.all)")
    }

    /// A cached copy counts as config: under the default `.fail`, a cache on
    /// disk starts the client on it instead of throwing.
    func testFailWithCacheStartsOnCache() async throws {
        let logs = CapturingLogSink()
        let q = try await make(
            ScriptedClient { _ in .offline }, persistence: try seededPersistence(), logs: logs)
        XCTAssertEqual(q.source, .cache)
        XCTAssertTrue(q.isReady)
        XCTAssertEqual(q.string("greeting", default: "code"), "cached")
        XCTAssertEqual(logs.count(.warn, "onInitFailure=fail: STARTING ON cached config"), 1, "\(logs.all)")
        await q.shutdown()
    }

    // MARK: .continue

    /// No cache, delivery down: returns at the timeout on code defaults, not
    /// ready; the client keeps retrying and heals (no dead client).
    func testContinueWithoutCacheStartsOnDefaultsThenHeals() async throws {
        let logs = CapturingLogSink()
        let client = ScriptedClient { _ in .offline }
        let q = try await make(client, mode: .continue, logs: logs)
        XCTAssertEqual(q.source, .defaults)
        XCTAssertFalse(q.isReady)
        XCTAssertEqual(q.string("greeting", default: "code"), "code")
        XCTAssertEqual(logs.count(.warn, "onInitFailure=continue: STARTING ON CODE DEFAULTS"), 1, "\(logs.all)")

        let ready = Task { await q.waitForReady() }
        client.setHandler { _ in .ok(InitFailureTests.body) }
        await q.refreshForTesting()  // the poll the lifecycle would fire
        await ready.value
        XCTAssertTrue(q.isReady)
        XCTAssertEqual(q.source, .network)
        XCTAssertEqual(q.string("greeting", default: "code"), "live")
        XCTAssertEqual(logs.count(.info, "^\\[quonfig\\] init recovered: config loaded after"), 1, "\(logs.all)")
        await q.shutdown()
    }

    /// With a cache, `.continue` returns at once (even while delivery hangs).
    func testContinueWithCacheReturnsImmediately() async throws {
        let started = Date()
        let q = try await make(
            ScriptedClient { _ in .hang }, mode: .continueWithDefaults,
            persistence: try seededPersistence(), initTimeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(q.source, .cache)
        XCTAssertEqual(q.string("greeting", default: "code"), "cached")
        await q.shutdown()
    }

    /// Background retry WARN cadence: every 30s for the first 5 minutes.
    func testBackgroundRetryWarnIsThrottled() async throws {
        let clock = InitTestClock()
        let logs = CapturingLogSink()
        let client = ScriptedClient { _ in .offline }
        let q = try await make(client, mode: .continue, logs: logs, now: { clock.now })
        await q.refreshForTesting()
        clock.advance(10)
        await q.refreshForTesting()
        XCTAssertEqual(logs.count(.warn, "still not connected to Quonfig delivery"), 1, "\(logs.all)")
        clock.advance(25)
        await q.refreshForTesting()
        XCTAssertEqual(logs.count(.warn, "still not connected to Quonfig delivery"), 2, "\(logs.all)")
        await q.shutdown()
    }

    // MARK: .wait

    /// No cache: keeps blocking past initTimeout until delivery answers.
    func testWaitBlocksPastTheTimeoutUntilConfigArrives() async throws {
        let logs = CapturingLogSink()
        let client = ScriptedClient { _ in .offline }
        let pending = Task { try await self.make(client, mode: .wait, initTimeout: 0.1, logs: logs) }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(logs.count(.warn, "onInitFailure=wait: still blocking startup"), 1, "\(logs.all)")
        client.setHandler { _ in .ok(InitFailureTests.body) }
        let q = try await pending.value
        XCTAssertEqual(q.source, .network)
        XCTAssertEqual(q.string("greeting", default: "code"), "live")
        await q.shutdown()
    }

    func testWaitKeepsRetryingOnRejectedKey() async throws {
        let client = ScriptedClient { n in n < 4 ? .status(403) : .ok(InitFailureTests.body) }
        let q = try await make(client, mode: .wait, initTimeout: 0.05)
        XCTAssertEqual(client.count, 4)
        XCTAssertEqual(q.source, .network)
        await q.shutdown()
    }

    // MARK: Surface

    func testModeSpellings() {
        XCTAssertEqual(OnInitFailure.continueWithDefaults, .continue)
        XCTAssertEqual(OnInitFailure.allCases.map(\.rawValue), ["fail", "wait", "continue"])
    }

    func testBackoffIsJitteredAndCapped() {
        for attempt in 1...40 {
            let d = InitRetry.backoff(attempt: attempt)
            XCTAssertLessThanOrEqual(d, 30)
            XCTAssertGreaterThan(d, 0)
        }
        XCTAssertEqual(InitRetry.backoff(attempt: 1), 0.5, accuracy: 0.11)
        XCTAssertEqual(InitRetry.backoff(attempt: 3), 2, accuracy: 0.41)
    }
}

/// A clock a test advances by hand.
final class InitTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: TimeInterval = 1000
    var now: TimeInterval { lock.locked { _now } }
    func advance(_ by: TimeInterval) { lock.locked { _now += by } }
}
