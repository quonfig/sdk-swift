# Changelog

All notable changes to the Quonfig Swift SDK. The version lives in
`Sources/Quonfig/Version.swift`; a `vX.Y.Z` tag is the release (see
`RELEASING.md`).

## 0.5.0 - 2026-10-21

`initialize` now fails by default when there is no config at all
(qfg-9p4i.11, minor). New `onInitFailure: .fail | .wait | .continue`, a
`source` property and `waitForReady()`. See the upgrade note below.

> **UPGRADE (minor, pre-1.0 behavior change):** an app with no cached copy and
> Quonfig delivery unreachable now gets an error from `initialize()` instead of
> a client serving code defaults. A cached copy on disk still counts as config,
> so returning users start on it as before. To keep the old behavior, pass
> `onInitFailure: .continue`. Under `.continue` with no cache, `isReady` is now
> `false` (and `source` is `.defaults`) until a config lands; before, an empty
> envelope was installed and `isReady` was `true`. `QuonfigInitError` gains the
> cases `.timeout`, `.unavailable` and `.unauthorized`, so an exhaustive
> `switch` over it needs updating.

### Changed

- **The default startup-failure mode is `.fail` (qfg-9p4i.11).** When
  `initTimeout` (default 5s) passes with no network config and no cached copy,
  `initialize` throws `QuonfigInitError.timeout` (the last attempt hung: no
  API URL in it failed fast, or none completed) or `.unavailable` (the last
  attempt failed fast on at least one URL). A rejected SDK key
  (401/403/404/410 from EVERY API URL) throws `.unauthorized` at once instead
  of waiting out the timeout; a rejection from the primary alone is an
  ordinary failed attempt (qfg-9p4i.17.8). No client is returned, so no poll
  loop or telemetry keeps running.
- **Each fetch is a hedged primary+secondary request (qfg-9p4i.17.8).** The
  secondary fires 2s after the primary (at once if the primary fails fast),
  the first 2xx/304 wins and the other leg is cancelled. A hung primary used
  to hold the sequential failover for the 10s request timeout, past the 5s
  `initTimeout`, so a first launch with no cache threw while the secondary
  was healthy.
- **`initTimeout <= 0` (or NaN) runs exactly one attempt** and then applies
  `onInitFailure` (qfg-9p4i.17.8). It used to decide at once, before any
  attempt.
- **The loader's `allURLsFailed` message strips URL userinfo** (`user:pass@`).
- **`initialize` retries before the timeout.** It retries the first fetch with
  jittered backoff (0.5s, 1s, 2s, ... capped at 30s) instead of making one
  attempt.
- **`.continue` with a cached copy returns at once** on the cache and confirms
  it with one background fetch; the poll loop keeps retrying.
- **`waitForReady()` is cancellation-safe.** Cancelling the waiting task
  returns it promptly (with `isReady` still `false`) and removes its queued
  callback; it used to hang until a config arrived.
- **`shutdown()` cancels init work still in flight** (an init attempt pending
  when `initialize` returned, and the `.continue`-with-cache confirm fetch), so
  it cannot land a config or write the disk cache after shutdown.

### Added

- `onInitFailure:` on `Quonfig.initialize` with `.fail` (default), `.wait`
  (keep waiting with no upper bound) and `.continue` (start on code defaults;
  alias `.continueWithDefaults`). In every mode a cached copy counts as config:
  at the timeout the client starts on it.
- `Quonfig.source` (`.network`, `.cache`, `.defaults`) and
  `Quonfig.waitForReady()`.
- Startup logging per the cross-SDK contract, prefixed `[quonfig]`: DEBUG at
  init start, WARN on the first failed attempt and every 5s of waiting, ERROR
  when `.fail` raises, WARN when `.wait` keeps blocking or `.continue` starts
  on cache or defaults, a WARN every 30s (every 5 minutes after the first 5)
  while a degraded client still cannot connect, and one INFO when it recovers.
  Lines name the API hosts and a short error class per leg
  (`primary=<host:port>: URLError -1009`), never the SDK key or the
  context-carrying request URL.

## 0.4.0 - 2026-10-16

`initialize()` now honors `initTimeout` when the first fetch hangs
(qfg-goi1.2.33); one malformed evaluation no longer drops the whole envelope
(qfg-goi1.2.26); a rejected SDK key slows polling and logs one ERROR
(qfg-goi1.10.30); a foreground catch-up can no longer restart polling after
`shutdown()` or a return to the background (qfg-goi1.10.13). See the upgrade
note below.

