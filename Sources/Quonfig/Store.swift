import Foundation
import os

/// A native, typed config value coerced from the wire `WireValue`.
///
/// Mirrors `sdk-javascript/src/config.ts` `parseValue`: the server sends a
/// `{ type, value }` pair and the SDK presents a native value. We keep the
/// graph as `QuonfigJSONValue` internally (lossless, `int` distinct from
/// `double`) and coerce on read through the typed getters.
public enum QuonfigValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case stringList([String])
    case json(QuonfigJSONValue)
    case null
}

/// OpenFeature-style resolution details for a single key.
///
/// Mirrors `sdk-javascript`'s `getDetails` return shape (value + reason +
/// ruleIndex + variant), built so a future `openfeature-swift` provider can wrap
/// the client without re-deriving anything (plan §3.7). `value` is the native
/// coerced value; `reason` is the 5-value `EvaluationReason`; `ruleIndex` /
/// `weightedValueIndex` are present only for TARGETING_MATCH / SPLIT.
public struct EvaluationDetails: Sendable, Equatable {
    public let value: QuonfigValue?
    public let reason: EvaluationReason
    public let ruleIndex: Int?
    public let weightedValueIndex: Int?
    public let variant: String
    public let configId: String?
    public let configType: String?

    public init(
        value: QuonfigValue?,
        reason: EvaluationReason,
        ruleIndex: Int?,
        weightedValueIndex: Int?,
        variant: String,
        configId: String?,
        configType: String?
    ) {
        self.value = value
        self.reason = reason
        self.ruleIndex = ruleIndex
        self.weightedValueIndex = weightedValueIndex
        self.variant = variant
        self.configId = configId
        self.configType = configType
    }
}

/// Build the OpenFeature `variant` string per the cross-SDK spec
/// (`project/plans/openfeature-resolution-details.md` §2). Byte-for-byte the
/// same logic as `sdk-javascript/src/quonfig.ts` `buildVariant`.
func buildVariant(
    reason: EvaluationReason,
    ruleIndex: Int?,
    weightedValueIndex: Int?
) -> String {
    switch reason {
    case .static:
        return "static"
    case .targetingMatch:
        return ruleIndex.map { "targeting:\($0)" } ?? "targeting:0"
    case .split:
        return weightedValueIndex.map { "split:\($0)" } ?? "split:0"
    case .default, .error:
        return "default"
    }
}

/// An immutable, atomically-published view of the resolved configs.
///
/// The store mutates by replacing this whole object behind a lock; the
/// synchronous getters read one reference and coerce — so the UI thread never
/// contends with a network callback that's rebuilding the map (plan §2.5
/// "reads go through a snapshot so the UI thread never contends"). Sendable
/// because every stored type is Sendable and the object is never mutated after
/// construction.
struct ResolvedSnapshot: Sendable {
    /// key -> resolved evaluation. Empty before the first envelope is applied.
    let evaluations: [String: Evaluation]
    /// Stable hash of the applied envelope, used for diff-before-notify. `nil`
    /// means "no envelope applied yet" (cold).
    let envelopeHash: Int?
    /// `Meta.generation` of the currently-held envelope (0 before the first
    /// apply, or when the server is unversioned / pre-watermark). The
    /// reject-older guard compares an incoming generation against
    /// this to refuse a regression (spec 5f).
    let generation: Int
    /// `true` once any envelope (live or cache) has been applied — gates the
    /// reads-before-ready replay (plan §2.10, Statsig #1/#36).
    let ready: Bool

    static let empty = ResolvedSnapshot(
        evaluations: [:], envelopeHash: nil, generation: 0, ready: false)
}

