import Foundation
import XCTest

@testable import Quonfig

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Telemetry: the eval-summary aggregator + uploader (qfg-2t2d.8).
///
/// Verifies the exact POST wire shape against the pinned fixture
/// (`Fixtures/telemetry-post.body.json`, qfg-2t2d.1) and the exposure-decoupled
/// read wiring into `Store`. The transport policy (retention, caps, status
/// handling, logging) is in `TelemetryTransportTests`.
final class TelemetryTests: XCTestCase {
    // MARK: Mock transport

    /// Captures every POST; can be scripted to fail N times.
    final class MockClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        private(set) var bodies: [Data] = []
        var failCount: Int = 0  // first N posts throw

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock()
            defer { lock.unlock() }
            let idx = requests.count
            requests.append(request)
            bodies.append(request.httpBody ?? Data())
            if idx < failCount {
                throw URLError(.notConnectedToInternet)
            }
            let http = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data("{\"success\":true}".utf8), http)
        }
    }

    /// In-memory queue store so tests don't touch the filesystem. The disk
    /// queue itself is covered by `TelemetryTransportTests`.
    final class MemoryQueueStore: TelemetryQueueStore, @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [StoredTelemetryBatch] = []
        func load() -> [StoredTelemetryBatch] {
            lock.lock()
            defer { lock.unlock() }
            return batches
        }
        func save(id: String, body: Data) {
            lock.lock()
            defer { lock.unlock() }
            batches.append(StoredTelemetryBatch(id: id, body: body, createdAt: Date()))
        }
        func remove(id: String) {
            lock.lock()
            defer { lock.unlock() }
            batches.removeAll { $0.id == id }
        }
    }

    private func makeUploader(_ client: MockClient) -> TelemetryUploader {
        TelemetryUploader(
            postURL: URL(string: "https://telemetry.quonfig-localhost/api/v1/telemetry/")!,
            sdkKey: "qf_ck_test", userAgent: "Quonfig-Swift/test", client: client)
    }

    private func details(
        _ value: QuonfigValue, reason: EvaluationReason = .static, configType: String,
        configId: String = "cfg_x", ruleIndex: Int? = nil, weightedValueIndex: Int? = nil
    ) -> EvaluationDetails {
        EvaluationDetails(
            value: value, reason: reason, ruleIndex: ruleIndex,
            weightedValueIndex: weightedValueIndex,
            variant: buildVariant(reason: reason, ruleIndex: ruleIndex, weightedValueIndex: weightedValueIndex),
            configId: configId, configType: configType)
    }

    // MARK: - Aggregation

    func testRecordCountsAndDedupesByKeyType() async {
        let client = MockClient()
        let agg = SummaryAggregator(
            uploader: makeUploader(client), instanceHash: "ih", queueStore: MemoryQueueStore())

        for _ in 0..<17 {
            await agg.record(key: "new-checkout", details: details(.bool(true), configType: "feature_flag"))
        }
        await agg.record(
            key: "button-color",
            details: details(.string("green"), reason: .targetingMatch, configType: "config", ruleIndex: 0))

        let live = await agg.liveKeyCount
        XCTAssertEqual(live, 2, "two distinct {key,type} counters")
    }

    func testEmptyWindowSkipsUpload() async {
        let client = MockClient()
        let agg = SummaryAggregator(
            uploader: makeUploader(client), instanceHash: "ih", queueStore: MemoryQueueStore())
        await agg.flush()
        XCTAssertEqual(client.requests.count, 0, "empty window posts nothing (JS parity)")
    }

    // MARK: - Wire shape (vs pinned fixture)

    func testPostBodyMatchesPinnedFixtureShape() async throws {
        let client = MockClient()
        let store = MemoryQueueStore()
        let agg = SummaryAggregator(
            uploader: makeUploader(client), instanceHash: "ih-123", clientVersion: "0.0.1",
            queueStore: store)

        for _ in 0..<3 {
            await agg.record(
                key: "new-checkout", details: details(.bool(true), configType: "feature_flag", configId: "cfg_a"))
        }
        await agg.flush()

        XCTAssertEqual(client.requests.count, 1)
        let req = client.requests[0]
        XCTAssertEqual(req.httpMethod, "POST")
        // HTTP Basic with the fleet "1:" username + content type.
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), authHeaderValue(sdkKey: "qf_ck_test"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.url?.absoluteString, "https://telemetry.quonfig-localhost/api/v1/telemetry/")

        let json = try JSONSerialization.jsonObject(with: client.bodies[0]) as! [String: Any]
        XCTAssertEqual(json["instanceHash"] as? String, "ih-123")
        XCTAssertEqual(json["clientName"] as? String, "swift")
        XCTAssertEqual(json["clientVersion"] as? String, "0.0.1")
        let events = json["events"] as! [[String: Any]]
        let summaries = events[0]["summaries"] as! [String: Any]
        XCTAssertNotNil(summaries["start"] as? NSNumber)
        XCTAssertNotNil(summaries["end"] as? NSNumber)
        let list = summaries["summaries"] as! [[String: Any]]
        let entry = list[0]
        XCTAssertEqual(entry["key"] as? String, "new-checkout")
        XCTAssertEqual(entry["type"] as? String, "feature_flag")
        let counter = (entry["counters"] as! [[String: Any]])[0]
        XCTAssertEqual(counter["count"] as? Int, 3)
        XCTAssertEqual(counter["configId"] as? String, "cfg_a")
        XCTAssertEqual(counter["reason"] as? String, "STATIC")  // reason is a STRING, per fixture
        let selected = counter["selectedValue"] as! [String: Any]
        XCTAssertEqual(selected["bool"] as? Bool, true)  // { [valueType]: value }
    }

    func testSelectedValueShapes() {
        func obj(_ v: QuonfigValue, _ t: String) -> [String: QuonfigJSONValue]? {
            if case .object(let o) = SummaryAggregator.selectedValue(for: v, configType: t) { return o }
            return nil
        }
        XCTAssertEqual(obj(.string("green"), "config"), ["string": .string("green")])
        XCTAssertEqual(obj(.int(42), "config"), ["int": .int(42)])
        // string_list massages to { string_list: { values: [...] } } (JS massageSelectedValue).
        if case .object(let o)? = Optional(
            SummaryAggregator.selectedValue(for: .stringList(["a", "b"]), configType: "config")),
            case .object(let inner)? = o["string_list"],
            case .array(let arr)? = inner["values"]
        {
            XCTAssertEqual(arr, [.string("a"), .string("b")])
        } else {
            XCTFail("string_list shape")
        }
    }

    func testBoundedKeys() async {
        let client = MockClient()
        let agg = SummaryAggregator(
            uploader: makeUploader(client), instanceHash: "ih", maxKeys: 2,
            queueStore: MemoryQueueStore())
        for i in 0..<5 {
            await agg.record(key: "k\(i)", details: details(.bool(true), configType: "feature_flag"))
        }
        let live = await agg.liveKeyCount
        XCTAssertEqual(live, 2, "distinct keys capped at maxKeys")
    }

    // MARK: - Store wiring: exposure decoupled from reads

    func testExposedReadRecordsButSuppressedDoesNot() async throws {
        let store = Store()
        let env = EvalEnvelope(
            evaluations: [
                "new-checkout": Evaluation(
                    value: WireValue(type: "bool", value: .bool(true)),
                    configId: "cfg_a", configType: "feature_flag", valueType: "bool",
                    reason: .static, ruleIndex: nil, weightedValueIndex: nil)
            ],
            meta: EvalMeta(version: "v1", environment: "production"))
        await store.apply(env)

        // Count exposures fanned out from the store via a recorder closure.
        let counter = ExposureCounter()
        await store.setExposureRecorder { key, _ in counter.bump(key) }

        // EXPOSED reads record.
        _ = store.isEnabled("new-checkout")
        _ = store.isEnabled("new-checkout")
        // SUPPRESSED reads (logExposure:false) do NOT record.
        _ = store.isEnabled("new-checkout", logExposure: false)

        // Give the detached recorder Tasks a moment (they're synchronous closures
        // here, so this is belt-and-braces).
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.count(for: "new-checkout"), 2, "only EXPOSED reads count")
    }

    final class ExposureCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func bump(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
        func count(for key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
    }
}
