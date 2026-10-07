# Changelog

All notable changes to the Quonfig Swift SDK. The version lives in
`Sources/Quonfig/Version.swift`; a `vX.Y.Z` tag is the release (see
`RELEASING.md`).

## Unreleased

Semver: none (CI and test-only; no published artifact changes, no release needed).

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
