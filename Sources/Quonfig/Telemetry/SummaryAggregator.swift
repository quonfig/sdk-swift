import Foundation

/// In-memory key for a counter: `{flagKey, configType}` (JS keys its map by
/// `"${config.key},${configType}"`). We keep the two parts structured rather than
/// string-joined so we never have to split on a comma a key might contain.
private struct CounterKey: Hashable, Sendable {
    let key: String
    let type: String
}

/// Resolved telemetry transport settings (policy P1-P5 in
/// `project/plans/2026-09-24-sdk-telemetry-transport-policy.md`, mobile column).
/// Built from the `telemetry*` options on `Configuration`.
struct TelemetryTransportPolicy: Sendable, Equatable {
    /// Tick cadence: one window per tick.
    var flushInterval: TimeInterval = SummaryAggregator.defaultFlushInterval
    /// Overall foreground POST deadline (P1, mobile 15s).
    var timeout: TimeInterval = SummaryAggregator.defaultTimeout
    /// Retained (on-disk) queue cap in batches (P5).
    var maxRetainedBatches: Int = SummaryAggregator.defaultMaxRetainedBatches
    /// Retained (on-disk) queue cap in bytes (P5, mobile 512KB).
    var maxRetainedBytes: Int = SummaryAggregator.defaultMaxRetainedBytes
    /// A retained batch older than this is discarded at send time (P5).
    var maxRetainedAge: TimeInterval = SummaryAggregator.defaultMaxRetainedAge

    init() {}

    init(configuration c: Configuration) {
        flushInterval = c.telemetryFlushInterval > 0 ? c.telemetryFlushInterval : SummaryAggregator.defaultFlushInterval
        timeout = c.telemetryTimeout > 0 ? c.telemetryTimeout : SummaryAggregator.defaultTimeout
        maxRetainedBatches =
            c.telemetryMaxRetainedBatches > 0
            ? c.telemetryMaxRetainedBatches : SummaryAggregator.defaultMaxRetainedBatches
        maxRetainedBytes =
            c.telemetryMaxRetainedBytes > 0 ? c.telemetryMaxRetainedBytes : SummaryAggregator.defaultMaxRetainedBytes
        maxRetainedAge =
            c.telemetryMaxRetainedAge > 0 ? c.telemetryMaxRetainedAge : SummaryAggregator.defaultMaxRetainedAge
    }
}

