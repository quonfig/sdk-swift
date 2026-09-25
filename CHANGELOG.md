# Changelog

All notable changes to the Quonfig Swift SDK. The version lives in
`Sources/Quonfig/Version.swift`; a `vX.Y.Z` tag is the release (see
`RELEASING.md`).

## Unreleased

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
