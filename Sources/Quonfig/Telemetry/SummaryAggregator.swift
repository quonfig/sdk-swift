import Foundation

/// In-memory key for a counter: `{flagKey, configType}` (JS keys its map by
/// `"${config.key},${configType}"`). We keep the two parts structured rather than
/// string-joined so we never have to split on a comma a key might contain.
private struct CounterKey: Hashable, Sendable {
    let key: String
    let type: String
}

/// Batches per-flag evaluation reads into counters and uploads them on an
/// exponential-backoff cadence. The Apple SDK's **only** telemetry component
/// (§2.8): context shapes/examples are server-side via `collectContextMode`.
///
/// Mirrors `sdk-javascript/src/telemetry/evaluationSummaryAggregator.ts` +
/// `periodicSync.ts` + `exponentialBackoff.ts`, with two mobile twists (§2.8/§2.11):
///   - **Backoff cadence 8s → 300s** (NOT a flat 30s) — same params as JS.
///   - **`flushOnBackground()`** persists the pending queue to **disk first**,
///     then attempts a network flush (~5s budget). iOS has no clean shutdown.
///
/// ## Decoupled exposure (Statsig §7.6)
/// `record(_:)` IS the exposure. The store's `…logExposure:false` read variants
/// never call it, so debug-screen / pre-render reads don't inflate counts.
///
/// ## Bounded offline queue
/// Distinct counter keys are capped at `maxKeys` (JS `maxKeys`); over the cap,
/// new keys are dropped (existing counts still increment). On a failed flush the
/// window is merged back into the live map (collapse, not unbounded growth), and
/// a separate bounded list of pending windows is persisted to disk so a
/// suspension doesn't lose the last window.
public actor SummaryAggregator {
    /// Default max distinct counter keys held in one window (JS uses 100k; mobile
    /// workspaces are ~500 flags, so this is generous headroom while still bounded).
    public static let defaultMaxKeys = 100_000

    /// Bound on persisted offline windows so an app that's offline for a long time
    /// can't grow the on-disk queue without limit (oldest dropped past the cap).
    public static let defaultMaxQueuedWindows = 50

    private let uploader: TelemetryUploader
    private let instanceHash: String
    private let clientVersion: String
    private let maxKeys: Int
    private let maxQueuedWindows: Int
    private let now: @Sendable () -> Date

    /// Live counters for the current window, plus the window start.
    private var counters: [CounterKey: EvaluationCounter] = [:]
    private var windowStart: Date

    /// Persisted-to-disk offline queue of windows that failed to upload. Bounded.
    private var queued: [EvaluationSummaries] = []
    private let queueStore: TelemetryQueueStore?

    /// Backoff state (8s → 300s). `nil` until the loop starts.
    private var backoff: ExponentialBackoff
    private var syncTask: Task<Void, Never>?
    private var running = false

    init(
        uploader: TelemetryUploader,
        instanceHash: String,
        clientVersion: String = quonfigVersion,
        maxKeys: Int = SummaryAggregator.defaultMaxKeys,
        maxQueuedWindows: Int = SummaryAggregator.defaultMaxQueuedWindows,
        queueStore: TelemetryQueueStore? = TelemetryFileQueueStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.uploader = uploader
        self.instanceHash = instanceHash
        self.clientVersion = clientVersion
        self.maxKeys = max(1, maxKeys)
        self.maxQueuedWindows = max(0, maxQueuedWindows)
        self.queueStore = queueStore
        self.now = now
        self.windowStart = now()
        // 8s initial → 300s max, multiplier 2 — identical to periodicSync.ts.
        self.backoff = ExponentialBackoff(maxDelaySeconds: 300, initialDelaySeconds: 8, multiplier: 2)
        // Restore any windows persisted on a prior background/suspension.
        if let store = queueStore, let restored = store.load() {
            self.queued = Array(restored.suffix(self.maxQueuedWindows))
        }
    }

    // MARK: - Record (the exposure)

    /// Record one exposure for `details` (the store calls this from the EXPOSED
    /// read path only). Never blocks reads — the store hops onto this actor with a
    /// detached, non-awaited `Task` (see `Store` wiring). Mirrors JS `record`:
    /// first sight of a `{key,type}` creates the counter (with `selectedValue`),
    /// every sight increments its count.
    public func record(key: String, details: EvaluationDetails) {
        let ck = CounterKey(key: key, type: details.configType ?? "")

        if counters[ck] == nil {
            // Bound distinct keys (JS: drop once the map hits maxKeys).
            if counters.count >= maxKeys { return }
            counters[ck] = EvaluationCounter(
                configRowIndex: nil,
                conditionalValueIndex: nil,
                configId: details.configId,
                reason: details.reason.rawValue,
                ruleIndex: details.ruleIndex,
                weightedValueIndex: details.weightedValueIndex,
                selectedValue: Self.selectedValue(for: details.value, configType: details.configType ?? ""),
                count: 0
            )
        }
        counters[ck]?.count += 1
    }

    /// Build the JS `{ [config.type]: massagedValue }` `selectedValue` shape. The
    /// outer key is the value's wire type; `string_list` massages to
    /// `{ values: [...] }`, json to `{ json: <graph> }` — mirroring
    /// `massageSelectedValue` in the JS aggregator. An absent value (default
    /// served) yields an empty object, matching JS when `config.value` is undefined.
    static func selectedValue(for value: QuonfigValue?, configType: String) -> QuonfigJSONValue {
        guard let value else { return .object([:]) }
        switch value {
        case .bool(let b):
            return .object(["bool": .bool(b)])
        case .int(let i):
            return .object(["int": .int(i)])
        case .double(let d):
            return .object(["double": .double(d)])
        case .string(let s):
            return .object(["string": .string(s)])
        case .stringList(let arr):
            return .object(["string_list": .object(["values": .array(arr.map { .string($0) })])])
        case .json(let graph):
            return .object(["json": graph])
        case .null:
            return .object([:])
        }
    }

    // MARK: - Sync loop (8s → 300s backoff)

    /// Start the backoff-driven flush loop. Idempotent. The loop sleeps for the
    /// next backoff interval, then flushes; an empty window is skipped (JS
    /// `sync()` returns early when `data.size === 0`) but still advances the timer.
    public func start() {
        guard !running else { return }
        running = true
        syncTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stop the loop (does NOT flush — call `flushOnBackground()` for that).
    public func stop() {
        running = false
        syncTask?.cancel()
        syncTask = nil
    }

    private func runLoop() async {
        while running && !Task.isCancelled {
            let delay = backoff.nextDelaySeconds()
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return  // cancelled
            }
            guard running else { return }
            await flush()
        }
    }

    // MARK: - Flush

    /// Drain the current window + any queued offline windows and POST them. A
    /// failed upload re-queues the window (bounded, persisted) rather than losing
    /// the counts. Never throws to the caller.
    public func flush() async {
        // Snapshot + reset the live window (JS `prepareData` clears `data`).
        let window = drainCurrentWindow()
        var toShip = queued
        if let window { toShip.append(window) }
        guard !toShip.isEmpty else { return }
        queued = []
        persistQueue()

        var failed: [EvaluationSummaries] = []
        for summaries in toShip {
            let events = TelemetryEvents(
                instanceHash: instanceHash,
                clientName: "swift",
                clientVersion: clientVersion,
                events: [TelemetryEvent(summaries: summaries)]
            )
            do {
                try await uploader.post(events)
            } catch {
                failed.append(summaries)
            }
        }

        if failed.isEmpty {
            // A clean flush resets the backoff to its initial 8s.
            backoff.reset()
        } else {
            // Re-queue failures (bounded, oldest dropped), persist to disk.
            queued = Array((queued + failed).suffix(maxQueuedWindows))
            persistQueue()
        }
    }

    /// Background-entry flush (§2.8 mobile twist, Statsig 1.56.0): persist the
    /// pending queue to **disk first** (the durable safety net for a suspension),
    /// THEN attempt a network flush within a short budget. The disk write happens
    /// before any network so a kill mid-flush never loses the window.
    public func flushOnBackground(networkBudgetSeconds: Double = 5) async {
        // 1. Move the live window into the queue and write it to disk FIRST.
        if let window = drainCurrentWindow() {
            queued = Array((queued + [window]).suffix(maxQueuedWindows))
        }
        persistQueue()

        // 2. Best-effort network flush within the budget. If it fails or times
        //    out, the disk copy survives for the next launch's restore.
        let budget = Task {
            await self.flush()
        }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(networkBudgetSeconds * 1_000_000_000))
            budget.cancel()
        }
        await budget.value
        timeout.cancel()
    }

    /// Snapshot the live counters into an immutable window and reset the window.
    /// Returns `nil` if there were no counters (skip an empty flush — JS parity).
    private func drainCurrentWindow() -> EvaluationSummaries? {
        guard !counters.isEmpty else {
            // Still advance the window start so the next non-empty window's
            // `start` is accurate.
            windowStart = now()
            return nil
        }
        let summaries = counters.map { entry -> EvaluationSummary in
            EvaluationSummary(key: entry.key.key, type: entry.key.type, counters: [entry.value])
        }
        let result = EvaluationSummaries(
            start: Int64(windowStart.timeIntervalSince1970 * 1000),
            end: Int64(now().timeIntervalSince1970 * 1000),
            summaries: summaries
        )
        counters = [:]
        windowStart = now()
        return result
    }

    private func persistQueue() {
        queueStore?.save(queued)
    }

    // MARK: - Test/inspection hooks

    var liveKeyCount: Int { counters.count }
    var queuedWindowCount: Int { queued.count }
    var isRunning: Bool { running }
}

