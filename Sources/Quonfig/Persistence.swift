import Foundation

/// The no-flicker persistence layer (plan §2.7, §2.10).
///
/// On every successful fetch / `updateContext`, the resolved envelope is written
/// to a cache keyed by `(envKey, contextFingerprint)`. On `initialize`, the
/// cached envelope for the current context is loaded **synchronously** and served
/// immediately while the network fetch runs — this kills the "all defaults for
/// 200ms then real values" flicker that plagues naive clients. The cache is also
/// served **on error** (not just cold start), so a failed poll keeps the last
/// known-good values on screen rather than reverting to defaults.
///
/// ## Storage strategy (Statsig `enableCacheByFile`, #32/#34/#39)
/// Both reference SDKs persist last-known flags; Statsig's cautionary tale is
/// shipping a UserDefaults-only store, hitting the 4MB-ish practical ceiling, and
/// then having to migrate to file storage mid-flight. We do both from day one:
///   - Small index/metadata + small envelopes live in our **own UserDefaults
///     suite** (`com.quonfig.sdk`), never `UserDefaults.standard` (#32/#34/#39).
///   - Large envelopes spill to our **own file** under Application Support, so a
///     500-flag workspace doesn't bloat UserDefaults.
/// We **never** use `URLCache` for persistence — Flagsmith iterated on a
/// URLCache-backed store three times and it stayed buggy. The eval URL's
/// `URLCache` is independently disabled in `Configuration` (§2.3).
///
/// ## Versioned on-disk schema + migration (LD `CacheConverter`)
/// Every record carries a `schemaVersion`. A `CacheMigrator` runs on load: a
/// record from an older (known) version is migrated forward; a record from an
/// unknown/incompatible version is discarded (treated as a cold start) rather
/// than mis-decoded. Statsig is visibly mid-migration *because* they didn't
/// version from day one — we do.
///
/// ## Bounded + evict-oldest (Statsig `MaxCachedUserObjects = 10`)
/// The cache is capped at `maxCachedContexts` distinct `(envKey, fingerprint)`
/// keys; the least-recently-written entry is evicted when the cap is exceeded, so
/// an identity-switching app can't grow the cache unbounded.
public final class Persistence: @unchecked Sendable {
    /// Current on-disk schema version. Bump this whenever the persisted record
    /// shape changes, and add a migration step to `CacheMigrator`.
    public static let currentSchemaVersion = 1

    /// The dedicated UserDefaults suite name. NEVER `UserDefaults.standard`
    /// (Statsig #32/#34/#39) — a shared suite leaks our keys into the host app's
    /// defaults and risks collisions.
    public static let suiteName = "com.quonfig.sdk"

    /// Statsig's `MaxCachedUserObjects`. Bounds the number of distinct contexts
    /// we retain so identity-switching apps don't grow the cache unbounded.
    public static let defaultMaxCachedContexts = 10

    /// Payloads at or under this many bytes live inline in UserDefaults; larger
    /// ones spill to a file (Statsig `enableCacheByFile`). 16KB is comfortably
    /// under the practical UserDefaults ceiling while covering small workspaces.
    static let inlineByteThreshold = 16 * 1024

    private let store: PersistenceStore
    private let maxCachedContexts: Int
    private let lock = NSLock()

    /// Designated initializer. `store` is injectable so tests can use an
    /// in-memory backing instead of touching the real UserDefaults/filesystem.
    init(store: PersistenceStore, maxCachedContexts: Int = Persistence.defaultMaxCachedContexts) {
        self.store = store
        self.maxCachedContexts = max(1, maxCachedContexts)
    }

    /// Production initializer: own UserDefaults suite + own file directory under
    /// Application Support (`<AppSupport>/com.quonfig.sdk/cache`). Falls back to a
    /// temp directory if Application Support is unavailable (sandbox edge cases).
    public convenience init(maxCachedContexts: Int = Persistence.defaultMaxCachedContexts) {
        // `UserDefaults(suiteName:)` only returns nil if the name is the app's
        // bundle id or "Global" — neither is our constant `com.quonfig.sdk`, so
        // this is always non-nil in practice. We deliberately do NOT fall back to
        // `UserDefaults.standard` (the bead's hard rule): a nil here means we got
        // a pathological suite name, in which case persistence is disabled by
        // routing through an in-memory store rather than polluting the host app's
        // standard defaults.
        let store: PersistenceStore
        if let defaults = UserDefaults(suiteName: Persistence.suiteName) {
            store = DefaultsAndFileStore(
                defaults: defaults, directory: Persistence.defaultFileDirectory())
        } else {
            store = InMemoryFallbackStore()
        }
        self.init(store: store, maxCachedContexts: maxCachedContexts)
    }

