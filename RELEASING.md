# Releasing `sdk-swift` (the `Quonfig` Apple SDK)

This SDK is distributed two ways, both **tag-driven** — there is no central
package registry gate like npm. Swift Package Manager resolves directly from a
git tag; CocoaPods resolves from a podspec that points at the same tag.

> The SDK is on its own `0.0.x` line (it graduates to `1.0.0` at feature parity
> with the other Quonfig SDKs — see `Sources/Quonfig/Version.swift`). It still
> follows semver: patch for fixes, minor for backward-compatible features, major
> for breaking public-API changes. A breaking change to the public API needs
> human sign-off (see `.claude/rules/constitution.md`).

## The single source of truth for the version

The version lives in **three places that must agree** before a tag:

1. `Sources/Quonfig/Version.swift` — `quonfigVersion` (used in the `User-Agent`).
2. `Quonfig.podspec` — `s.version`.
3. The git tag itself — `vX.Y.Z`.

The release workflow (`.github/workflows/release.yaml`) **fails the release** if
the tag does not match `quonfigVersion` and the podspec version, so a mismatch
can never ship.

## SPM release (primary channel) — tag and you're done

SPM has no build/publish step. The tag *is* the release. Consumers add:

```swift
.package(url: "https://github.com/quonfig/sdk-swift.git", from: "0.0.1")
```

and SPM resolves the matching tag. So the entire SPM release is:

1. Bump `quonfigVersion` in `Sources/Quonfig/Version.swift` and `s.version` in
   `Quonfig.podspec` to the new `X.Y.Z` (same commit).
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

That is the complete SPM release. Everything below is CocoaPods, which is a
secondary channel.

## CocoaPods release (secondary channel) — `pod trunk push`

CocoaPods needs one extra publish step after the tag exists, and it requires a
**registered trunk session** tied to a maintainer's account. This step is
**not automated** and is **gated on human sign-off** — pushing to the public
CocoaPods trunk is a production-facing publish (a customer-visible release that
cannot be unpublished), so an agent must not run it autonomously.

Manual maintainer steps, once `vX.Y.Z` is tagged and pushed:

1. Lint the podspec against the published tag (this clones the tag, so the tag
   must already be pushed):
   ```bash
   pod spec lint Quonfig.podspec
   ```
   Use `pod lib lint` to validate locally **without** the remote tag while
   iterating on the podspec.
2. Register a trunk session if you don't have one (one-time, per machine):
   ```bash
   pod trunk register you@quonfig.com "Your Name"
   ```
3. Publish:
   ```bash
   pod trunk push Quonfig.podspec
   ```

Consumers then add to their `Podfile`:

```ruby
pod 'Quonfig', '~> 0.0.1'
```

### Binary `.xcframework` (deferred)

v1.x ships **source** only — no pre-built `.xcframework`. A binary CocoaPods
distribution would require an Apple Developer cert to sign the framework and its
privacy manifest (plan §3.6). Defer until a customer needs faster builds; the
source podspec above is the v1 path.

## Privacy-manifest release check (do not skip)

`PrivacyInfo.xcprivacy` is an App Store gate. Both distribution channels must
actually ship it (the "Statsig trap": the file exists in the repo but isn't
wired into the distribution, so consumers don't bundle it — plan §2.10).

- **SPM:** wired via `.process("Resources/PrivacyInfo.xcprivacy")` in
  `Package.swift`. CI asserts it lands in the built `quonfig-swift_Quonfig.bundle`
  (the "Verify PrivacyInfo.xcprivacy is bundled" step in `ci.yaml`).
- **CocoaPods:** wired via the `resource_bundles` entry in `Quonfig.podspec`,
  which produces a signed `Quonfig_Privacy.bundle` inside the consumer app.

Verify locally before tagging:

```bash
swift build
find .build -path '*quonfig-swift_Quonfig.bundle/PrivacyInfo.xcprivacy'
```

## Why tag-driven (and not npm-style)

Apple's ecosystem is decentralized: SPM resolves from git tags and CocoaPods
from a podspec referencing a tag (plan §4.6). This matches `sdk-go` (Go modules
resolve from tags) and `sdk-java` (tag-triggered publish) rather than the
npm-gated `sdk-node`/`cli` flow.
