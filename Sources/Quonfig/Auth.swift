import Foundation

/// HTTP Basic auth header for Quonfig API requests.
///
/// Sent as `Authorization: Basic base64("1:" + sdkKey)`. The Basic-auth
/// username is ignored by `api-delivery` — authorization is driven entirely by
/// the SDK key, and frontend vs backend is determined by the stored key record,
/// not the username (see `api-delivery/internal/auth/auth.go`). All Quonfig SDKs
/// send `"1"`; we match the fleet for consistency.
func authHeaderValue(sdkKey: String) -> String {
    let raw = "1:\(sdkKey)"
    let encoded = Data(raw.utf8).base64EncodedString()
    return "Basic \(encoded)"
}
