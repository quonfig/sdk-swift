import XCTest

@testable import Quonfig

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

final class LifecycleTests: XCTestCase {

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
        func current() -> Int { value }
    }

    /// A test lifecycle provider with synthetic notification names on a private
    /// notification center, so tests can post foreground/background events without
    /// a real UIApplication/NSApplication.
    private struct TestLifecycleProvider: LifecycleProvider {
        let foregroundNotification: Notification.Name?
        let backgroundNotification: Notification.Name?
        let notificationCenter: NotificationCenter
    }

    private static let fgName = Notification.Name("test.qfg.foreground")
    private static let bgName = Notification.Name("test.qfg.background")

    private func makeProvider(center: NotificationCenter) -> TestLifecycleProvider {
        TestLifecycleProvider(
            foregroundNotification: Self.fgName,
            backgroundNotification: Self.bgName,
            notificationCenter: center
        )
    }

    /// Spin until `predicate` is true or we give up.
    private func eventually(_ predicate: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)  // 5ms
        }
        return await predicate()
    }

    // MARK: - start() starts the poll timer

    func testStartStartsTheTimer() async {
        let center = NotificationCenter()
        let fetches = Counter()
        let poller = Poller(fetch: { await fetches.bump() })
        let coord = LifecycleCoordinator(
            provider: makeProvider(center: center),
            poller: poller,
            pollInterval: 100  // long, so we assert on running-ness not tick count
        )

        coord.start()
        let started = await eventually { await poller.isRunning }
        XCTAssertTrue(started, "lifecycle start() must start the poll timer")
        coord.stop()
    }

    // MARK: - background suspends the timer + runs the flush hook

    func testBackgroundSuspendsTimerAndFlushes() async {
        let center = NotificationCenter()
        let fetches = Counter()
        let flushes = Counter()
        let poller = Poller(fetch: { await fetches.bump() })
        let coord = LifecycleCoordinator(
            provider: makeProvider(center: center),
            poller: poller,
            pollInterval: 100,
            onBackground: { await flushes.bump() }
        )

        coord.start()
        _ = await eventually { await poller.isRunning }

        center.post(name: Self.bgName, object: nil)

        let stopped = await eventually { await poller.isRunning == false }
        XCTAssertTrue(stopped, "background entry must suspend the poll timer")

        let flushed = await eventually { await flushes.current() >= 1 }
        XCTAssertTrue(flushed, "background entry must run the telemetry-flush hook")
        coord.stop()
    }

    // MARK: - foreground re-starts the timer AND fires a catch-up fetch

    func testForegroundCatchUpFetchAndRestart() async {
        let center = NotificationCenter()
        let fetches = Counter()
        let poller = Poller(fetch: { await fetches.bump() })
        let coord = LifecycleCoordinator(
            provider: makeProvider(center: center),
            poller: poller,
            pollInterval: 100  // long so the catch-up is the only fetch in window
        )

        coord.start()
        _ = await eventually { await poller.isRunning }

        // Background to suspend, then foreground to trigger the catch-up.
        center.post(name: Self.bgName, object: nil)
        _ = await eventually { await poller.isRunning == false }

        let before = await fetches.current()
        center.post(name: Self.fgName, object: nil)

        let caughtUp = await eventually { await fetches.current() > before }
        XCTAssertTrue(caughtUp, "foreground entry must fire one immediate catch-up fetch")

        let resumed = await eventually { await poller.isRunning }
        XCTAssertTrue(resumed, "foreground entry must resume the poll timer")
        coord.stop()
    }

    // MARK: - stop() removes observers (no fetch after stop)

    func testStopRemovesObservers() async {
        let center = NotificationCenter()
        let fetches = Counter()
        let poller = Poller(fetch: { await fetches.bump() })
        let coord = LifecycleCoordinator(
            provider: makeProvider(center: center),
            poller: poller,
            pollInterval: 100
        )
        coord.start()
        _ = await eventually { await poller.isRunning }
        coord.stop()
        let stopped = await eventually { await poller.isRunning == false }
        XCTAssertTrue(stopped)

        let before = await fetches.current()
        // A foreground post AFTER stop must not trigger anything.
        center.post(name: Self.fgName, object: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms grace
        let after = await fetches.current()
        XCTAssertEqual(after, before, "no fetch should fire after stop() removes observers")
    }

    // MARK: - nil notifications (Linux/no-platform): timer just runs, no crash

    func testNilNotificationsStillStartsTimer() async {
        let center = NotificationCenter()
        let fetches = Counter()
        let poller = Poller(fetch: { await fetches.bump() })
        let provider = TestLifecycleProvider(
            foregroundNotification: nil,
            backgroundNotification: nil,
            notificationCenter: center
        )
        let coord = LifecycleCoordinator(provider: provider, poller: poller, pollInterval: 100)
        coord.start()
        let running = await eventually { await poller.isRunning }
        XCTAssertTrue(running, "with no platform notifications the timer still runs continuously")
        coord.stop()
    }

    // MARK: - System provider mapping (F6, qfg-goi1.2.17)

    /// macOS has no "enter background". Mapping resign-active to background
    /// stopped polling whenever another app was frontmost, so menu-bar apps and
    /// windows left behind others kept stale config for hours. On AppKit the
    /// system provider now has no background notification: polling runs
    /// continuously, and becoming active still fires a catch-up fetch.
    func testSystemProviderNotificationMapping() {
        let provider = SystemLifecycleProvider(notificationCenter: NotificationCenter())
        #if canImport(UIKit)
            XCTAssertEqual(provider.foregroundNotification, UIApplication.didBecomeActiveNotification)
            XCTAssertEqual(provider.backgroundNotification, UIApplication.didEnterBackgroundNotification)
        #elseif canImport(AppKit)
            XCTAssertEqual(provider.foregroundNotification, NSApplication.didBecomeActiveNotification)
            XCTAssertNil(provider.backgroundNotification, "macOS must not treat losing focus as backgrounding")
        #else
            XCTAssertNil(provider.foregroundNotification)
            XCTAssertNil(provider.backgroundNotification)
        #endif
    }

    #if !canImport(UIKit) && canImport(AppKit)
        /// F6 end to end on macOS: resigning active (the user clicks another
        /// app) leaves the poll timer running and does not flush telemetry.
        func testMacOSResignActiveKeepsPolling() async {
            let center = NotificationCenter()
            let flushes = Counter()
            let poller = Poller(fetch: {})
            let coord = LifecycleCoordinator(
                provider: SystemLifecycleProvider(notificationCenter: center),
                poller: poller,
                pollInterval: 100,
                onBackground: { await flushes.bump() }
            )
            coord.start()
            let running = await eventually { await poller.isRunning }
            XCTAssertTrue(running)

            center.post(name: NSApplication.didResignActiveNotification, object: nil)
            // Give a (wrongly) wired background handler time to run.
            try? await Task.sleep(nanoseconds: 200_000_000)
            let stillRunning = await poller.isRunning
            let flushCount = await flushes.current()
            XCTAssertTrue(stillRunning, "resign-active must not stop polling on macOS")
            XCTAssertEqual(flushCount, 0, "resign-active must not run the background flush on macOS")
            coord.stop()
        }
    #endif
}
