import Foundation
import Quonfig

// test-swift headless demo — the CI-runnable validation of the Quonfig Apple SDK.
//
// Drives the full public surface (initialize → getters → subscribe →
// updateContext) against either:
//   - a LIVE api-delivery if QUONFIG_SDK_KEY is set (QUONFIG_DOMAIN optional,
//     defaults to quonfig.com), or
//   - a built-in in-process FIXTURE server (default) that flips a flag each poll,
//     so the demo shows poll-driven updates with no external server.
//
// On a Mac with a windowing session you'd instead host `FlagListView` in a
// SwiftUI `App`; this executable is the headless equivalent so `swift run`
// exercises the SDK end-to-end in CI.

@MainActor
func runDemo() async {
    let env = ProcessInfo.processInfo.environment
    let liveKey = env["QUONFIG_SDK_KEY"]

    let apiURL: URL
    let sdkKey: String
    var fixtureServer: FixtureServer?

    if let liveKey, !liveKey.isEmpty {
        // Live mode: target a real api-delivery via QUONFIG_DOMAIN.
        let domain = env["QUONFIG_DOMAIN"] ?? "quonfig.com"
        apiURL = URL(string: "https://primary.\(domain)")!
        sdkKey = liveKey
        print("[test-swift] LIVE mode -> \(apiURL.absoluteString)")
    } else {
        // Fixture mode (default): start the in-process server.
        guard
            let fixtureURL = Bundle.module.url(
                forResource: "eval-with-context.response",
                withExtension: "json", subdirectory: "Fixtures")
        else {
            print("[test-swift] FATAL: missing bundled fixture")
            exit(1)
        }
        guard let server = try? FixtureServer(fixtureURL: fixtureURL) else {
            print("[test-swift] FATAL: could not build fixture server")
            exit(1)
        }
        fixtureServer = server

        // Start the server and wait for the bound port.
        let portBox = PortBox()
        server.start { port in Task { await portBox.set(port) } }
        let port = await portBox.wait()
        apiURL = URL(string: "http://127.0.0.1:\(port)")!
        sdkKey = "qf_ck_fixture_demo"
        print("[test-swift] FIXTURE mode -> \(apiURL.absoluteString)")
    }

    // Configuration: poll fast so the demo observes updates within seconds.
    let config = Configuration(
        sdkKey: sdkKey,
        apiURLs: [apiURL],
        telemetryURL: apiURL,
        pollInterval: 1,
        collectEvaluationSummaries: true)

    let context = QuonfigContext([
        "user": ["key": .string("u_123"), "email": .string("a@example.test")]
    ])

    let quonfig: Quonfig
    do {
        quonfig = try await Quonfig.initialize(
            context: context, options: config, initTimeout: 5)
    } catch {
        print("[test-swift] FATAL: initialize failed: \(error)")
        exit(1)
    }

    print("[test-swift] ready=\(quonfig.isReady)")
    printFlags(quonfig, label: "initial")

    // Subscribe: print on every change (diff-before-notify keeps it quiet).
    let changes = ChangeCounter()
    let token = await quonfig.subscribe {
        changes.bump()
    }
    defer { token.cancel() }

    // Watch the poll loop drive updates for a few cycles.
    for i in 1...3 {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        printFlags(quonfig, label: "poll \(i)")
    }

    // updateContext: switch identity and refetch.
    print("[test-swift] updateContext -> u_456")
    try? await quonfig.updateContext(
        QuonfigContext([
            "user": ["key": .string("u_456"), "email": .string("b@example.test")]
        ]))
    printFlags(quonfig, label: "after updateContext")

    print("[test-swift] subscriber change notifications observed: \(changes.value)")
    await quonfig.shutdown()
    fixtureServer?.stop()
    print("[test-swift] done")
}

@MainActor
func printFlags(_ q: Quonfig, label: String) {
    let nc = q.isEnabled("new-checkout")
    let color = q.string("button-color", default: "blue")
    let limit = q.int("rate-limit", default: 0)
    let detail = q.details("checkout-experiment")
    print(
        "[test-swift] [\(label)] new-checkout=\(nc) button-color=\(color) "
            + "rate-limit=\(limit) checkout-experiment.variant=\(detail.variant)")
}

/// Tiny one-shot async port handoff from the server's `ready` callback to the
/// awaiting caller, via a single checked continuation (no locking from an async
/// context — that's a Swift 6 hard error).
actor PortBox {
    private var port: UInt16?
    private var waiter: CheckedContinuation<UInt16, Never>?

    func set(_ p: UInt16) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: p)
        } else {
            port = p
        }
    }

    func wait() async -> UInt16 {
        if let port { return port }
        return await withCheckedContinuation { continuation in
            self.waiter = continuation
        }
    }
}

/// Thread-safe change counter for the subscriber.
final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func bump() { lock.lock(); _value += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}

await runDemo()
