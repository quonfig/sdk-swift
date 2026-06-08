import Foundation
import XCTest

@testable import Quonfig

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end behaviour of the public `Quonfig` facade (§2.4): `initialize` →
/// synchronous getters → `subscribe` → `updateContext`, plus the cold-cache and
/// init-timeout fallbacks. Built on the injectable `Quonfig.make(...)` seam so the
/// whole client runs against a mock `HTTPClient`-backed `Loader`, an in-memory
/// `Persistence`, and a manual-trigger `LifecycleProvider` — no network, no disk.
final class QuonfigClientTests: XCTestCase {
    // MARK: Mock HTTP client (one scripted response per call, in order)

    final class MockClient: HTTPClient, @unchecked Sendable {
        struct Response {
            let status: Int
            let headers: [String: String]
            let body: Data
        }
        private let lock = NSLock()
        private var responses: [Response]
        private(set) var requestCount = 0
        /// When non-empty, every call throws `URLError(.notConnectedToInternet)`.
        var alwaysThrow = false

        init(_ responses: [Response]) { self.responses = responses }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock()
            defer { lock.unlock() }
            requestCount += 1
            if alwaysThrow { throw URLError(.notConnectedToInternet) }
            guard !responses.isEmpty else { throw URLError(.badServerResponse) }
            let r = responses.removeFirst()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: r.status,
                httpVersion: "HTTP/1.1", headerFields: r.headers)!
            return (r.body, http)
        }
    }

    /// A LifecycleProvider that never auto-fires (no UIKit/AppKit notifications in
    /// the test harness) but lets a test post foreground/background manually.
    struct ManualLifecycleProvider: LifecycleProvider {
        let notificationCenter: NotificationCenter
        let foregroundNotification: Notification.Name?
        let backgroundNotification: Notification.Name?
        init(center: NotificationCenter) {
            self.notificationCenter = center
            self.foregroundNotification = Notification.Name("quonfig.test.foreground")
            self.backgroundNotification = Notification.Name("quonfig.test.background")
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: nil, subdirectory: "Fixtures")
        else {
            XCTFail("missing fixture: Fixtures/\(name)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func evalBody() throws -> Data { try fixtureData("eval-with-context.response.json") }

    private func sampleContext() -> QuonfigContext {
        QuonfigContext(["user": ["key": .string("u_123"), "email": .string("a@b.com")]])
    }

    /// Build a client over the given mock client + (optional) in-memory persistence.
    private func makeClient(
        mock: MockClient,
        context: QuonfigContext,
        persistence: Persistence? = Persistence(store: InMemoryFallbackStore()),
        lifecycleProvider: LifecycleProvider? = nil,
        collectSummaries: Bool = false,
        pollInterval: TimeInterval = 0,  // 0 = no background polling during the test
        initTimeout: TimeInterval = 5
    ) async -> Quonfig {
        let config = Configuration(
            sdkKey: "qf_ck_test", apiURLs: [URL(string: "https://primary.quonfig.com")!],
            telemetryURL: URL(string: "https://telemetry.quonfig.com")!,
            pollInterval: pollInterval, collectEvaluationSummaries: collectSummaries)
        let loader = Loader(
            sdkKey: config.sdkKey, context: context, apiURLs: [config.apiURLs!.first!],
            collectContextMode: config.collectContextMode, client: mock)
        let provider = lifecycleProvider ?? ManualLifecycleProvider(center: NotificationCenter())
        return await Quonfig.make(
            configuration: config, context: context, loader: loader,
            persistence: persistence, aggregator: nil,
            lifecycleProvider: provider, initTimeout: initTimeout,
            fingerprint: defaultContextFingerprint)
    }

    // MARK: initialize + typed getters

    func testInitializeAndTypedGetters() async throws {
        let mock = MockClient([.init(status: 200, headers: ["ETag": "e1"], body: try evalBody())])
        let q = await makeClient(mock: mock, context: sampleContext())

        XCTAssertTrue(q.isReady)
        // Each getter coerces from the fixture's `{type,value}` pairs.
        XCTAssertTrue(q.isEnabled("new-checkout"))
        XCTAssertEqual(q.string("button-color", default: "blue"), "green")
        XCTAssertEqual(q.int("rate-limit", default: 100), 250)
        XCTAssertEqual(q.json("pricing")?["currency"] as? String, "USD")

        // details() carries the reason + variant.
        let d = q.details("checkout-experiment")
        XCTAssertEqual(d.reason, .split)
        XCTAssertEqual(d.variant, "split:2")

        // Caller default for an absent key.
        XCTAssertFalse(q.isEnabled("does-not-exist"))
        XCTAssertEqual(q.string("missing", default: "fallback"), "fallback")
    }

    // MARK: subscribe fires on a changing poll

    func testSubscribeFiresOnChange() async throws {
        // First body: the fixture. Second poll body: a mutated value (button-color
        // green -> red) under a NEW ETag so the loader applies it.
        var mutated = try evalBody()
        if var obj = try JSONSerialization.jsonObject(with: mutated) as? [String: Any],
           var evals = obj["evaluations"] as? [String: Any],
           var bc = evals["button-color"] as? [String: Any] {
            bc["value"] = ["type": "string", "value": "red"]
            evals["button-color"] = bc
            obj["evaluations"] = evals
            mutated = try JSONSerialization.data(withJSONObject: obj)
        }
        let mock = MockClient([
            .init(status: 200, headers: ["ETag": "e1"], body: try evalBody()),
            .init(status: 200, headers: ["ETag": "e2"], body: mutated),
        ])
        let q = await makeClient(mock: mock, context: sampleContext())

        let fired = FireCount()
        // Hold the token — a dropped token deinits and cancels the subscription.
        let token = await q.subscribe { fired.bump() }
        defer { token.cancel() }

        // Drive one more poll directly through the store+loader (the poller is
        // off during the test, pollInterval==0) and confirm the subscriber fired
        // and the value changed.
        await q.refreshForTesting()
        XCTAssertEqual(q.string("button-color", default: "x"), "red")
        XCTAssertGreaterThanOrEqual(fired.value, 1)
    }

    // MARK: updateContext refetches for the new identity

    func testUpdateContextRefetches() async throws {
        // Second response (the updateContext refetch) returns rate-limit = 999.
        var mutated = try evalBody()
        if var obj = try JSONSerialization.jsonObject(with: mutated) as? [String: Any],
           var evals = obj["evaluations"] as? [String: Any],
           var rl = evals["rate-limit"] as? [String: Any] {
            rl["value"] = ["type": "int", "value": 999]
            evals["rate-limit"] = rl
            obj["evaluations"] = evals
            mutated = try JSONSerialization.data(withJSONObject: obj)
        }
        let mock = MockClient([
            .init(status: 200, headers: ["ETag": "e1"], body: try evalBody()),
            .init(status: 200, headers: ["ETag": "e2"], body: mutated),
        ])
        let q = await makeClient(
            mock: mock, context: sampleContext(), pollInterval: 0)

        XCTAssertEqual(q.int("rate-limit", default: 0), 250)

        try await q.updateContext(QuonfigContext(["user": ["key": .string("u_456")]]))

        XCTAssertEqual(q.int("rate-limit", default: 0), 999)
        XCTAssertEqual(q.context.namespaces["user"]?["key"], .string("u_456"))
    }

    // MARK: init falls back to cache on network failure

    func testInitServesCacheWhenNetworkFails() async throws {
        let ctx = sampleContext()
        let persistence = Persistence(store: InMemoryFallbackStore())
        let envKey = Quonfig.envKey(for: Configuration(sdkKey: "qf_ck_test"))
        let fp = defaultContextFingerprint(ctx)

        // Seed the cache with the fixture envelope under this client's envKey+fp.
        let cached = try JSONDecoder().decode(EvalEnvelope.self, from: try evalBody())
        persistence.save(envelope: cached, envKey: envKey, fingerprint: fp)

        // Network always fails; init must still resolve and serve the cache.
        let mock = MockClient([])
        mock.alwaysThrow = true
        let q = await makeClient(
            mock: mock, context: ctx, persistence: persistence,
            pollInterval: 0, initTimeout: 0.2)

        XCTAssertTrue(q.isReady)
        XCTAssertTrue(q.isEnabled("new-checkout"))
        XCTAssertEqual(q.string("button-color", default: "x"), "green")
    }

    // MARK: init resolves (empty defaults) with no cache and a failing network

    func testInitResolvesToDefaultsWithNoCacheNoNetwork() async throws {
        let mock = MockClient([])
        mock.alwaysThrow = true
        let q = await makeClient(
            mock: mock, context: sampleContext(), pollInterval: 0, initTimeout: 0.2)

        // Ready (so reads return caller defaults rather than hanging), but empty.
        XCTAssertTrue(q.isReady)
        XCTAssertFalse(q.isEnabled("new-checkout"))
        XCTAssertEqual(q.int("rate-limit", default: 42), 42)
    }

    // MARK: missing SDK key throws

    func testInitializeWithoutKeyThrows() async {
        do {
            _ = try await Quonfig.initialize(context: sampleContext())
            XCTFail("expected missingSDKKey")
        } catch {
            XCTAssertEqual(error as? QuonfigInitError, .missingSDKKey)
        }
    }
}

/// Thread-safe fire counter for subscriber assertions.
final class FireCount: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func bump() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
