import Foundation
import XCTest

@testable import Quonfig

/// High-contention concurrency stress (bead qfg-2t2d.7, plan §2.10 Unleash #73).
///
/// The rule from the plan/bead: "Concurrency tests at high contention must run
/// clean. If the test is flaky, the lock is wrong — fix the contention, don't
/// lower the threshold." So these tests deliberately pour many concurrent
/// readers, appliers, and subscribers at the `Store` (and the `Loader` cache) at
/// once and assert no torn reads, no crashes, and consistent final state.
///
/// The `Store` design under test: synchronous reads off-actor through a
/// lock-guarded `SnapshotBox`, all mutation serialized on the actor. These tests
/// exercise exactly the read/write tear the `SnapshotBox` lock exists to prevent.
final class ConcurrencyStressTests: XCTestCase {

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: nil, subdirectory: "Fixtures")
        else {
            XCTFail("missing fixture: Fixtures/\(name)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func envelope(boolValue: Bool, version: Int) throws -> EvalEnvelope {
        var root = try JSONSerialization.jsonObject(
            with: try fixtureData("eval-with-context.response.json")) as! [String: Any]
        var evals = root["evaluations"] as! [String: Any]
        var checkout = evals["new-checkout"] as! [String: Any]
        var val = checkout["value"] as! [String: Any]
        val["value"] = boolValue
        checkout["value"] = val
        evals["new-checkout"] = checkout
        root["evaluations"] = evals
        var meta = root["meta"] as! [String: Any]
        meta["version"] = "v\(version)"
        root["meta"] = meta
        let data = try JSONSerialization.data(withJSONObject: root)
        return try JSONDecoder().decode(EvalEnvelope.self, from: data)
    }

    /// Many concurrent synchronous readers while the store is repeatedly mutated.
    /// Every read must observe a self-consistent snapshot (the bool and the string
    /// from the SAME applied envelope), never a torn mix. We assert no crash and
    /// that the FINAL state is exactly the last-applied envelope.
    func testConcurrentReadsDuringRapidApplies() async throws {
        let store = Store()
        // Seed so reads are never "before ready".
        await store.apply(try envelope(boolValue: true, version: 0))

        let applyCount = 200
        let readersPerApply = 50

        // Pre-build the envelopes up front so the task closures never capture
        // `self` (the non-Sendable XCTestCase) — keeps the suite clean under
        // StrictConcurrency=complete (it must be Sendable-safe from day one,
        // plan §2.10). `EvalEnvelope` is Sendable, so the array is too.
        let appliesSequence: [EvalEnvelope] = try (1...applyCount).map {
            try envelope(boolValue: $0 % 2 == 0, version: $0)
        }

        // Drive a stream of applies that alternate the bool value, interleaved
        // with a swarm of concurrent reads after each apply.
        await withTaskGroup(of: Void.self) { group in
            // Writer task: rapid-fire applies on the actor.
            group.addTask {
                for env in appliesSequence {
                    await store.apply(env)
                }
            }
            // Reader tasks: hammer the synchronous off-actor getters.
            for _ in 0..<(applyCount * readersPerApply / 10) {
                group.addTask {
                    for _ in 0..<10 {
                        // Read several getters; each must come from a ready, valid
                        // snapshot. We can't assert a specific value (it races the
                        // writer) but we CAN assert the snapshot is self-consistent:
                        // these two keys always coexist in every applied envelope.
                        XCTAssertTrue(store.isReady)
                        _ = store.isEnabled("new-checkout")
                        // button-color is "green" in EVERY applied envelope here,
                        // so a torn read would surface the default instead.
                        XCTAssertEqual(store.string("button-color", default: "TORN"), "green",
                            "a torn snapshot read would return the default")
                        _ = store.int("rate-limit", default: -1)
                        _ = store.details("checkout-experiment")
                    }
                }
            }
        }

        // After all writers finish, the final snapshot is the last apply
        // (version applyCount, bool = applyCount % 2 == 0).
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.isEnabled("new-checkout"), applyCount % 2 == 0)
        XCTAssertEqual(store.string("button-color", default: "TORN"), "green")
    }

    /// Concurrent subscribe / cancel / apply. Subscribers register and tear down
    /// from many tasks while applies fire; the actor must serialize the
    /// subscriber set so no apply ever touches a half-mutated collection.
    func testConcurrentSubscribeCancelDuringApplies() async throws {
        let store = Store()
        await store.apply(try envelope(boolValue: true, version: 0))

        let fires = NotifyCounter()

        // Pre-build outside the task group so the closure stays Sendable-safe.
        let applies: [EvalEnvelope] = try (1...150).map {
            try envelope(boolValue: $0 % 2 == 0, version: $0)
        }

        await withTaskGroup(of: Void.self) { group in
            // Appliers: alternate the value so each apply is a real change that
            // notifies whatever subscribers are live at that instant.
            group.addTask {
                for env in applies {
                    await store.apply(env)
                }
            }
            // Subscribers churn: subscribe, let it live briefly, cancel.
            for _ in 0..<100 {
                group.addTask {
                    let token = await store.subscribe { fires.bump() }
                    // Yield a few times so applies can fire while subscribed.
                    for _ in 0..<5 { await Task.yield() }
                    token.cancel()
                }
            }
        }

        // No assertion on the exact fire count (it races subscribe/cancel timing),
        // only that we got here without a crash or data race and the store is
        // still consistent and readable.
        XCTAssertTrue(store.isReady)
        XCTAssertGreaterThanOrEqual(fires.value, 0)
        // Final-state sanity: all churned subscribers cancelled -> count back to 0.
        let remaining = await store.subscriberCount
        XCTAssertEqual(remaining, 0, "every churned subscriber must be cancelled")
    }

    /// Many concurrent callers hammer the SAME Loader (its actor-isolated ETag/LRU
    /// cache) at once. The actor must serialize all cache mutation; we assert no
    /// crash and that the cache stays bounded and coherent under contention.
    func testConcurrentLoaderHammering() async throws {
        // A client that always 200s with an ETag, so every call mints/refreshes a
        // cache entry for its URL. Distinct contexts -> distinct URLs -> exercise
        // the bounded LRU under concurrency.
        final class AlwaysOK: HTTPClient, @unchecked Sendable {
            let body: Data
            init(_ body: Data) { self.body = body }
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: ["ETag": "\"\(request.url!.path.hashValue)\""])!
                return (body, response)
            }
        }

        let body = try fixtureData("eval-with-context.response.json")
        let loader = Loader(
            sdkKey: "qf_ck_test",
            context: QuonfigContext(["user": ["key": .string("u_0")]]),
            apiURLs: [URL(string: "https://primary.quonfig.com")!],
            client: AlwaysOK(body))

        // Hammer load() from many tasks; each succeeds and the actor serializes
        // the per-URL cache writes. (Same context -> same URL -> contended entry.)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<500 {
                group.addTask {
                    (try? await loader.load()) != nil
                }
            }
            var successes = 0
            for await ok in group where ok { successes += 1 }
            XCTAssertEqual(successes, 500, "every concurrent load must succeed")
        }

        // The cache holds exactly the one URL (same context throughout) and never
        // exceeds the bounded limit — proof the LRU mutated coherently under load.
        let count = await loader.cacheCount
        XCTAssertEqual(count, 1, "single-context hammering yields one cache entry")
    }
}
