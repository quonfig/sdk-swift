Pod::Spec.new do |s|
  s.name             = "Quonfig"
  s.version          = "0.0.1"
  s.summary          = "Quonfig feature-flag & config SDK for Apple platforms (iOS, macOS)."

  s.description      = <<-DESC
    The native Apple-platform SDK for Quonfig — a polling, cache-first feature-flag
    and configuration client. Mirrors the sdk-javascript frontend pattern: fetch the
    server-evaluated envelope for a context, cache it, poll with ETag/304, and read
    typed values synchronously. Swift-first, strict-concurrency clean, with a shipped
    App Store privacy manifest.
  DESC

  s.homepage         = "https://github.com/quonfig/sdk-swift"
  s.license          = { :type => "MIT", :file => "LICENSE" }
  s.author           = { "Quonfig" => "support@quonfig.com" }

  # Tag-driven release: CocoaPods resolves the source from the git tag, which is
  # `v`-prefixed (`vX.Y.Z`, per RELEASING.md), while `s.version` is bare (`X.Y.Z`).
  # So the source tag must be "v#{s.version}" — using s.version.to_s directly looks
  # for a non-existent bare tag and fails validation with "Remote branch X.Y.Z not
  # found in upstream origin".
  s.source           = {
    :git => "https://github.com/quonfig/sdk-swift.git",
    :tag => "v#{s.version}"
  }

  # Deployment targets match Package.swift (plan §3.4: iOS 15 / macOS 12, Swift
  # Concurrency throughout). tvOS/watchOS are deliberately omitted in v1.
  s.ios.deployment_target  = "15.0"
  s.osx.deployment_target  = "12.0"

  s.swift_versions   = ["5.9", "6.0"]

  # Swift-only v1 (no ObjC surface — plan §3.4, §7.10).
  s.source_files     = "Sources/Quonfig/**/*.swift"

  # App Store privacy manifest. CocoaPods bundles a `resource_bundles` entry into
  # a signed .bundle inside the consumer app, which is how Apple expects a pod to
  # ship PrivacyInfo.xcprivacy (the SPM `.process` resource is the equivalent on
  # the SPM side). This is the Statsig trap (plan §2.10): shipping the file but
  # not wiring it into the distribution means consumers don't bundle it.
  s.resource_bundles = {
    "Quonfig_Privacy" => ["Sources/Quonfig/Resources/PrivacyInfo.xcprivacy"]
  }

  s.frameworks       = "Foundation"
end