    static func defaultFileDirectory() -> URL {
        let fm = FileManager.default
        let base =
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent(suiteName, isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
    }

    // MARK: - Cache key

    /// The cache key for a context within an environment. `envKey` distinguishes
    /// the SDK key / environment so two clients in the same process don't collide;
    /// `fingerprint` is the SHA256-of-context (LD's `fingerprint-<key>` pattern).
    static func cacheKey(envKey: String, fingerprint: String) -> String {
        "\(envKey)::\(fingerprint)"
    }

    // MARK: - Write

    /// Persist a resolved envelope for `(envKey, context)`. Updates the
    /// last-written recency and evicts the oldest entry past the cap. Never
    /// throws — a persistence failure must not break a successful fetch (we log
    /// nothing here; the caller's network result already succeeded).
    public func save(envelope: EvalEnvelope, envKey: String, fingerprint: String) {
        lock.lock()
        defer { lock.unlock() }

        let key = Persistence.cacheKey(envKey: envKey, fingerprint: fingerprint)
        let record = PersistedCacheRecord(
            schemaVersion: Persistence.currentSchemaVersion,
            envKey: envKey,
            fingerprint: fingerprint,
            savedAt: Date().timeIntervalSince1970,
            envelope: envelope
        )

        guard let data = try? JSONEncoder().encode(record) else { return }

        // Pick inline (UserDefaults) vs file based on size (Statsig
        // enableCacheByFile): large payloads must not bloat UserDefaults.
        let inline = data.count <= Persistence.inlineByteThreshold
        store.write(key: key, data: data, inline: inline)

        var index = loadIndexLocked()
        index.touch(key: key, inline: inline, savedAt: record.savedAt)
        // Evict oldest beyond the cap (Statsig MaxCachedUserObjects).
        for evicted in index.evictOldest(keepingAtMost: maxCachedContexts) {
            store.remove(key: evicted.key, inline: evicted.inline)
        }
        saveIndexLocked(index)
    }

    // MARK: - Read

    /// Synchronously load the cached envelope for `(envKey, context)`, or `nil` if
    /// there is no (migratable) entry. This is the cold-start / serve-on-error
    /// read — it must be synchronous so `initialize` can serve last-known values
    /// before the first network round-trip returns (plan §2.7).
    public func load(envKey: String, fingerprint: String) -> EvalEnvelope? {
        lock.lock()
        defer { lock.unlock() }

        let key = Persistence.cacheKey(envKey: envKey, fingerprint: fingerprint)
        var index = loadIndexLocked()
        guard let entry = index.entries[key] else { return nil }

        guard let data = store.read(key: key, inline: entry.inline) else {
            // Index/storage drift — drop the dangling index entry.
            index.remove(key: key)
            saveIndexLocked(index)
            return nil
        }

        guard let record = decodeRecord(data) else {
            // Unknown/incompatible schema or corruption: discard, treat as cold
            // start (never mis-decode a future format — LD CacheConverter intent).
            store.remove(key: key, inline: entry.inline)
            index.remove(key: key)
            saveIndexLocked(index)
            return nil
        }
        return record.envelope
    }

    /// Decode a persisted record, running schema migration. Returns `nil` for an
    /// unknown/unmigratable version or corrupt data.
    func decodeRecord(_ data: Data) -> PersistedCacheRecord? {
        let decoder = JSONDecoder()
        // First peek the schemaVersion alone so a future shape that no longer
        // decodes as the current record still tells us its version.
        guard let probe = try? decoder.decode(SchemaProbe.self, from: data) else {
            return nil
        }
        return CacheMigrator.migrate(data: data, fromVersion: probe.schemaVersion)
    }

    // MARK: - Maintenance

    /// Drop everything (test/debug hook; also used on a hard schema reset).
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        let index = loadIndexLocked()
        for (key, entry) in index.entries {
            store.remove(key: key, inline: entry.inline)
        }
        store.removeIndex()
    }

    /// Number of distinct cached contexts (test hook).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadIndexLocked().entries.count
    }

    // MARK: - Index (locked helpers; caller holds `lock`)

    private func loadIndexLocked() -> CacheIndex {
        guard let data = store.readIndex(),
            let index = try? JSONDecoder().decode(CacheIndex.self, from: data)
        else {
            return CacheIndex()
        }
        return index
    }

    private func saveIndexLocked(_ index: CacheIndex) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        store.writeIndex(data)
    }
}

/// The versioned on-disk record. `schemaVersion` is FIRST-class so a migrator can
/// always read it even if the rest of the shape changed.
struct PersistedCacheRecord: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let envKey: String
    let fingerprint: String
    let savedAt: TimeInterval
    let envelope: EvalEnvelope
}

/// Minimal probe to read only the schema version from an unknown record.
private struct SchemaProbe: Decodable {
    let schemaVersion: Int
}

/// LD-`CacheConverter`-style migration. Each known older version migrates forward
/// to the current shape; an unknown version returns `nil` (cold start).
enum CacheMigrator {
    static func migrate(data: Data, fromVersion version: Int) -> PersistedCacheRecord? {
        switch version {
        case Persistence.currentSchemaVersion:
            // Current shape — decode directly.
            return try? JSONDecoder().decode(PersistedCacheRecord.self, from: data)
        // Future: case 1: migrate v1 -> v2 here, etc. Add a step per bump.
        default:
            // Unknown / incompatible version: discard rather than mis-decode.
            return nil
        }
    }
}

