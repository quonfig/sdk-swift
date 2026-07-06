# Quonfig Swift SDK (`Quonfig`)

Native Apple-platform (iOS / macOS) SDK for [Quonfig](https://quonfig.com).

- SPM package: `quonfig-swift`
- Module / product: `Quonfig` (`import Quonfig`)
- Platforms: iOS 15+, macOS 12+
- Swift-only, Swift Concurrency throughout (`StrictConcurrency=complete`)

This is a **frontend** client: it fetches server-evaluated config for a
context, caches it, polls for updates, and posts evaluation telemetry. It does
**not** run a targeting engine — evaluation happens server-side in `api-delivery`
(same model as `sdk-javascript`). See `project/plans/sdk-ios.md`.

## Install

Distributed via **Swift Package Manager**. In Xcode: **File → Add Package
Dependencies…** and enter the repo URL, or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/quonfig/sdk-swift.git", from: "0.0.1"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "Quonfig", package: "sdk-swift"),
        ]
    ),
]
```

Then `import Quonfig`.

## Quickstart

The public API (mirrors `project/plans/sdk-ios.md` §2.4):

```swift
import Quonfig

let quonfig = try await Quonfig.initialize(
    context: QuonfigContext([
        "user": ["key": .string("u_123"), "email": .string("a@b.com")],
    ]),
    options: .init(
        sdkKey: "qf_ck_production_…",     // client/frontend key (see note below)
        domain: "quonfig.com"             // or .apiURLs(...) escape hatch
    )
)

// Synchronous, never-blocking reads (served from the in-memory store):
let on    = quonfig.isEnabled("new-checkout")                 // Bool
let color = quonfig.string("button-color", default: "blue")   // String
let limit = quonfig.int("rate-limit", default: 100)           // Int
let cfg   = quonfig.json("pricing")                           // [String: Any]?
let detail = quonfig.details("new-checkout")                  // value + reason + variant

// React to live updates (SwiftUI-friendly — diff-before-notify, so unchanged
// polls don't churn). Hold the returned token; dropping it unsubscribes.
let token = await quonfig.subscribe { /* re-read flags */ }

// Identity change -> refetch the evaluated envelope for the new context.
try await quonfig.updateContext(
    QuonfigContext(["user": ["key": .string("u_456")]])
)
```

Notes:

- `initialize` is `async throws` and **resolves once the first envelope is
  available** — from the network, or, after a bounded `initTimeout` (default 5s),
  from the cold-start cache / empty defaults (the LaunchDarkly `startWaitSeconds`
  pattern). A hung network never hangs your UI.
- Reads are **synchronous and never block** — they serve from an in-memory
  snapshot. An absent key (or a not-yet-ready store) returns the caller-supplied
  default.
- The SDK **polls** (default 60s foreground) with `ETag`/`If-None-Match` so an
  unchanged flag set is a cheap `304`. It refetches immediately on app foreground
  and on `updateContext`, and suspends polling in the background.
- Use the **client/frontend SDK key** (the same key type the JavaScript/React
  SDKs use) — a mobile binary is extractable, so never embed a backend key.

### Exposure-decoupled reads

Every getter has a `logExposure:` variant so debug screens / pre-render probes
can read a flag without it counting as an exposure for telemetry:

```swift
let v = quonfig.isEnabled("new-checkout", logExposure: false)
```

## Logging (`QuonfigLogger`)

Drive a logger's minimum level from a Quonfig `log_level` config, so you can
raise or lower verbosity from the dashboard **without a redeploy** — the SDK's
native equivalent of `sdk-go`'s `NewQuonfigHandler` and `@quonfig/node/winston`.
It's built on Apple's unified logging (`os.Logger`) with **no external
dependencies**.

```swift
import Quonfig

let log = QuonfigLogger(quonfig: quonfig, loggerKey: "log-level.my-app")

