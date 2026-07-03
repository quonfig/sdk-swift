import Foundation

/// The OpenFeature-compatible resolution reason carried alongside each
/// evaluated value.
///
/// The server (`api-delivery/internal/serve/eval_context.go` `resolutionReason`)
/// emits exactly three values on the wire: `STATIC`, `TARGETING_MATCH`, `SPLIT`.
/// The SDK synthesizes two more for caller-facing semantics, mirroring
/// `sdk-javascript/src/types.ts` `EvaluationReason`:
///   - `DEFAULT` — the key was absent from the envelope, so the caller's default
///     was returned.
///   - `ERROR`  — a value was served stale/from cache after a failure, OR an
///     unknown reason arrived on the wire.
///
/// Per plan §2.3 / §2.10: an **unknown** wire `reason` decodes to `.error`,
/// never failing the envelope (Flagsmith #70; Unleash #83).
public enum EvaluationReason: String, Sendable, Equatable, Codable {
    case `static` = "STATIC"
    case targetingMatch = "TARGETING_MATCH"
    case split = "SPLIT"
    case `default` = "DEFAULT"
    case error = "ERROR"

    /// Decode a wire string, falling back to `.error` for any unknown value
    /// instead of throwing (the §2.10 "unknown reason -> ERROR" rule).
    public init(wire raw: String) {
        self = EvaluationReason(rawValue: raw) ?? .error
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EvaluationReason(wire: raw)
    }

    /// Encodable so the resolved envelope can be round-tripped to the on-disk
    /// persistence cache (qfg-2t2d.5). Emits the wire rawValue.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// The inner value wrapper from the wire: `{ "type": <ValueType>, "value": <any> }`.
///
/// Mirrors `api-delivery/internal/config/types.go` `Value` (the `confidential` /
/// `decryptWith` fields are `omitempty` and irrelevant to frontend clients, but
/// are decoded-if-present so a future server build that emits them never breaks
/// the decode). `value` is polymorphic; we keep it as a `QuonfigJSONValue` so the
/// typed accessors in `Quonfig` can coerce it without a second parse.
public struct WireValue: Sendable, Equatable, Codable {
    /// The inner value type tag (`bool | int | double | string | json |
    /// string_list | log_level | weighted_values | schema | provided`).
    public let type: String
    /// The decoded value, kept as a JSON value graph for typed coercion.
    public let value: QuonfigJSONValue?

    enum CodingKeys: String, CodingKey {
        case type, value
    }

    public init(type: String, value: QuonfigJSONValue?) {
        self.type = type
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `type` is always present on a well-formed wire value, but decodeIfPresent
        // keeps a malformed/partial value from blowing up the whole envelope —
        // the §2.10 decoder-safety rule applies to every field.
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        value = try c.decodeIfPresent(QuonfigJSONValue.self, forKey: .value)
    }

    /// Encodable for the persistence cache (qfg-2t2d.5).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(value, forKey: .value)
    }
}

/// A single evaluated config/flag entry from the `eval-with-context` envelope.
///
/// Mirrors `api-delivery/internal/config/types.go` `EvalResult` and
/// `sdk-javascript/src/types.ts` `Evaluation`. Every server-`omitempty` field
/// (`reason`, `ruleIndex`, `weightedValueIndex`) is decoded with
/// `decodeIfPresent` — they are absent (never `null`) when empty, and a
/// non-optional decode would break the whole SDK on a future server-added field
/// (Flagsmith #70/#28, Unleash #83/#84 — plan §2.3/§2.10).
public struct Evaluation: Sendable, Equatable, Codable {
    public let value: WireValue
    public let configId: String
    public let configType: String
    public let valueType: String
    /// Server emits only STATIC/TARGETING_MATCH/SPLIT; an unknown value decodes
    /// to `.error` (never failing). Absent on older builds -> `nil` here, which
    /// the SDK treats as STATIC caller-side.
    public let reason: EvaluationReason?
    /// Present only for TARGETING_MATCH / SPLIT (eval_context.go emits indexes
    /// only for those reason classes); otherwise omitted.
    public let ruleIndex: Int?
    /// Present only for SPLIT; otherwise omitted.
    public let weightedValueIndex: Int?

    enum CodingKeys: String, CodingKey {
        case value, configId, configType, valueType
        case reason, ruleIndex, weightedValueIndex
    }

    public init(
        value: WireValue,
        configId: String,
        configType: String,
        valueType: String,
        reason: EvaluationReason?,
        ruleIndex: Int?,
        weightedValueIndex: Int?
    ) {
        self.value = value
        self.configId = configId
        self.configType = configType
        self.valueType = valueType
        self.reason = reason
        self.ruleIndex = ruleIndex
        self.weightedValueIndex = weightedValueIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(WireValue.self, forKey: .value)
        configId = try c.decode(String.self, forKey: .configId)
        configType = try c.decode(String.self, forKey: .configType)
        valueType = try c.decode(String.self, forKey: .valueType)
        // Every optional uses decodeIfPresent (§2.10).
        reason = try c.decodeIfPresent(EvaluationReason.self, forKey: .reason)
        ruleIndex = try c.decodeIfPresent(Int.self, forKey: .ruleIndex)
        weightedValueIndex = try c.decodeIfPresent(Int.self, forKey: .weightedValueIndex)
    }

