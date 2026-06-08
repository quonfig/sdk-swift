import Foundation

/// Test/diagnostic accessor for the SDK's own resource bundle — the one that
/// carries `PrivacyInfo.xcprivacy`. This exists so the privacy-manifest test can
/// assert the manifest actually landed in *Quonfig's* resource bundle (the Statsig
/// trap is the manifest existing but not being bundled with the library, §1).
///
/// The resource bundle is located differently per distribution channel, because
/// the privacy manifest is wired in twice — once for each (see RELEASING.md):
///   - **SwiftPM** generates `Bundle.module` from `Package.swift` `resources:`.
///     `Bundle.module` only exists in a SwiftPM build (SwiftPM defines the
///     `SWIFT_PACKAGE` compilation flag), and references to it fail to compile
///     under CocoaPods — which is why this is guarded.
///   - **CocoaPods** ships the manifest in the `Quonfig_Privacy` resource bundle
///     declared by `resource_bundles` in `Quonfig.podspec`. That `.bundle` sits
///     next to the framework binary, so we resolve it relative to this type's
///     own bundle.
enum PrivacyManifest {
    /// The Quonfig module's resource bundle, resolved per build system.
    static var resourceBundle: Bundle? {
        #if SWIFT_PACKAGE
            return .module
        #else
            // CocoaPods: the framework bundle that contains this type, then the
            // nested `Quonfig_Privacy.bundle` declared by `resource_bundles`.
            let frameworkBundle = Bundle(for: BundleToken.self)
            if let url = frameworkBundle.url(forResource: "Quonfig_Privacy", withExtension: "bundle"),
                let nested = Bundle(url: url)
            {
                return nested
            }
            return frameworkBundle
        #endif
    }

    /// URL of the bundled `PrivacyInfo.xcprivacy`, or `nil` if it is not wired into
    /// the resource bundle.
    static var url: URL? {
        resourceBundle?.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    }
}

/// Anchor class used to locate the framework bundle under CocoaPods (where there
/// is no `Bundle.module`). Unused on the SwiftPM path.
private final class BundleToken {}
