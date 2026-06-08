import Foundation
import XCTest

@testable import Quonfig

/// Store behaviour: typed getters with defaults, the 5-value reason enum +
/// variant strings, details for absent/not-ready, diff-before-notify, subscriber
/// isolation + cancellation, reads-before-ready replay, exposure-decoupled
/// variants, and loader-result wiring.
final class StoreTests: XCTestCase {
    // MARK: - Envelope builders

    private func eval(
        type: String,
        value: QuonfigJSONValue,
        reason: EvaluationReason? = nil,
        ruleIndex: Int? = nil,
        weightedValueIndex: Int? = nil,
        configId: String = "cfg",
        configType: String = "config"
    ) -> Evaluation {
        Evaluation(
            value: WireValue(type: type, value: value),
            configId: configId,
            configType: configType,
            valueType: type,
            reason: reason,
            ruleIndex: ruleIndex,
            weightedValueIndex: weightedValueIndex)
    }

    private func envelope(_ evaluations: [String: Evaluation]) -> EvalEnvelope {
        EvalEnvelope(
            evaluations: evaluations,
            meta: EvalMeta(version: "1", environment: "production"))
    }

    // MARK: - Typed getters

    func testTypedGettersReturnValues() async {
        let store = Store()
        await store.apply(envelope([
            "flag": eval(type: "bool", value: .bool(true)),
            "name": eval(type: "string", value: .string("blue")),
            "limit": eval(type: "int", value: .int(100)),
            "ratio": eval(type: "double", value: .double(0.5)),
        ]))

        XCTAssertTrue(store.isEnabled("flag"))
        XCTAssertEqual(store.string("name", default: "x"), "blue")
        XCTAssertEqual(store.int("limit", default: 0), 100)
        XCTAssertEqual(store.double("ratio", default: 0), 0.5)
    }

    func testGettersFallBackToDefaultOnAbsentOrWrongType() async {
        let store = Store()
        await store.apply(envelope([
            "name": eval(type: "string", value: .string("blue")),
        ]))

        // Absent key -> default.
        XCTAssertFalse(store.isEnabled("missing"))
        XCTAssertEqual(store.string("missing", default: "fallback"), "fallback")
        XCTAssertEqual(store.int("missing", default: 42), 42)
        XCTAssertEqual(store.double("missing", default: 1.5), 1.5)

        // Wrong type -> default (string read as int).
        XCTAssertEqual(store.int("name", default: 7), 7)
        XCTAssertFalse(store.isEnabled("name"))
    }

    func testNumericCoercionLeniency() async {
        let store = Store()
        await store.apply(envelope([
            "wholeDouble": eval(type: "double", value: .double(3.0)),
            "intAsDouble": eval(type: "int", value: .int(5)),
        ]))
        // Whole double readable as int.
        XCTAssertEqual(store.int("wholeDouble", default: 0), 3)
        // Int widens to double.
        XCTAssertEqual(store.double("intAsDouble", default: 0), 5.0)
    }

    func testJSONGetter() async {
        let store = Store()
        await store.apply(envelope([
            "pricing": eval(type: "json", value: .object([
                "tier": .string("pro"),
                "seats": .int(10),
            ])),
            "notObject": eval(type: "json", value: .array([.int(1)])),
            "str": eval(type: "string", value: .string("x")),
        ]))

        let obj = store.json("pricing")
        XCTAssertEqual(obj?["tier"] as? String, "pro")
        XCTAssertEqual(obj?["seats"] as? Int, 10)
        // Non-object json -> nil.
        XCTAssertNil(store.json("notObject"))
        // Wrong type -> nil.
        XCTAssertNil(store.json("str"))
    }

    func testStringListCoercion() async {
        let store = Store()
        await store.apply(envelope([
            "hosts": eval(type: "string_list", value: .array([.string("a"), .string("b")])),
        ]))
        let d = store.details("hosts")
        XCTAssertEqual(d.value, .stringList(["a", "b"]))
    }

    // MARK: - Reason enum + variant (all 5 values)

