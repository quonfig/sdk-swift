import Foundation
import XCTest

@testable import Quonfig

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The cross-SDK typed-getter contract (qfg-zvyy; JEFF'S DECISIONS 2026-10-22/23),
/// ported from the integration-test-data v2026.10.23 `getter.contract.*` matrix,
/// which the frontend SDKs do not consume. Every test drives the PUBLIC `Quonfig`
/// client getters.
///
/// The rule: a read that cannot return a value of the getter's type (a wrong
/// type, a malformed value, an unresolvable value) returns the caller's default
/// and logs one WARN per key per client. No string coercion. int <-> double
/// converts only when exact. `isEnabled` never throws: `false` + one WARN per key.
///
/// Missing ENV_VAR and decryption failures are resolved server-side for the
/// frontend: api-delivery omits the key (qfg-2agi.20), so the client sees an
/// absent key and returns the caller's default. That path is covered by the
/// "missing key" cases.
final class TypedGetterContractTests: XCTestCase {
    // MARK: Harness

    final class OneShotClient: HTTPClient, @unchecked Sendable {
        let body: Data
        init(body: Data) { self.body = body }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["ETag": "e1"])!
            return (body, http)
        }
    }

    private func eval(_ type: String, _ value: QuonfigJSONValue?) -> Evaluation {
        Evaluation(
            value: WireValue(type: type, value: value), configId: "cfg_\(type)", configType: "config",
            valueType: type, reason: .static, ruleIndex: nil, weightedValueIndex: nil)
    }

    /// The contract fixtures, mirroring `getter.contract.*` in integration-test-data.
    private var contractEvaluations: [String: Evaluation] {
        [
            "c.bool": eval("bool", .bool(true)),
            "c.bool.false": eval("bool", .bool(false)),
            "c.int": eval("int", .int(42)),
            "c.double": eval("double", .double(3.5)),
            "c.double.whole": eval("double", .double(3.0)),
            "c.double.maxsafe": eval("double", .double(9_007_199_254_740_991)),
            "c.double.unsafe": eval("double", .double(9_007_199_254_740_992)),
            "c.double.huge": eval("double", .double(1e300)),
            "c.string": eval("string", .string("fast")),
            "c.string.false": eval("string", .string("false")),
            "c.string.true": eval("string", .string("true")),
            "c.string.number": eval("string", .string("3")),
            "c.string.duration": eval("string", .string("PT1S")),
            "c.log_level": eval("log_level", .string("WARN")),
            "c.string_list": eval("string_list", .array([.string("a"), .string("b")])),
            "c.duration": eval("duration", .string("PT30S")),
            "c.json": eval("json", .object(["a": .int(1)])),
            "c.int.malformed": eval("int", .string("twelve")),
            "c.double.malformed": eval("double", .string("abc")),
            "c.provided": eval("provided", .object(["source": .string("ENV_VAR"), "lookup": .string("UNSET")])),
        ]
    }

    private func makeClient(logs: CapturingLogSink) async throws -> Quonfig {
        let envelope = EvalEnvelope(
            evaluations: contractEvaluations, meta: EvalMeta(version: "1", environment: "production"))
        let body = try JSONEncoder().encode(envelope)
        let config = Configuration(
            sdkKey: "qf_ck_test", apiURLs: [URL(string: "https://primary.quonfig.com")!],
            telemetryURL: URL(string: "https://telemetry.quonfig.com")!,
            pollInterval: 0, collectEvaluationSummaries: false, logSink: logs)
        let context = QuonfigContext(["user": ["key": .string("u_1")]])
        let loader = Loader(
            sdkKey: config.sdkKey, context: context, apiURLs: [config.apiURLs!.first!],
            collectContextMode: config.collectContextMode, client: OneShotClient(body: body))
        let q = try await Quonfig.make(
            configuration: config, context: context, loader: loader,
            persistence: Persistence(store: InMemoryFallbackStore()), aggregator: nil,
            lifecycleProvider: QuonfigClientTests.ManualLifecycleProvider(center: NotificationCenter()),
            initTimeout: 5, fingerprint: defaultContextFingerprint)
        // Install the exact in-memory values (JSON would fold 3.0 into 3), so the
        // matrix sees the stored types it names.
        await q.configStore.apply(
            EvalEnvelope(evaluations: contractEvaluations, meta: EvalMeta(version: "2", environment: "production")))
        return q
    }

    private var allKeys: [String] { contractEvaluations.keys.sorted() }

    // MARK: Matrix: each getter on each stored type

    func testIsEnabledIsTrueOnlyForStoredBoolTrue() async throws {
        let q = try await makeClient(logs: CapturingLogSink())
        for key in allKeys {
            XCTAssertEqual(q.isEnabled(key), key == "c.bool", "isEnabled(\(key))")
        }
    }

    func testStringGetterReadsOnlyStringAndLogLevel() async throws {
        let q = try await makeClient(logs: CapturingLogSink())
        let want: [String: String] = [
            "c.string": "fast", "c.string.false": "false", "c.string.true": "true",
            "c.string.number": "3", "c.string.duration": "PT1S", "c.log_level": "WARN",
        ]
        for key in allKeys {
            XCTAssertEqual(q.string(key, default: "DEFAULT"), want[key] ?? "DEFAULT", "string(\(key))")
        }
    }

    func testIntGetterSafeConversionsOnly() async throws {
        let q = try await makeClient(logs: CapturingLogSink())
        let want: [String: Int] = [
            "c.int": 42, "c.double.whole": 3, "c.double.maxsafe": 9_007_199_254_740_991,
        ]
        for key in allKeys {
            XCTAssertEqual(q.int(key, default: -1), want[key] ?? -1, "int(\(key))")
        }
    }

    func testDoubleGetterReadsDoubleAndInt() async throws {
        let q = try await makeClient(logs: CapturingLogSink())
        let want: [String: Double] = [
            "c.int": 42.0, "c.double": 3.5, "c.double.whole": 3.0,
            "c.double.maxsafe": 9_007_199_254_740_991, "c.double.unsafe": 9_007_199_254_740_992,
            "c.double.huge": 1e300,
        ]
        for key in allKeys {
            XCTAssertEqual(q.double(key, default: -1), want[key] ?? -1, "double(\(key))")
        }
    }

    func testStringListGetterReadsOnlyStringList() async throws {
        let q = try await makeClient(logs: CapturingLogSink())
        for key in allKeys {
            XCTAssertEqual(
                q.stringList(key, default: ["DEFAULT"]), key == "c.string_list" ? ["a", "b"] : ["DEFAULT"],
                "stringList(\(key))")
        }
    }

    func testDurationGetterReadsOnlyDuration() async throws {
        let q = try await makeClient(logs: CapturingLogSink())
        for key in allKeys {
            XCTAssertEqual(q.duration(key, default: -1), key == "c.duration" ? 30 : -1, "duration(\(key))")
        }
    }

    func testJSONGetterReadsOnlyJSON() async throws {
        let q = try await makeClient(logs: CapturingLogSink())
        for key in allKeys {
            let got = q.json(key)
            if key == "c.json" {
                XCTAssertEqual(got?["a"] as? Int, 1, "json(\(key))")
            } else {
                XCTAssertNil(got, "json(\(key)) must be absent")
            }
        }
    }

    // MARK: Values JSON cannot store: never trap, never truncate

    func testIntGetterOnNonFiniteAndFractionalDoublesReturnsDefault() async throws {
        let q = try await makeClient(logs: CapturingLogSink())
        await q.configStore.apply(
            EvalEnvelope(
                evaluations: [
                    "nan": eval("double", .double(.nan)),
                    "inf": eval("double", .double(.infinity)),
                    "ninf": eval("double", .double(-.infinity)),
                    "frac": eval("double", .double(3.9)),
                    "negfrac": eval("double", .double(-3.9)),
                    "minsafe": eval("double", .double(-9_007_199_254_740_991)),
                    "belowsafe": eval("double", .double(-9_007_199_254_740_992)),
                    "intfrac": eval("int", .double(3.9)),
                    "intwhole": eval("int", .double(42.0)),
                    "intunsafe": eval("int", .double(1e20)),
                    "int64max": eval("int", .int(Int64.max)),
                ], meta: EvalMeta(version: "3", environment: "production")))
        XCTAssertEqual(q.int("nan", default: 7), 7)
        XCTAssertEqual(q.int("inf", default: 7), 7)
        XCTAssertEqual(q.int("ninf", default: 7), 7)
        XCTAssertEqual(q.int("frac", default: 7), 7, "never truncate 3.9")
        XCTAssertEqual(q.int("negfrac", default: 7), 7, "never truncate -3.9")
        XCTAssertEqual(q.int("minsafe", default: 7), -9_007_199_254_740_991)
        XCTAssertEqual(q.int("belowsafe", default: 7), 7)
        XCTAssertEqual(q.int("intfrac", default: 7), 7, "malformed int")
        XCTAssertEqual(q.int("intwhole", default: 7), 42)
        XCTAssertEqual(q.int("intunsafe", default: 7), 7)
        XCTAssertEqual(q.int("int64max", default: 7), Int(Int64.max))
        XCTAssertTrue(q.double("nan", default: 0).isNaN, "the double getter returns the stored double")
        XCTAssertEqual(q.double("intfrac", default: 7), 7, "malformed int is not a double either")
    }

    // MARK: Logging: once per key, never the value

    func testEveryFailedReadLogsOneWarnPerKey() async throws {
        let logs = CapturingLogSink()
        let q = try await makeClient(logs: logs)
        for _ in 0..<3 {
            for key in allKeys {
                _ = q.isEnabled(key)
                _ = q.string(key, default: "d")
                _ = q.int(key, default: 0)
                _ = q.double(key, default: 0)
                _ = q.stringList(key, default: [])
                _ = q.duration(key, default: 0)
                _ = q.json(key)
                _ = q.isEnabled(key, logExposure: false)
                _ = q.int(key, default: 0, logExposure: false)
            }
        }
        // Every fixture key fails at least one getter, so each logs exactly once.
        for key in allKeys {
            let pattern = NSRegularExpression.escapedPattern(for: "\"\(key)\"")
            XCTAssertEqual(logs.count(.warn, pattern), 1, "WARNs for \(key):\n\(logs.all.joined(separator: "\n"))")
        }
        for secret in ["fast", "twelve", "abc", "ENV_VAR", "UNSET"] {
            XCTAssertFalse(logs.all.contains { $0.contains(secret) }, "log leaked a value: \(secret)")
        }
    }

    func testSuccessfulReadsDoNotLog() async throws {
        let logs = CapturingLogSink()
        let q = try await makeClient(logs: logs)
        _ = q.isEnabled("c.bool")
        _ = q.isEnabled("c.bool.false")
        _ = q.string("c.string", default: "d")
        _ = q.int("c.int", default: 0)
        _ = q.double("c.int", default: 0)
        _ = q.int("c.double.whole", default: 0)
        _ = q.stringList("c.string_list", default: [])
        _ = q.duration("c.duration", default: 0)
        _ = q.json("c.json")
        XCTAssertEqual(logs.count(.warn), 0, logs.all.joined(separator: "\n"))
    }

    func testMissingKeyTypedReadIsNotLogged() async throws {
        let logs = CapturingLogSink()
        let q = try await makeClient(logs: logs)
        XCTAssertEqual(q.string("missing.key", default: "d"), "d")
        XCTAssertEqual(q.int("missing.key", default: 5), 5)
        XCTAssertNil(q.json("missing.key"))
        XCTAssertEqual(logs.count(.warn, "missing\\.key"), 0, logs.all.joined(separator: "\n"))
    }

    func testIsEnabledOnMissingKeyReturnsFalseAndLogsOnce() async throws {
        let logs = CapturingLogSink()
        let q = try await makeClient(logs: logs)
        for _ in 0..<3 {
            XCTAssertFalse(q.isEnabled("missing.flag"))
        }
        XCTAssertEqual(logs.count(.warn, "missing\\.flag"), 1, logs.all.joined(separator: "\n"))
    }

    func testIsEnabledBeforeReadyDoesNotLog() {
        let logs = CapturingLogSink()
        let store = Store(logSink: logs)
        XCTAssertFalse(store.isEnabled("any.flag"))
        XCTAssertEqual(store.int("any.int", default: 4), 4)
        XCTAssertEqual(logs.count(.warn), 0)
    }

    // MARK: Details report ERROR / TYPE_MISMATCH

    func testTypedDetailsReportTypeMismatch() async throws {
        let logs = CapturingLogSink()
        let q = try await makeClient(logs: logs)

        let mismatch = q.details("c.string.false", as: .bool)
        XCTAssertNil(mismatch.value, "a stored \"false\" is never a bool")
        XCTAssertEqual(mismatch.reason, .error)
        XCTAssertEqual(mismatch.errorCode, .typeMismatch)
        XCTAssertEqual(mismatch.variant, "default")
        XCTAssertEqual(mismatch.configId, "cfg_string")

        let fractional = q.details("c.double", as: .int)
        XCTAssertNil(fractional.value)
        XCTAssertEqual(fractional.errorCode, .typeMismatch)

        let malformed = q.details("c.int.malformed", as: .int)
        XCTAssertNil(malformed.value)
        XCTAssertEqual(malformed.reason, .error)
        XCTAssertEqual(malformed.errorCode, .typeMismatch)

        let widened = q.details("c.int", as: .double)
        XCTAssertEqual(widened.value, .double(42))
        XCTAssertEqual(widened.reason, .static)
        XCTAssertNil(widened.errorCode)

        let whole = q.details("c.double.whole", as: .int)
        XCTAssertEqual(whole.value, .int(3))
        XCTAssertNil(whole.errorCode)

        let missing = q.details("missing.key", as: .string)
        XCTAssertEqual(missing.reason, .error)
        XCTAssertEqual(missing.errorCode, .flagNotFound)

        XCTAssertEqual(logs.count(.warn, "c\\.string\\.false"), 1)
        XCTAssertEqual(logs.count(.warn, "missing\\.key"), 0)
    }

    func testUntypedDetailsOnMalformedValueIsErrorWithoutTheValue() async throws {
        let q = try await makeClient(logs: CapturingLogSink())
        for key in ["c.int.malformed", "c.double.malformed"] {
            let d = q.details(key)
            XCTAssertNil(d.value, "\(key) must not surface the raw value")
            XCTAssertEqual(d.reason, .error, key)
            XCTAssertEqual(d.errorCode, .typeMismatch, key)
        }
        let ok = q.details("c.int")
        XCTAssertEqual(ok.value, .int(42))
        XCTAssertNil(ok.errorCode)
        XCTAssertEqual(QuonfigClientTestsNotReady.details().errorCode, .providerNotReady)
    }
}

/// A store that never got an envelope.
private enum QuonfigClientTestsNotReady {
    static func details() -> EvaluationDetails { Store().details("k") }
}
