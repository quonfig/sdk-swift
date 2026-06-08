import Foundation
import XCTest

@testable import Quonfig

/// Persistence behaviour (plan §2.7, §2.10):
///   - fingerprint-keyed save/load round-trip
///   - synchronous cold-start read (same Persistence -> serve last-known)
///   - serve-on-error semantics (load survives across instances)
///   - bounded cache + evict-oldest
///   - large-payload spill to file vs inline UserDefaults
///   - versioned schema + migration: unknown version discarded as cold start
///   - NEVER UserDefaults.standard / NEVER URLCache (own suite + own file)
final class PersistenceTests: XCTestCase {
    // MARK: - In-memory store double

    /// Records which backing (inline vs file) each key landed in so the
    /// inline-vs-file routing is observable in tests, without touching real
    /// UserDefaults or the filesystem.
    final class MemoryStore: PersistenceStore, @unchecked Sendable {
        private let lock = NSLock()
        var inlineData: [String: Data] = [:]
        var fileData: [String: Data] = [:]
        var index: Data?

        func write(key: String, data: Data, inline: Bool) {
            lock.lock(); defer { lock.unlock() }
            if inline {
                inlineData[key] = data
                fileData[key] = nil
            } else {
                fileData[key] = data
                inlineData[key] = nil
            }
        }
        func read(key: String, inline: Bool) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return inline ? inlineData[key] : fileData[key]
        }
        func remove(key: String, inline: Bool) {
            lock.lock(); defer { lock.unlock() }
            if inline { inlineData[key] = nil } else { fileData[key] = nil }
        }
        func writeIndex(_ data: Data) { lock.lock(); index = data; lock.unlock() }
        func readIndex() -> Data? { lock.lock(); defer { lock.unlock() }; return index }
        func removeIndex() { lock.lock(); index = nil; lock.unlock() }
    }

    // MARK: - Builders

    private func envelope(_ evaluations: [String: Evaluation], version: String = "1") -> EvalEnvelope {
        EvalEnvelope(
            evaluations: evaluations,
            meta: EvalMeta(version: version, environment: "production"))
    }

    private func eval(_ type: String, _ value: QuonfigJSONValue) -> Evaluation {
        Evaluation(
            value: WireValue(type: type, value: value),
            configId: "cfg", configType: "config", valueType: type,
            reason: .targetingMatch, ruleIndex: 2, weightedValueIndex: nil)
    }

    private func ctx(_ key: String) -> QuonfigContext {
        QuonfigContext(["user": ["key": .string(key)]])
    }

    // MARK: - Round-trip

    func testSaveLoadRoundTrip() {
        let p = Persistence(store: MemoryStore())
        let env = envelope([
            "flag": eval("bool", .bool(true)),
            "color": eval("string", .string("blue")),
        ])
        let fp = ctx("u1").defaultFingerprint()
        p.save(envelope: env, envKey: "ck_prod", fingerprint: fp)

        let loaded = p.load(envKey: "ck_prod", fingerprint: fp)
        XCTAssertEqual(loaded, env)
    }

    func testLoadMissReturnsNil() {
        let p = Persistence(store: MemoryStore())
        XCTAssertNil(p.load(envKey: "ck_prod", fingerprint: "deadbeef"))
    }

    /// Different context fingerprint must not serve another context's values —
    /// the §2.7 "is this cache still for the current context?" guard.
    func testFingerprintKeyedIsolation() {
        let p = Persistence(store: MemoryStore())
        let env = envelope(["flag": eval("bool", .bool(true))])
        p.save(envelope: env, envKey: "ck", fingerprint: ctx("u1").defaultFingerprint())

        XCTAssertNotNil(p.load(envKey: "ck", fingerprint: ctx("u1").defaultFingerprint()))
        XCTAssertNil(p.load(envKey: "ck", fingerprint: ctx("u2").defaultFingerprint()))
    }

    /// Same context, different envKey (different SDK key / env) must not collide.
    func testEnvKeyIsolation() {
        let p = Persistence(store: MemoryStore())
        let fp = ctx("u1").defaultFingerprint()
        p.save(envelope: envelope(["a": eval("bool", .bool(true))]), envKey: "prod", fingerprint: fp)
        p.save(envelope: envelope(["b": eval("bool", .bool(false))]), envKey: "staging", fingerprint: fp)

        XCTAssertEqual(p.load(envKey: "prod", fingerprint: fp)?.evaluations.keys.first, "a")
        XCTAssertEqual(p.load(envKey: "staging", fingerprint: fp)?.evaluations.keys.first, "b")
    }

    // MARK: - Cold start / serve-on-error (cross-instance load over shared store)

    /// A new Persistence over the same backing store serves the last-known
    /// envelope synchronously — the cold-start no-flicker path AND the
    /// serve-on-error path both rely on this read surviving process restart.
    func testColdStartLoadFromSharedStore() {
        let backing = MemoryStore()
        let writer = Persistence(store: backing)
        let env = envelope(["flag": eval("bool", .bool(true))])
        let fp = ctx("u1").defaultFingerprint()
        writer.save(envelope: env, envKey: "ck", fingerprint: fp)

        // Simulate a fresh launch: brand-new Persistence, same backing.
        let reader = Persistence(store: backing)
        XCTAssertEqual(reader.load(envKey: "ck", fingerprint: fp), env)
    }

    // MARK: - Bounded + evict oldest

    func testBoundedEvictsOldest() {
        let p = Persistence(store: MemoryStore(), maxCachedContexts: 3)
        // Save 5 distinct contexts; oldest 2 should be evicted.
        var fps: [String] = []
        for i in 0..<5 {
            let fp = ctx("u\(i)").defaultFingerprint()
            fps.append(fp)
            p.save(envelope: envelope(["k": eval("int", .int(Int64(i)))]), envKey: "ck", fingerprint: fp)
        }
        XCTAssertEqual(p.count, 3)
        // Oldest two evicted.
        XCTAssertNil(p.load(envKey: "ck", fingerprint: fps[0]))
        XCTAssertNil(p.load(envKey: "ck", fingerprint: fps[1]))
        // Newest three retained.
        XCTAssertNotNil(p.load(envKey: "ck", fingerprint: fps[2]))
        XCTAssertNotNil(p.load(envKey: "ck", fingerprint: fps[3]))
        XCTAssertNotNil(p.load(envKey: "ck", fingerprint: fps[4]))
    }

    /// Re-saving an existing key refreshes its recency, so it survives eviction.
    func testResaveRefreshesRecency() {
        let p = Persistence(store: MemoryStore(), maxCachedContexts: 2)
        let a = ctx("a").defaultFingerprint()
        let b = ctx("b").defaultFingerprint()
        let c = ctx("c").defaultFingerprint()
        p.save(envelope: envelope(["k": eval("int", .int(1))]), envKey: "ck", fingerprint: a)
        p.save(envelope: envelope(["k": eval("int", .int(2))]), envKey: "ck", fingerprint: b)
        // Re-save `a` so it is now newest; saving `c` should evict `b`, not `a`.
        p.save(envelope: envelope(["k": eval("int", .int(3))]), envKey: "ck", fingerprint: a)
        p.save(envelope: envelope(["k": eval("int", .int(4))]), envKey: "ck", fingerprint: c)

        XCTAssertNotNil(p.load(envKey: "ck", fingerprint: a))
        XCTAssertNil(p.load(envKey: "ck", fingerprint: b))
        XCTAssertNotNil(p.load(envKey: "ck", fingerprint: c))
    }

    // MARK: - Inline vs file spill

    func testSmallPayloadInlineLargeSpillsToFile() throws {
        let backing = MemoryStore()
        let p = Persistence(store: backing)

        // Small envelope -> inline (UserDefaults).
        let small = envelope(["flag": eval("bool", .bool(true))])
        let smallFp = ctx("small").defaultFingerprint()
        p.save(envelope: small, envKey: "ck", fingerprint: smallFp)
        let smallKey = Persistence.cacheKey(envKey: "ck", fingerprint: smallFp)
        XCTAssertNotNil(backing.inlineData[smallKey], "small payload should be inline")
        XCTAssertNil(backing.fileData[smallKey])

        // Large envelope (>16KB) -> file.
        var bigEvals: [String: Evaluation] = [:]
        let blob = String(repeating: "x", count: 64)
        for i in 0..<400 { bigEvals["flag_\(i)"] = eval("string", .string(blob)) }
        let big = envelope(bigEvals)
        let bigFp = ctx("big").defaultFingerprint()
        p.save(envelope: big, envKey: "ck", fingerprint: bigFp)
        let bigKey = Persistence.cacheKey(envKey: "ck", fingerprint: bigFp)
        XCTAssertNotNil(backing.fileData[bigKey], "large payload should spill to file")
        XCTAssertNil(backing.inlineData[bigKey])

        // Both still load correctly regardless of backing.
        XCTAssertEqual(p.load(envKey: "ck", fingerprint: smallFp), small)
        XCTAssertEqual(p.load(envKey: "ck", fingerprint: bigFp), big)
    }

    // MARK: - Versioned schema + migration

    func testCurrentSchemaVersionStamped() throws {
        let backing = MemoryStore()
        let p = Persistence(store: backing)
        let fp = ctx("u1").defaultFingerprint()
        p.save(envelope: envelope(["k": eval("bool", .bool(true))]), envKey: "ck", fingerprint: fp)
        let key = Persistence.cacheKey(envKey: "ck", fingerprint: fp)
        let data = try XCTUnwrap(backing.inlineData[key])
        let record = try JSONDecoder().decode(PersistedCacheRecord.self, from: data)
        XCTAssertEqual(record.schemaVersion, Persistence.currentSchemaVersion)
    }

    /// A record stamped with an unknown future schema version is DISCARDED on
    /// load (treated as a cold start), never mis-decoded — the LD CacheConverter
    /// safety contract.
    func testUnknownFutureVersionIsDiscarded() throws {
        let backing = MemoryStore()
        // Hand-craft a record claiming schemaVersion 999.
        let env = envelope(["k": eval("bool", .bool(true))])
        let fp = ctx("u1").defaultFingerprint()
        let key = Persistence.cacheKey(envKey: "ck", fingerprint: fp)
        let future: [String: Any] = [
            "schemaVersion": 999,
            "envKey": "ck",
            "fingerprint": fp,
            "savedAt": Date().timeIntervalSince1970,
            "envelope": ["evaluations": [:], "meta": ["version": "1", "environment": "production"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: future)
        backing.inlineData[key] = data
        // Index must point at it so load reaches the decode path.
        var idx = CacheIndex()
        idx.touch(key: key, inline: true, savedAt: Date().timeIntervalSince1970)
        backing.index = try JSONEncoder().encode(idx)

        let p = Persistence(store: backing)
        XCTAssertNil(p.load(envKey: "ck", fingerprint: fp), "unknown version must be discarded")
        // And the dangling entry was cleaned up.
        XCTAssertNil(backing.inlineData[key])
        _ = env
    }

    func testCorruptDataDiscarded() throws {
        let backing = MemoryStore()
        let fp = ctx("u1").defaultFingerprint()
        let key = Persistence.cacheKey(envKey: "ck", fingerprint: fp)
        backing.inlineData[key] = Data("not json".utf8)
        var idx = CacheIndex()
        idx.touch(key: key, inline: true, savedAt: 1)
        backing.index = try JSONEncoder().encode(idx)

        let p = Persistence(store: backing)
        XCTAssertNil(p.load(envKey: "ck", fingerprint: fp))
    }

    // MARK: - clearAll

    func testClearAllRemovesEverything() {
        let backing = MemoryStore()
        let p = Persistence(store: backing)
        let fp = ctx("u1").defaultFingerprint()
        p.save(envelope: envelope(["k": eval("bool", .bool(true))]), envKey: "ck", fingerprint: fp)
        XCTAssertEqual(p.count, 1)
        p.clearAll()
        XCTAssertEqual(p.count, 0)
        XCTAssertNil(p.load(envKey: "ck", fingerprint: fp))
    }

    // MARK: - Own-suite / never UserDefaults.standard contract

    func testProductionStoreUsesOwnSuiteNotStandard() throws {
        // The production convenience init must target the com.quonfig.sdk suite,
        // never UserDefaults.standard (Statsig #32/#34/#39). Verify by writing
        // through it and confirming UserDefaults.standard stays clean.
        let p = Persistence()
        p.clearAll()  // start clean
        let fp = ctx("suite_test_\(UUID().uuidString)").defaultFingerprint()
        let env = envelope(["k": eval("bool", .bool(true))])
        p.save(envelope: env, envKey: "ck_suite_test", fingerprint: fp)

        // The dedicated suite must hold the index; standard must not.
        let suite = try XCTUnwrap(UserDefaults(suiteName: Persistence.suiteName))
        XCTAssertNotNil(suite.data(forKey: "quonfig.cache.index.v1"))
        XCTAssertNil(
            UserDefaults.standard.data(forKey: "quonfig.cache.index.v1"),
            "must never write to UserDefaults.standard")

        XCTAssertEqual(p.load(envKey: "ck_suite_test", fingerprint: fp), env)
        p.clearAll()
    }
}