    func testDetailsReasonsAndVariants() async {
        let store = Store()
        await store.apply(envelope([
            "stat": eval(type: "bool", value: .bool(true), reason: .static),
            "target": eval(type: "bool", value: .bool(true), reason: .targetingMatch, ruleIndex: 2),
            "split": eval(type: "bool", value: .bool(true), reason: .split, weightedValueIndex: 1),
        ]))

        XCTAssertEqual(store.details("stat").reason, .static)
        XCTAssertEqual(store.details("stat").variant, "static")

        let t = store.details("target")
        XCTAssertEqual(t.reason, .targetingMatch)
        XCTAssertEqual(t.ruleIndex, 2)
        XCTAssertEqual(t.variant, "targeting:2")

        let s = store.details("split")
        XCTAssertEqual(s.reason, .split)
        XCTAssertEqual(s.weightedValueIndex, 1)
        XCTAssertEqual(s.variant, "split:1")
    }

    func testDetailsDefaultReasonWhenAbsent() async {
        let store = Store()
        await store.apply(envelope([
            "flag": eval(type: "bool", value: .bool(true)),
        ]))
        // Missing key -> ERROR reason, default variant (sdk-javascript parity).
        let d = store.details("missing")
        XCTAssertEqual(d.reason, .error)
        XCTAssertEqual(d.variant, "default")
        XCTAssertNil(d.value)
    }

    func testDetailsErrorReasonBeforeReady() {
        let store = Store()
        // No apply yet — not ready -> ERROR.
        let d = store.details("flag")
        XCTAssertEqual(d.reason, .error)
        XCTAssertFalse(store.isReady)
    }

    func testWireReasonAbsentDefaultsToStatic() async {
        let store = Store()
        // reason omitted on the wire -> treated as STATIC in details.
        await store.apply(envelope([
            "flag": eval(type: "bool", value: .bool(true), reason: nil),
        ]))
        XCTAssertEqual(store.details("flag").reason, .static)
    }

    // MARK: - Diff-before-notify

    func testUnchangedApplyDoesNotNotify() async {
        let store = Store()
        let counter = Counter()
        // Retain the token for the test's lifetime: a dropped token tears down
        // its subscription on deinit (documented SubscriptionToken contract), so
        // `_ =` would race the cancellation against the apply below.
        let token = await store.subscribe { counter.increment() }

        let env = envelope(["flag": eval(type: "bool", value: .bool(true))])
        let firstChanged = await store.apply(env)
        XCTAssertTrue(firstChanged)
        XCTAssertEqual(counter.value, 1)

        // Re-applying the SAME evaluations must NOT fire subscribers (Flagsmith #76).
        let secondChanged = await store.apply(env)
        XCTAssertFalse(secondChanged)
        XCTAssertEqual(counter.value, 1)
        withExtendedLifetime(token) {}
    }

    func testChangedApplyNotifies() async {
        let store = Store()
        let counter = Counter()
        let token = await store.subscribe { counter.increment() }

        await store.apply(envelope(["flag": eval(type: "bool", value: .bool(true))]))
        XCTAssertEqual(counter.value, 1)

        // A real value change DOES notify.
        let changed = await store.apply(envelope(["flag": eval(type: "bool", value: .bool(false))]))
        XCTAssertTrue(changed)
        XCTAssertEqual(counter.value, 2)
        withExtendedLifetime(token) {}
    }

    func testHashIsOrderIndependent() async {
        let store = Store()
        let counter = Counter()
        let token = await store.subscribe { counter.increment() }

        let a = envelope([
            "x": eval(type: "int", value: .int(1)),
            "y": eval(type: "int", value: .int(2)),
        ])
        // Same logical content, built separately — must hash equal (no re-notify).
        let b = envelope([
            "y": eval(type: "int", value: .int(2)),
            "x": eval(type: "int", value: .int(1)),
        ])
        await store.apply(a)
        await store.apply(b)
        XCTAssertEqual(counter.value, 1)
        withExtendedLifetime(token) {}
    }

    // MARK: - Subscriber isolation + cancellation

    func testSubscriberCancellationToken() async {
        let store = Store()
        let counter = Counter()
        let token = await store.subscribe { counter.increment() }

        await store.apply(envelope(["a": eval(type: "int", value: .int(1))]))
        XCTAssertEqual(counter.value, 1)

        token.cancel()
        // cancel() hops onto the actor via a Task; poll until it lands rather
        // than assuming a particular Task ordering.
        var count = await store.subscriberCount
        var spins = 0
        while count != 0 && spins < 100 {
            try? await Task.sleep(nanoseconds: 1_000_000)
            count = await store.subscriberCount
            spins += 1
        }
        XCTAssertEqual(count, 0)

        await store.apply(envelope(["a": eval(type: "int", value: .int(2))]))
        XCTAssertEqual(counter.value, 1)
    }

