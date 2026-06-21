import Foundation
import XCTest

@testable import Quonfig

/// qfg-7h5d.2 (Swift frontend parity) — reject-older install guard + gen<=0
/// carve-out (spec 5f/5f.1), and the watermark rule applied to the on-disk
/// last-known-good cache (spec 5h). Mirrors the backend SDKs' ordering guard
/// (sdk-go `ordering_guard_test.go`, sdk-node `shouldInstall`) at the Store
/// install point — the single `apply` every load path funnels through.
///
/// Swift v1 stays POLL-ONLY with sequential failover (the parallel hedge is
/// deferred to v1.x per project/plans/sdk-ios.md §3.3), but the guard matters
/// even without the hedge: a sequential failover to the depth-1 (generation 1)
/// secondary would otherwise regress an established client.
final class OrderingGuardTests: XCTestCase {

    /// A one-flag envelope stamped at `gen` with `feature = value`.
    private func env(gen: Int, _ value: Bool) -> EvalEnvelope {
        EvalEnvelope(
            evaluations: [
                "feature": Evaluation(
                    value: WireValue(type: "bool", value: .bool(value)),
                    configId: "cfg",
                    configType: "config",
                    valueType: "bool",
                    reason: nil,
                    ruleIndex: nil,
                    weightedValueIndex: nil)
            ],
            meta: EvalMeta(version: "gen-\(gen)", environment: "production", generation: gen))
    }

    // MARK: - Store reject-older guard

    func testFreshStoreInstallsAnyGeneration() async {
        // Even the gen=1 secondary floor seeds a fresh client.
        let store = Store()
        let changed = await store.apply(env(gen: 1, true))
        XCTAssertTrue(changed)
        XCTAssertTrue(store.isEnabled("feature"))
        XCTAssertEqual(store.heldGeneration, 1)
    }

    func testRejectOlderDoesNotRegressEstablishedClient() async {
        let store = Store()
        _ = await store.apply(env(gen: 42, true))
        XCTAssertEqual(store.heldGeneration, 42)

        // Sequential failover to the older gen 41 secondary: dropped.
        let changed = await store.apply(env(gen: 41, false))
        XCTAssertFalse(changed, "an older generation must be dropped, not installed")
        XCTAssertTrue(store.isEnabled("feature"), "value stays at gen 42 (true) — no regression")
        XCTAssertEqual(store.heldGeneration, 42)
    }

    func testSameGenerationSameContentIsNoOp() async {
        let store = Store()
        _ = await store.apply(env(gen: 42, true))
        let changed = await store.apply(env(gen: 42, true))
        XCTAssertFalse(changed, "same generation, same content must not re-notify")
        XCTAssertEqual(store.heldGeneration, 42)
    }

    func testSameGenerationDifferentContentInstalls() async {
        // Same config version, different evaluation = a context re-eval (the
        // analog of sdk-javascript's context-switch bypass). It is not a
        // regression, so it must install.
        let store = Store()
        _ = await store.apply(env(gen: 42, true))
        let changed = await store.apply(env(gen: 42, false))
        XCTAssertTrue(changed, "same-generation re-eval (context switch) must install")
        XCTAssertFalse(store.isEnabled("feature"))
        XCTAssertEqual(store.heldGeneration, 42)
    }

    func testHealForwardOnNewerGeneration() async {
        let store = Store()
        _ = await store.apply(env(gen: 41, true))
        let changed = await store.apply(env(gen: 42, false))
        XCTAssertTrue(changed, "a newer generation must heal forward")
        XCTAssertFalse(store.isEnabled("feature"))
        XCTAssertEqual(store.heldGeneration, 42)
    }

    func testUnversionedCarveOutInstalls() async {
        // An established client must install a gen<=0 (pre-watermark) snapshot
        // rather than freeze — the carve-out that the backend's 5-of-6 miss
        // forgot (qfg-7h5d.1.18).
        let store = Store()
        _ = await store.apply(env(gen: 42, true))
        let changed = await store.apply(env(gen: 0, false))
        XCTAssertTrue(changed, "gen<=0 carve-out must install, not freeze")
        XCTAssertFalse(store.isEnabled("feature"))
        XCTAssertEqual(store.heldGeneration, 0)
    }

    // MARK: - Persistence watermark monotonicity (spec 5h)

    func testPersistenceSaveIsWatermarkMonotonic() {
        let p = Persistence(store: InMemoryFallbackStore())
        let fp = "fp-alice"

        p.save(envelope: env(gen: 42, true), envKey: "ck", fingerprint: fp)
        // An older versioned save (a failover poll to the gen=1 secondary) must
        // NOT regress the cached last-known-good.
        p.save(envelope: env(gen: 41, false), envKey: "ck", fingerprint: fp)
        XCTAssertEqual(
            p.load(envKey: "ck", fingerprint: fp)?.meta.generation, 42,
            "an older save must not regress the cache")

        // A newer save advances it.
        p.save(envelope: env(gen: 43, false), envKey: "ck", fingerprint: fp)
        XCTAssertEqual(p.load(envKey: "ck", fingerprint: fp)?.meta.generation, 43)
    }

    func testPersistenceUnversionedSaveIsAllowed() {
        // gen<=0 carries no ordering info, so it is allowed through (carve-out),
        // matching the store's install guard.
        let p = Persistence(store: InMemoryFallbackStore())
        let fp = "fp-bob"
        p.save(envelope: env(gen: 42, true), envKey: "ck", fingerprint: fp)
        p.save(envelope: env(gen: 0, false), envKey: "ck", fingerprint: fp)
        XCTAssertEqual(p.load(envKey: "ck", fingerprint: fp)?.meta.generation, 0)
    }
}
