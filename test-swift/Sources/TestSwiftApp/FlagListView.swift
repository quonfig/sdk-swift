#if canImport(SwiftUI)
import SwiftUI
import Quonfig

/// An `ObservableObject` that owns the `Quonfig` client and republishes a flag
/// snapshot whenever the SDK notifies a change (`subscribe`). This is the SwiftUI
/// glue the plan calls a v1.x nice-to-have (§2.9) — the Swift analog of
/// `sdk-react`'s `useSyncExternalStore` — kept minimal here for the demo.
@MainActor
final class FlagModel: ObservableObject {
    @Published var newCheckout = false
    @Published var buttonColor = "blue"
    @Published var rateLimit = 0
    @Published var ready = false
    @Published var userKey = "u_123"

    private var quonfig: Quonfig?
    private var token: SubscriptionToken?

    /// Initialize the client (fixture server by default) and start observing.
    func start(apiURL: URL, sdkKey: String) async {
        let config = Configuration(
            sdkKey: sdkKey,
            apiURLs: [apiURL],
            telemetryURL: apiURL,  // demo posts telemetry to the same fixture
            pollInterval: 3,       // poll every 3s so updates are visible
            collectEvaluationSummaries: true)
        let q = try? await Quonfig.initialize(context: contextFor(userKey), options: config)
        self.quonfig = q
        // Re-read flags on every change (diff-before-notify keeps this quiet).
        self.token = await q?.subscribe { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Switch identity — drives the SDK's `updateContext` (stop + refetch + restart).
    func updateUser(_ key: String) async {
        userKey = key
        try? await quonfig?.updateContext(contextFor(key))
        refresh()
    }

    private func refresh() {
        guard let q = quonfig else { return }
        ready = q.isReady
        newCheckout = q.isEnabled("new-checkout")
        buttonColor = q.string("button-color", default: "blue")
        rateLimit = q.int("rate-limit", default: 0)
    }

    private func contextFor(_ key: String) -> QuonfigContext {
        QuonfigContext(["user": ["key": .string(key), "email": .string("\(key)@example.test")]])
    }
}

/// The flag dashboard. Shows each flag's live value (updating on poll) and a
/// button to switch identity (driving `updateContext`).
struct FlagListView: View {
    @StateObject private var model = FlagModel()
    let apiURL: URL
    let sdkKey: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quonfig test-swift")
                .font(.title2).bold()
            Text(model.ready ? "Ready" : "Initializing…")
                .foregroundColor(model.ready ? .green : .secondary)

            Divider()

            row("new-checkout (Bool)", model.newCheckout ? "true" : "false")
            row("button-color (String)", model.buttonColor)
            row("rate-limit (Int)", "\(model.rateLimit)")
            row("user.key", model.userKey)

            Divider()

            Button("Switch user (updateContext)") {
                Task { await model.updateUser(model.userKey == "u_123" ? "u_456" : "u_123") }
            }

            Spacer()
        }
        .padding()
        .task {
            await model.start(apiURL: apiURL, sdkKey: sdkKey)
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.body.monospaced())
            Spacer()
            Text(value).bold()
        }
    }
}
#endif