> **UPGRADE (minor):** retry cadence and log levels change after a rejected
> 401/403/404/410 fetch cycle; a revoked key logs one config ERROR. Polling
> slows to one retry every max(150-300s, `pollInterval`) until a fetch is
> accepted, instead of retrying silently every `pollInterval`.

### Changed

- **A rejected SDK key slows polling and logs one ERROR (qfg-goi1.10.30,
  minor).** Before, a revoked or wrong key kept polling every `pollInterval`
  (60s by default) forever and logged nothing. Now a poll cycle in which the
  primary API URL answers 401, 403, 404 or 410 and no URL answers 200 or 304
  puts the SDK in an auth-failed state: one ERROR (`config fetch rejected: the
  SDK key is invalid or revoked (check the SDK key)`, with `status` and
  `host`, never the key), then one retry across every URL each max(T,
  `pollInterval`), T uniform in 150-300s and re-drawn each time, with no
  doubling and no give-up. Rejected retries log at DEBUG. The first 200 or 304
  on any URL (a secondary-only 200 counts) installs the envelope, logs one INFO
  and resumes polling at `pollInterval`. A later rejected cycle enters again.
  A primary 503 with a secondary 401 does not enter. The init fetch, the
  foreground catch-up and the `updateContext` refetch never enter; going to the
  background and back keeps the slow cadence. Failover now records each URL's
  HTTP status; the error `Loader.load()` throws is unchanged.

### Fixed

- **A foreground catch-up could restart polling after `shutdown()` or after
  the app went back to the background (qfg-goi1.10.13, patch).** The
  foreground handler fetched, then started the poll timer, with no check that
  it was still current. A background or `shutdown()` that happened while that
  catch-up fetch was in flight was undone when it landed, so the timer polled
  in the background or after shutdown. Each lifecycle event now carries an
  epoch: the timer is started or stopped only by the latest event of a started
  client.
- **One malformed evaluation rejected the whole envelope (qfg-goi1.2.26,
  minor).** An entry with a `null` value, a missing field or a non-object body
  failed the decode for every flag, so that fetch was dropped and the app kept
  stale or cached values (or got nothing at init). Entries now decode per key,
  like sdk-go and sdk-javascript: a bad entry resolves like an absent key
  (caller default, `details` reason `ERROR`) and the other flags still load.
- **`initTimeout` did not bound `initialize()` when the first fetch hung
  (qfg-goi1.2.33, minor).** The first fetch and the timeout were raced in a task
  group, which waits for every child, so a hung request held `initialize()` until
  URLSession gave up (60s or more) instead of resolving on defaults after
  `initTimeout` (default 5s) as documented. `initialize()` now returns at
  whichever comes first. The slow fetch keeps running and still applies when it
  lands, unless `updateContext` has switched away from its context.

## 0.3.0 - 2026-10-09

`updateContext` never serves or caches the previous user's values under a new
context (qfg-goi1.2.3); crash, timeout and macOS polling fixes (qfg-goi1.2.17).
The context-switch fix changes what getters return in the window between
`updateContext` and its refetch, and while offline after a switch; see the
upgrade note below. The value after a successful refetch is unchanged.

### Fixed

- **`updateContext` could serve and cache the previous user's values under the
  new user (qfg-goi1.2.3).** If a poll for the old context was in flight when
  `updateContext` ran, the old result was applied when it landed and saved to
  disk under the new context's cache key, and the refetch for the new context
  was dropped (it ran only at the next timer tick). Each fetch is now tagged
  with the context it was built for. A result for a context that is no longer
  current is discarded, neither served nor persisted, and the new context's
  refetch runs as soon as the old fetch lands. The init fetch goes through the
  same check.
- **Offline `updateContext` kept the previous user's values on screen.** The
  reject-older generation guard compared the new context's cached envelope with
  the previous context's generation and refused it when the cache was older.
  `updateContext` now resets the store for the new context. It serves that
  context's cached envelope unconditionally, or caller defaults when there is
  none, as the README's "Known limitation" section already describes. The
  generation guard now applies only within one context.
