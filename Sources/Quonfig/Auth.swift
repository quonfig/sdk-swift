import Foundation

/// HTTP Basic auth header for Quonfig API requests.
///
/// The frontend/client key is sent as `Authorization: Basic base64("u:" + sdkKey)`.
/// The `"u"` username is how `api-delivery` distinguishes a client key from a
/// backend key — any non-`"u"` username (e.g. `"authuser"`) is treated as a
/// backend key. See `api-delivery/internal/auth/auth.go` (`ParseAuthHeader`).
///
/// (Note: `sdk-javascript` currently sends `base64("1:" + sdkKey)`; that path
/// resolves to a *backend* key in `auth.go`. This Apple SDK is a frontend
/// client, so it uses the canonical `"u"` username per the plan §2.3 and the
/// server's own switch statement.)
func authHeaderValue(sdkKey: String) -> String {
    let raw = "u:\(sdkKey)"
    let encoded = Data(raw.utf8).base64EncodedString()
    return "Basic \(encoded)"
}
