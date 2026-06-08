import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Abstracts the platform's app-lifecycle notifications behind a protocol so the
/// polling core stays platform-agnostic — no `#if os(iOS)` scattered through the
/// client (plan §2.6). This is LaunchDarkly's `SystemCapabilities` indirection:
/// it vends `foreground`/`background` notification names that resolve to
/// `UIApplication` (iOS/tvOS/watchOS via UIKit), `NSApplication` (macOS), or — on
/// a platform with neither (Linux test harnesses) — to nothing, in which case the
/// observer simply never fires and the timer just runs continuously.
///
/// `Sendable` so it can be held by the `Quonfig` client across concurrency
/// domains; conformers are value types or notification-center wrappers.
public protocol LifecycleProvider: Sendable {
    /// Notification posted when the app enters the foreground / becomes active.
    /// `nil` on platforms with no app-lifecycle concept (the observer is skipped).
    var foregroundNotification: Notification.Name? { get }
    /// Notification posted when the app enters the background / resigns active.
    var backgroundNotification: Notification.Name? { get }
    /// The notification center to observe (injectable for tests).
    var notificationCenter: NotificationCenter { get }
}

/// The default platform lifecycle provider. Resolves the foreground/background
/// notification names for the compiled platform, exactly mirroring LD's
/// `SystemCapabilities`:
///   - UIKit (iOS/tvOS/watchOS): `didBecomeActive` / `didEnterBackground`.
///   - AppKit (macOS): `didBecomeActive` / `didResignActive` (macOS has no
///     "enter background" — resign-active is the closest analog).
///   - Neither: both `nil`, so the observer is a no-op and the poller runs
///     continuously (Linux/server-Swift test harnesses).
public struct SystemLifecycleProvider: LifecycleProvider {
    public let notificationCenter: NotificationCenter

    public init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    public var foregroundNotification: Notification.Name? {
        #if canImport(UIKit)
        return UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        return NSApplication.didBecomeActiveNotification
        #else
        return nil
        #endif
    }

    public var backgroundNotification: Notification.Name? {
        #if canImport(UIKit)
        return UIApplication.didEnterBackgroundNotification
        #elseif canImport(AppKit)
        return NSApplication.didResignActiveNotification
        #else
        return nil
        #endif
    }
}

/// Wires a `LifecycleProvider`'s foreground/background notifications to the poll
/// loop, implementing the §2.6 mobile-staleness/battery seam that three of the
/// five surveyed SDKs skip entirely:
///
///   - **Foreground:** start the poll timer AND fire one immediate catch-up
///     `eval-with-context` fetch — the gap PostHog leaves to the app developer.
///   - **Background:** suspend the poll timer (iOS suspends the app anyway; a live
///     timer just wastes the few seconds the OS grants) and run the telemetry
///     flush hook so summaries are flushed before suspension (the telemetry bead,
///     qfg-2t2d.8, supplies the real flush; here it's an injected closure).
///
/// The default foreground interval is the `Configuration` poll interval; a single
/// override knob lives on `Configuration.pollInterval` (§2.11 — "one override
/// knob"). This type owns the observer tokens and removes them on `deinit`.
public final class LifecycleCoordinator: @unchecked Sendable {
    private let provider: LifecycleProvider
    private let poller: Poller
    private let pollInterval: TimeInterval
    /// The telemetry-flush hook fired on background entry. Defaults to a no-op;
    /// qfg-2t2d.8 wires the real summary flush here. Disk-persist-before-network
    /// is that bead's responsibility — this just provides the seam (§2.8/§2.10
    /// Statsig 1.56.0).
    private let onBackground: @Sendable () async -> Void

    private let lock = NSLock()
    private var foregroundObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var started = false

    public init(
        provider: LifecycleProvider = SystemLifecycleProvider(),
        poller: Poller,
        pollInterval: TimeInterval,
        onBackground: @escaping @Sendable () async -> Void = {}
    ) {
        self.provider = provider
        self.poller = poller
        self.pollInterval = pollInterval
        self.onBackground = onBackground
    }

    /// Begin observing lifecycle notifications and start the poll timer for the
    /// current (assumed-foreground) state. Idempotent — a second call is a no-op.
    public func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true

        let center = provider.notificationCenter
        let interval = pollInterval

        if let fg = provider.foregroundNotification {
            foregroundObserver = center.addObserver(
                forName: fg, object: nil, queue: nil
            ) { [weak self] _ in
                self?.handleForeground(interval: interval)
            }
        }
        if let bg = provider.backgroundNotification {
            backgroundObserver = center.addObserver(
                forName: bg, object: nil, queue: nil
            ) { [weak self] _ in
                self?.handleBackground()
            }
        }
        lock.unlock()

        // Assume we launch in the foreground: start the timer immediately. (The
        // initial catch-up fetch is `Quonfig.initialize`'s job — the very first
        // envelope — so we don't double-fetch here; we only start the cadence.)
        let poller = self.poller
        Task { await poller.start(interval: interval) }
    }

    /// Foreground entry: one immediate catch-up fetch, then (re)start the timer.
    /// Order matters — kick the catch-up before the cadence so the user sees fresh
    /// values as fast as possible (§2.6). The poller's dedup/coalesce makes the
    /// catch-up + first tick safe even if they overlap.
    private func handleForeground(interval: TimeInterval) {
        let poller = self.poller
        Task {
            await poller.refreshNow()
            await poller.start(interval: interval)
        }
    }

    /// Background entry: suspend the timer FIRST (stop wasting the few seconds the
    /// OS grants on network polls), then run the telemetry-flush hook.
    private func handleBackground() {
        let poller = self.poller
        let onBackground = self.onBackground
        Task {
            await poller.stop()
            await onBackground()
        }
    }

    /// Stop observing and tear down the timer.
    public func stop() {
        lock.lock()
        let fg = foregroundObserver
        let bg = backgroundObserver
        foregroundObserver = nil
        backgroundObserver = nil
        started = false
        let center = provider.notificationCenter
        lock.unlock()

        if let fg { center.removeObserver(fg) }
        if let bg { center.removeObserver(bg) }
        let poller = self.poller
        Task { await poller.stop() }
    }

    deinit {
        if let fg = foregroundObserver {
            provider.notificationCenter.removeObserver(fg)
        }
        if let bg = backgroundObserver {
            provider.notificationCenter.removeObserver(bg)
        }
    }
}
