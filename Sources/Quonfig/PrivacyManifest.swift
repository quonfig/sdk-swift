import Foundation

/// Test/diagnostic accessor for the SDK's own resource bundle (the one SPM builds
/// from `Package.swift` `resources:`). This exists so the privacy-manifest test can
/// assert `PrivacyInfo.xcprivacy` actually landed in *Quonfig's* `Bundle.module` —
/// a test target's own `Bundle.module` points at the test bundle, not ours, so the
/// check has to reach into the Quonfig module to be meaningful (the Statsig trap is
/// the manifest existing but not being bundled with the library, §1).
enum PrivacyManifest {
    /// The Quonfig module's resource bundle.
    static var resourceBundle: Bundle { .module }

    /// URL of the bundled `PrivacyInfo.xcprivacy`, or `nil` if it is not wired into
    /// the resource bundle.
    static var url: URL? {
        Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    }
}
