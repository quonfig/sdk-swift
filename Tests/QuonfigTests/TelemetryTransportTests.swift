import Foundation
import XCTest

@testable import Quonfig

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Telemetry transport contract, mobile subset (qfg-y8je.12).
//
// Spec: integration-test-data/chaos/telemetry-transport-contract.md ("Frontend
// and mobile": sdk-swift runs T2, T3 and T5 against its disk queue) and the
// policy P1-P10 in project/plans/2026-09-24-sdk-telemetry-transport-policy.md.
//
// Fixture per the contract: a URLProtocol stub scripted per received POST
// (status, Retry-After, hang), a manual clock injected into the aggregator, a
// capturing log sink, and the REAL on-disk queue in a temp directory. The
// aggregator and its queue are never mocked. Ticks are called directly.

// MARK: - Fixture

/// Scripted state shared by `StubTelemetryProtocol` instances. One per process;
/// reset in `setUp`. Everything behind a lock.
final class StubTelemetryState: @unchecked Sendable {
    struct Step {
        var status: Int = 200
        var retryAfter: String?
        var hang = false
    }

    private let lock = NSLock()
    private var script: [Step] = []
    private var fallback = Step()
    private var received: [Data] = []
    private var parked: [StubTelemetryProtocol] = []

    func reset() {
        lock.lock()
        script = []
        fallback = Step()
        received = []
        let old = parked
        parked = []
        lock.unlock()
        for p in old { p.respond(Step(status: 200)) }
    }

    /// Queue responses for the next POSTs, in order; `then` answers every POST
    /// after the script runs out.
    func script(_ steps: [Step], then fallback: Step = Step()) {
        lock.lock()
        script = steps
        self.fallback = fallback
        lock.unlock()
    }

    func next(body: Data) -> Step {
        lock.lock()
        defer { lock.unlock() }
        received.append(body)
        return script.isEmpty ? fallback : script.removeFirst()
    }

    func park(_ p: StubTelemetryProtocol) {
        lock.lock()
        parked.append(p)
        lock.unlock()
    }

    func unpark(_ p: StubTelemetryProtocol) {
        lock.lock()
        parked.removeAll { $0 === p }
        lock.unlock()
    }

    /// Answer every hung POST with `status`.
    func release(status: Int) {
        lock.lock()
        let old = parked
        parked = []
        lock.unlock()
        for p in old { p.respond(Step(status: status)) }
    }

    var postCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return received.count
    }

    func body(_ i: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        return received[i]
    }
}

/// `URLProtocol` stub standing in for api-telemetry. Records the raw body of
/// every POST (including ones that later hang or get cancelled) and answers per
/// the script.
final class StubTelemetryProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubTelemetryState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let step = Self.state.next(body: Self.readBody(request))
        if step.hang {
            Self.state.park(self)
            return
        }
        respond(step)
    }

    override func stopLoading() {
        Self.state.unpark(self)
    }

    func respond(_ step: StubTelemetryState.Step) {
        var headers = ["Content-Type": "application/json"]
        if let ra = step.retryAfter { headers["Retry-After"] = ra }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: step.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands a protocol the body as a stream, not `httpBody`.
    static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Manual clock: the aggregator reads `now` from it; tests `advance` it.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_790_000_000)
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return t
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        t = t.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Capturing log sink at every level (the contract's `log_count`).
final class CapturingLogSink: QuonfigLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [(QuonfigLogLevel, String)] = []
    func emit(level: QuonfigLogLevel, message: String) {
        lock.lock()
        lines.append((level, message))
        lock.unlock()
    }
    func count(_ level: QuonfigLogLevel, _ pattern: String = ".*") -> Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.filter { entry in
            entry.0 == level && entry.1.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }.count
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines.map { "\($0.0) \($0.1)" }
    }
}

// MARK: - Tests

final class TelemetryTransportTests: XCTestCase {
    private var dir: URL!
    private var clock: ManualClock!
    private var logs: CapturingLogSink!
    private var stub: StubTelemetryState { StubTelemetryProtocol.state }

    override func setUp() {
        super.setUp()
        freshFixture()
    }