/// Stable structural hash of an envelope's evaluations, used to skip notifying
/// subscribers when an unchanged poll comes back (plan §2.10 "diff the resolved
/// envelope before firing subscribers" — Flagsmith #76). Order-independent over
/// keys so dictionary iteration order can't produce a false diff.
private func envelopeHash(_ evaluations: [String: Evaluation]) -> Int {
    var acc: UInt64 = 1_469_598_103_934_665_603  // FNV offset basis
    let prime: UInt64 = 1_099_511_628_211
    func mix(_ h: Int) {
        acc = (acc ^ UInt64(bitPattern: Int64(h))) &* prime
    }
    // XOR per-key hashes so the result is independent of dictionary order.
    var combined = 0
    for (key, ev) in evaluations {
        var hasher = Hasher()
        hasher.combine(key)
        hasher.combine(ev.value.type)
        hasher.combine(ev.value.value)
        hasher.combine(ev.reason)
        hasher.combine(ev.ruleIndex)
        hasher.combine(ev.weightedValueIndex)
        combined ^= hasher.finalize()
    }
    mix(combined)
    mix(evaluations.count)
    return Int(bitPattern: UInt(truncatingIfNeeded: acc))
}

/// The in-memory store: an `actor` that owns the resolved envelope, the
/// subscriber set, and the reads-before-ready queue. The loader writes into it
/// via `apply(_:)`; callers read through the synchronous typed getters.
///
/// Reads are served from `_snapshot`, an atomically-published immutable value
/// guarded by a tiny `os_unfair_lock`-equivalent (`NSLock`) so the **synchronous**
/// getters never have to hop onto the actor (plan §2.4 "reads are synchronous and
/// never block"). All *mutation* (apply / subscribe / replay) goes through the
/// actor, which serializes it. This is the three-surfaces split from §2.10:
/// state actor ≠ public-callback dispatch ≠ the lock-guarded read snapshot.
public actor Store {
    /// Lock-guarded published snapshot. Read by the synchronous getters off-actor;
    /// only ever *written* from inside the actor (so writes are already serialized,
    /// the lock only protects the read/write tear across threads).
    private let snapshotBox = SnapshotBox()

    /// Lock-guarded exposure recorder, read off-actor from the synchronous
    /// EXPOSED read path (`resolved(_:logExposure:true)`). The telemetry
    /// aggregator (qfg-2t2d.8) registers a closure here that fans an exposure to
    /// the aggregator actor via a detached, non-awaited `Task` — so a read NEVER
    /// blocks on telemetry (§2.8). `nil` until wired (or when summaries are
    /// disabled via `Configuration.collectEvaluationSummaries`).
    private let exposureBox = ExposureRecorderBox()

    /// Keys already warned about for a malformed duration value (one warning per
    /// key per client, qfg-2agi.14). Lock-guarded; touched off-actor by reads.
    private let invalidDurationWarnings = WarnOnceBox()

    /// Active subscribers, keyed by token id so cancellation is O(1).
    private var subscribers: [UInt64: @Sendable () -> Void] = [:]
    private var nextSubscriberID: UInt64 = 0

    /// Reads that arrived before the first envelope. Each is replayed exactly once
    /// when the store becomes ready, then cleared (plan §2.10 Statsig #1/#36 —
    /// "reads-before-init register, then replay on ready, not silently dropped").
    private var pendingReadyCallbacks: [@Sendable () -> Void] = []

    /// Fingerprint of the context the held snapshot belongs to (qfg-goi1.2.3).
    /// `nil` for a standalone store that is never context-tagged. Set by the
    /// client at init and on every `updateContext`; a fetch built for any other
    /// context is discarded by `applyIfCurrent`.
    private var contextTag: String?

    public init() {}

    // MARK: - Mutation (actor-isolated)

    /// Apply a resolved envelope. Diffs against the current snapshot's hash and
    /// only notifies subscribers when the evaluations actually changed — an
    /// unchanged poll (or a 304-backed re-apply of the same context) does NOT
    /// fire subscribers, avoiding SwiftUI re-render storms (Flagsmith #76).
    ///
    /// The first apply always flips `ready` and replays any reads-before-ready
    /// callbacks, even if the envelope is empty.
    @discardableResult
    public func apply(_ envelope: EvalEnvelope) -> Bool {
        install(envelope, rejectOlder: true)
    }

    /// Install `envelope`; `rejectOlder: false` skips the reject-older guard (a
    /// context switch, where the held watermark belongs to another context).
    @discardableResult
    private func install(_ envelope: EvalEnvelope, rejectOlder: Bool) -> Bool {
        let current = snapshotBox.value
        let wasReady = current.ready
        let incomingGen = envelope.meta.generation

        // Reject-older install guard (spec 5f, qfg-7h5d.2.x — frontend parity
        // with the backend SDKs). A versioned snapshot strictly older than the
        // held generation is dropped, so a sequential failover to a lagging
        // (equal-or-lower generation — spec 5f.1, honest counts on both legs)
        // secondary can't regress an established client. A fresh
        // store installs anything; an unversioned snapshot (generation <= 0 — a
        // pre-watermark server, or an old persisted-cache record) carries no
        // ordering information so it installs anyway (the carve-out, mandatory
        // from day one). A same-or-newer generation installs; a same-generation
        // snapshot whose evaluations differ is a context re-eval (the config
        // version is the same, the context changed), not a regression, so it
        // still applies — its hash differs, so it also notifies.
        if rejectOlder, wasReady, incomingGen > 0, incomingGen < current.generation {
            return false
        }

        let newHash = envelopeHash(envelope.evaluations)
        let changed = !wasReady || current.envelopeHash != newHash

        // Update the snapshot when the values changed OR the generation advanced
        // on identical values (so the held watermark stays current for the next
        // reject-older comparison even on a no-notify poll).
        if changed || current.generation != incomingGen {
            snapshotBox.value = ResolvedSnapshot(
                evaluations: envelope.evaluations,
                envelopeHash: newHash,
                generation: incomingGen,
                ready: true
            )
        }

        if !wasReady {
            replayPendingReady()
        }
        if changed {
            notifySubscribers()
        }
        return changed
    }

    /// Apply a `LoaderResult` directly. A `notModified` (304/204) result whose
    /// envelope hash already matches the live snapshot is a true no-op — no
    /// subscriber churn — but a 304 that arrives *after a context switch* (the
    /// snapshot holds a different context's values) still applies, because the
    /// loader returns the matching cached envelope for the requested context and
    /// its hash will differ from what's live. This mirrors `sdk-javascript`'s
    /// `load()` 304-after-updateContext handling via the hash diff rather than a
    /// separate context signature.
    @discardableResult
    public func apply(loaderResult: LoaderResult) -> Bool {
        apply(loaderResult.envelope)
    }

    // MARK: - Context isolation (qfg-goi1.2.3)

    /// Tag the store with the context its snapshot belongs to, without changing
    /// the snapshot. The client calls this once at init.
    func setContextTag(_ tag: String) {
        contextTag = tag
    }

    /// Apply a fetch result only if it was built for the current context
    /// (`contextTag` is the fingerprint of the context the request carried).
    /// Returns `false`, installing nothing, for a result that belongs to a
    /// context the client has since switched away from. Returns `true` for a
    /// current-context result, even if the reject-older guard then refuses it
    /// (that refusal is within one context's stream). The check and the
    /// install run in one actor turn, so a concurrent `resetForContextSwitch`
    /// cannot slip between them.
    func applyIfCurrent(_ result: LoaderResult, contextTag tag: String) -> Bool {
        guard contextTag == nil || contextTag == tag else { return false }
        apply(loaderResult: result)
        return true
    }

    /// Switch the store to a new context: install that context's cached envelope
    /// unconditionally, or an empty ready envelope (getters return caller
    /// defaults) when it has none. The previous context's snapshot and its
    /// generation watermark are dropped, so the reject-older guard only ever
    /// compares generations within one context's stream. Subscribers are
    /// notified when the resolved values change.
    ///
    /// A no-op when `tag` is already the current context (an app re-identifying
    /// the same user): the held snapshot already belongs to it, and the cache
    /// may lag memory (a failed `Persistence.save`), so reinstalling from disk
    /// could flash defaults.
    func resetForContextSwitch(to cached: EvalEnvelope?, contextTag tag: String) {
        guard contextTag != tag else { return }
        contextTag = tag
        let envelope =
            cached ?? EvalEnvelope(evaluations: [:], meta: EvalMeta(version: "", environment: ""))
        install(envelope, rejectOlder: false)
    }

    /// Pull one envelope from the loader and apply it. Returns whether the
    /// applied envelope changed the resolved values.
    ///
    /// This does no context check: it applies whatever the loader returns. The
    /// `Quonfig` client does not use it; its polls go through a step that
    /// discards a result fetched for a context it has since switched away from
    /// (qfg-goi1.2.3).
    @discardableResult
    public func refresh(using loader: Loader) async throws -> Bool {
        let result = try await loader.load()
        return apply(loaderResult: result)
    }

    /// Register a subscriber invoked after every *change* to the resolved
    /// envelope. Returns a cancellation token; the subscriber stays active until
    /// the token is cancelled (or deinit'd, which cancels it).
    ///
    /// Subscriber callbacks are isolated: a throwing/crashing closure is wrapped
    /// so one bad listener can't break the others (matches `sdk-javascript`'s
    /// swallow-on-throw; plan §2.10 Listeners). The callback fires on the actor's
    /// executor — re-read flags from it via the synchronous getters.
    public func subscribe(_ listener: @escaping @Sendable () -> Void) -> SubscriptionToken {
        let id = nextSubscriberID
        nextSubscriberID &+= 1
        subscribers[id] = listener
        return SubscriptionToken { [weak self] in
            guard let self else { return }
            Task { await self.cancelSubscription(id) }
        }
    }

    private func cancelSubscription(_ id: UInt64) {
        subscribers[id] = nil
    }

    /// Register a callback to run as soon as the store is ready. If it's already
    /// ready, the callback runs immediately; otherwise it's queued and replayed on
    /// the first `apply` (plan §2.10 Statsig #1/#36).
    public func onReady(_ callback: @escaping @Sendable () -> Void) {
        if snapshotBox.value.ready {
            callback()
        } else {
            pendingReadyCallbacks.append(callback)
        }
    }

    private func replayPendingReady() {
        let callbacks = pendingReadyCallbacks
        pendingReadyCallbacks.removeAll()
        for cb in callbacks {
            cb()
        }
    }

    private func notifySubscribers() {
        for listener in subscribers.values {
            // Isolate each callback: a closure that traps can't be caught, but a
            // throwing wrapper is impossible here (the closure is non-throwing),
            // so isolation is structural — each runs independently and one
            // returning has no bearing on the next. Matches sdk-javascript's
            // per-listener try/catch intent.
            listener()
        }
    }

    /// The held `Meta.generation` watermark (0 before the first apply, or when
    /// the server is unversioned / pre-watermark). Read by
    /// the reject-older guard and the failover chaos/parity tests. Synchronous,
    /// off-actor.
    public nonisolated var heldGeneration: Int {
        snapshotBox.value.generation
    }

    /// Test/inspection hook: live subscriber count.
    var subscriberCount: Int { subscribers.count }
    /// Test/inspection hook: queued reads-before-ready count.
    var pendingReadyCount: Int { pendingReadyCallbacks.count }

    // MARK: - Synchronous reads (served off-actor from the snapshot)

    /// `true` once any envelope has been applied. Synchronous, off-actor.
    public nonisolated var isReady: Bool {
        snapshotBox.value.ready
    }

    /// Whether a flag is enabled. Returns `false` for any non-`true` value or an
    /// absent key (matches `sdk-javascript`'s `isEnabled`: `=== true`).
    public nonisolated func isEnabled(_ key: String) -> Bool {
        if case .bool(let b)? = resolved(key)?.coerced { return b }
        return false
    }

    /// String value, or the caller-supplied default if absent / wrong type.
    public nonisolated func string(_ key: String, default def: String) -> String {
        if case .string(let s)? = resolved(key)?.coerced { return s }
        return def
    }

    /// Int value, or the caller-supplied default. Coerces a whole `double` to
    /// `int` for forgiveness, matching the family's lenient numeric reads.
    public nonisolated func int(_ key: String, default def: Int) -> Int {
        switch resolved(key)?.coerced {
        case .int(let i)?: return Int(i)
        case .double(let d)?: return Int(exactly: d) ?? def
        default: return def
        }
    }

    /// Double value, or the caller-supplied default. An `int` widens to `double`.
    public nonisolated func double(_ key: String, default def: Double) -> Double {
        switch resolved(key)?.coerced {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return def
        }
    }

    /// String-list value, or the caller-supplied default if absent / wrong type.
    public nonisolated func stringList(_ key: String, default def: [String]) -> [String] {
        stringList(key, default: def, logExposure: true)
    }

    /// Duration value in seconds (`TimeInterval`), or the caller-supplied default.
    ///
    /// Only a `duration` config whose stored value is inside the shared ISO-8601
    /// grammar (`PT30S`, `P1DT6H`, `PT1.5S`, ...; see `parseISODurationMillis`)
    /// yields a value. Absent, wrong type, or malformed -> the default; a
    /// malformed value also logs one warning per key.
    public nonisolated func duration(_ key: String, default def: TimeInterval) -> TimeInterval {
        duration(key, default: def, logExposure: true)
    }

    /// JSON object value as a Foundation dictionary, or `nil` if absent / not an
    /// object. Mirrors `sdk-javascript`'s `json(key) -> object | undefined`.
    public nonisolated func json(_ key: String) -> [String: Any]? {
        guard case .json(let v)? = resolved(key)?.coerced else { return nil }
        guard case .object = v else { return nil }
        return v.foundationValue as? [String: Any]
    }

    /// Full resolution details (value + reason + ruleIndex + variant) for a key.
    /// Returns `.error` reason when the store isn't ready or the key is absent,
    /// exactly as `sdk-javascript`'s `getDetails`.
    public nonisolated func details(_ key: String) -> EvaluationDetails {
        let snap = snapshotBox.value
        guard snap.ready else {
            return EvaluationDetails(
                value: nil, reason: .error, ruleIndex: nil, weightedValueIndex: nil,
                variant: "default", configId: nil, configType: nil)
        }
        guard let ev = snap.evaluations[key] else {
            return EvaluationDetails(
                value: nil, reason: .error, ruleIndex: nil, weightedValueIndex: nil,
                variant: "default", configId: nil, configType: nil)
        }
        let value = coerce(ev.value)
        // Older api-delivery builds omit `reason` on the wire; absence -> STATIC
        // (matches sdk-javascript getDetails fallback). A malformed duration is
        // an ERROR (qfg-2agi.14).
        let reason = (ev.value.type == "duration" && value == nil) ? .error : (ev.reason ?? .static)
        return EvaluationDetails(
            value: value,
            reason: reason,
            ruleIndex: ev.ruleIndex,
            weightedValueIndex: ev.weightedValueIndex,
            variant: buildVariant(
                reason: reason, ruleIndex: ev.ruleIndex,
                weightedValueIndex: ev.weightedValueIndex),
            configId: ev.configId,
            configType: ev.configType)
    }

    // MARK: - Exposure-decoupled read variants
    //
    // The `…ExposureLoggingDisabled` analog (plan §2.10 Statsig §7.6). The getter
    // shape is baked in NOW so debug screens / admin tooling can read a flag
    // without it counting as an exposure for the telemetry aggregator (qfg-2t2d.8
    // wires the aggregator into the EXPOSED path). Today both paths return the
    // same value; the only difference is the suppressed exposure log, which is
    // why these forward through `resolved(key, logExposure: false)`.

    /// `isEnabled` without recording an exposure.
    public nonisolated func isEnabled(_ key: String, logExposure: Bool) -> Bool {
        if case .bool(let b)? = resolved(key, logExposure: logExposure)?.coerced { return b }
        return false
    }

    /// `string` without recording an exposure.
    public nonisolated func string(_ key: String, default def: String, logExposure: Bool) -> String {
        if case .string(let s)? = resolved(key, logExposure: logExposure)?.coerced { return s }
        return def
    }

    /// `int` without recording an exposure.
    public nonisolated func int(_ key: String, default def: Int, logExposure: Bool) -> Int {
        switch resolved(key, logExposure: logExposure)?.coerced {
        case .int(let i)?: return Int(i)
        case .double(let d)?: return Int(exactly: d) ?? def
        default: return def
        }
    }

    /// `double` without recording an exposure.
    public nonisolated func double(_ key: String, default def: Double, logExposure: Bool) -> Double {
        switch resolved(key, logExposure: logExposure)?.coerced {
        case .double(let d)?: return d
        case .int(let i)?: return Double(i)
        default: return def
        }
    }

    /// `stringList` without recording an exposure (when `logExposure` is false).
    public nonisolated func stringList(_ key: String, default def: [String], logExposure: Bool) -> [String] {
        if case .stringList(let l)? = resolved(key, logExposure: logExposure)?.coerced { return l }
        return def
    }

    /// `duration` without recording an exposure (when `logExposure` is false).
    public nonisolated func duration(_ key: String, default def: TimeInterval, logExposure: Bool) -> TimeInterval {
        guard let r = resolved(key, logExposure: logExposure), r.evaluation.value.type == "duration" else {
            return def
        }
        if case .string(let s)? = r.coerced, let millis = parseISODurationMillis(s) {
            return TimeInterval(millis) / 1000
        }
        invalidDurationWarnings.warnOnce(key)
        return def
    }

    // MARK: - Internal coercion

    /// A resolved entry plus its coerced native value. `coerced` is computed once
    /// per read; cheap enough not to memoize.
    private struct Resolved {
        let evaluation: Evaluation
        let coerced: QuonfigValue?
    }

    /// Look up a key in the current snapshot and coerce it. `logExposure` is the
    /// hook the telemetry aggregator (qfg-2t2d.8) will branch on; today it's a
    /// no-op so the EXPOSED and SUPPRESSED paths return identical values.
    private nonisolated func resolved(_ key: String, logExposure: Bool = true) -> Resolved? {
        let snap = snapshotBox.value
        guard snap.ready, let ev = snap.evaluations[key] else { return nil }
        let coerced = coerce(ev.value)
        // qfg-2t2d.8: an EXPOSED read records one exposure. The recorder fans to
        // the aggregator actor via a detached Task, so this never blocks the read.
        if logExposure, let recorder = exposureBox.recorder {
            let reason = (ev.value.type == "duration" && coerced == nil) ? .error : (ev.reason ?? .static)
            let details = EvaluationDetails(
                value: coerced,
                reason: reason,
                ruleIndex: ev.ruleIndex,
                weightedValueIndex: ev.weightedValueIndex,
                variant: buildVariant(
                    reason: reason, ruleIndex: ev.ruleIndex,
                    weightedValueIndex: ev.weightedValueIndex),
                configId: ev.configId,
                configType: ev.configType)
            recorder(key, details)
        }
        return Resolved(evaluation: ev, coerced: coerced)
    }

    /// Wire the exposure recorder. The telemetry aggregator (qfg-2t2d.8) calls
    /// this with a closure that forwards each EXPOSED read to its `record(...)`.
    /// Passing `nil` disables exposure recording (e.g.
    /// `collectEvaluationSummaries == false`). Actor-isolated so the write is
    /// serialized; the read side is the lock-guarded `exposureBox`.
    public func setExposureRecorder(_ recorder: (@Sendable (String, EvaluationDetails) -> Void)?) {
        exposureBox.recorder = recorder
    }

    /// Coerce a wire `{ type, value }` into a native `QuonfigValue`, mirroring
    /// `sdk-javascript/src/config.ts` `parseValue` for the frontend types the
    /// eval endpoint serves (bool/int/double/string/json/string_list).
    private nonisolated func coerce(_ wire: WireValue) -> QuonfigValue? {
        guard let v = wire.value else { return .null }
        switch wire.type {
        case "bool":
            if case .bool(let b) = v { return .bool(b) }
        case "int":
            if case .int(let i) = v { return .int(i) }
            if case .double(let d) = v, let i = Int64(exactly: d) { return .int(i) }
        case "double":
            if case .double(let d) = v { return .double(d) }
            if case .int(let i) = v { return .double(Double(i)) }
        case "string", "log_level":
            if case .string(let s) = v { return .string(s) }
        case "duration":
            // The stored ISO-8601 string, only when it is inside the grammar
            // (qfg-2agi.14). A malformed or non-string duration coerces to nil,
            // so no getter or details() ever surfaces the raw value.
            if case .string(let s) = v, parseISODurationMillis(s) != nil { return .string(s) }
            return nil
        case "string_list":
            if case .array(let arr) = v {
                let strings = arr.compactMap { item -> String? in
                    if case .string(let s) = item { return s }
                    return nil
                }
                if strings.count == arr.count { return .stringList(strings) }
            }
        case "json":
            // sdk-javascript rejects stringified JSON loudly; native only.
            if case .string = v { return nil }
            return .json(v)
        default:
            break
        }
        // Type/shape mismatch — fall back to carrying the raw graph as json so a
        // forgiving caller can still inspect it, rather than dropping silently.
        return .json(v)
    }
}