/// Batches per-flag evaluation reads into counters and uploads them under the
/// SDK telemetry transport policy. The Apple SDK's **only** telemetry component
/// (§2.8): context shapes/examples are server-side via `collectContextMode`.
///
/// Aggregation mirrors `sdk-javascript/src/telemetry/evaluationSummaryAggregator.ts`.
/// The transport mirrors the sdk-node reference (`src/telemetry/transportQueue.ts`,
/// qfg-mol-9u0) with one mobile difference: the retained queue lives **on
/// disk**, one file per serialized batch, so it survives suspension and relaunch.
///
/// ## One tick (the contract's tick model)
/// 1. Skip if a POST is in flight (P2); the live window keeps aggregating.
/// 2. Discard retained batches older than 5 min (P5), evaluated at send time.
/// 3. Skip if fewer than 30s have passed since the last failure or a
///    `Retry-After` (up to 600s) has not elapsed (P4).
/// 4. Serialize the live window once, write it to disk, append it to the queue;
///    evict oldest past 5 batches / 512KB (P5).
/// 5. POST oldest-first, one at a time. 2xx: delete the file, continue.
///    Network error, timeout, 408, 429, 5xx: keep it, end the tick.
///    401/403/404: one ERROR, delete the queue, disable telemetry for the
///    process. Other 4xx: delete that batch, one ERROR, continue (P3).
///
/// A batch is removed from disk only after a 2xx (or an explicit drop), so a
/// window in flight when the app is backgrounded or killed is still on disk.
/// Retained bytes are never rewritten: a resend carries the original
/// `instanceHash` even after a relaunch, so the server dedup token matches.
///
/// ## Decoupled exposure (Statsig §7.6)
/// `record(_:)` IS the exposure. The store's `…logExposure:false` read variants
/// never call it, so debug-screen / pre-render reads don't inflate counts.
///
/// ## Bounded memory (P6)
/// Distinct counter keys are capped at `maxKeys`; over the cap, new keys are
/// dropped (existing counts still increment).
public actor SummaryAggregator {
    /// Default max distinct counter keys held in one window (JS uses 100k; mobile
    /// workspaces are ~500 flags, so this is generous headroom while still bounded).
    public static let defaultMaxKeys = 100_000

    /// Default flush interval (one window per tick).
    public static let defaultFlushInterval: TimeInterval = 60
    /// Default overall POST deadline while in the foreground (P1).
    public static let defaultTimeout: TimeInterval = 15
    /// Default retained-queue cap in batches (P5).
    public static let defaultMaxRetainedBatches = 5
    /// Default retained-queue cap in bytes: 512KB (P5, mobile).
    public static let defaultMaxRetainedBytes = 524_288
    /// Default max age of a retained batch (P5).
    public static let defaultMaxRetainedAge: TimeInterval = 300
    /// Budget for the final flush of the live window on background (P8).
    public static let backgroundFlushBudget: TimeInterval = 5

    /// Former name of the retained-queue batch cap (was 50 windows in 0.0.1).
    @available(*, deprecated, renamed: "defaultMaxRetainedBatches")
    public static let defaultMaxQueuedWindows = defaultMaxRetainedBatches

    /// No send sooner than this after a failed POST (P4).
    static let resendFloor: TimeInterval = 30
    /// `Retry-After` is honored up to this (P4).
    static let retryAfterCap: TimeInterval = 600
    /// At most one drop WARN per this interval while dropping continues (P7).
    static let dropWarnInterval: TimeInterval = 600

    private let uploader: TelemetryUploader
    private let instanceHash: String
    private let clientVersion: String
    private let maxKeys: Int
    private let policy: TelemetryTransportPolicy
    private let queueStore: TelemetryQueueStore?
    private let log: QuonfigLogSink
    private let now: @Sendable () -> Date

    /// Live counters for the current window, plus the window start.
    private var counters: [CounterKey: EvaluationCounter] = [:]
    private var windowStart: Date

    /// Retained batches, oldest first. Mirrors the on-disk queue (oversize
    /// batches are memory-only and never survive a tick).
    private var queue: [RetainedBatch] = []
    private var sequence = 0

    private var busy = false
    private var disabled = false
    private var lastFailureAt: Date?
    private var retryAfterUntil: Date?

    // Outage episode (P7).
    private var failuresSinceSuccess = 0
    private var firstFailureAt: Date?
    private var lastResult = ""
    private var lastDropWarnAt: Date?
    private var dropsSinceWarn = 0
    private var dropsThisOutage = 0

    // Rejected-batch (other 4xx) cadence.
    private var lastRejectErrorAt: Date?
    private var rejectsSinceError = 0

    private var syncTask: Task<Void, Never>?
    private var running = false

    init(
        uploader: TelemetryUploader,
        instanceHash: String,
        clientVersion: String = quonfigVersion,
        maxKeys: Int = SummaryAggregator.defaultMaxKeys,
        policy: TelemetryTransportPolicy = TelemetryTransportPolicy(),
        queueStore: TelemetryQueueStore? = TelemetryFileQueueStore(),
        logSink: QuonfigLogSink? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.uploader = uploader
        self.instanceHash = instanceHash
        self.clientVersion = clientVersion
        self.maxKeys = max(1, maxKeys)
        self.policy = policy
        self.queueStore = queueStore
        self.log = logSink ?? OSLogSink(category: "Telemetry")
        self.now = now
        self.windowStart = now()
        // Restore batches retained on disk by a previous launch (or a suspension
        // that ended in termination). Oversize files cannot be retained; the
        // caps are re-applied oldest-first. Age is checked at send time.
        var restored: [RetainedBatch] = []
        for stored in queueStore?.load() ?? [] {
            if stored.body.count > policy.maxRetainedBytes {
                queueStore?.remove(id: stored.id)
                continue
            }
            restored.append(
                RetainedBatch(id: stored.id, body: stored.body, createdAt: stored.createdAt, oversize: false))
        }
        while restored.count > policy.maxRetainedBatches
            || restored.reduce(0, { $0 + $1.body.count }) > policy.maxRetainedBytes
        {
            let evicted = restored.removeFirst()
            queueStore?.remove(id: evicted.id)
        }
        self.queue = restored
    }

    // MARK: - Record (the exposure)

    /// Record one exposure for `details` (the store calls this from the EXPOSED
    /// read path only). Never blocks reads — the store hops onto this actor with a
    /// detached, non-awaited `Task` (see `Store` wiring). Mirrors JS `record`:
    /// first sight of a `{key,type}` creates the counter (with `selectedValue`),
    /// every sight increments its count.
    public func record(key: String, details: EvaluationDetails) {
        guard !disabled else { return }
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

    // MARK: - Tick loop

    /// Start the flush loop: one tick every `flushInterval` seconds. Idempotent.
    public func start() {
        guard !running, !disabled else { return }
        running = true
        let interval = policy.flushInterval
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return  // cancelled
                }
                guard let self, await self.isRunning else { return }
                await self.tick()
            }
        }
    }

    /// Stop the loop (does NOT flush; call `flushOnBackground()` for that).
    public func stop() {
        running = false
        syncTask?.cancel()
        syncTask = nil
    }

    /// Run one tick now (see the type docs). Respects the one-POST-in-flight
    /// rule, the 30s floor and `Retry-After`. Never throws.
    public func flush() async {
        await tick()
    }

    /// One tick of the contract's model. Test seam; `flush()` is the public name.
    func tick() async {
        guard !disabled, !busy else { return }
        expire()
        guard sendAllowed() else { return }
        if let body = serializeWindow() {
            append(body)
        }
        await drain()
    }

    /// Background entry (and `shutdown`): the final flush of the live window
    /// (P8, iOS background task ~5s). The live window is serialized and written
    /// to disk FIRST, then POSTed once within `networkBudgetSeconds`. The
    /// retained queue is not drained here. If a POST is already in flight, or
    /// the 30s floor / `Retry-After` has not elapsed, nothing is sent; the
    /// window is on disk for the next foreground tick or launch.
    public func flushOnBackground(networkBudgetSeconds: Double = SummaryAggregator.backgroundFlushBudget) async {
        guard !disabled, let body = serializeWindow() else { return }
        let id = append(body)
        guard !busy, sendAllowed(), let batch = queue.first(where: { $0.id == id }) else { return }
        busy = true
        defer { busy = false }
        _ = await attempt(batch, timeout: min(networkBudgetSeconds, policy.timeout))
    }

    // MARK: - Transport

    private struct RetainedBatch: Sendable {
        let id: String
        let body: Data
        let createdAt: Date
        let oversize: Bool
    }

    /// Discard retained batches older than the max age (P5). Each is a drop.
    private func expire() {
        let t = now()
        let minutes = Int((policy.maxRetainedAge / 60).rounded())
        for batch in queue where t.timeIntervalSince(batch.createdAt) > policy.maxRetainedAge {
            remove(batch.id)
            recordDrop("batch older than \(minutes) min")
        }
    }

    /// The 30s floor after a failure and any `Retry-After` have both elapsed.
    private func sendAllowed() -> Bool {
        let t = now()
        if let last = lastFailureAt, t < last.addingTimeInterval(Self.resendFloor) { return false }
        if let until = retryAfterUntil, t < until { return false }
        return true
    }

    /// Append a serialized window: write it to disk, then enforce the caps
    /// (evict oldest). A batch over the byte cap is kept in memory only for its
    /// one POST attempt and is never written to disk. Returns its id.
    @discardableResult
    private func append(_ body: Data) -> String {
        let createdAt = now()
        sequence += 1
        let id = TelemetryFileQueueStore.batchID(createdAt: createdAt, sequence: sequence)
        let oversize = body.count > policy.maxRetainedBytes
        queue.append(RetainedBatch(id: id, body: body, createdAt: createdAt, oversize: oversize))
        if !oversize {
            queueStore?.save(id: id, body: body)
        }

        while true {
            let retained = queue.filter { !$0.oversize }
            let bytes = retained.reduce(0) { $0 + $1.body.count }
            guard retained.count > policy.maxRetainedBatches || bytes > policy.maxRetainedBytes,
                let oldest = retained.first
            else { break }
            remove(oldest.id)
            recordDrop("retained queue full")
        }
        return id
    }

    private func remove(_ id: String) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        let batch = queue.remove(at: i)
        if !batch.oversize {
            queueStore?.remove(id: id)
        }
    }

    /// POST retained batches oldest-first, one at a time; stop at the first
    /// retryable failure.
    private func drain() async {
        busy = true
        defer { busy = false }
        while !disabled, let batch = queue.first {
            guard await attempt(batch, timeout: policy.timeout) else { break }
        }
        // Oversize batches are never carried across ticks.
        for batch in queue where batch.oversize {
            remove(batch.id)
            recordDrop("batch larger than the byte cap")
        }
    }

    /// POST one batch and apply its outcome. Returns whether the drain may
    /// continue with the next batch.
    private func attempt(_ batch: RetainedBatch, timeout: TimeInterval) async -> Bool {
        let result: TelemetryPostResult
        do {
            result = try await uploader.send(batch.body, timeout: timeout)
        } catch TelemetryTransportError.aborted {
            return false  // stopped: keep the batch, no failure recorded
        } catch is CancellationError {
            return false
        } catch TelemetryTransportError.timeout {
            onRetryableFailure(batch, result: "timeout", retryAfter: nil)
            return false
        } catch TelemetryTransportError.network(let detail) {
            onRetryableFailure(batch, result: "network error: \(detail)", retryAfter: nil)
            return false
        } catch {
            onRetryableFailure(batch, result: "network error: \(error)", retryAfter: nil)
            return false
        }

        switch Self.classify(result.status) {
        case .ok:
            remove(batch.id)
            onSuccess()
            return true
        case .retryable:
            onRetryableFailure(batch, result: String(result.status), retryAfter: result.retryAfter)
            return false
        case .auth:
            disable(status: result.status)
            return false
        case .rejected:
            remove(batch.id)
            onRejected(status: result.status, bytes: batch.body.count, bodySnippet: result.bodySnippet)
            return true
        }
    }

    private func onSuccess() {
        guard failuresSinceSuccess > 0 else { return }
        let t = now()
        let seconds = Int(t.timeIntervalSince(firstFailureAt ?? t).rounded())
        log.emit(
            level: .info,
            message:
                "Telemetry recovered: POST succeeded after \(failuresSinceSuccess) failed attempt(s) over \(seconds)s; \(dropsThisOutage) batch(es) were dropped."
        )
        failuresSinceSuccess = 0
        firstFailureAt = nil
        dropsThisOutage = 0
        lastDropWarnAt = nil
        dropsSinceWarn = 0
    }

    private func onRetryableFailure(_ batch: RetainedBatch, result: String, retryAfter: String?) {
        let t = now()
        failuresSinceSuccess += 1
        if firstFailureAt == nil { firstFailureAt = t }
        lastFailureAt = t
        lastResult = result
        if let wait = Self.parseRetryAfter(retryAfter, now: t) {
            retryAfterUntil = t.addingTimeInterval(wait)
        }
        let floorAt = t.addingTimeInterval(Self.resendFloor)
        let next = max(floorAt, retryAfterUntil ?? floorAt).timeIntervalSince(t)
        log.emit(
            level: .debug,
            message:
                "Telemetry POST failed (\(result)); \(queue.count) batch(es) / \(retainedBytesTotal) bytes retained, next send in >= \(Int(next.rounded(.up)))s"
        )
        if batch.oversize {
            remove(batch.id)
            recordDrop("batch larger than the byte cap")
        }
    }

    private func disable(status: Int) {
        let hint = status == 404 ? "wrong telemetryURL" : "the SDK key was rejected"
        log.emit(
            level: .error,
            message:
                "Telemetry disabled for this process: \(uploader.postURL.absoluteString) answered \(status) (\(hint)). Flag evaluation is unaffected."
        )
        for batch in queue { remove(batch.id) }
        queue = []
        counters = [:]
        disabled = true
        stop()
    }

    private func onRejected(status: Int, bytes: Int, bodySnippet: String) {
        let t = now()
        if let last = lastRejectErrorAt, t.timeIntervalSince(last) < Self.dropWarnInterval {
            rejectsSinceError += 1
            log.emit(level: .debug, message: "Telemetry batch rejected with \(status) and dropped (\(bytes) bytes)")
            return
        }
        let more = rejectsSinceError > 0 ? ", \(rejectsSinceError) more since the last report" : ""
        log.emit(
            level: .error,
            message:
                "Telemetry batch rejected with \(status) and dropped (\(bytes) bytes\(more)): \(bodySnippet). This is likely an SDK bug; please report it."
        )
        lastRejectErrorAt = t
        rejectsSinceError = 0
    }

    private func recordDrop(_ reason: String) {
        let t = now()
        dropsSinceWarn += 1
        dropsThisOutage += 1
        let last = lastResult.isEmpty ? "none" : lastResult
        if let warnedAt = lastDropWarnAt {
            if t.timeIntervalSince(warnedAt) >= Self.dropWarnInterval {
                let minutes = Int((t.timeIntervalSince(warnedAt) / 60).rounded())
                log.emit(
                    level: .warn,
                    message:
                        "Telemetry still dropping data: \(dropsSinceWarn) batch(es) dropped in the last \(minutes) min (last POST result: \(last)); retained queue \(queue.count) batches, \(retainedBytesTotal) bytes."
                )
                lastDropWarnAt = t
                dropsSinceWarn = 0
            } else {
                log.emit(
                    level: .debug,
                    message: "Telemetry dropped a batch: \(reason); \(dropsSinceWarn) since the last warning")
            }
            return
        }
        log.emit(
            level: .warn,
            message:
                "Telemetry is dropping data: \(reason) (last POST result: \(last)). \(dropsThisOutage) batch(es) dropped so far; retained queue \(queue.count)/\(policy.maxRetainedBatches) batches, \(retainedBytesTotal) bytes. Flag evaluation is unaffected; further drops log at debug with a summary every 10 min."
        )
        lastDropWarnAt = t
        dropsSinceWarn = 0
    }

    private var retainedBytesTotal: Int { queue.reduce(0) { $0 + $1.body.count } }

    // MARK: - Policy helpers

    enum StatusClass: Sendable, Equatable {
        case ok, retryable, auth, rejected
    }

    /// 2xx -> ok; 401, 403, 404 -> auth; 408, 429, 5xx -> retryable; every
    /// other status -> rejected (P3).
    static func classify(_ status: Int) -> StatusClass {
        switch status {
        case 200..<300: return .ok
        case 401, 403, 404: return .auth
        case 408, 429, 500..<600: return .retryable
        default: return .rejected
        }
    }

    /// Parse `Retry-After` (delta-seconds or HTTP-date relative to `now`; past
    /// dates -> 0) into seconds, clamped to 600s. Unparseable -> nil.
    static func parseRetryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        var seconds: TimeInterval
        if raw.allSatisfy(\.isNumber), let n = Double(raw) {
            seconds = n
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let at = f.date(from: raw) else { return nil }
            seconds = max(0, at.timeIntervalSince(now))
        }
        return min(seconds, retryAfterCap)
    }

    // MARK: - Window

    /// Serialize the live window into one POST body and reset it. `nil` when
    /// the window is empty (no batch, no POST). This is the only serialization:
    /// the bytes are retained and resent as-is (P5, P9).
    private func serializeWindow() -> Data? {
        guard let summaries = drainCurrentWindow() else { return nil }
        let events = TelemetryEvents(
            instanceHash: instanceHash,
            clientName: "swift",
            clientVersion: clientVersion,
            events: [TelemetryEvent(summaries: summaries)]
        )
        return try? TelemetryUploader.encode(events)
    }

    /// Snapshot the live counters into an immutable window and reset the window.
    /// Returns `nil` if there were no counters (skip an empty flush, JS parity).
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

    // MARK: - Test/inspection hooks (the contract's vocabulary)

    var liveKeyCount: Int { counters.count }
    /// `retained_count`: retained batches, excluding the live window.
    var retainedCount: Int { queue.count }
    /// `retained_bytes`: total serialized size of the retained batches.
    var retainedBytes: Int { retainedBytesTotal }
    /// `telemetry_enabled()`.
    var isTelemetryEnabled: Bool { !disabled }
    var isPostInFlight: Bool { busy }
    var isRunning: Bool { running }
}