    override func tearDown() {
        cleanFixture()
        super.tearDown()
    }

    /// Per-case fixture (the parameterized tests reset it per status).
    private func freshFixture() {
        stub.reset()
        clock = ManualClock()
        logs = CapturingLogSink()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qfg-telemetry-\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanFixture() {
        stub.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeAggregator(
        maxKeys: Int = SummaryAggregator.defaultMaxKeys,
        policy: TelemetryTransportPolicy = TelemetryTransportPolicy(),
        instanceHash: String = "ih-launch-1"
    ) -> SummaryAggregator {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubTelemetryProtocol.self]
        let uploader = TelemetryUploader(
            postURL: URL(string: "https://telemetry.quonfig-localhost/api/v1/telemetry/")!,
            sdkKey: "qf_ck_test", userAgent: "Quonfig-Swift/test", client: URLSession(configuration: cfg))
        let clock = self.clock!
        return SummaryAggregator(
            uploader: uploader, instanceHash: instanceHash, maxKeys: maxKeys, policy: policy,
            queueStore: TelemetryFileQueueStore(directory: dir), logSink: logs, now: { clock.now() })
    }

    private func details(_ i: Int = 1) -> EvaluationDetails {
        EvaluationDetails(
            value: .int(Int64(i)), reason: .static, ruleIndex: nil, weightedValueIndex: nil,
            variant: buildVariant(reason: .static, ruleIndex: nil, weightedValueIndex: nil),
            configId: "cfg_\(i)", configType: "config")
    }

    /// Record an evaluation set: `n` distinct keys `<prefix>-0 ..`.
    private func record(_ agg: SummaryAggregator, _ prefix: String, _ n: Int = 3) async {
        for i in 0..<n {
            await agg.record(key: "\(prefix)-\(i)", details: details(i))
        }
    }

    /// One tick, `interval` seconds after the previous one.
    private func tick(_ agg: SummaryAggregator, after interval: TimeInterval = 60) async {
        clock.advance(interval)
        await agg.tick()
    }

    /// The summary keys carried in a POST body.
    private func keys(_ body: Data) -> Set<String> {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let events = json["events"] as? [[String: Any]]
        else { return [] }
        var out = Set<String>()
        for e in events {
            let s = (e["summaries"] as? [String: Any])?["summaries"] as? [[String: Any]] ?? []
            for entry in s { if let k = entry["key"] as? String { out.insert(k) } }
        }
        return out
    }

    private func prefixes(_ body: Data) -> Set<String> {
        Set(keys(body).map { String($0.split(separator: "-").first ?? "") })
    }

    private func diskFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return names.filter { $0.pathExtension == "batch" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func eventually(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    // MARK: Defaults (P1, P5, flush interval)

    func testShippedDefaults() {
        let p = TelemetryTransportPolicy()
        XCTAssertEqual(p.flushInterval, 60)
        XCTAssertEqual(p.timeout, 15, "P1 mobile foreground timeout")
        XCTAssertEqual(p.maxRetainedBatches, 5)
        XCTAssertEqual(p.maxRetainedBytes, 524_288, "P5 mobile byte cap stays 512KB")
        XCTAssertEqual(p.maxRetainedAge, 300)
        XCTAssertEqual(SummaryAggregator.defaultMaxKeys, 100_000)
        XCTAssertEqual(SummaryAggregator.backgroundFlushBudget, 5, "P8 iOS background task ~5s")
        XCTAssertEqual(SummaryAggregator.resendFloor, 30)
        XCTAssertEqual(SummaryAggregator.retryAfterCap, 600)

        let c = Configuration(sdkKey: "k")
        XCTAssertEqual(c.telemetryFlushInterval, 60)
        XCTAssertEqual(c.telemetryTimeout, 15)
        XCTAssertEqual(c.telemetryMaxRetainedBatches, 5)
        XCTAssertEqual(c.telemetryMaxRetainedBytes, 524_288)
        XCTAssertEqual(c.telemetryMaxRetainedAge, 300)
        XCTAssertEqual(c.telemetryMaxEvaluationSummaries, 100_000)
        XCTAssertNil(c.logSink)
        let fromConfig = TelemetryTransportPolicy(configuration: c)
        XCTAssertEqual(fromConfig, p)
    }

    // MARK: T2 - 5xx retains verbatim and resends (P4, P5)

    func testT2_5xxRetainsVerbatimAndResends() async {
        stub.script([.init(status: 503), .init(status: 503), .init(status: 200), .init(status: 200)])
        let agg = makeAggregator()

        await record(agg, "a")
        await tick(agg)  // tick 1: POST 0 carries A -> 503
        var retained = await agg.retainedCount
        XCTAssertEqual(retained, 1)
        XCTAssertEqual(diskFiles().count, 1, "the failed batch is on disk")
        XCTAssertEqual(try? Data(contentsOf: diskFiles()[0]), stub.body(0), "disk holds the exact POSTed bytes")

        await record(agg, "b")
        await tick(agg)  // tick 2: POST 1 carries A -> 503; B appended behind it
        retained = await agg.retainedCount
        XCTAssertEqual(retained, 2)
        XCTAssertEqual(diskFiles().count, 2)

        await tick(agg)  // tick 3: POST 2 = A -> 200, POST 3 = B -> 200
        XCTAssertEqual(stub.postCount, 4)
        XCTAssertEqual(sha256Hex(stub.body(0)), sha256Hex(stub.body(1)))
        XCTAssertEqual(sha256Hex(stub.body(1)), sha256Hex(stub.body(2)))
        XCTAssertEqual(prefixes(stub.body(0)), ["a"])
        XCTAssertEqual(prefixes(stub.body(3)), ["b"], "B went out in its own batch, never merged into A")
        retained = await agg.retainedCount
        XCTAssertEqual(retained, 0)
        XCTAssertEqual(diskFiles().count, 0, "removed from disk only after the 2xx")
        XCTAssertEqual(logs.count(.info, "recover"), 1)
        XCTAssertEqual(logs.count(.warn), 0)
        XCTAssertEqual(logs.count(.error), 0)
    }

    // MARK: T3 - non-retryable 4xx (P3)

    func testT3a_AuthStatusesDisableTelemetry() async {
        for status in [401, 403, 404] {
            cleanFixture()
            freshFixture()
            stub.script([.init(status: 503), .init(status: status)], then: .init(status: 200))
            let agg = makeAggregator()

            await record(agg, "a")
            await tick(agg)  // 503: one retained batch
            await record(agg, "b")
            await tick(agg)  // POST 1 -> auth failure

            XCTAssertEqual(logs.count(.error, "\(status)"), 1, "\(status): one ERROR")
            let enabled = await agg.isTelemetryEnabled
            XCTAssertFalse(enabled, "\(status): telemetry disabled for the process")
            let retained = await agg.retainedCount
            XCTAssertEqual(retained, 0, "\(status): retained queue dropped")
            XCTAssertEqual(diskFiles().count, 0, "\(status): disk queue dropped")
            XCTAssertEqual(logs.count(.warn), 0, "\(status): auth failure is one ERROR, then silence")

            let before = stub.postCount
            for i in 0..<3 {
                await record(agg, "c\(i)")
                await tick(agg)
            }
            await agg.flushOnBackground(networkBudgetSeconds: 1)
            XCTAssertEqual(stub.postCount, before, "\(status): no POST after disable")
            XCTAssertEqual(logs.count(.error), 1, "\(status): still one ERROR")
            XCTAssertEqual(diskFiles().count, 0, "\(status): nothing written after disable")
        }
    }

    func testT3b_PayloadRejectionsDropOneBatchAndKeepTicking() async {
        for status in [400, 413, 422] {
            cleanFixture()
            freshFixture()
            stub.script([.init(status: status)], then: .init(status: 200))
            let agg = makeAggregator()

            await record(agg, "a")
            await tick(agg)
            let retained = await agg.retainedCount
            XCTAssertEqual(retained, 0, "\(status): batch dropped")
            XCTAssertEqual(diskFiles().count, 0, "\(status): and removed from disk")
            XCTAssertEqual(logs.count(.error), 1, "\(status): one ERROR")
            XCTAssertEqual(logs.count(.warn), 0, "\(status): no separate WARN for the same batch")
            let enabled = await agg.isTelemetryEnabled
            XCTAssertTrue(enabled, "\(status): telemetry stays enabled")

            await record(agg, "b")
            await tick(agg)
            XCTAssertEqual(stub.postCount, 2, "\(status): the next tick still posts")
            XCTAssertNotEqual(stub.body(1), stub.body(0))
        }
    }

    func testT3_AntiVacuity_408And429AreRetryable() async {
        for status in [408, 429] {
            cleanFixture()
            freshFixture()
            stub.script([.init(status: status)], then: .init(status: 200))
            let agg = makeAggregator()
            await record(agg, "a")
            await tick(agg)
            let retained = await agg.retainedCount
            XCTAssertEqual(retained, 1, "\(status) is retryable: batch retained")
            XCTAssertEqual(diskFiles().count, 1)
            let enabled = await agg.isTelemetryEnabled
            XCTAssertTrue(enabled)
            XCTAssertEqual(logs.count(.error), 0)
        }
    }

    // MARK: T5 - caps under outage (P5, P6), against the disk queue

    func testT5_QueueCapsDropOldest() async {
        stub.script([], then: .init(status: 503))
        let agg = makeAggregator()
        var firstPostOf: [String: Data] = [:]

        for k in 1...8 {
            await record(agg, "e\(k)")
            let before = stub.postCount
            await tick(agg)
            for i in before..<stub.postCount {
                let p = prefixes(stub.body(i))
                if p.count == 1, let only = p.first, firstPostOf[only] == nil { firstPostOf[only] = stub.body(i) }
            }
            let count = await agg.retainedCount
            let bytes = await agg.retainedBytes
            XCTAssertLessThanOrEqual(count, 5, "tick \(k)")
            XCTAssertLessThanOrEqual(bytes, 524_288, "tick \(k)")
            XCTAssertEqual(diskFiles().count, count, "tick \(k): disk mirrors the retained queue")
        }
        let count = await agg.retainedCount
        XCTAssertEqual(count, 5)

        stub.script([], then: .init(status: 200))
        let before = stub.postCount
        await tick(agg)  // tick 9, nothing new recorded
        XCTAssertEqual(stub.postCount - before, 5)
        let sent = (before..<stub.postCount).map { stub.body($0) }
        XCTAssertEqual(sent.map { prefixes($0) }, [["e4"], ["e5"], ["e6"], ["e7"], ["e8"]], "oldest-first, E1-E3 gone")
        for body in sent {
            let p = prefixes(body).first!
            if let first = firstPostOf[p] {
                XCTAssertEqual(sha256Hex(body), sha256Hex(first), "\(p) resent byte-identical")
            }
        }
        XCTAssertNotNil(firstPostOf["e4"], "E4 was POSTed during the outage, so its resend was compared")
        XCTAssertEqual(diskFiles().count, 0)
        XCTAssertEqual(logs.count(.warn), 1, "first drop is one WARN; further drops within 10 min are DEBUG")
        XCTAssertEqual(logs.count(.info, "recover"), 1)
    }

    func testT5_MaxAgeDiscardsStaleBatchesAtSendTime() async {
        stub.script([], then: .init(status: 503))
        let agg = makeAggregator()
        for k in 1...3 {
            await record(agg, "m\(k)")
            await tick(agg)
        }
        var count = await agg.retainedCount
        XCTAssertEqual(count, 3)

        clock.advance(6 * 60)
        await agg.tick()
        count = await agg.retainedCount
        XCTAssertEqual(count, 0, "batches older than 5 min are discarded")
        XCTAssertEqual(diskFiles().count, 0, "and removed from disk")
        XCTAssertEqual(logs.count(.warn), 1, "the age discard is a drop: one WARN")

        stub.script([], then: .init(status: 200))
        let before = stub.postCount
        await tick(agg)
        XCTAssertEqual(stub.postCount, before, "no POST carries a discarded batch")
    }

    func testT5_OversizeBatchIsDroppedNotRetained() async {
        stub.script([.init(status: 503)], then: .init(status: 200))
        var policy = TelemetryTransportPolicy()
        policy.maxRetainedBytes = 4096
        let agg = makeAggregator(policy: policy)
        await record(agg, "big", 200)
        await tick(agg)

        XCTAssertEqual(stub.postCount, 1, "the oversize batch is POSTed once")
        XCTAssertGreaterThan(stub.body(0).count, 4096)
        let count = await agg.retainedCount
        let bytes = await agg.retainedBytes
        XCTAssertEqual(count, 0)
        XCTAssertEqual(bytes, 0)
        XCTAssertEqual(diskFiles().count, 0, "never retained on disk")
        XCTAssertEqual(logs.count(.warn), 1, "the oversize drop counts for P7")
    }

    func testT5_AggregatorCapDropsNewestAndExistingKeysIncrement() async {
        let agg = makeAggregator(maxKeys: 3)
        await record(agg, "k", 5)  // k-0..k-2 recorded, k-3/k-4 dropped
        await agg.record(key: "k-0", details: details(0))  // existing key still increments
        await tick(agg)

        XCTAssertEqual(stub.postCount, 1)
        XCTAssertEqual(keys(stub.body(0)), ["k-0", "k-1", "k-2"])
        let json = try! JSONSerialization.jsonObject(with: stub.body(0)) as! [String: Any]
        let events = json["events"] as! [[String: Any]]
        let list = (events[0]["summaries"] as! [String: Any])["summaries"] as! [[String: Any]]
        let k0 = list.first { ($0["key"] as? String) == "k-0" }!
        let counter = (k0["counters"] as! [[String: Any]])[0]
        XCTAssertEqual(counter["count"] as? Int, 2)
    }

    // MARK: Resend gate: 30s floor + Retry-After (P4)

    func testResendFloorAndRetryAfter() async {
        stub.script([.init(status: 503), .init(status: 429, retryAfter: "120")], then: .init(status: 200))
        var policy = TelemetryTransportPolicy()
        policy.flushInterval = 8
        let agg = makeAggregator(policy: policy)
        await record(agg, "a")
        await tick(agg, after: 8)  // 503 at F
        for _ in 0..<3 { await tick(agg, after: 8) }  // F+8, F+16, F+24
        XCTAssertEqual(stub.postCount, 1, "no send inside the 30s floor")
        await tick(agg, after: 8)  // F+32
        XCTAssertEqual(stub.postCount, 2, "first tick past the floor resends")
        XCTAssertEqual(stub.body(1), stub.body(0))

        // POST 1 got 429 Retry-After: 120 at G.
        for _ in 0..<14 { await tick(agg, after: 8) }  // G+112
        XCTAssertEqual(stub.postCount, 2, "Retry-After honored")
        await tick(agg, after: 8)  // G+120
        XCTAssertEqual(stub.postCount, 3)
        XCTAssertEqual(stub.body(2), stub.body(0))
    }

    func testRetryAfterParsingAndClamp() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(SummaryAggregator.parseRetryAfter("120", now: now), 120)
        XCTAssertEqual(SummaryAggregator.parseRetryAfter("3600", now: now), 600, "clamped to 600s")
        XCTAssertNil(SummaryAggregator.parseRetryAfter(nil, now: now))
        XCTAssertNil(SummaryAggregator.parseRetryAfter("soon", now: now))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        XCTAssertEqual(SummaryAggregator.parseRetryAfter(f.string(from: now.addingTimeInterval(90)), now: now), 90)
        XCTAssertEqual(SummaryAggregator.parseRetryAfter(f.string(from: now.addingTimeInterval(-90)), now: now), 0)
    }

    func testStatusClassification() {
        XCTAssertEqual(SummaryAggregator.classify(200), .ok)
        XCTAssertEqual(SummaryAggregator.classify(204), .ok)
        for s in [401, 403, 404] { XCTAssertEqual(SummaryAggregator.classify(s), .auth, "\(s)") }
        for s in [408, 429, 500, 502, 503, 504] { XCTAssertEqual(SummaryAggregator.classify(s), .retryable, "\(s)") }
        for s in [400, 402, 409, 413, 422, 301] { XCTAssertEqual(SummaryAggregator.classify(s), .rejected, "\(s)") }
    }

    // MARK: P7 logging: a blip stays at DEBUG + one recovery INFO

    func testBlipLogsDebugAndOneRecoveryInfo() async {
        stub.script([.init(status: 503)], then: .init(status: 200))
        let agg = makeAggregator()
        await record(agg, "a")
        await tick(agg)
        await tick(agg)
        XCTAssertEqual(stub.postCount, 2)
        XCTAssertEqual(logs.count(.warn), 0)
        XCTAssertEqual(logs.count(.error), 0)
        XCTAssertGreaterThanOrEqual(logs.count(.debug, "503"), 1)
        XCTAssertEqual(logs.count(.info, "recover"), 1)
    }

    // MARK: P1: a hung POST is aborted at the timeout and retained (compressed)

    func testTimeoutAbortsAndRetains() async {
        stub.script([.init(hang: true)], then: .init(status: 200))
        var policy = TelemetryTransportPolicy()
        policy.timeout = 0.3
        let agg = makeAggregator(policy: policy)
        await record(agg, "a")
        let started = Date()
        await tick(agg)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the timeout bounds the POST")
        let count = await agg.retainedCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(diskFiles().count, 1)
        XCTAssertGreaterThanOrEqual(logs.count(.debug, "timeout"), 1)
        XCTAssertEqual(logs.count(.warn), 0)

        await tick(agg)
        XCTAssertEqual(stub.postCount, 2)
        XCTAssertEqual(stub.body(1), stub.body(0))
        XCTAssertEqual(diskFiles().count, 0)
    }

    // MARK: Regressions for the 0.0.1 bugs

    /// 0.0.1 emptied the queue before the POST completed, so a window in flight
    /// when the app backgrounded was lost. It must stay on disk until a 2xx.
    func testRegression_InFlightWindowStaysOnDiskAcrossBackground() async {
        stub.script([.init(hang: true)], then: .init(status: 503))
        let agg = makeAggregator()
        await record(agg, "a")
        clock.advance(60)
        let inflight = Task { await agg.tick() }
        let reached = await eventually { stub.postCount == 1 }
        XCTAssertTrue(reached)
        let busy = await agg.isPostInFlight
        XCTAssertTrue(busy)

        await record(agg, "b")
        await agg.flushOnBackground(networkBudgetSeconds: 1)
        XCTAssertEqual(stub.postCount, 1, "one POST in flight: the background flush does not send a second")
        XCTAssertEqual(diskFiles().count, 2, "in-flight A and live B are both on disk")

        // A gets its 2xx; the same drain then sends B, which gets 503.
        stub.release(status: 200)
        await inflight.value
        XCTAssertEqual(stub.postCount, 2)
        XCTAssertEqual(prefixes(stub.body(1)), ["b"])
        XCTAssertEqual(diskFiles().count, 1, "A removed from disk after its 2xx; failed B stays")
        XCTAssertEqual(try? Data(contentsOf: diskFiles()[0]), stub.body(1))
        let retained = await agg.retainedCount
        XCTAssertEqual(retained, 1)
    }

    /// Background final flush (P8): the live window gets one POST inside the
    /// budget; the retained queue is not drained; a 2xx removes it from disk.
    func testBackgroundFinalFlushSendsLiveWindowOnly() async {
        stub.script([.init(status: 503)], then: .init(status: 200))
        let agg = makeAggregator()
        await record(agg, "r")
        await tick(agg)  // retained R
        clock.advance(31)
        await record(agg, "live")
        await agg.flushOnBackground()

        XCTAssertEqual(stub.postCount, 2)
        XCTAssertEqual(prefixes(stub.body(1)), ["live"], "only the live window is sent")
        let retained = await agg.retainedCount
        XCTAssertEqual(retained, 1, "retained queue is not drained on background")
        XCTAssertEqual(diskFiles().count, 1)
        XCTAssertEqual(try? Data(contentsOf: diskFiles()[0]), stub.body(0), "R is still on disk, byte-exact")
    }

    /// The background flush never outlives its budget; a hung POST leaves the
    /// window on disk for the next launch.
    func testBackgroundFlushHonorsBudget() async {
        stub.script([], then: .init(hang: true))
        let agg = makeAggregator()
        await record(agg, "a")
        let started = Date()
        await agg.flushOnBackground(networkBudgetSeconds: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(stub.postCount, 1)
        XCTAssertEqual(diskFiles().count, 1, "window kept on disk")
        XCTAssertEqual(logs.count(.warn), 0)
    }

    /// Next launch: a new aggregator (new per-launch instanceHash) restores the
    /// retained bytes from disk and resends them verbatim, original
    /// instanceHash included, so the server dedup token matches.
    func testRestoreFromDiskResendsOriginalBytes() async {
        stub.script([.init(status: 503)], then: .init(status: 200))
        let first = makeAggregator(instanceHash: "launch-1")
        await record(first, "a")
        await tick(first)
        XCTAssertEqual(diskFiles().count, 1)

        let second = makeAggregator(instanceHash: "launch-2")
        let restored = await second.retainedCount
        XCTAssertEqual(restored, 1)
        await tick(second)
        XCTAssertEqual(stub.postCount, 2)
        XCTAssertEqual(sha256Hex(stub.body(1)), sha256Hex(stub.body(0)))
        let json = try! JSONSerialization.jsonObject(with: stub.body(1)) as! [String: Any]
        XCTAssertEqual(json["instanceHash"] as? String, "launch-1")
        XCTAssertEqual(diskFiles().count, 0)
    }

    /// The 0.0.1 single-file queue (re-serialized windows, no instanceHash) is
    /// removed rather than resent as a new payload.
    func testLegacyQueueFileIsRemoved() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = dir.appendingPathComponent("telemetry-queue.json")
        try Data("[]".utf8).write(to: legacy)
        TelemetryFileQueueStore.removeLegacyQueue(in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }
    // MARK: Client wiring: background entry runs the flush in a background task

    func testBackgroundNotificationFlushesInsideBackgroundTask() async {
        stub.script([], then: .init(status: 200))
        let agg = makeAggregator()
        let center = NotificationCenter()
        let bg = Notification.Name("test.qfg.telemetry.background")
        let runner = SpyBackgroundRunner()
        let config = Configuration(
            sdkKey: "qf_ck_test", apiURLs: [URL(string: "https://primary.quonfig.com")!],
            telemetryURL: URL(string: "https://telemetry.quonfig.com")!, pollInterval: 0)
        let ctx = QuonfigContext(["user": ["key": .string("u")]])
        let loader = Loader(
            sdkKey: config.sdkKey, context: ctx, apiURLs: [config.apiURLs!.first!],
            collectContextMode: config.collectContextMode, client: OfflineClient())
        let q = await Quonfig.make(
            configuration: config, context: ctx, loader: loader, persistence: nil, aggregator: agg,
            lifecycleProvider: BackgroundOnlyProvider(notificationCenter: center, backgroundNotification: bg),
            initTimeout: 0.1, fingerprint: defaultContextFingerprint, backgroundTaskRunner: runner)

        await record(agg, "bg")
        center.post(name: bg, object: nil)
        let flushed = await eventually { stub.postCount == 1 }
        XCTAssertTrue(flushed, "background entry POSTs the live window")
        XCTAssertEqual(runner.calls, [5], "inside a background task with the ~5s budget")
        XCTAssertEqual(prefixes(stub.body(0)), ["bg"])
        await q.shutdown()
    }
}

private struct BackgroundOnlyProvider: LifecycleProvider {
    let notificationCenter: NotificationCenter
    let backgroundNotification: Notification.Name?
    let foregroundNotification: Notification.Name? = nil
}

private final class OfflineClient: HTTPClient, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private final class SpyBackgroundRunner: BackgroundTaskRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var budgets: [TimeInterval] = []
    var calls: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return budgets
    }
    func run(reason: String, budget: TimeInterval, _ work: @escaping @Sendable () async -> Void) async {
        lock.withLock { budgets.append(budget) }
        await work()
    }
}
