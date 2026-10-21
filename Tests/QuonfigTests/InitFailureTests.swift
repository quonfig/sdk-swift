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
            /// Answers 200 after `seconds`, unless the calling task is cancelled.
            case slowOK(Data, seconds: TimeInterval)
            /// Fails fast-style (offline) after `seconds`.
            case slowFail(seconds: TimeInterval)
            /// Ends on a transport timeout after `seconds` (a hung leg).
            case timeoutAfter(seconds: TimeInterval)
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
            case .slowOK(let body, let seconds):
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            case .slowFail(let seconds):
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.notConnectedToInternet)
            case .timeoutAfter(let seconds):
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
        backoff: @escaping @Sendable (Int) -> TimeInterval = { _ in 0.01 },
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
                initRetryBackoff: backoff, now: now)
        }
        return try await Quonfig.make(
            configuration: cfg, context: ctx, loader: loader(client, cfg),
            persistence: persistence, aggregator: nil, lifecycleProvider: provider,
            initTimeout: initTimeout, fingerprint: defaultContextFingerprint,
            initRetryBackoff: backoff, now: now)
    }

    /// A backoff long enough that no new attempt starts before the deadline,
    /// so a test asserting `.unavailable` sees the deadline land in the sleep
    /// after a fast failure (an attempt still in flight counts as hung, D2).
    /// Not slow: `.fail` cancels the sleep when it throws.
    static let sleepThroughDeadline: @Sendable (Int) -> TimeInterval = { _ in 30 }

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
            try await make(ScriptedClient { _ in .offline }, logs: logs, backoff: InitFailureTests.sleepThroughDeadline)
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

    /// `waitForReady` is cancellation-safe: cancelling the waiting task
    /// returns it promptly even though the store never becomes ready.
    func testWaitForReadyReturnsPromptlyWhenCancelled() async throws {
        let client = ScriptedClient { _ in .offline }
        let q = try await make(client, mode: .continue, initTimeout: 0.05)
        XCTAssertFalse(q.isReady)
        let waiter = Task { await q.waitForReady() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        let returned = expectation(description: "waitForReady returned after cancel")
        Task {
            await waiter.value
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertFalse(q.isReady)
        let queued = await q.configStore.readyWaiterCount
        XCTAssertEqual(queued, 0, "a cancelled wait left its callback queued on the store")
        await q.shutdown()
    }

    /// `waitForReady` called from an already-cancelled task returns at once.
    func testWaitForReadyReturnsAtOnceInACancelledTask() async throws {
        let q = try await make(ScriptedClient { _ in .offline }, mode: .continue, initTimeout: 0.05)
        let returned = expectation(description: "waitForReady returned")
        Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await q.waitForReady()
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 1)
        await q.shutdown()
    }

    /// `shutdown()` stops the `.continue` init retry loop: no fetch attempts
    /// after it returns (the loop used to keep retrying with no cancel path).
    func testShutdownStopsContinueModeInitRetries() async throws {
        let client = ScriptedClient { _ in .offline }
        let q = try await make(client, mode: .continue, initTimeout: 0.05)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(client.count, 1, "the init retry loop should be running before shutdown")
        await q.shutdown()
        try await Task.sleep(nanoseconds: 30_000_000)  // let an in-flight attempt settle
        let afterShutdown = client.count
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(client.count, afterShutdown, "init retries kept running after shutdown()")
    }

    /// An init attempt still in flight when `.continue` returns on code
    /// defaults is cancelled by `shutdown()`: it does not land a config (or
    /// write the disk cache) on a client that was shut down.
    func testShutdownCancelsInFlightContinueModeInitAttempt() async throws {
        let client = ScriptedClient { _ in .slowOK(InitFailureTests.body, seconds: 0.25) }
        let q = try await make(client, mode: .continue, initTimeout: 0.05)
        XCTAssertEqual(q.source, .defaults)
        await q.shutdown()
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(q.isReady, "an init attempt landed a config after shutdown()")
        XCTAssertEqual(q.source, .defaults)
    }

    /// The one background confirm fetch `.continue` fires when it starts on a
    /// cached copy is cancelled by `shutdown()` too.
    func testShutdownCancelsContinueWithCacheBackgroundFetch() async throws {
        let client = ScriptedClient { _ in .slowOK(InitFailureTests.body, seconds: 0.25) }
        let q = try await make(client, mode: .continue, persistence: try seededPersistence(), initTimeout: 5)
        XCTAssertEqual(q.source, .cache)
        await q.shutdown()
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(q.string("greeting", default: "code"), "cached", "the background fetch landed after shutdown()")
        XCTAssertEqual(q.source, .cache)
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

    // MARK: qfg-9p4i.17.8 conformance (decisions D1-D3)

    /// Routes each request by host: `primary` / `secondary` pick the step
    /// from that leg's own 1-based call count.
    final class LegClient: HTTPClient, @unchecked Sendable {
        typealias Step = ScriptedClient.Step
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private let primary: @Sendable (Int) -> Step
        private let secondary: @Sendable (Int) -> Step
        init(primary: @escaping @Sendable (Int) -> Step, secondary: @escaping @Sendable (Int) -> Step) {
            self.primary = primary
            self.secondary = secondary
        }
        func count(_ host: String) -> Int { lock.locked { counts[host] ?? 0 } }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let host = request.url!.host!
            let step: Step = lock.locked {
                counts[host, default: 0] += 1
                let n = counts[host]!
                return host.hasPrefix("primary") ? primary(n) : secondary(n)
            }
            return try await ScriptedClient { _ in step }.data(for: request)
        }
    }

    func twoLegMake(
        _ client: HTTPClient, mode: OnInitFailure = .fail, initTimeout: TimeInterval,
        logs: CapturingLogSink? = nil, backoff: @escaping @Sendable (Int) -> TimeInterval = { _ in 0.01 }
    ) async throws -> Quonfig {
        let cfg = Configuration(
            sdkKey: "qf_ck_test",
            apiURLs: [URL(string: "https://primary.quonfig.com")!, URL(string: "https://secondary.quonfig.com")!],
            telemetryURL: URL(string: "https://telemetry.quonfig.com")!,
            pollInterval: 0, collectEvaluationSummaries: false, logSink: logs)
        return try await Quonfig.make(
            configuration: cfg, context: ctx, loader: loader(client, cfg),
            persistence: Persistence(store: InMemoryFallbackStore()), aggregator: nil,
            lifecycleProvider: QuonfigClientTests.ManualLifecycleProvider(center: NotificationCenter()),
            onInitFailure: mode, initTimeout: initTimeout, fingerprint: defaultContextFingerprint,
            initRetryBackoff: backoff)
    }

    /// (a) A HUNG primary must not keep the secondary from being tried before
    /// the init deadline: the attempt is a hedged primary+secondary fetch, so
    /// a first launch with no cache starts on the secondary's config.
    func testHungPrimaryIsHedgedToSecondaryBeforeInitTimeout() async throws {
        let client = LegClient(primary: { _ in .hang }, secondary: { _ in .ok(InitFailureTests.body) })
        let started = Date()
        let q = try await twoLegMake(client, initTimeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "the secondary fires at the hedge delay")
        XCTAssertEqual(q.source, .network)
        XCTAssertEqual(q.string("greeting", default: "code"), "live")
        XCTAssertEqual(client.count("secondary.quonfig.com"), 1)
        await q.shutdown()
    }

    func twoLegLoader(_ client: HTTPClient, hedgeDelay: TimeInterval) async -> Loader {
        let l = Loader(
            sdkKey: "k", context: ctx,
            apiURLs: [URL(string: "https://primary.quonfig.com")!, URL(string: "https://secondary.quonfig.com")!],
            client: client)
        await l.setHedgeDelay(hedgeDelay)
        return l
    }

    /// A primary that answers inside the hedge delay: the secondary is never
    /// contacted.
    func testHedgeDoesNotFireSecondaryWhenPrimaryAnswersInTime() async throws {
        let client = LegClient(
            primary: { _ in .slowOK(InitFailureTests.body, seconds: 0.02) },
            secondary: { _ in .ok(InitFailureTests.body) })
        let l = await twoLegLoader(client, hedgeDelay: 0.5)
        _ = try await l.load()
        XCTAssertEqual(client.count("secondary.quonfig.com"), 0)
    }

    /// A fast primary error fires the secondary at once (no hedge wait).
    func testFastPrimaryErrorFiresSecondaryImmediately() async throws {
        let client = LegClient(primary: { _ in .status(503) }, secondary: { _ in .ok(InitFailureTests.body) })
        let l = await twoLegLoader(client, hedgeDelay: 10)
        let started = Date()
        _ = try await l.load()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    /// The first success wins; the slower primary leg is cancelled.
    func testHedgedSecondaryWinsAndPrimaryIsCancelled() async throws {
        let client = LegClient(
            primary: { _ in .slowOK(InitFailureTests.body, seconds: 5) }, secondary: { _ in .ok(InitFailureTests.body) }
        )
        let l = await twoLegLoader(client, hedgeDelay: 0.05)
        let started = Date()
        _ = try await l.load()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(client.count("primary.quonfig.com"), 1)
        XCTAssertEqual(client.count("secondary.quonfig.com"), 1)
    }

    /// D1: a primary 401 while the secondary answers 503 is NOT unauthorized
    /// (only every leg answering auth-class is). The init waits out the
    /// timeout and reports unavailable.
    func testPrimaryAuthWithSecondaryErrorIsNotUnauthorized() async throws {
        await expectInitError(.unavailable) {
            try await twoLegMake(
                LegClient(primary: { _ in .status(401) }, secondary: { _ in .status(503) }), initTimeout: 0.3,
                backoff: InitFailureTests.sleepThroughDeadline)
        }
    }

    /// D1: every leg auth-class (401 + 410) decides unauthorized at once.
    func testAllLegsAuthClassIsUnauthorizedImmediately() async throws {
        let started = Date()
        await expectInitError(.unauthorized) {
            try await twoLegMake(
                LegClient(primary: { _ in .status(401) }, secondary: { _ in .status(410) }), initTimeout: 5)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    /// D2: the reason follows the LAST attempt. Attempt 1 fails fast, then
    /// the next attempt hangs through the deadline: timeout, not unavailable.
    func testFastFailureThenHangIsTimeout() async throws {
        await expectInitError(.timeout) {
            try await make(ScriptedClient { n in n == 1 ? .offline : .hang }, initTimeout: 0.3)
        }
    }

    /// D2: a hang first, then fast failures on the last attempt: unavailable.
    func testHangThenFastFailureIsUnavailable() async throws {
        await expectInitError(.unavailable) {
            try await make(
                ScriptedClient { n in n == 1 ? .timeoutAfter(seconds: 0.1) : .offline }, initTimeout: 1,
                backoff: { n in n == 1 ? 0.01 : 30 })
        }
    }

    /// D2: every attempt ended on a transport timeout: timeout.
    func testEveryAttemptTimingOutIsTimeout() async throws {
        await expectInitError(.timeout) {
            try await make(ScriptedClient { _ in .timeoutAfter(seconds: 0.05) }, initTimeout: 0.3)
        }
    }

    /// D4: the loader's aggregate error never carries URL userinfo, even when
    /// the raw transport error embeds the failing URL.
    func testLoaderErrorRedactsURLUserinfo() async throws {
        final class EchoURLClient: HTTPClient, @unchecked Sendable {
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                throw URLError(
                    .cannotConnectToHost,
                    userInfo: [NSURLErrorFailingURLStringErrorKey: request.url!.absoluteString])
            }
        }
        let l = Loader(
            sdkKey: "k", context: ctx, apiURLs: [URL(string: "https://alice:s3cret@primary.quonfig.com")!],
            client: EchoURLClient())
        do {
            _ = try await l.load()
            XCTFail("expected failure")
        } catch let QuonfigLoaderError.allURLsFailed(msg) {
            XCTAssertFalse(msg.contains("s3cret"), msg)
            XCTAssertFalse(msg.contains("alice:"), msg)
            XCTAssertTrue(msg.contains("primary.quonfig.com"), msg)
        }
        let summary = await l.lastFailureSummary ?? ""
        XCTAssertFalse(summary.contains("s3cret"), summary)
    }

    /// D3: initTimeout 0 runs exactly one attempt before deciding; a config
    /// that arrives in that attempt is used.
    func testZeroInitTimeoutRunsOneAttemptThatCanSucceed() async throws {
        let q = try await make(ScriptedClient { _ in .slowOK(InitFailureTests.body, seconds: 0.1) }, initTimeout: 0)
        XCTAssertEqual(q.source, .network)
        XCTAssertEqual(q.string("greeting", default: "code"), "live")
        await q.shutdown()
    }

    /// D3: initTimeout 0 under fail: exactly one attempt, then the policy.
    func testZeroInitTimeoutFailRunsExactlyOneAttempt() async throws {
        let client = ScriptedClient { _ in .offline }
        await expectInitError(.unavailable) { try await make(client, initTimeout: 0) }
        XCTAssertEqual(client.count, 1)
    }

    /// D3: a negative or NaN initTimeout behaves like 0 (never a crash, never
    /// "no deadline"); continue starts on defaults after the one attempt.
    func testNegativeAndNaNInitTimeoutRunOneAttemptThenContinue() async throws {
        for t in [-1, TimeInterval.nan] {
            let client = ScriptedClient { _ in .slowFail(seconds: 0.05) }
            let q = try await make(client, mode: .continue, initTimeout: t)
            XCTAssertGreaterThanOrEqual(client.count, 1, "decided before any attempt finished (initTimeout=\(t))")
            XCTAssertEqual(q.source, .defaults)
            await q.shutdown()
        }
    }

    /// D3: under wait, initTimeout 0 keeps retrying after the one attempt.
    func testZeroInitTimeoutWaitKeepsRetrying() async throws {
        let client = ScriptedClient { n in n < 3 ? .offline : .ok(InitFailureTests.body) }
        let q = try await make(client, mode: .wait, initTimeout: 0)
        XCTAssertEqual(client.count, 3)
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
