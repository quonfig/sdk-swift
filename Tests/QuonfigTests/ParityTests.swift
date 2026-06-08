import Foundation
import XCTest

@testable import Quonfig

/// Cross-component parity suite (bead qfg-2t2d.7).
///
/// The other test files (`StoreTests`, `LoaderTests`, `PersistenceTests`,
/// `ConfigDecoderTests`, …) each red/green their own component in isolation.
/// THIS file is the layer on top: it wires the real components together
/// (`Loader` -> `Store`, `Persistence` -> cold-start read -> `Store`,
/// `Loader.updateContext` -> refetch -> `Store`) and asserts the SAME end-to-end
/// behaviors `sdk-javascript` covers — the frontend SDKs do NOT consume
/// `integration-test-data` (plan §3.2), so this hand-written mirror IS the
/// cross-SDK parity check for the Swift client.
///
/// Each test names the `sdk-javascript` behavior it mirrors. Shapes are taken
/// from the source-derived fixture (`Fixtures/eval-with-context.response.json`),
/// never a paraphrase.
final class ParityTests: XCTestCase {

    // MARK: - Test doubles

    /// A scripted `HTTPClient` that returns a queued sequence of responses, so a
    /// single test can drive an ETag 200 -> 304 -> updateContext-200 sequence
    /// through the real `Loader`. Mirrors `sdk-javascript`'s loader tests driving
    /// a mocked `fetch`.
    final class ScriptedClient: HTTPClient, @unchecked Sendable {
        struct Step: Sendable {
            let status: Int
            let body: Data
            let etag: String?
            /// If set, the step only matches a request carrying this
            /// `If-None-Match` value (used to prove the conditional path fires).
            let requireIfNoneMatch: String?
        }

        private let lock = NSLock()
        private var steps: [Step]
        private(set) var capturedRequests: [URLRequest] = []

        init(_ steps: [Step]) { self.steps = steps }

        /// Pop the next scripted step under the lock. Synchronous so the lock is
        /// never held across an `await` (avoids the NSLock-in-async-context
        /// warning; the critical section is captured here, not in `data(for:)`).
        private func nextStep(recording request: URLRequest) throws -> Step {
            try lock.withLock {
                capturedRequests.append(request)
                guard !steps.isEmpty else { throw QuonfigLoaderError.noResponse }
                return steps.removeFirst()
            }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let step = try nextStep(recording: request)

            if let expected = step.requireIfNoneMatch {
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "If-None-Match"), expected,
                    "step expected a conditional GET carrying If-None-Match=\(expected)")
            }