/// One retained batch as stored on disk.
struct StoredTelemetryBatch: Sendable, Equatable {
    let id: String
    let body: Data
    let createdAt: Date
}

/// The on-disk retained queue: one file per serialized batch. Injectable so
/// tests can point it at a temp directory. The disk write is the §2.8 safety net
/// for suspension with no clean shutdown.
protocol TelemetryQueueStore: Sendable {
    /// Every stored batch, oldest first.
    func load() -> [StoredTelemetryBatch]
    func save(id: String, body: Data)
    func remove(id: String)
}

/// Production queue store: one atomically-written file per batch
/// (`<createdAt ms>-<seq>-<nonce>.batch`, holding the exact POST body) under the
/// SDK's Application Support directory (same root the `Persistence` cache uses),
/// never `UserDefaults.standard`. The creation time is in the file name, so no
/// file-timestamp API is read (privacy manifest). Failures are swallowed:
/// telemetry must never break the host app.
final class TelemetryFileQueueStore: TelemetryQueueStore, @unchecked Sendable {
    static let fileExtension = "batch"
    /// The 0.0.1 single-file queue (re-serialized windows).
    static let legacyFileName = "telemetry-queue.json"

    let directory: URL
    private let fm = FileManager.default

    init(directory: URL? = nil) {
        let dir = directory ?? TelemetryFileQueueStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.directory = dir
    }