log.trace("entering render")                 // suppressed unless level <= TRACE
log.debug("cache warm: \(count) entries")    // suppressed unless level <= DEBUG
log.info("signed in as \(userID)")
log.warn("retrying after \(err)")
log.error("checkout failed: \(err)")
```

The severity ladder is `TRACE < DEBUG < INFO < WARN < ERROR < FATAL` (the same
ranks every Quonfig SDK uses). A record emits iff its level is **at or above** the
configured threshold — e.g. a `log_level` config of `WARN` emits `WARN`/`ERROR`/
`FATAL` and drops `TRACE`/`DEBUG`/`INFO`. The gate is re-checked on every call, so
flipping the level live takes effect on the next log line. If no `log_level`
config resolves, the gate is permissive (logs everything). Message arguments are
autoclosures, so a suppressed record never builds its string.

Need just the decision (e.g. to gate your own logging framework)?

```swift
if quonfig.shouldLog(.debug, loggerKey: "log-level.my-app") { /* … */ }
```

**Custom sink.** By default records go to `os.Logger`. Supply a `QuonfigLogSink`
to bridge to another backend (or to capture records in a test):

```swift
struct MySink: QuonfigLogSink {
    func emit(level: QuonfigLogLevel, message: String) { /* forward anywhere */ }
}
let log = QuonfigLogger(quonfig: quonfig, loggerKey: "log-level.my-app", sink: MySink())
```

> **Frontend note.** Quonfig evaluates server-side, so this client gates against
> the single threshold the server resolved for its current context. Per-logger
> overrides (the backend SDKs' per-`quonfig-sdk-logging.key` routing) require
> on-device evaluation and are not available in a frontend SDK — one `log_level`
> config drives one threshold for the whole client.

## Known limitation: offline + context changes (server-side evaluation)

Quonfig evaluates **100% server-side** — the device sends a context and the
server returns the evaluated values. The SDK caches the evaluated envelope
**keyed by a fingerprint of the context**, so:

- **Cold start / offline for a previously-seen context** works: the cached
  envelope is served instantly (no flicker), and is also served **on error** so
  a failed poll keeps the last known-good values on screen.
- **Offline with a *new* context** cannot be evaluated locally — there is no
  targeting engine on-device. The SDK can only serve the cached envelope for a
  previously-seen context, or fall back to your caller-supplied defaults.

This is the same trade-off LaunchDarkly and Statsig make; it is called out
explicitly here because Quonfig's evaluation is entirely server-side.

## Privacy manifest

The SDK ships an App Store `PrivacyInfo.xcprivacy` (required since 2024-05-01),
wired into `Package.swift` `resources:` so it lands in `Bundle.module` for SPM
consumers (the trap is shipping the file but not bundling it). It declares:

- `NSPrivacyTracking = false`, empty `NSPrivacyTrackingDomains` (we do not track
  across apps; an empty domains array is the correct declaration — a populated
  one breaks network calls for ATT-declined users).
- `NSPrivacyCollectedDataTypes` for **User ID** and **Device ID** (linked, not
  tracking, app-functionality) — the context you supply is sent to `api-delivery`
  on the eval request itself.
- `NSPrivacyAccessedAPICategoryUserDefaults` reason **`CA92.1`** — UserDefaults
  backs the no-flicker cache. `FileTimestamp` (`C617.1`) is intentionally **not**
  declared: the file cache tracks recency via a `savedAt` value written at save
  time, never by reading `contentModificationDate`/`stat`.

The eval request's `URLCache` is disabled (`urlCache = nil`) so the
context-bearing eval URL is never written to an on-device URL cache.

## test-swift validation app

`test-swift/` is the smoke / validation app (mirrors the other SDKs' `test-*`
pattern). It drives the full public surface — `initialize` → getters →
`subscribe` → `updateContext` — against either:

- a **live** `api-delivery` (set `QUONFIG_SDK_KEY`, optional `QUONFIG_DOMAIN`), or
- a built-in **in-process fixture server** (default) that flips a flag each poll
  so the demo shows poll-driven updates with no external server.

```bash
cd test-swift
swift run TestSwiftApp          # fixture mode (default)
QUONFIG_SDK_KEY=qf_ck_… swift run TestSwiftApp   # live mode
```

The package also contains `FlagListView` (SwiftUI) for hosting in an iOS/macOS
app target; the executable's headless demo is the CI-runnable equivalent.

## Build & test

```bash
swift build
swift test
```