- **`int(...)` crashed on a whole double outside the `Int` range
  (qfg-goi1.2.17).** A `double` config of `1e20` read through `int(...)`, or an
  `int`-typed value that decoded as a double at or above 2^63 (read through any
  getter, including `isEnabled`), trapped with "Double value cannot be converted
  to Int". `int(...)` now returns your default, and an out-of-range `int` wire
  value is not coerced (`int(...)` returns the default, `isEnabled` false).
- **A NaN or infinite context attribute crashed `initialize` and
  `updateContext`.** `ContextValue.double(.nan)` (or an infinity) reached
  `JSONSerialization`, which raises an Objective-C exception Swift cannot catch.
  Non-finite doubles are now sent as JSON `null`, as sdk-javascript's
  `JSON.stringify` does, with a debug log naming the attribute.
- **Infinite intervals trapped.** `initTimeout: .infinity`, or an infinite
  `telemetryFlushInterval` / `telemetryTimeout`, overflowed the nanosecond
  conversion and crashed. They are now clamped to about 100 years, so they mean
  "wait as long as possible". The clamp stays well inside `Int64` because the
  macOS 15 concurrency runtime reads a sleep longer than `Int64.max`
  nanoseconds as negative and wakes at once.
- **macOS stopped polling whenever the app lost focus.** Resigning active was
  treated as entering the background, so the poll timer stopped (and telemetry
  flushed) every time another app became frontmost; menu-bar apps and windows
  behind others kept stale config for hours. macOS now polls continuously.
  Becoming active still fires a catch-up fetch, and `shutdown()` still flushes
  telemetry. iOS is unchanged.

### Changed

- **`updateContext` steps are serialized; the refetch is not.** Overlapping
  `updateContext` calls apply their context, loader and store switch one at a
  time, so the loader and the store always agree on the current context. The
  network refetch runs outside that critical section, so a second switch (a
  logout, say) takes effect at once instead of waiting behind the first
  switch's slow fetch.
- **Re-identifying the same context is a no-op for the store.** `updateContext`
  with a context whose fingerprint matches the current one keeps serving the
  current values while it refetches.
- **`Poller` (public actor) contract.** `Poller.updateContext()` now restarts
  the timer before it runs the refetch, and a follow-up fetch armed after the
  latest generation bump always runs; the poller no longer drops it when the
  generation changed while a fetch was in flight. `stop()` still drops any armed
  follow-up. The poller never judged fetch results; the client's fetch closure
  discards a result for a context that is no longer current.
- **The default session bounds every request (qfg-goi1.2.17).** It used
  URLSession's defaults (a 60s idle timeout and a 7-day resource timeout), so a
  primary that accepted the connection and never answered held each poll for
  60s before failover, and a slow-drip response held the poller's single
  in-flight fetch indefinitely. The default session now uses a 10s idle timeout
  (`requestTimeout`) and a 30s end-to-end timeout (`resourceTimeout`). The
  resource timeout also covers telemetry POSTs on the same session, so it stays
  above the 15s telemetry deadline. Pass `requestTimeout` / `resourceTimeout`,
  or your own `sessionConfiguration`, to change them.
- **`subscribe` warns when its token is discarded.** `@discardableResult` is
  removed. A discarded `SubscriptionToken` cancels the subscription at once, so
  `await quonfig.subscribe { ... }` compiled silently and the listener never
  fired. Such call sites now get a compiler warning (not an error); hold the
  token for as long as you want updates.

Upgrade note: switching to a context the device has never seen (for example the
first login of a new user on a device) now returns your caller-supplied defaults
until its refetch lands. Before, it returned the previous user's values in that
window. Subscribers and SwiftUI bindings therefore see two changes on such a
switch: previous values to defaults, then defaults to the new values. Before,
they saw one. The old `updateContext` doc comment's promise that the UI "doesn't
flicker defaults during the refetch" is removed. A previously-seen context
switches straight to its cached values, with no defaults in between.

### Internal

- CI now checks out `integration-test-data` at the pinned tag `v2026.10.03` as
  a sibling of `sdk-swift` in the SPM job, so the duration-grammar drift check
  (`DurationTests.testVendoredFixtureMatchesIntegrationTestData`) runs in CI
  instead of always skipping (qfg-goi1.1.8).