/// Exponential backoff for the flush cadence. Mirrors
/// `sdk-javascript/src/telemetry/exponentialBackoff.ts`: `call()` returns the
/// current delay then advances `delay = min(delay * multiplier, maxDelay)`.
/// Seconds throughout (the JS class returns ms; we keep seconds and convert at
/// the sleep site). `reset()` (no JS analog) returns to the initial delay after a
/// clean flush so a recovered connection resumes the tight 8s cadence.
struct ExponentialBackoff: Sendable {
    private let initialDelay: Double
    private let maxDelay: Double
    private let multiplier: Double
    private var delay: Double

    init(maxDelaySeconds: Double, initialDelaySeconds: Double = 2, multiplier: Double = 2) {
        self.initialDelay = initialDelaySeconds
        self.maxDelay = maxDelaySeconds
        self.multiplier = multiplier
        self.delay = initialDelaySeconds
    }

    /// Returns the next delay in **seconds**, then advances toward `maxDelay`.
    mutating func nextDelaySeconds() -> Double {
        let value = delay
        delay = min(delay * multiplier, maxDelay)
        return value
    }

    mutating func reset() {
        delay = initialDelay
    }
}

/// On-disk persistence for the bounded offline window queue. Injectable so tests
/// don't touch the filesystem. The disk write is the §2.8 safety net for
/// suspension with no clean shutdown.
protocol TelemetryQueueStore: Sendable {
    func save(_ windows: [EvaluationSummaries])
    func load() -> [EvaluationSummaries]?
}

/// Production queue store: a single atomically-written JSON file under the SDK's
/// Application Support directory (same root the `Persistence` cache uses), never
/// `UserDefaults.standard`. Failures are swallowed — telemetry must never break
/// the host app.
final class TelemetryFileQueueStore: TelemetryQueueStore, @unchecked Sendable {
    private let fileURL: URL
    private let fm = FileManager.default

    init(directory: URL? = nil) {
        let dir = directory ?? TelemetryFileQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("telemetry-queue.json")
    }

    static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("com.quonfig.sdk", isDirectory: true)
            .appendingPathComponent("telemetry", isDirectory: true)
    }

    func save(_ windows: [EvaluationSummaries]) {
        guard let data = try? JSONEncoder().encode(windows) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    func load() -> [EvaluationSummaries]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([EvaluationSummaries].self, from: data)
    }
}
