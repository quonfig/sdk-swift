import Foundation

/// Default Quonfig domain, mirroring `sdk-javascript`'s `DEFAULT_DOMAIN`.
public let quonfigDefaultDomain = "quonfig.com"

/// Resolves the API and telemetry base URLs a client talks to.
///
/// Mirrors `sdk-javascript/src/config.ts` host derivation:
///   - api:        `https://primary.<domain>` and `https://secondary.<domain>`
///   - telemetry:  `https://telemetry.<domain>`
///
/// There is **no** `QUONFIG_DOMAIN` env read on-device (§4.8) — the domain
/// comes from `Configuration`. The frontend SDK does not open SSE, so we ship
/// both primary and secondary as ordered HTTP failover targets (matching
/// `getDefaultApiUrls`).
///
/// Resolution order (highest wins), mirroring the JS resolution order:
///   1. explicit `apiUrls` / `telemetryUrl`
///   2. `domain` → derived hosts
public struct QuonfigURLs: Sendable, Equatable {
    /// Ordered list of API base URLs to try (failover order).
    public let apiURLs: [URL]
    /// Telemetry service base URL.
    public let telemetryURL: URL

    /// Derive hosts from a domain (the `domain` knob path).
    public static func fromDomain(_ domain: String) -> QuonfigURLs {
        let d = domain.isEmpty ? quonfigDefaultDomain : domain
        // Force-unwraps are safe: these are constructed from a validated host
        // string with a fixed scheme. A malformed `domain` (e.g. containing a
        // space) would fail here, which is the desired loud failure.
        let primary = URL(string: "https://primary.\(d)")!
        let secondary = URL(string: "https://secondary.\(d)")!
        let telemetry = URL(string: "https://telemetry.\(d)")!
        return QuonfigURLs(apiURLs: [primary, secondary], telemetryURL: telemetry)
    }

    /// Resolve from a `Configuration`, honoring the explicit-URL escape hatches
    /// (`apiUrls` / `telemetryUrl`) over the derived `domain` hosts.
    public static func resolve(from config: Configuration) -> QuonfigURLs {
        let derived = fromDomain(config.domain)
        let api = config.apiURLs ?? derived.apiURLs
        let telemetry = config.telemetryURL ?? derived.telemetryURL
        return QuonfigURLs(apiURLs: api, telemetryURL: telemetry)
    }
}