/// Recency index over cache keys, persisted alongside the records. Tracks where
/// each entry lives (inline vs file) and when it was written, so eviction can
/// drop the oldest and reads know which backing to hit.
struct CacheIndex: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var inline: Bool
        var savedAt: TimeInterval
    }
    var entries: [String: Entry] = [:]

    mutating func touch(key: String, inline: Bool, savedAt: TimeInterval) {
        entries[key] = Entry(inline: inline, savedAt: savedAt)
    }

    mutating func remove(key: String) {
        entries[key] = nil
    }

    /// Evict the oldest entries until at most `keepingAtMost` remain. Returns the
    /// evicted keys + their backing so the caller can delete the data.
    mutating func evictOldest(keepingAtMost limit: Int) -> [(key: String, inline: Bool)] {
        guard entries.count > limit else { return [] }
        let sorted = entries.sorted { $0.value.savedAt < $1.value.savedAt }
        let toEvict = sorted.prefix(entries.count - limit)
        var evicted: [(key: String, inline: Bool)] = []
        for (key, entry) in toEvict {
            evicted.append((key: key, inline: entry.inline))
            entries[key] = nil
        }
        return evicted
    }
}

/// The storage backing abstraction. Injectable so tests don't touch real
/// UserDefaults / filesystem. `inline == true` means "small, lives in
/// UserDefaults"; `inline == false` means "large, lives in a file".
protocol PersistenceStore: Sendable {
    func write(key: String, data: Data, inline: Bool)
    func read(key: String, inline: Bool) -> Data?
    func remove(key: String, inline: Bool)
    func writeIndex(_ data: Data)
    func readIndex() -> Data?
    func removeIndex()
}

/// Production store: small payloads in our own UserDefaults suite, large payloads
/// in our own files under Application Support. NEVER `UserDefaults.standard`,
/// NEVER `URLCache`.
final class DefaultsAndFileStore: PersistenceStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let directory: URL
    private let indexKey = "quonfig.cache.index.v1"
    private let fm = FileManager.default

    init(defaults: UserDefaults, directory: URL) {
        self.defaults = defaults
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Defaults keys are namespaced so they can't collide with the host app.
    private func defaultsKey(_ key: String) -> String { "quonfig.cache.entry.\(key)" }

    /// File names are SHA256-derived so an arbitrary fingerprint string is always
    /// a safe filename (no path separators leaking out of the cache dir).
    private func fileURL(_ key: String) -> URL {
        let safe = sha256Hex(key)
        return directory.appendingPathComponent("\(safe).json")
    }

    func write(key: String, data: Data, inline: Bool) {
        if inline {
            defaults.set(data, forKey: defaultsKey(key))
            // Ensure a stale large-file copy from a prior save is removed.
            try? fm.removeItem(at: fileURL(key))
        } else {
            // exclude from iCloud/iTunes backup is a privacy/footprint nicety;
            // write atomically so a crash mid-write can't corrupt the entry.
            try? data.write(to: fileURL(key), options: [.atomic])
            defaults.removeObject(forKey: defaultsKey(key))
        }
    }

    func read(key: String, inline: Bool) -> Data? {
        if inline {
            return defaults.data(forKey: defaultsKey(key))
        } else {
            return try? Data(contentsOf: fileURL(key))
        }
    }

    func remove(key: String, inline: Bool) {
        if inline {
            defaults.removeObject(forKey: defaultsKey(key))
        } else {
            try? fm.removeItem(at: fileURL(key))
        }
    }

    func writeIndex(_ data: Data) {
        defaults.set(data, forKey: indexKey)
    }

    func readIndex() -> Data? {
        defaults.data(forKey: indexKey)
    }

    func removeIndex() {
        defaults.removeObject(forKey: indexKey)
    }
}

/// Last-resort in-memory store used only if the dedicated UserDefaults suite
/// cannot be created (pathological suite name). Chosen over
/// `UserDefaults.standard` so we NEVER pollute the host app's standard defaults
/// (the bead's hard rule). Persistence is effectively disabled in this state —
/// no cross-launch survival — but reads/writes within a session still work.
final class InMemoryFallbackStore: PersistenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var inlineData: [String: Data] = [:]
    private var fileData: [String: Data] = [:]
    private var index: Data?

    func write(key: String, data: Data, inline: Bool) {
        lock.lock(); defer { lock.unlock() }
        if inline { inlineData[key] = data; fileData[key] = nil } else { fileData[key] = data; inlineData[key] = nil }
    }
    func read(key: String, inline: Bool) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return inline ? inlineData[key] : fileData[key]
    }
    func remove(key: String, inline: Bool) {
        lock.lock(); defer { lock.unlock() }
        if inline { inlineData[key] = nil } else { fileData[key] = nil }
    }
    func writeIndex(_ data: Data) { lock.lock(); index = data; lock.unlock() }
    func readIndex() -> Data? { lock.lock(); defer { lock.unlock() }; return index }
    func removeIndex() { lock.lock(); index = nil; lock.unlock() }
}