    func testMultipleSubscribersAllFire() async {
        let store = Store()
        let c1 = Counter(), c2 = Counter()
        let t1 = await store.subscribe { c1.increment() }
        let t2 = await store.subscribe { c2.increment() }
        await store.apply(envelope(["a": eval(type: "int", value: .int(1))]))
        XCTAssertEqual(c1.value, 1)
        XCTAssertEqual(c2.value, 1)
        withExtendedLifetime((t1, t2)) {}
    }

    // MARK: - Reads-before-ready replay

    func testReadsBeforeReadyAreReplayedNotDropped() async {
        let store = Store()
        let counter = Counter()
        // Register a read-before-ready callback while still cold.
        await store.onReady { counter.increment() }
        let pending = await store.pendingReadyCount
        XCTAssertEqual(pending, 1)
        XCTAssertEqual(counter.value, 0)

        // First apply flips ready and replays the queued callback exactly once.
        await store.apply(envelope(["a": eval(type: "int", value: .int(1))]))
        XCTAssertEqual(counter.value, 1)
        let pendingAfter = await store.pendingReadyCount
        XCTAssertEqual(pendingAfter, 0)

        // A second apply must NOT re-replay.
        await store.apply(envelope(["a": eval(type: "int", value: .int(2))]))
        XCTAssertEqual(counter.value, 1)
    }

    func testOnReadyRunsImmediatelyWhenAlreadyReady() async {
        let store = Store()
        await store.apply(envelope(["a": eval(type: "int", value: .int(1))]))
        let counter = Counter()
        await store.onReady { counter.increment() }
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: - Exposure-decoupled variants

    func testExposureDecoupledVariantsReturnSameValues() async {
        let store = Store()
        await store.apply(envelope([
            "flag": eval(type: "bool", value: .bool(true)),
            "name": eval(type: "string", value: .string("blue")),
            "limit": eval(type: "int", value: .int(9)),
            "ratio": eval(type: "double", value: .double(2.5)),
        ]))
        // The …logExposure:false variant returns identical values today; the
        // only difference (suppressed exposure) wires in at qfg-2t2d.8.
        XCTAssertEqual(store.isEnabled("flag", logExposure: false), store.isEnabled("flag"))
        XCTAssertEqual(
            store.string("name", default: "x", logExposure: false),
            store.string("name", default: "x"))
        XCTAssertEqual(
            store.int("limit", default: 0, logExposure: false),
            store.int("limit", default: 0))
        XCTAssertEqual(
            store.double("ratio", default: 0, logExposure: false),
            store.double("ratio", default: 0))
    }

    // MARK: - Loader wiring

    func testApplyLoaderResult() async {
        let store = Store()
        let env = envelope(["flag": eval(type: "bool", value: .bool(true))])
        let changed = await store.apply(loaderResult: LoaderResult(notModified: false, envelope: env))
        XCTAssertTrue(changed)
        XCTAssertTrue(store.isEnabled("flag"))

        // A 304 carrying the same envelope is a no-op (no churn).
        let again = await store.apply(
            loaderResult: LoaderResult(notModified: true, envelope: env))
        XCTAssertFalse(again)
    }

    func testNotModifiedAfterContextSwitchStillApplies() async {
        let store = Store()
        let envA = envelope(["flag": eval(type: "bool", value: .bool(true))])
        await store.apply(loaderResult: LoaderResult(notModified: false, envelope: envA))

        // Loader returns the NEW context's cached envelope on a 304; its hash
        // differs from what's live, so it must apply (sdk-javascript parity).
        let envB = envelope(["flag": eval(type: "bool", value: .bool(false))])
        let changed = await store.apply(
            loaderResult: LoaderResult(notModified: true, envelope: envB))
        XCTAssertTrue(changed)
        XCTAssertFalse(store.isEnabled("flag"))
    }
}

/// Thread-safe counter for subscriber-fire assertions (callbacks run on the
/// actor executor, so access from the test thread needs a lock).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func increment() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}
