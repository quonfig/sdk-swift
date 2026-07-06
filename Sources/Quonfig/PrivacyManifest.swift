import Foundation

/// Test/diagnostic accessor for the SDK's own resource bundle — the one that
/// carries `PrivacyInfo.xcprivacy`. This exists so the privacy-manifest test can
/// assert the manifest actually landed in *Quonfig's* resource bundle (the Statsig
/// trap is the manifest existing but not being bundled with the library, §1).
///
/// The SDK ships via SwiftPM only, so the bundle is `Bundle.module`, generated
/// from `Package.swift` `resources:`.
enum PrivacyManifest {
    /// The Quonfig module's resource bundle.
    static var resourceBundle: Bundle? {
        .module
    }

    /// URL of the bundled `PrivacyInfo.xcprivacy`, or `nil` if it is not wired into
    /// the resource bundle.
    static var url: URL? {
        resourceBundle?.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    }
}