- Fixed the flaky `ConcurrencyStressTests.testConcurrentSubscribeCancelDuringApplies`
  (qfg-pmqy). `SubscriptionToken.cancel()` removes the subscriber through a
  fire-and-forget `Task` on the store actor, so the test read
  `subscriberCount` while the removals were still queued (`99 != 0` on the iOS
  Simulator job). The test now waits, with a 10 s limit, for the count to reach
  0. A real leak still fails it. Test-only change.

## 0.2.0

New getters (qfg-2agi.14), additive; telemetry summary cap default aligned to
10,000 (qfg-6bdw).

### Added

- **`duration(_:default:logExposure:)`** returns a `duration` config as a
  `TimeInterval` in seconds. The value must be inside Quonfig's ISO-8601
  duration grammar (`PT30S`, `PT1H30M`, `P1DT6H2M1.5S`; a fraction only on
  seconds, at most 9 digits, at most `P36500D`), and is converted with exact
  decimal arithmetic rounded half up to the millisecond. Absent, wrong type or
  malformed returns the default; a malformed value logs one warning per key
  (key only, never the raw value) and `details()` reports reason `.error` with a
  `nil` value. Tested against the shared grammar fixture
  `integration-test-data/tests/duration/grammar.yaml` (vendored under
  `Tests/QuonfigTests/Fixtures`, with a drift check against a sibling checkout).
- **`stringList(_:default:logExposure:)`** returns a `string_list` config as
  `[String]`, or the default.

### Changed

- A valid `duration` config now coerces to `.string(<ISO value>)` in
  `details().value` and `string()` (previously the raw value was carried as
  `.json(.string(...))` and `string()` returned the default).
- **`telemetryMaxEvaluationSummaries` now defaults to 10,000** (was 100,000),
  matching every other Quonfig SDK (policy P6 uniform cap, qfg-6bdw). A window
  holds at most 10,000 distinct counter keys; new keys past the cap are
  dropped. Pass a larger value to keep the old bound.

## 0.1.0

Telemetry transport policy, mobile subset (qfg-y8je.12). The wire format is
unchanged; the public API change is additive.

### Changed

- **Retries resend the exact bytes.** Each evaluation-summary window is
  serialized once and written to an on-disk queue (one file per batch) before
  it is POSTed, and deleted only after a `2xx`. A window in flight when the app
  is backgrounded is no longer lost, and a resend after a relaunch carries its
  original `instanceHash`, so the server's dedup token matches.
- **`401`/`403`/`404` stop telemetry for the process** with one ERROR and delete
  the queue, instead of retrying forever. Other `4xx` drop that batch with one
  ERROR. Network errors, timeouts, `408`, `429` and `5xx` are retried.
- **Resend schedule:** no sooner than 30s after a failure, and not before a
  `Retry-After` (honored up to 600s). One POST in flight at a time.
- **Disk queue capped** at 5 batches / 512KB (drop oldest; a batch over the byte
  cap is never retained) and 5 minutes of age, checked at send time. Was 50
  windows with no age limit.
- **Flush interval** is a fixed 60s (was an 8s-to-300s backoff).
- **Foreground POST timeout** is 15s end to end (was the 60s URLSession
  default).
- **Background flush** writes the live window to disk, then POSTs it once inside
  a ~5s background task (`ProcessInfo.performExpiringActivity`). The retained
  queue is not drained on background or `shutdown()`.
- The 0.0.1 single-file queue (`telemetry-queue.json`) is deleted on first
  launch; its windows are not resent.

### Added

- `Configuration` options: `telemetryFlushInterval`, `telemetryTimeout`,
  `telemetryMaxRetainedBatches`, `telemetryMaxRetainedBytes`,
  `telemetryMaxRetainedAge`, `telemetryMaxEvaluationSummaries`, and `logSink`
  (where SDK diagnostic lines go; default `os.Logger`, category `Telemetry`).
- `SummaryAggregator` defaults: `defaultFlushInterval`, `defaultTimeout`,
  `defaultMaxRetainedBatches`, `defaultMaxRetainedBytes`,
  `defaultMaxRetainedAge`, `backgroundFlushBudget`.
- Telemetry logging: a failed POST is DEBUG, the first dropped batch is one WARN
  (then at most one summary WARN per 10 min), recovery is one INFO.

### Deprecated

- `SummaryAggregator.defaultMaxQueuedWindows`: use `defaultMaxRetainedBatches`
  (now 5).

## 0.0.1

- Initial release.
