import XCTest

@testable import Quonfig

final class PollerTests: XCTestCase {

    /// A thread-safe counter the fetch closure increments, so tests can assert on
    /// how many fetches actually ran. Also lets a test hold a fetch open (gate) to
    /// exercise the in-flight dedup/coalesce path deterministically.
    private actor FetchRecorder {
        private(set) var count = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var blockNext = false

        /// Arm the NEXT fetch to block until `release()` is called.
        func armBlock() { blockNext = true }

        func record() async {
            count += 1
            if blockNext {
                blockNext = false
                await withCheckedContinuation { c in self.gate = c }
            }
        }

        func release() {
            gate?.resume()
            gate = nil
        }

        func current() -> Int { count }
    }

    // MARK: - interval == 0 guard (Unleash #101)

    func testZeroIntervalDisablesPolling() async {
        let rec = FetchRecorder()
        let poller = Poller(fetch: { await rec.record() })

        await poller.start(interval: 0)
        let running = await poller.isRunning
        XCTAssertFalse(running, "interval 0 must not schedule a timer")
        let interval = await poller.currentInterval
        XCTAssertNil(interval)
    }

    func testNegativeIntervalDisablesPolling() async {
        let rec = FetchRecorder()
        let poller = Poller(fetch: { await rec.record() })
        await poller.start(interval: -5)
        let running = await poller.isRunning
        XCTAssertFalse(running)
    }

    // MARK: - idempotent start (Unleash #68/#72/#74)

    func testStartIsIdempotentSingleTimer() async {
        let rec = FetchRecorder()
        let poller = Poller(fetch: { await rec.record() })

        await poller.start(interval: 10)
        let gen1 = await poller.currentGeneration
        await poller.start(interval: 10)
        let gen2 = await poller.currentGeneration

        // Each start cancels-before-scheduling, bumping the generation via stop().
        XCTAssertGreaterThan(gen2, gen1, "restart must bump generation (cancel-before-schedule)")
        let running = await poller.isRunning
        XCTAssertTrue(running)
        await poller.stop()
    }

    func testStopTearsDownTimer() async {
        let rec = FetchRecorder()
        let poller = Poller(fetch: { await rec.record() })
        await poller.start(interval: 10)
        await poller.stop()
        let running = await poller.isRunning
        XCTAssertFalse(running)
        let interval = await poller.currentInterval
        XCTAssertNil(interval)
    }

    // MARK: - refreshNow fires a fetch

    func testRefreshNowFiresOneFetch() async {
        let rec = FetchRecorder()
        let poller = Poller(fetch: { await rec.record() })
        await poller.refreshNow()
        let count = await rec.current()
        XCTAssertEqual(count, 1)
    }

    // MARK: - dedup + coalesce (PostHog-style, §2.11)

    func testConcurrentRefreshCoalescesIntoOneFollowUp() async {
        let rec = FetchRecorder()
        let poller = Poller(fetch: { await rec.record() })

        // Block the first fetch so it stays in flight while we fire more.
        await rec.armBlock()
        async let first: Void = poller.refreshNow()

        // Spin until the first fetch is actually in flight.
        var waited = 0
        while await poller.isFetching == false, waited < 200 {
            await Task.yield()
            waited += 1
        }
        let inFlight = await poller.isFetching
        XCTAssertTrue(inFlight, "first fetch should be in flight")

        // Fire several more refreshes while the first is blocked — they must NOT
        // launch parallel fetches; they coalesce into a single pending follow-up.
        await poller.refreshNow()
        await poller.refreshNow()
        await poller.refreshNow()
        let pending = await poller.hasPendingFollowUp
        XCTAssertTrue(pending, "overlapping refreshes must arm exactly one follow-up")

        // Release the in-flight fetch; exactly ONE follow-up runs (not three).
        await rec.release()
        _ = await first

        // Let the follow-up complete.
        var settled = 0
        while await poller.isFetching, settled < 200 {
            await Task.yield()
            settled += 1
        }

        let total = await rec.current()
        XCTAssertEqual(total, 2, "3 overlapping refreshes coalesce into 1 follow-up => 2 total fetches")
        let stillPending = await poller.hasPendingFollowUp
        XCTAssertFalse(stillPending)
    }

    // MARK: - generation discards superseded fetches (Statsig #1/#36)

    func testStopDuringFetchDiscardsFollowUp() async {
        let rec = FetchRecorder()
        let poller = Poller(fetch: { await rec.record() })

        await rec.armBlock()
        async let first: Void = poller.refreshNow()

        var waited = 0
        while await poller.isFetching == false, waited < 200 {
            await Task.yield()
            waited += 1
        }

        // Arm a follow-up, then stop() — the follow-up must be discarded because
        // the generation moved.
        await poller.refreshNow()
        let armed = await poller.hasPendingFollowUp
        XCTAssertTrue(armed)
        await poller.stop()

        await rec.release()
        _ = await first

        var settled = 0
        while await poller.isFetching, settled < 200 {
            await Task.yield()
            settled += 1
        }

        let total = await rec.current()
        XCTAssertEqual(total, 1, "stop() during a fetch discards the coalesced follow-up")
    }

    func testUpdateContextBumpsGenerationAndRefetches() async {
        let rec = FetchRecorder()
        let poller = Poller(fetch: { await rec.record() })

        await poller.start(interval: 100)  // long interval so timer ticks don't fire
        let genBefore = await poller.currentGeneration

        await poller.updateContext()
        let genAfter = await poller.currentGeneration
        XCTAssertGreaterThan(genAfter, genBefore, "updateContext bumps the generation")

        // updateContext does an immediate refetch.
        let count = await rec.current()
        XCTAssertGreaterThanOrEqual(count, 1, "updateContext fires an immediate catch-up fetch")

        // And resumes the timer at the same interval.
        let running = await poller.isRunning
        XCTAssertTrue(running)
        let interval = await poller.currentInterval
        XCTAssertEqual(interval, 100)
        await poller.stop()
    }

    // MARK: - timer actually fires (DispatchSourceTimer, runloop-independent)

    func testTimerFiresOnInterval() async {
        let rec = FetchRecorder()
        let poller = Poller(fetch: { await rec.record() })

        // Short interval; the dispatch-source timer fires off its own queue, so
        // it must tick even though no runloop is being spun in this async test
        // (the whole point of DispatchSourceTimer over Timer — Unleash #88/#125).
        await poller.start(interval: 0.05)

        var waited = 0
        while await rec.current() < 2, waited < 400 {
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            waited += 1
        }
        let count = await rec.current()
        await poller.stop()
        XCTAssertGreaterThanOrEqual(count, 2, "DispatchSourceTimer must fire repeatedly off its own queue")
    }
}