            var headers: [String: String] = ["Content-Type": "application/json"]
            if let etag = step.etag { headers["ETag"] = etag }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: step.status,
                httpVersion: "HTTP/1.1", headerFields: headers)!
            return (step.body, response)
        }

        var requestCount: Int { lock.withLock { capturedRequests.count } }
    }

    // MARK: - Fixtures

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: nil, subdirectory: "Fixtures")
        else {
            XCTFail("missing fixture: Fixtures/\(name)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// The canonical evaluated envelope used across most parity tests.
    private func canonicalEnvelopeData() throws -> Data {
        try fixtureData("eval-with-context.response.json")
    }

    /// Build a second envelope (different values) by mutating the fixture, used
    /// to prove updateContext / change-notification paths see NEW values.
    private func mutatedEnvelopeData() throws -> Data {
        var root = try JSONSerialization.jsonObject(with: canonicalEnvelopeData()) as! [String: Any]
        var evals = root["evaluations"] as! [String: Any]
        var checkout = evals["new-checkout"] as! [String: Any]
        var val = checkout["value"] as! [String: Any]
        val["value"] = false  // flip the bool
        checkout["value"] = val
        evals["new-checkout"] = checkout
        var color = evals["button-color"] as! [String: Any]
        var cval = color["value"] as! [String: Any]
        cval["value"] = "red"  // change the string
        color["value"] = cval
        evals["button-color"] = color
        root["evaluations"] = evals
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func userContext(_ key: String) -> QuonfigContext {
        QuonfigContext(["user": ["key": .string(key)]])
    }

    private func makeLoader(client: HTTPClient, context: QuonfigContext) -> Loader {
        Loader(
            sdkKey: "qf_ck_test",
            context: context,
            apiURLs: [URL(string: "https://primary.quonfig.com")!],
            collectContextMode: .periodicExample,
            client: client)
    }

    // MARK: - 1. Eval read / typed getters (mirrors quonfig.ts get/isEnabled/string/int/json)

    /// Pull the real envelope through Loader -> Store and read every typed getter,
    /// asserting the same coercions sdk-javascript's `get`/`isEnabled` produce.
    func testEndToEndEvalReadThroughLoaderAndStore() async throws {
        let client = ScriptedClient([
            .init(status: 200, body: try canonicalEnvelopeData(), etag: "\"v1\"", requireIfNoneMatch: nil)
        ])
        let loader = makeLoader(client: client, context: userContext("u_1"))
        let store = Store()

        XCTAssertFalse(store.isReady, "store must be cold before the first apply")
        try await store.refresh(using: loader)
        XCTAssertTrue(store.isReady)

        XCTAssertTrue(store.isEnabled("new-checkout"))           // bool true
        XCTAssertEqual(store.string("button-color", default: "x"), "green")
        XCTAssertEqual(store.int("rate-limit", default: 0), 250)
        let pricing = try XCTUnwrap(store.json("pricing"))
        XCTAssertEqual(pricing["currency"] as? String, "USD")
        XCTAssertEqual(pricing["trial"] as? Bool, true)
    }

    // MARK: - 2. Reason mapping (mirrors quonfig.ts getDetails + buildVariant)

    func testReasonMappingAndVariantParity() async throws {
        let client = ScriptedClient([
            .init(status: 200, body: try canonicalEnvelopeData(), etag: nil, requireIfNoneMatch: nil)
        ])
        let store = Store()
        try await store.refresh(using: makeLoader(client: client, context: userContext("u_1")))

        // STATIC -> variant "static"
        let stat = store.details("new-checkout")
        XCTAssertEqual(stat.reason, .static)
        XCTAssertEqual(stat.variant, "static")

        // TARGETING_MATCH with ruleIndex 0 -> "targeting:0"
        let target = store.details("button-color")
        XCTAssertEqual(target.reason, .targetingMatch)
        XCTAssertEqual(target.ruleIndex, 0)
        XCTAssertEqual(target.variant, "targeting:0")

        // SPLIT with weightedValueIndex 2 -> "split:2"
        let split = store.details("checkout-experiment")
        XCTAssertEqual(split.reason, .split)
        XCTAssertEqual(split.weightedValueIndex, 2)
        XCTAssertEqual(split.variant, "split:2")
    }

    // MARK: - 3. Default fallback (mirrors quonfig.ts: absent key / not-ready -> default+ERROR)

    func testDefaultFallbackForAbsentKeyAndBeforeReady() async throws {
        let store = Store()

        // Before ready: getters return caller default, details() returns .error.
        XCTAssertFalse(store.isEnabled("anything"))
        XCTAssertEqual(store.string("anything", default: "fallback"), "fallback")
        XCTAssertEqual(store.int("anything", default: 99), 99)
        XCTAssertEqual(store.details("anything").reason, .error)
        XCTAssertEqual(store.details("anything").variant, "default")

        // After ready: an ABSENT key still returns the caller default and ERROR
        // reason (sdk-javascript getDetails FLAG_NOT_FOUND -> reason ERROR).
        let client = ScriptedClient([
            .init(status: 200, body: try canonicalEnvelopeData(), etag: nil, requireIfNoneMatch: nil)
        ])
        try await store.refresh(using: makeLoader(client: client, context: userContext("u_1")))
        XCTAssertTrue(store.isReady)
        XCTAssertEqual(store.string("not-a-real-flag", default: "fallback"), "fallback")
        XCTAssertEqual(store.details("not-a-real-flag").reason, .error)
        // A PRESENT key still resolves normally alongside the missing one.
        XCTAssertTrue(store.isEnabled("new-checkout"))
    }

    // MARK: - 4. Context encoding (mirrors context.ts base64url path; the URL the server receives)

    func testContextEncodingReachesServerInURLPath() async throws {
        let client = ScriptedClient([
            .init(status: 200, body: try canonicalEnvelopeData(), etag: nil, requireIfNoneMatch: nil)
        ])
        let ctx = QuonfigContext([
            "user": ["key": .string("u_1"), "email": .string("a@b.com")],
            "device": ["os": .string("ios")],
        ])
        let loader = makeLoader(client: client, context: ctx)
        _ = try await loader.load()

        let req = try XCTUnwrap(client.capturedRequests.first)
        let urlString = try XCTUnwrap(req.url?.absoluteString)
        // The encoded context must be the base64url segment the loader computes
        // from the SAME context, in the v2 eval-with-context path.
        let expectedSegment = try ctx.encodedPathSegment()
        XCTAssertTrue(
            urlString.contains("/api/v2/configs/eval-with-context/\(expectedSegment)"),
            "url should embed the base64url-encoded context: \(urlString)")
        // Privacy/Unleash-#67 guard: a `+` must never reach the server's path.
        let path = try XCTUnwrap(req.url?.path)
        XCTAssertFalse(path.contains("+"), "encoded context path must not contain '+'")
        // And the round-trip decodes back to the same canonical JSON.
        let canonical = try ctx.canonicalJSONData()
        // The encoded segment is base64url(canonicalJSON), percent-encoded; decode it.
        let decoded = try decodeEncodedSegment(expectedSegment)
        XCTAssertEqual(decoded, canonical)
    }

    /// Decode a percent+base64url-encoded path segment back to its raw JSON bytes.
    private func decodeEncodedSegment(_ segment: String) throws -> Data {
        let unescaped = segment.removingPercentEncoding ?? segment
        var b64 = unescaped
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4.
        while b64.count % 4 != 0 { b64.append("=") }
        return try XCTUnwrap(Data(base64Encoded: b64))
    }

    // MARK: - 5. ETag / 304 no-change path (mirrors plan §2.11 + Unleash ETag/304)

    /// 200 (mints ETag) -> 304 (conditional GET, server confirms unchanged).
    /// The 304 must serve the SAME context's cached envelope and NOT churn the
    /// store's subscribers (diff-before-notify, Flagsmith #76).
    func testETagThen304NoChangeServesCacheAndDoesNotNotify() async throws {
        let client = ScriptedClient([
            .init(status: 200, body: try canonicalEnvelopeData(), etag: "\"v1\"", requireIfNoneMatch: nil),
            .init(status: 304, body: Data(), etag: nil, requireIfNoneMatch: "\"v1\""),
        ])
        let loader = makeLoader(client: client, context: userContext("u_1"))
        let store = Store()

        // First poll: 200, store becomes ready and notifies.
        let counter = NotifyCounter()
        let token = await store.subscribe { counter.bump() }
        defer { token.cancel() }

        let changed1 = try await store.refresh(using: loader)
        XCTAssertTrue(changed1, "first apply must register as a change")
        XCTAssertTrue(store.isEnabled("new-checkout"))

        // Second poll: 304. Loader returns notModified=true with the SAME cached
        // envelope; the store hash is identical -> NO subscriber churn.
        let result2 = try await loader.load()
        XCTAssertTrue(result2.notModified, "second poll must be a 304/notModified")
        let changed2 = await store.apply(loaderResult: result2)
        XCTAssertFalse(changed2, "an unchanged 304 must NOT report a change")

        // Values still readable from the cached envelope after the 304.
        XCTAssertTrue(store.isEnabled("new-checkout"))
        XCTAssertEqual(store.string("button-color", default: "x"), "green")
        // Subscriber fired exactly once (for the 200), never for the 304.
        XCTAssertEqual(counter.value, 1, "304 must not fire subscribers")
    }

    // MARK: - 6. Cold-start cache serve (mirrors plan §2.7 — Persistence -> Store before network)

    /// A previous session persisted an envelope; on a fresh launch the Store is
    /// seeded SYNCHRONOUSLY from the cache so reads return last-known values with
    /// zero network round-trips (no-flicker cold start).
    func testColdStartServesPersistedEnvelopeBeforeNetwork() async throws {
        let envKey = "qf_ck_test"
        let ctx = userContext("u_1")
        let fingerprint = ctx.defaultFingerprint()

        // Session 1: persist the canonical envelope.
        let store1: PersistenceStore = SharedMemoryStore()
        let p1 = Persistence(store: store1)
        let envelope = try JSONDecoder().decode(EvalEnvelope.self, from: try canonicalEnvelopeData())
        p1.save(envelope: envelope, envKey: envKey, fingerprint: fingerprint)

        // Session 2 (cold launch): a brand-new Persistence over the SAME backing
        // store loads the cached envelope and seeds a brand-new Store — no Loader,
        // no network.
        let p2 = Persistence(store: store1)
        let cached = try XCTUnwrap(
            p2.load(envKey: envKey, fingerprint: fingerprint),
            "cold start must find the previously persisted envelope")

        let store = Store()
        XCTAssertFalse(store.isReady)
        await store.apply(cached)  // synchronous-equivalent seed from cache
        XCTAssertTrue(store.isReady, "store is ready from cache with no network")
        XCTAssertTrue(store.isEnabled("new-checkout"), "served from cache")
        XCTAssertEqual(store.int("rate-limit", default: 0), 250)
    }

    /// Serve-on-error (Flagsmith #93): the cache is consulted for the SAME context
    /// when a poll fails, so a failed network keeps last-known values rather than
    /// reverting to defaults. We prove the persisted envelope is recoverable for
    /// the exact context the failed loader was fetching.
    func testServeFromCacheOnLoadError() async throws {
        let envKey = "qf_ck_test"
        let ctx = userContext("u_err")
        let fingerprint = ctx.defaultFingerprint()

        let backing: PersistenceStore = SharedMemoryStore()
        let persistence = Persistence(store: backing)
        let envelope = try JSONDecoder().decode(EvalEnvelope.self, from: try canonicalEnvelopeData())
        persistence.save(envelope: envelope, envKey: envKey, fingerprint: fingerprint)

        // The loader fails outright (all URLs error).
        let store = Store()
        let failClient = ScriptedClient([])  // empty -> throws noResponse
        let loader = makeLoader(client: failClient, context: ctx)
        do {
            _ = try await store.refresh(using: loader)
            XCTFail("loader should have thrown")
        } catch {
            // Expected. The integration then falls back to the cache for the SAME
            // context fingerprint (what the client coordinator will do).
        }
        let recovered = try XCTUnwrap(
            persistence.load(envKey: envKey, fingerprint: fingerprint),
            "serve-on-error must recover the cached envelope for the same context")
        await store.apply(recovered)
        XCTAssertTrue(store.isEnabled("new-checkout"), "served from cache after a failed poll")
    }

    // MARK: - 7. updateContext refetch (mirrors Unleash updateContext = stop+refetch+restart)

    /// Switching the loader's context fetches a NEW envelope (a different URL,
    /// so no stale 304), and applying it surfaces the new values and DOES notify
    /// subscribers because the resolved values changed.
    func testUpdateContextRefetchesAndAppliesNewValues() async throws {
        // First context returns the canonical envelope; second context returns the
        // mutated one. Both are 200s on distinct URLs (distinct base64url paths).
        let client = ScriptedClient([
            .init(status: 200, body: try canonicalEnvelopeData(), etag: "\"v1\"", requireIfNoneMatch: nil),
            .init(status: 200, body: try mutatedEnvelopeData(), etag: "\"v2\"", requireIfNoneMatch: nil),
        ])
        let loader = makeLoader(client: client, context: userContext("u_old"))
        let store = Store()
        let counter = NotifyCounter()
        let token = await store.subscribe { counter.bump() }
        defer { token.cancel() }

        try await store.refresh(using: loader)
        XCTAssertTrue(store.isEnabled("new-checkout"))   // canonical: true
        XCTAssertEqual(store.string("button-color", default: "x"), "green")
        XCTAssertEqual(counter.value, 1)

        // updateContext -> the loader now fetches for u_new (a NEW URL).
        await loader.updateContext(userContext("u_new"))
        let changed = try await store.refresh(using: loader)
        XCTAssertTrue(changed, "new context's envelope changed the resolved values")
        XCTAssertFalse(store.isEnabled("new-checkout"))  // mutated: false
        XCTAssertEqual(store.string("button-color", default: "x"), "red")
        XCTAssertEqual(counter.value, 2, "the context-switch change must notify subscribers")

        // The two requests hit different URLs (different encoded contexts).
        let urls = client.capturedRequests.compactMap { $0.url?.absoluteString }
        XCTAssertEqual(urls.count, 2)
        XCTAssertNotEqual(urls[0], urls[1], "updateContext must fetch a different URL")
    }

    // MARK: - 8. Decoder field-strip through the full read path (integrated, complements ConfigDecoderTests)

    /// Strip one server-optional field at a time, push the stripped envelope all
    /// the way through Loader -> Store, and assert the typed getters STILL return
    /// correct values. ConfigDecoderTests proves decode doesn't throw; this proves
    /// the END-TO-END read survives a missing optional (no crash, sane reason).
    func testFieldStripStillReadsThroughStore() async throws {
        let optionalFields = ["reason", "ruleIndex", "weightedValueIndex"]
        for field in optionalFields {
            var root = try JSONSerialization.jsonObject(with: try canonicalEnvelopeData()) as! [String: Any]
            var evals = root["evaluations"] as! [String: Any]
            for (k, v) in evals {
                var e = v as! [String: Any]
                e.removeValue(forKey: field)
                evals[k] = e
            }
            root["evaluations"] = evals
            let body = try JSONSerialization.data(withJSONObject: root)

            let client = ScriptedClient([
                .init(status: 200, body: body, etag: nil, requireIfNoneMatch: nil)
            ])
            let store = Store()
            try await store.refresh(using: makeLoader(client: client, context: userContext("u_1")))

            XCTAssertTrue(store.isEnabled("new-checkout"),
                "value read must survive stripping optional \(field)")
            XCTAssertEqual(store.string("button-color", default: "x"), "green",
                "value read must survive stripping optional \(field)")
            // With `reason` stripped, details() falls back to STATIC (JS parity).
            let details = store.details("new-checkout")
            if field == "reason" {
                XCTAssertEqual(details.reason, .static,
                    "absent reason must fall back to STATIC, not error")
            }
        }
    }
}

/// Thread-safe notification counter for subscriber-fire assertions.
final class NotifyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _v = 0
    func bump() { lock.lock(); _v += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _v }
}

/// An in-memory `PersistenceStore` whose backing survives across distinct
/// `Persistence` instances (simulates cross-launch on-disk survival). The
/// existing `PersistenceTests.MemoryStore` is private to that file; this one is
/// shared so the cold-start parity test can hand the SAME backing to two
/// `Persistence` instances.
final class SharedMemoryStore: PersistenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var inlineData: [String: Data] = [:]
    private var fileData: [String: Data] = [:]
    private var indexData: Data?

    func write(key: String, data: Data, inline: Bool) {
        lock.lock(); defer { lock.unlock() }
        if inline { inlineData[key] = data; fileData[key] = nil }
        else { fileData[key] = data; inlineData[key] = nil }
    }
    func read(key: String, inline: Bool) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return inline ? inlineData[key] : fileData[key]
    }
    func remove(key: String, inline: Bool) {
        lock.lock(); defer { lock.unlock() }
        if inline { inlineData[key] = nil } else { fileData[key] = nil }
    }
    func writeIndex(_ data: Data) { lock.lock(); indexData = data; lock.unlock() }
    func readIndex() -> Data? { lock.lock(); defer { lock.unlock() }; return indexData }
    func removeIndex() { lock.lock(); indexData = nil; lock.unlock() }
}
