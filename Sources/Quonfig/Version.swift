import Foundation

/// The released version of the Quonfig Swift SDK.
///
/// Mirrors `sdk-javascript/src/version.ts` (`export default "1.0.0"`). The
/// other Quonfig SDKs are at 1.0.0; this Apple-platform SDK starts its own
/// 0.0.x line and graduates to 1.0.0 when it reaches feature parity.
public let quonfigVersion = "0.0.1"

/// Library / platform identifier used in the `User-Agent` header.
///
/// Resolves to the Apple OS family at compile time. There is intentionally no
/// `process.env`-style runtime lookup (§4.8) — everything is derived from the
/// build platform plus `Configuration`.
enum Platform {
    static var name: String {
        #if os(iOS)
            return "iOS"
        #elseif os(macOS)
            return "macOS"
        #elseif os(tvOS)
            return "tvOS"
        #elseif os(watchOS)
            return "watchOS"
        #elseif os(visionOS)
            return "visionOS"
        #elseif os(Linux)
            return "Linux"
        #else
            return "Apple"
        #endif
    }

    /// Marketing-style OS version string, e.g. `"17.4.0"`.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

/// `User-Agent` value sent on every request:
/// `Quonfig-Swift/<version> (<platform> <os-version>)`.
///
/// Backend triage without a UA is brutal (Flagsmith #88), so we send it from
/// v0.0.1.
func quonfigUserAgent() -> String {
    "Quonfig-Swift/\(quonfigVersion) (\(Platform.name) \(Platform.osVersion))"
}