    static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let base =
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("com.quonfig.sdk", isDirectory: true)
            .appendingPathComponent("telemetry", isDirectory: true)
    }

    /// Per-(key, telemetry URL) queue directory, so a retained batch is only
    /// ever resent with the SDK key and endpoint it was built for.
    static func directory(for configuration: Configuration) -> URL {
        let urls = QuonfigURLs.resolve(from: configuration)
        let namespace = sha256Hex("\(configuration.sdkKey)|\(urls.telemetryURL.absoluteString)")
        return defaultDirectory().appendingPathComponent(String(namespace.prefix(16)), isDirectory: true)
    }

    /// Delete the 0.0.1 queue file. Its windows were re-serialized on every
    /// save and carry no creation time, so resending them would be a new
    /// payload of unknown age; they are discarded.
    static func removeLegacyQueue(in directory: URL = defaultDirectory()) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(legacyFileName))
    }

    /// Sortable, unique batch id: zero-padded creation time in ms, a per-launch
    /// sequence, and a random nonce so two launches never collide.
    static func batchID(createdAt: Date, sequence: Int) -> String {
        let ms = Int64((createdAt.timeIntervalSince1970 * 1000).rounded())
        let nonce = UUID().uuidString.prefix(8)
        return String(format: "%015lld-%08d-", ms, sequence) + nonce
    }

    func load() -> [StoredTelemetryBatch] {
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return
            files
            .filter { $0.pathExtension == Self.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> StoredTelemetryBatch? in
                let id = url.deletingPathExtension().lastPathComponent
                guard let msText = id.split(separator: "-").first, let ms = Double(msText),
                    let body = try? Data(contentsOf: url)
                else {
                    try? fm.removeItem(at: url)
                    return nil
                }
                return StoredTelemetryBatch(id: id, body: body, createdAt: Date(timeIntervalSince1970: ms / 1000))
            }
    }

    func save(id: String, body: Data) {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.write(to: url(for: id), options: [.atomic])
    }

    func remove(id: String) {
        try? fm.removeItem(at: url(for: id))
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension(Self.fileExtension)
    }
}