    /// Encodable for the persistence cache (qfg-2t2d.5). Optionals use
    /// `encodeIfPresent` so a re-decode of the cache file sees the same
    /// omitempty shape as the wire (absent, not null).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(configId, forKey: .configId)
        try c.encode(configType, forKey: .configType)
        try c.encode(valueType, forKey: .valueType)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(ruleIndex, forKey: .ruleIndex)
        try c.encodeIfPresent(weightedValueIndex, forKey: .weightedValueIndex)
    }
}

/// Response metadata. Mirrors `api-delivery/internal/config/types.go` `Meta`.
///
/// `ServeHTTP` builds `Meta` with only `Version` + `Environment` for the
/// frontend eval path, so `workspaceId` (`omitempty`) is absent on the wire —
/// decoded-if-present so a future build that includes it is handled gracefully.
public struct EvalMeta: Sendable, Equatable, Codable {
    public let version: String
    public let environment: String
    public let workspaceId: String?
    /// Monotonic per-branch commit counter (`git rev-list --count HEAD`) the
    /// backend stamps on every eval response (`eval_context.go`). Unlike
    /// `version` — a commit SHA, which is unordered — a higher `generation` is
    /// strictly newer, so the reject-older install guard (spec 5f) can order two
    /// snapshots and refuse to regress an established client.
    ///
    /// Absent or `<= 0` means "unversioned" — a server that predates the
    /// watermark — and `decodeIfPresent` defaults it to 0, so the guard's
    /// carve-out installs it rather than freezing. Both delivery legs emit the
    /// honest true commit count (spec 5f.1, the 2026-06-29 A2 fix): a lagging
    /// secondary's generation is equal-or-lower, which the strict-greater check
    /// no-ops or rejects for an established client.
    public let generation: Int

    enum CodingKeys: String, CodingKey {
        case version, environment, workspaceId, generation
    }

    public init(
        version: String, environment: String, workspaceId: String? = nil, generation: Int = 0
    ) {
        self.version = version
        self.environment = environment
        self.workspaceId = workspaceId
        self.generation = generation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        environment = try c.decode(String.self, forKey: .environment)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        // Absent on a pre-watermark server (and in old persisted cache records) —
        // default to 0 so the guard's gen<=0 carve-out installs it.
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
    }

    /// Encodable for the persistence cache (qfg-2t2d.5).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(environment, forKey: .environment)
        try c.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try c.encode(generation, forKey: .generation)
    }
}

/// The full `eval-with-context` response envelope.
///
/// Mirrors `api-delivery/internal/config/types.go` `EvalEnvelope` and
/// `sdk-javascript/src/types.ts` `EvaluationPayload`:
///   `{ evaluations: { <key>: Evaluation }, meta: EvalMeta }`.
public struct EvalEnvelope: Sendable, Equatable, Codable {
    public let evaluations: [String: Evaluation]
    public let meta: EvalMeta

    enum CodingKeys: String, CodingKey {
        case evaluations, meta
    }

    public init(evaluations: [String: Evaluation], meta: EvalMeta) {
        self.evaluations = evaluations
        self.meta = meta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        evaluations = try c.decode([String: Evaluation].self, forKey: .evaluations)
        meta = try c.decode(EvalMeta.self, forKey: .meta)
    }

    /// Encodable for the persistence cache (qfg-2t2d.5).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(evaluations, forKey: .evaluations)
        try c.encode(meta, forKey: .meta)
    }
}

/// A minimal JSON value graph used to carry the polymorphic `value.value` field
/// without committing to a concrete type at decode time.
///
/// The wire `value` is one of: bool, int (as a JSON number), double, string,
/// native JSON (object/array/etc.), or string list. We preserve it losslessly so
/// the typed accessors in `Quonfig` (qfg-2t2d.6+) can coerce on read. Integers
/// are distinguished from doubles so `int(...)` accessors are exact.
public enum QuonfigJSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([QuonfigJSONValue])
    case object([String: QuonfigJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        // Order matters: Bool must be probed before the numeric branches, since
        // Foundation will happily decode `true`/`false` as a number on some
        // platforms. Int before Double so whole numbers stay exact.
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let arr = try? c.decode([QuonfigJSONValue].self) {
            self = .array(arr)
        } else if let obj = try? c.decode([String: QuonfigJSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value")
        }
    }

    /// Encodable so the value graph round-trips through the persistence cache
    /// (qfg-2t2d.5). `int` encodes as a JSON integer (preserved exact) and
    /// `double` as a JSON number, mirroring the decode branch order.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let arr): try c.encode(arr)
        case .object(let obj): try c.encode(obj)
        }
    }

    /// Project the value graph back into a Foundation object graph
    /// (`NSNull`/`Bool`/`Int64`/`Double`/`String`/`[Any]`/`[String: Any]`) so the
    /// `json(_:) -> [String: Any]?` accessor can hand callers an idiomatic
    /// dictionary. `int` widens to `Int` where representable for ergonomics.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return Int(exactly: i) ?? i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.foundationValue }
        case .object(let obj): return obj.mapValues { $0.foundationValue }
        }
    }
}