/// A cancellation token returned by `Store.subscribe`. Cancels on `cancel()` or
/// on deinit (so a dropped token tears down its subscription — the SwiftUI
/// `@State` lifetime pattern).
public final class SubscriptionToken: Sendable {
    private let onCancel: @Sendable () -> Void
    private let cancelled = LockedFlag()

    init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        guard cancelled.setIfUnset() else { return }
        onCancel()
    }

    deinit {
        if cancelled.setIfUnset() {
            onCancel()
        }
    }
}

/// Tiny lock-guarded one-shot flag so `cancel()`/`deinit` fire `onCancel` exactly
/// once even under a cancel/deinit race.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// Returns `true` the first time it's called, `false` thereafter.
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

/// A lock-guarded box holding the published `ResolvedSnapshot`. The synchronous
/// getters read `value` off-actor; the actor writes it. `@unchecked Sendable`
/// because the `NSLock` makes the read/write tear-free and `ResolvedSnapshot` is
/// itself Sendable/immutable.
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ResolvedSnapshot = .empty

    var value: ResolvedSnapshot {
        get {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _value = newValue
        }
    }
}

/// Lock-guarded holder for the exposure recorder closure. Written from inside the
/// `Store` actor, read off-actor from the synchronous read path. `@unchecked
/// Sendable` because the `NSLock` makes the closure read/write tear-free and the
/// stored closure is itself `@Sendable`.
private final class ExposureRecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _recorder: (@Sendable (String, EvaluationDetails) -> Void)?

    var recorder: (@Sendable (String, EvaluationDetails) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _recorder
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _recorder = newValue
        }
    }
}

/// Lock-guarded "warn once per key" set for malformed duration values. The raw
/// value is never logged, only the key.
private final class WarnOnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var warned: Set<String> = []
    private let logger = os.Logger(subsystem: "com.quonfig.sdk", category: "Quonfig")

    func warnOnce(_ key: String) {
        lock.lock()
        let isNew = warned.insert(key).inserted
        lock.unlock()
        if isNew {
            logger.warning(
                "Quonfig: config \(key, privacy: .public) has a malformed duration value; returning the default")
        }
    }
}
