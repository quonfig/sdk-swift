# Releasing `sdk-swift` (the `Quonfig` Apple SDK)

This SDK is distributed via **Swift Package Manager** and is **tag-driven** —
there is no central package registry gate like npm. SPM resolves directly from a
git tag, so tagging *is* the release.

> The SDK is on its own `0.0.x` line (it graduates to `1.0.0` at feature parity
> with the other Quonfig SDKs — see `Sources/Quonfig/Version.swift`). It still
> follows semver: patch for fixes, minor for backward-compatible features, major
> for breaking public-API changes. A breaking change to the public API needs
> human sign-off (see `.claude/rules/constitution.md`).

## The single source of truth for the version

The version lives in **two places that must agree** before a tag:

1. `Sources/Quonfig/Version.swift` — `quonfigVersion` (used in the `User-Agent`).
2. The git tag itself — `vX.Y.Z`.

The release workflow (`.github/workflows/release.yaml`) **fails the release** if
the tag does not match `quonfigVersion`, so a mismatch can never ship.

## SPM release — tag and you're done

SPM has no build/publish step. The tag *is* the release. Consumers add:

```swift
.package(url: "https://github.com/quonfig/sdk-swift.git", from: "0.0.1")
```

and SPM resolves the matching tag (with or without the `v` prefix). So the entire
release is:

1. Bump `quonfigVersion` in `Sources/Quonfig/Version.swift` to the new `X.Y.Z`.
2. Run the full local gate (mirrors CI):
   ```bash
   swift format lint --strict --recursive --configuration .swift-format \
     Sources Tests test-swift/Sources
   swift build
   swift test
   swift test --sanitize=thread
   ```
3. Commit on `main`.
4. Tag and push the tag:
   ```bash
   git tag vX.Y.Z
   git push origin main
   git push origin vX.Y.Z
   ```
5. The `release.yaml` workflow fires on the `v*` tag, re-verifies the version
   matches, runs the build/test gate once more, and creates the GitHub Release.
   No artifact upload is needed — SPM consumers resolve straight from the tag.

That is the complete release.

## Privacy-manifest release check (do not skip)

`PrivacyInfo.xcprivacy` is an App Store gate. The distribution must actually ship
it (the "Statsig trap": the file exists in the repo but isn't wired into the
distribution, so consumers don't bundle it). It is wired via
`.process("Resources/PrivacyInfo.xcprivacy")` in `Package.swift`, and CI asserts
it lands in the built `quonfig-swift_Quonfig.bundle` (the "Verify
PrivacyInfo.xcprivacy is bundled" step in `release.yaml` / `ci.yaml`).

Verify locally before tagging:

```bash
swift build
find .build -path '*quonfig-swift_Quonfig.bundle/PrivacyInfo.xcprivacy'
```

## Why tag-driven (and not npm-style)

Swift Package Manager resolves directly from git tags (plan §4.6), so there is
nothing to publish to a registry — this matches `sdk-go` (Go modules resolve from
tags) and `sdk-java` (tag-triggered publish) rather than the npm-gated
`sdk-node`/`cli` flow.
