import Foundation
import XCTest

@testable import Quonfig

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Auth-failure rule (qfg-goi1.10.30; plan project/plans/2026-10-07-sdk-auth-failure-rule.md
// R1-R5, frontend scope; shape copied from the sdk-go canary, quonfig/sdk-go#28).
//
// Rig: a per-leg fake server (primary + secondary hosts, each answering a
// scripted status), a manual poll scheduler that records every wait the poller
// requests and fires it on demand (the mocked clock), a scripted probe-period
// source, and a capturing log sink.

/// Records every wait the poller schedules; `fire()` runs the one live timer.
final class ManualPollScheduler: PollScheduler, @unchecked Sendable {
    final class Entry: PollTimer, @unchecked Sendable {
        let delay: TimeInterval
        let repeating: Bool
        let handler: @Sendable () async -> Void
        private let lock = NSLock()
        private var _cancelled = false
        private var _fired = false
        init(delay: TimeInterval, repeating: Bool, handler: @escaping @Sendable () async -> Void) {
            self.delay = delay
            self.repeating = repeating
            self.handler = handler
        }
        func cancel() {
            lock.lock()
            _cancelled = true
            lock.unlock()
        }
        func markFired() {
            lock.lock()
            _fired = true
            lock.unlock()
        }
        var live: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !_cancelled && (repeating || !_fired)
        }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func schedule(
        after delay: TimeInterval, repeating: Bool, _ handler: @escaping @Sendable () async -> Void
    ) -> PollTimer {
        let e = Entry(delay: delay, repeating: repeating, handler: handler)
        lock.lock()
        entries.append(e)
        lock.unlock()
        return e
    }

    var all: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
    var live: [Entry] { all.filter(\.live) }
    var count: Int { all.count }

    /// Fire the single live timer and wait for its tick to finish.
    func fire(file: StaticString = #filePath, line: UInt = #line) async {
        let l = live
        guard l.count == 1, let e = l.first else {
            XCTFail("expected exactly one live timer, have \(l.count)", file: file, line: line)
            return
        }
        if !e.repeating { e.markFired() }
        await e.handler()
    }
}

/// Fake per-leg server: routes on host, answers each leg's current status.
final class PerLegServer: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [String: Int] = [:]
    private(set) var hitLog: [String] = []
    let body: Data

    init(body: Data, primary: Int, secondary: Int) {
        self.body = body
        set(primary: primary, secondary: secondary)
    }

    func set(primary: Int, secondary: Int) {
        lock.lock()
        statuses = ["primary.test": primary, "secondary.test": secondary]
        lock.unlock()
    }

    var hits: [String] {
        lock.lock()
        defer { lock.unlock() }
        return hitLog
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let host = request.url!.host!
        lock.lock()
        hitLog.append(host)
        let status = statuses[host] ?? 0
        lock.unlock()
        if status == 0 { throw URLError(.timedOut) }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (status == 200 ? body : Data(), http)
    }
}

/// Scripted probe periods (T), recorded as drawn.
final class ProbeDelays: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [TimeInterval]
    init(_ script: [TimeInterval]) { self.script = script }
    func next() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return script.isEmpty ? 222 : script.removeFirst()
    }
}

final class AuthFailureTests: XCTestCase {
    static let errorPattern = "config fetch rejected: the SDK key is invalid or revoked"
    static let infoPattern = "config fetch accepted; leaving auth-failed"

