# Quonfig Swift SDK (`Quonfig`)

Native Apple-platform (iOS / macOS) SDK for [Quonfig](https://quonfig.com).

- SPM package: `quonfig-swift`
- Module / product: `Quonfig` (`import Quonfig`)
- Platforms: iOS 15+, macOS 12+
- Swift-only, Swift Concurrency throughout (`StrictConcurrency=complete`)

This is a **frontend** client: it fetches server-evaluated config for a
context, caches it, polls for updates, and posts evaluation telemetry. It does
not run a targeting engine — evaluation happens server-side in `api-delivery`
(same model as `sdk-javascript`). See `project/plans/sdk-ios.md`.

## Status

Early development (v0.0.x). The core value types are in place:

- `Configuration` — init options (domain, `apiURLs`/`telemetryURL` escape
  hatches, SDK key, poll interval, telemetry toggles, `URLSessionConfiguration`
  / timeouts, per-request `customHeaders` closure). No `process.env` at runtime.
- `QuonfigURLs` — derives `primary`/`secondary`/`telemetry` hosts from a domain;
  explicit URLs win.
- `QuonfigContext` — multi-namespace context, base64url path encoding (no `+`
  ever reaches the server path), and an injectable SHA256 fingerprint for cache
  keying.
- Auth: HTTP Basic with username `u` (`Authorization: Basic base64("u:" + key)`).
- `User-Agent: Quonfig-Swift/<version> (<platform> <os-version>)`.

## Build & test

```bash
swift build
swift test
```
