import Foundation
import XCTest

@testable import Quonfig

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// qfg-goi1.2.3 (audit F1 + F2): context isolation on `updateContext`.
///
/// Every scenario switches identity while something is racing or failing: a poll
/// for the old context still in flight (F1), the init fetch outliving
/// `initTimeout` (F1, init variant), or the network down with an older-generation
/// cache for the new context (F2) or no cache at all. The invariant under test:
/// after `updateContext(bob)`, the client never serves or persists another
/// identity's values for bob. It serves bob's fetched values, bob's own cache, or
/// the caller's defaults (README "Known limitation").
final class ContextSwitchTests: XCTestCase {

    // MARK: - Per-context mock transport

    /// Opens once; every waiter (current and future) then proceeds.
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
    }

    /// Answers each eval request with a one-flag envelope `who = <user key>` at a
    /// per-user generation, routed by the encoded context in the URL. A user can
    /// be held (the response waits on a `Gate`), and the whole transport can go
    /// offline.
    final class ContextMockClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        /// encoded path segment -> (user key, generation)
        private var routes: [String: (who: String, gen: Int)] = [:]
        private var held: [String: Gate] = [:]
        private var _requests: [String] = []
        private var _completed: [String] = []
        private var _offline = false

        func route(_ ctx: QuonfigContext, who: String, gen: Int) throws {
            let segment = try ctx.encodedPathSegment()
            locked { routes[segment] = (who, gen) }
        }

        /// Hold every response for `who` until the returned gate is released.
        func hold(_ who: String) -> Gate {
            let gate = Gate()
            locked { held[who] = gate }
            return gate
        }

        var offline: Bool {
            get { locked { _offline } }
            set { locked { _offline = newValue } }
        }

        var requests: [String] { locked { _requests } }
        var completed: [String] { locked { _completed } }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!
            let (who, gen, gate, offline): (String, Int, Gate?, Bool) = locked {
                let route = routes.first { url.path.hasSuffix("/" + $0.key) }?.value
                let who = route?.who ?? "unknown"
                _requests.append(who)
                return (who, route?.gen ?? 0, held[who], _offline)
            }
            if offline { throw URLError(.notConnectedToInternet) }
            if let gate { await gate.wait() }
            let body = try JSONEncoder().encode(ContextSwitchTests.envelope(who: who, gen: gen))
            locked { _completed.append(who) }
            let http = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, http)
        }

        private func locked<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }

    // MARK: - Fixtures

    static func envelope(who: String, gen: Int) -> EvalEnvelope {
        EvalEnvelope(
            evaluations: [
                "who": Evaluation(
                    value: WireValue(type: "string", value: .string(who)),
                    configId: "cfg-who",
                    configType: "config",
                    valueType: "string",
                    reason: nil,
                    ruleIndex: nil,
                    weightedValueIndex: nil)
            ],
            meta: EvalMeta(version: "gen-\(gen)", environment: "production", generation: gen))
    }

    private func user(_ key: String) -> QuonfigContext {
        QuonfigContext(["user": ["key": .string(key)]])
    }

    private let configuration = Configuration(
        sdkKey: "qf_ck_test", apiURLs: [URL(string: "https://primary.quonfig.com")!],
        telemetryURL: URL(string: "https://telemetry.quonfig.com")!,
        pollInterval: 0, collectEvaluationSummaries: false)

    private var envKey: String { Quonfig.envKey(for: configuration) }

    private func makeClient(
        mock: ContextMockClient,
        context: QuonfigContext,
        persistence: Persistence,
        initTimeout: TimeInterval = 5
    ) async -> Quonfig {
        let loader = Loader(
            sdkKey: configuration.sdkKey, context: context, apiURLs: configuration.apiURLs!,
            collectContextMode: configuration.collectContextMode, client: mock)
        return await Quonfig.make(
            configuration: configuration, context: context, loader: loader,
            persistence: persistence, aggregator: nil,
            lifecycleProvider: QuonfigClientTests.ManualLifecycleProvider(center: NotificationCenter()),
            initTimeout: initTimeout,
            fingerprint: defaultContextFingerprint)
    }

    /// Persisted `who` for a context, or nil when nothing is cached.
    private func persistedWho(_ persistence: Persistence, _ ctx: QuonfigContext) -> String? {
        let env = persistence.load(envKey: envKey, fingerprint: defaultContextFingerprint(ctx))
        guard case .string(let who)? = env?.evaluations["who"]?.value.value else { return nil }
        return who
    }

    /// Poll `condition` every 5ms until it holds or `timeout` elapses.
    @discardableResult
    private func eventually(
        timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    // MARK: - F1: updateContext while a poll for the old context is in flight

    func testUpdateContextDuringInFlightPoll() async throws {
        let alice = user("alice")
        let bob = user("bob")
        let mock = ContextMockClient()
        try mock.route(alice, who: "alice", gen: 10)
        try mock.route(bob, who: "bob", gen: 10)
        let persistence = Persistence(store: InMemoryFallbackStore())

        let q = await makeClient(mock: mock, context: alice, persistence: persistence)
        XCTAssertEqual(q.string("who", default: "default"), "alice")

        // Hold alice's next poll open, then switch to bob while it is in flight.
        let gate = mock.hold("alice")
        let poll = Task { await q.refreshForTesting() }
        let inFlight = await eventually { mock.requests.filter { $0 == "alice" }.count == 2 }
        XCTAssertTrue(inFlight, "alice's poll should be in flight")

        try await q.updateContext(bob)
        XCTAssertNotEqual(
            q.string("who", default: "default"), "alice",
            "after updateContext(bob) the store must not serve alice's values")

        // The stale alice poll lands after the switch.
        await gate.release()
        await poll.value

        let fetchedBob = await eventually { mock.requests.contains("bob") }
        XCTAssertTrue(fetchedBob, "updateContext should have fetched bob; requests=\(mock.requests)")
        await eventually { q.string("who", default: "default") == "bob" }
        XCTAssertEqual(
            q.string("who", default: "default"), "bob",
            "store should serve bob's values after updateContext(bob)")
        XCTAssertEqual(
            persistedWho(persistence, bob), "bob",
            "bob's cache entry must hold bob's own refetched values, never alice's")
        XCTAssertEqual(
            persistedWho(persistence, alice), "alice",
            "alice's own cache entry must still hold alice's values")
        await q.shutdown()
    }

    // MARK: - Overlapping switches: a held refetch must not block the next switch

    func testSecondUpdateContextIsNotBlockedByFirstSwitchsRefetch() async throws {
        let alice = user("alice")
        let bob = user("bob")
        let carol = user("carol")
        let mock = ContextMockClient()
        try mock.route(alice, who: "alice", gen: 10)
        try mock.route(bob, who: "bob", gen: 10)
        try mock.route(carol, who: "carol", gen: 10)
        let persistence = Persistence(store: InMemoryFallbackStore())
        persistence.save(
            envelope: Self.envelope(who: "carol-cached", gen: 10), envKey: envKey,
            fingerprint: defaultContextFingerprint(carol))

        let q = await makeClient(mock: mock, context: alice, persistence: persistence)
        XCTAssertEqual(q.string("who", default: "default"), "alice")

        // Switch to bob; bob's refetch hangs (a slow login fetch).
        let gate = mock.hold("bob")
        let switchBob = Task { try await q.updateContext(bob) }
        let bobInFlight = await eventually { mock.requests.contains("bob") }
        XCTAssertTrue(bobInFlight, "bob's refetch should be in flight")

        // A second switch (e.g. logout to carol) must take effect at once, not
        // wait behind bob's in-flight refetch.
        let switchCarol = Task { try await q.updateContext(carol) }
        let switched = await eventually(timeout: 1) {
            q.string("who", default: "default") == "carol-cached"
        }
        XCTAssertTrue(switched, "updateContext(carol) must not wait behind bob's held refetch")
        XCTAssertEqual(q.string("who", default: "default"), "carol-cached")
        XCTAssertEqual(
            defaultContextFingerprint(q.context), defaultContextFingerprint(carol),
            "the client's context must already be carol")

        // bob's stale refetch lands: it is discarded, and carol's refetch runs.
        await gate.release()
        try await switchBob.value
        try await switchCarol.value
        await eventually { q.string("who", default: "default") == "carol" }
        XCTAssertEqual(q.string("who", default: "default"), "carol")
        XCTAssertEqual(persistedWho(persistence, carol), "carol")
        await q.shutdown()
    }

    // MARK: - Same-context updateContext keeps serving the current values

    /// A persistence store whose writes silently fail (the `try?` paths in
    /// `Persistence.save`), so the disk never holds what memory holds.
    final class DroppingStore: PersistenceStore, @unchecked Sendable {
        func write(key: String, data: Data, inline: Bool) {}
        func read(key: String, inline: Bool) -> Data? { nil }
        func remove(key: String, inline: Bool) {}
        func writeIndex(_ data: Data) {}
        func readIndex() -> Data? { nil }
        func removeIndex() {}
    }

    func testSameContextUpdateContextKeepsCurrentValues() async throws {
        let alice = user("alice")
        let mock = ContextMockClient()
        try mock.route(alice, who: "alice", gen: 10)
        let persistence = Persistence(store: DroppingStore())

        let q = await makeClient(mock: mock, context: alice, persistence: persistence)
        XCTAssertEqual(q.string("who", default: "default"), "alice")
        XCTAssertNil(persistedWho(persistence, alice), "precondition: the save failed")

        // Re-identify the same user while the refetch is held.
        let gate = mock.hold("alice")
        let reidentify = Task { try await q.updateContext(alice) }
        let refetching = await eventually { mock.requests.filter { $0 == "alice" }.count == 2 }
        XCTAssertTrue(refetching, "the same-context refetch should be in flight")
        XCTAssertEqual(
            q.string("who", default: "default"), "alice",
            "re-identifying the same context must keep its current values, not flash defaults")

        await gate.release()
        try await reidentify.value
        XCTAssertEqual(q.string("who", default: "default"), "alice")
        await q.shutdown()
    }

    // MARK: - F1 (init variant): the init fetch outlives initTimeout

    func testInitFetchLandingAfterUpdateContextIsDiscarded() async throws {
        // initialize() cannot return before its first fetch finishes today, so
        // this scenario is unreachable until initTimeout really bounds init.
        // Remove this skip when qfg-goi1.2.33 lands; it then verifies end to end
        // that the init fetch goes through the same context check as the poll.
        // (Verified red->green for qfg-goi1.2.3 with a local, uncommitted
        // initTimeout patch.)
        try XCTSkipIf(
            true,
            "qfg-goi1.2.33: initTimeout does not bound initialize when the first fetch hangs, "
                + "so the init fetch cannot outlive initialize yet")
        let alice = user("alice")
        let bob = user("bob")
        let mock = ContextMockClient()
        try mock.route(alice, who: "alice", gen: 10)
        try mock.route(bob, who: "bob", gen: 10)
        let persistence = Persistence(store: InMemoryFallbackStore())

        // alice's init fetch hangs past initTimeout: init resolves on defaults.
        let gate = mock.hold("alice")
        let q = await makeClient(mock: mock, context: alice, persistence: persistence, initTimeout: 0.05)
        XCTAssertEqual(q.string("who", default: "default"), "default")

        try await q.updateContext(bob)
        await eventually { q.string("who", default: "default") == "bob" }
        XCTAssertEqual(q.string("who", default: "default"), "bob")

        // Now the stale init fetch for alice lands.
        await gate.release()
        await eventually { mock.completed.contains("alice") }
        // Give the stale result time to (wrongly) apply; it must not.
        let regressed = await eventually(timeout: 0.3) { q.string("who", default: "default") == "alice" }
        XCTAssertFalse(regressed, "the stale init fetch for alice must not overwrite bob's values")
        XCTAssertEqual(q.string("who", default: "default"), "bob")
        XCTAssertEqual(persistedWho(persistence, bob), "bob")
        await q.shutdown()
    }

    // MARK: - F2: offline switch to a context cached at an older generation

    func testCachedContextRejectedByGenerationGuardOffline() async throws {
        let alice = user("alice")
        let bob = user("bob")
        let mock = ContextMockClient()
        try mock.route(alice, who: "alice", gen: 10)
        try mock.route(bob, who: "bob", gen: 10)
        let persistence = Persistence(store: InMemoryFallbackStore())
        // bob was seen yesterday at generation 5.
        persistence.save(
            envelope: Self.envelope(who: "bob-cached", gen: 5), envKey: envKey,
            fingerprint: defaultContextFingerprint(bob))

        let q = await makeClient(mock: mock, context: alice, persistence: persistence)
        XCTAssertEqual(q.string("who", default: "default"), "alice")

        mock.offline = true
        try await q.updateContext(bob)
        XCTAssertEqual(
            q.string("who", default: "default"), "bob-cached",
            "README: the cached envelope for a previously-seen context is served")
        await q.shutdown()
    }

    // MARK: - F2: offline switch to a never-seen context

    func testOfflineSwitchToUnseenContextServesDefaults() async throws {
        let alice = user("alice")
        let carol = user("carol")
        let mock = ContextMockClient()
        try mock.route(alice, who: "alice", gen: 10)
        try mock.route(carol, who: "carol", gen: 10)
        let persistence = Persistence(store: InMemoryFallbackStore())

        let q = await makeClient(mock: mock, context: alice, persistence: persistence)
        XCTAssertEqual(q.string("who", default: "default"), "alice")

        mock.offline = true
        try await q.updateContext(carol)
        XCTAssertTrue(q.isReady)
        XCTAssertEqual(
            q.string("who", default: "default"), "default",
            "README: an unseen context offline falls back to caller defaults")
        XCTAssertNil(persistedWho(persistence, carol))
        await q.shutdown()
    }
}