    private func evalBody() throws -> Data {
        let url = Bundle.module.url(
            forResource: "eval-with-context.response.json", withExtension: nil, subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private struct Rig {
        let client: Quonfig
        let server: PerLegServer
        let scheduler: ManualPollScheduler
        let logs: CapturingLogSink
        let center: NotificationCenter
    }

    private func makeRig(
        pollInterval: TimeInterval = 60, primary: Int, secondary: Int,
        probes: [TimeInterval] = [200, 150, 299.5, 151, 300]
    ) async throws -> Rig {
        let server = PerLegServer(body: try evalBody(), primary: primary, secondary: secondary)
        let scheduler = ManualPollScheduler()
        let logs = CapturingLogSink()
        let delays = ProbeDelays(probes)
        let center = NotificationCenter()
        let urls = [URL(string: "https://primary.test")!, URL(string: "https://secondary.test")!]
        let config = Configuration(
            sdkKey: "qf_ck_secret_key", apiURLs: urls,
            telemetryURL: URL(string: "https://telemetry.test")!,
            pollInterval: pollInterval, collectEvaluationSummaries: false, logSink: logs)
        let loader = Loader(
            sdkKey: config.sdkKey,
            context: QuonfigContext(["user": ["key": .string("u_1")]]),
            apiURLs: urls, client: server)
        let client = await Quonfig.make(
            configuration: config, context: QuonfigContext(["user": ["key": .string("u_1")]]),
            loader: loader, persistence: Persistence(store: InMemoryFallbackStore()), aggregator: nil,
            lifecycleProvider: QuonfigClientTests.ManualLifecycleProvider(center: center),
            initTimeout: 5, fingerprint: defaultContextFingerprint,
            pollScheduler: scheduler, authProbeDelay: { delays.next() })
        // lifecycle.start() arms the poll cadence from a Task; wait for it.
        try await waitFor { scheduler.live.count == 1 }
        return Rig(client: client, server: server, scheduler: scheduler, logs: logs, center: center)
    }

    private func waitFor(
        _ cond: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<400 {
            if cond() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never held", file: file, line: line)
    }

    private func liveWait(_ rig: Rig) -> (TimeInterval, Bool)? {
        rig.scheduler.live.first.map { ($0.delay, $0.repeating) }
    }

    // MARK: - Entry, slow probe, exit (red repro, every auth-class status)

    func testAuthClassEntersAfterOnePollCycleProbesSlowlyAndExitsOnSecondary200() async throws {
        for status in [401, 403, 404, 410] {
            let rig = try await makeRig(primary: status, secondary: status)

            // The init fetch was rejected on both legs, but init never enters:
            // no ERROR, normal cadence armed.
            XCTAssertEqual(rig.logs.count(.error, Self.errorPattern), 0, "\(status): init must not enter")
            XCTAssertEqual(liveWait(rig)?.0, 60)
            XCTAssertEqual(liveWait(rig)?.1, true)

            // ONE failed poll cycle enters: exactly one ERROR with status + host,
            // never the key; the next wait is a one-shot probe at T.
            await rig.scheduler.fire()
            XCTAssertEqual(rig.logs.count(.error, Self.errorPattern), 1, "\(status): one ERROR on entry")
            let errorLine = rig.logs.all.first { $0.contains("config fetch rejected") } ?? ""
            XCTAssertTrue(errorLine.contains("status=\(status)"), errorLine)
            XCTAssertTrue(errorLine.contains("host=primary.test:443"), errorLine)
            XCTAssertFalse(errorLine.contains("qf_ck_secret_key"), errorLine)
            XCTAssertEqual(liveWait(rig)?.0, 200, "\(status): first probe waits T")
            XCTAssertEqual(liveWait(rig)?.1, false, "\(status): probe is one-shot, not the 60s cadence")

            // Rejected probes: DEBUG only, T re-drawn each time, no doubling, no stop.
            let hitsBefore = rig.server.hits.count
            for expected in [150, 299.5, 151, 300] as [TimeInterval] {
                await rig.scheduler.fire()
                XCTAssertEqual(liveWait(rig)?.0, expected, "\(status): probe wait = T, no doubling")
            }
            XCTAssertEqual(rig.server.hits.count - hitsBefore, 8, "\(status): each probe tries every leg")
            XCTAssertEqual(rig.logs.count(.error, Self.errorPattern), 1, "\(status): no second ERROR")
            XCTAssertGreaterThanOrEqual(rig.logs.count(.debug, "probe rejected"), 4)

            // First 200 on any leg exits: secondary-only 200 is enough.
            rig.server.set(primary: 503, secondary: 200)
            await rig.scheduler.fire()
            XCTAssertEqual(rig.logs.count(.info, Self.infoPattern), 1, "\(status): one INFO on exit")
            XCTAssertEqual(liveWait(rig)?.0, 60, "\(status): normal cadence resumes")
            XCTAssertEqual(liveWait(rig)?.1, true)
            XCTAssertTrue(rig.client.isEnabled("new-checkout"), "\(status): accepted envelope installed")

            await rig.client.shutdown()
        }
    }

    /// Polling-mode wait is max(T, poll interval) while auth-failed (R3).
    func testProbeWaitIsMaxOfTAndPollInterval() async throws {
        let rig = try await makeRig(pollInterval: 600, primary: 401, secondary: 401, probes: [200, 299])
        XCTAssertEqual(liveWait(rig)?.0, 600)
        await rig.scheduler.fire()
        XCTAssertEqual(rig.logs.count(.error, Self.errorPattern), 1)
        XCTAssertEqual(liveWait(rig)?.0, 600, "max(T=200, 600)")
        XCTAssertEqual(liveWait(rig)?.1, false)
        await rig.scheduler.fire()
        XCTAssertEqual(liveWait(rig)?.0, 600, "max(T=299, 600)")
        await rig.client.shutdown()
    }

    // MARK: - Which cycles enter

    func testPrimaryAuthPlusSecondary503Enters() async throws {
        let rig = try await makeRig(primary: 401, secondary: 503)
        await rig.scheduler.fire()
        XCTAssertEqual(rig.logs.count(.error, Self.errorPattern), 1)
        XCTAssertEqual(liveWait(rig)?.1, false)
        await rig.client.shutdown()
    }

    func testPrimaryAuthPlusSecondaryTimeoutEnters() async throws {
        let rig = try await makeRig(primary: 403, secondary: 0)
        await rig.scheduler.fire()
        XCTAssertEqual(rig.logs.count(.error, Self.errorPattern), 1)
        await rig.client.shutdown()
    }

    func testPrimary503PlusSecondaryAuthDoesNotEnter() async throws {
        let rig = try await makeRig(primary: 503, secondary: 401)
        for _ in 0..<3 {
            await rig.scheduler.fire()
        }
        XCTAssertEqual(rig.logs.count(.error, Self.errorPattern), 0)
        XCTAssertEqual(liveWait(rig)?.0, 60)
        XCTAssertEqual(liveWait(rig)?.1, true)
        await rig.client.shutdown()
    }

    func testPrimaryAuthPlusSecondary200DoesNotEnter() async throws {
        let rig = try await makeRig(primary: 401, secondary: 200)
        await rig.scheduler.fire()
        XCTAssertEqual(rig.logs.count(.error, Self.errorPattern), 0)
        XCTAssertEqual(liveWait(rig)?.1, true)
        await rig.client.shutdown()
    }

    /// No latch: after an exit, a later rejected cycle enters again.
    func testNoLatchReentersAfterExit() async throws {
        let rig = try await makeRig(primary: 401, secondary: 401)
        await rig.scheduler.fire()  // enter
        rig.server.set(primary: 200, secondary: 200)
        await rig.scheduler.fire()  // probe accepted -> exit
        XCTAssertEqual(rig.logs.count(.info, Self.infoPattern), 1)
        rig.server.set(primary: 410, secondary: 410)
        await rig.scheduler.fire()  // poll rejected -> enter again
        XCTAssertEqual(rig.logs.count(.error, Self.errorPattern), 2)
        XCTAssertEqual(liveWait(rig)?.1, false)
        await rig.client.shutdown()
    }

    // MARK: - Lifecycle (qfg-goi1.10.13 epoch)

    /// Background stops the probe; foreground re-arms the probe, not the 60s
    /// cadence. The flag survives the stop/start.
    func testBackgroundForegroundKeepsAuthFailedCadence() async throws {
        let rig = try await makeRig(primary: 401, secondary: 401)
        await rig.scheduler.fire()  // enter
        XCTAssertEqual(rig.scheduler.live.count, 1)

        rig.center.post(name: Notification.Name("quonfig.test.background"), object: nil)
        try await waitFor { rig.scheduler.live.isEmpty }

        rig.center.post(name: Notification.Name("quonfig.test.foreground"), object: nil)
        try await waitFor { rig.scheduler.live.count == 1 }
        XCTAssertEqual(liveWait(rig)?.1, false, "foreground while auth-failed re-arms the probe")
        XCTAssertGreaterThanOrEqual(liveWait(rig)?.0 ?? 0, 150)
        XCTAssertEqual(rig.logs.count(.error, Self.errorPattern), 1)
        await rig.client.shutdown()
    }

    // MARK: - Loader per-leg status

    func testLoaderReportsPerLegStatusAndPrimaryAuthClass() async throws {
        let urls = [URL(string: "https://primary.test")!, URL(string: "https://secondary.test:8443")!]
        let server = PerLegServer(body: try evalBody(), primary: 401, secondary: 503)
        let loader = Loader(
            sdkKey: "k", context: QuonfigContext(["user": ["key": .string("u")]]), apiURLs: urls,
            client: server)
        do {
            _ = try await loader.loadForCurrentContext()
            XCTFail("expected rejection")
        } catch let e as AuthRejectedError {
            XCTAssertEqual(e.status, 401)
            XCTAssertEqual(e.host, "primary.test:443")
            XCTAssertEqual(e.legs, [LegStatus(index: 0, status: 401), LegStatus(index: 1, status: 503)])
        }
        // The public load() error is unchanged.
        do {
            _ = try await loader.load()
            XCTFail("expected failure")
        } catch let QuonfigLoaderError.allURLsFailed(msg) {
            XCTAssertTrue(msg.contains("503"), msg)
        }

        server.set(primary: 503, secondary: 401)
        do {
            _ = try await loader.loadForCurrentContext()
            XCTFail("expected failure")
        } catch {
            XCTAssertFalse(error is AuthRejectedError, "primary 503 + secondary 401 is not the auth class")
        }
    }

    func testDefaultProbeDelayIsUniformIn150To300AndRedrawn() {
        let draws = (0..<200).map { _ in Poller.randomAuthProbeDelay() }
        XCTAssertTrue(draws.allSatisfy { $0 >= 150 && $0 <= 300 })
        XCTAssertGreaterThan(Set(draws).count, 100, "T is re-drawn, not fixed")
    }
}
