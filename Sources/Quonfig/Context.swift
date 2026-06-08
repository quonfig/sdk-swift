import Foundation
import CryptoKit

/// A scalar context value. Quonfig contexts are flat per namespace — only
/// scalars and string arrays match operators at runtime; nested objects are
/// not supported (mirrors `sdk-javascript/src/types.ts` `ContextValue` and the
/// `validateContexts` warning).
public enum ContextValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case stringList([String])
}

/// A multi-namespace context, e.g. `{ user: {...}, device: {...} }`.
///
/// Mirrors `sdk-javascript`'s `Contexts = { [key: string]: Record<string, ContextValue> }`.
/// Namespaces map to per-namespace key/value dictionaries.
public struct QuonfigContext: Sendable, Equatable {
    /// namespace -> (attribute -> value)
    public private(set) var namespaces: [String: [String: ContextValue]]

    public init(_ namespaces: [String: [String: ContextValue]] = [:]) {
        self.namespaces = namespaces
    }

    /// Set or replace a whole namespace.
    public mutating func set(namespace: String, values: [String: ContextValue]) {
        namespaces[namespace] = values
    }

    /// The namespaces serialized to a JSON-encodable, deterministic form.
    ///
    /// Keys are sorted at both levels so the same logical context always
    /// produces byte-identical JSON — this is what makes the base64url path and
    /// the SHA256 fingerprint stable across calls.
    func canonicalJSONData() throws -> Data {
        // Build a Foundation object graph, then encode with `.sortedKeys`.
        var root: [String: [String: Any]] = [:]
        for (ns, values) in namespaces {
            var inner: [String: Any] = [:]
            for (k, v) in values {
                inner[k] = v.jsonValue
            }
            root[ns] = inner
        }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )
    }
}

extension ContextValue {
    /// The Foundation/JSON representation used for serialization.
    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .stringList(let l): return l
        }
    }
}

/// RFC 3986 unreserved character set: `A-Z a-z 0-9 - . _ ~`.
///
/// We percent-encode the base64url string against THIS explicit set rather
/// than any Foundation `.urlPathAllowed`-style default. Foundation's defaults
/// let `+` through, and the server decodes `+` as a space — corrupting the
/// context (Unleash #67). base64url already maps `+`→`-` and `/`→`_`, so no
/// `+`/`/` ever appears; encoding against the unreserved set is belt-and-braces
/// so the `=` padding (and anything else) is percent-escaped and `+` can never
/// pass through.
let rfc3986Unreserved: CharacterSet = {
    var set = CharacterSet()
    set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz")
    set.insert(charactersIn: "0123456789")
    set.insert(charactersIn: "-._~")
    return set
}()

/// Encode raw bytes as base64url **without** padding and without any of the
/// base64 characters that are unsafe in a URL path:
///   - `+` → `-`
///   - `/` → `_`
///   - trailing `=` padding removed
func base64URLEncode(_ data: Data) -> String {
    var s = data.base64EncodedString()
    s = s.replacingOccurrences(of: "+", with: "-")
    s = s.replacingOccurrences(of: "/", with: "_")
    s = s.replacingOccurrences(of: "=", with: "")
    return s
}

/// A function that turns a context into a cache-key fingerprint string.
///
/// Injectable from day one (Statsig's `customCacheKey` lesson — their default
/// fingerprint was wrong for anonymous users / on-device-ID A/B / multi-tenant
/// apps). The default is a SHA256 over the canonical context JSON.
public typealias ContextFingerprintFn = @Sendable (QuonfigContext) -> String

public extension QuonfigContext {
    /// The path segment for `GET /api/v2/configs/eval-with-context/{ctx}`:
    /// `percentEncode(base64url(canonicalContextJSON))`.
    ///
    /// `base64url` guarantees no `+`/`/`; the percent-encode against the
    /// RFC 3986 unreserved set guarantees nothing else (incl. a stray `+`)
    /// ever reaches the server's path decoder.
    func encodedPathSegment() throws -> String {
        let json = try canonicalJSONData()
        let b64url = base64URLEncode(json)
        // base64url's alphabet (`A–Z a–z 0–9 - _`) is entirely within the
        // unreserved set, so this is a no-op for well-formed input but defends
        // against any future alphabet change.
        guard let encoded = b64url.addingPercentEncoding(
            withAllowedCharacters: rfc3986Unreserved
        ) else {
            // Should be unreachable for a base64url string; fail loud.
            throw QuonfigContextError.encodingFailed
        }
        return encoded
    }

    /// Default SHA256 fingerprint over the canonical context JSON, hex-encoded.
    /// Used for cache keying (LD stores a SHA256-of-context as `fingerprint-<key>`).
    func defaultFingerprint() -> String {
        let data = (try? canonicalJSONData()) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The default injectable fingerprint function (SHA256 hex of canonical JSON).
public let defaultContextFingerprint: ContextFingerprintFn = { context in
    context.defaultFingerprint()
}

public enum QuonfigContextError: Error, Sendable {
    case encodingFailed
}
