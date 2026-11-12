import Foundation
import XCTest

@testable import Quonfig

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The default (and every `domain`-derived) API-URL list carries a primary and a
/// secondary leg, and the SDK fails over between them. An explicit `apiURLs`
/// with a single entry silently drops the secondary, so the SDK logs a one-time
/// WARN at init pointing the caller at the fix. Mirrors sdk-go
/// `apiurls_failover_warn_test.go` (qfg-ea56y).
final class APIURLsFailoverWarnTests: XCTestCase {
    static let fragment = "explicit apiURLs disables automatic failover"

    static let body = Data(
        """
        {"evaluations":{
          "greeting":{"value":{"type":"string","value":"live"},"configId":"c1",
            "configType":"config","valueType":"string","reason":"STATIC"}
        },"meta":{"version":"1","environment":"production"}}
        """.utf8)

    let ctx = QuonfigContext(["user": ["key": .string("u_1")]])

    func initialize(apiURLs: [URL]?, logs: CapturingLogSink) async throws -> Quonfig {
        let cfg = Configuration(
            sdkKey: "qf_pk_test", apiURLs: apiURLs,
            telemetryURL: URL(string: "https://telemetry.quonfig.com")!,
            pollInterval: 0, collectEvaluationSummaries: false, logSink: logs)
        let client = InitFailureTests.ScriptedClient { _ in .ok(Self.body) }
        let loader = Loader(
            sdkKey: cfg.sdkKey, context: ctx,
            apiURLs: QuonfigURLs.resolve(from: cfg).apiURLs,
            collectContextMode: cfg.collectContextMode, client: client)
        return try await Quonfig.make(
            configuration: cfg, context: ctx, loader: loader,
            persistence: Persistence(store: InMemoryFallbackStore()), aggregator: nil,
            lifecycleProvider: QuonfigClientTests.ManualLifecycleProvider(center: NotificationCenter()),
            initTimeout: 2, fingerprint: defaultContextFingerprint)
    }

    func testSingleExplicitAPIURLWarnsOnce() async throws {
        let logs = CapturingLogSink()
        let q = try await initialize(apiURLs: [URL(string: "https://primary.example.test")!], logs: logs)
        XCTAssertEqual(logs.count(.warn, Self.fragment), 1, "\(logs.all)")
        await q.shutdown()
    }

    func testTwoExplicitAPIURLsDoNotWarn() async throws {
        let logs = CapturingLogSink()
        let q = try await initialize(
            apiURLs: [URL(string: "https://primary.example.test")!, URL(string: "https://secondary.example.test")!],
            logs: logs)
        XCTAssertEqual(logs.count(.warn, Self.fragment), 0, "\(logs.all)")
        await q.shutdown()
    }

    func testDefaultAPIURLsDoNotWarn() async throws {
        let logs = CapturingLogSink()
        let q = try await initialize(apiURLs: nil, logs: logs)
        XCTAssertEqual(logs.count(.warn, Self.fragment), 0, "\(logs.all)")
        await q.shutdown()
    }
}
