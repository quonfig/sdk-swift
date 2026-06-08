import Foundation
import XCTest

@testable import Quonfig

final class AuthTests: XCTestCase {
    func testBasicAuthUsesUUsernameForClientKey() {
        // api-delivery/internal/auth/auth.go: frontend key = Basic base64("u:" + key)
        let header = authHeaderValue(sdkKey: "qf_ck_test")
        XCTAssertTrue(header.hasPrefix("Basic "))
        let encoded = String(header.dropFirst("Basic ".count))
        let decoded = String(data: Data(base64Encoded: encoded)!, encoding: .utf8)!
        XCTAssertEqual(decoded, "u:qf_ck_test")
    }
}

final class UserAgentTests: XCTestCase {
    func testUserAgentShape() {
        let ua = quonfigUserAgent()
        // Quonfig-Swift/<version> (<platform> <os-version>)
        XCTAssertTrue(ua.hasPrefix("Quonfig-Swift/0.0.1 ("))
        XCTAssertTrue(ua.hasSuffix(")"))
        XCTAssertTrue(ua.contains(Platform.name))
    }
}

final class URLsTests: XCTestCase {
    func testDeriveFromDomain() {
        let urls = QuonfigURLs.fromDomain("quonfig.com")
        XCTAssertEqual(urls.apiURLs.map(\.absoluteString),
                       ["https://primary.quonfig.com", "https://secondary.quonfig.com"])
        XCTAssertEqual(urls.telemetryURL.absoluteString, "https://telemetry.quonfig.com")
    }

    func testStagingDomain() {
        let urls = QuonfigURLs.fromDomain("quonfig-staging.com")
        XCTAssertEqual(urls.apiURLs.first?.absoluteString, "https://primary.quonfig-staging.com")
        XCTAssertEqual(urls.telemetryURL.absoluteString, "https://telemetry.quonfig-staging.com")
    }

    func testExplicitURLsWinOverDomain() {
        let api = [URL(string: "https://my.proxy/api")!]
        let tel = URL(string: "https://my.proxy/tel")!
        let cfg = Configuration(sdkKey: "k", domain: "quonfig.com", apiURLs: api, telemetryURL: tel)
        let urls = QuonfigURLs.resolve(from: cfg)
        XCTAssertEqual(urls.apiURLs, api)
        XCTAssertEqual(urls.telemetryURL, tel)
    }

    func testDomainUsedWhenNoExplicitURLs() {
        let cfg = Configuration(sdkKey: "k", domain: "quonfig.com")
        let urls = QuonfigURLs.resolve(from: cfg)
        XCTAssertEqual(urls.apiURLs.first?.absoluteString, "https://primary.quonfig.com")
    }
}

final class ConfigurationTests: XCTestCase {
    func testDefaults() {
        let cfg = Configuration(sdkKey: "k")
        XCTAssertEqual(cfg.domain, "quonfig.com")
        XCTAssertEqual(cfg.pollInterval, 60)
        XCTAssertTrue(cfg.collectEvaluationSummaries)
        XCTAssertEqual(cfg.collectContextMode, .periodicExample)
        // URL cache disabled for privacy (§2.3)
        XCTAssertNil(cfg.sessionConfiguration.urlCache)
        XCTAssertTrue(cfg.customHeaders().isEmpty)
    }

    func testTimeoutsApplied() {
        let cfg = Configuration(sdkKey: "k", requestTimeout: 5, resourceTimeout: 30)
        XCTAssertEqual(cfg.sessionConfiguration.timeoutIntervalForRequest, 5)
        XCTAssertEqual(cfg.sessionConfiguration.timeoutIntervalForResource, 30)
    }

    func testCustomHeadersRecomputed() {
        let counter = HeaderCounter()
        let cfg = Configuration(sdkKey: "k", customHeaders: { ["X-Seq": "\(counter.next())"] })
        XCTAssertEqual(cfg.customHeaders()["X-Seq"], "1")
        XCTAssertEqual(cfg.customHeaders()["X-Seq"], "2")
    }
}

/// Helper to prove `customHeaders` is recomputed per call.
final class HeaderCounter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
}

final class ContextEncodingTests: XCTestCase {
    func testMultiNamespace() throws {
        var ctx = QuonfigContext(["user": ["key": .string("u_123"), "email": .string("a@b.com")]])
        ctx.set(namespace: "device", values: ["os": .string("iOS")])
        let data = try ctx.canonicalJSONData()
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual((obj["user"] as! [String: Any])["key"] as! String, "u_123")
        XCTAssertEqual((obj["device"] as! [String: Any])["os"] as! String, "iOS")
    }

    func testCanonicalJSONIsDeterministic() throws {
        let a = QuonfigContext(["user": ["b": .string("2"), "a": .string("1")]])
        let b = QuonfigContext(["user": ["a": .string("1"), "b": .string("2")]])
        XCTAssertEqual(try a.canonicalJSONData(), try b.canonicalJSONData())
    }

    func testBase64URLNeverEmitsPlus() {
        // Craft bytes that base64-encode to a string containing '+' and '/'.
        // 0xFB,0xFF,0xBF -> base64 "+/+/" family; ensure they are remapped.
        let data = Data([0xFB, 0xFF, 0xBF, 0xFE, 0xFF])
        let stdB64 = data.base64EncodedString()
        XCTAssertTrue(stdB64.contains("+") || stdB64.contains("/"),
                      "test precondition: std base64 should contain + or /")
        let url = base64URLEncode(data)
        XCTAssertFalse(url.contains("+"))
        XCTAssertFalse(url.contains("/"))
        XCTAssertFalse(url.contains("="))
    }

    func testEncodedPathSegmentHasNoPlusEvenForPlusProneContext() throws {
        // Many realistic contexts produce '+' in std base64; verify the path
        // segment never contains a raw '+' (server would decode it as space).
        var ctx = QuonfigContext()
        for i in 0..<50 {
            ctx.set(namespace: "ns\(i)", values: ["v": .string("payload-\(i)-\u{00ff}\u{00fe}")])
        }
        let seg = try ctx.encodedPathSegment()
        XCTAssertFalse(seg.contains("+"))
        // The percent-encoded segment only contains unreserved chars + '%'.
        let allowed = rfc3986Unreserved.union(CharacterSet(charactersIn: "%"))
        XCTAssertNil(seg.rangeOfCharacter(from: allowed.inverted))
    }

    func testEncodedPathRoundTrip() throws {
        let ctx = QuonfigContext(["user": ["key": .string("u_1"), "n": .int(7), "on": .bool(true)]])
        let seg = try ctx.encodedPathSegment()
        // Reverse: percent-decode -> base64url -> JSON
        let unescaped = seg.removingPercentEncoding!
        var b64 = unescaped.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        let raw = Data(base64Encoded: b64)!
        let obj = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let user = obj["user"] as! [String: Any]
        XCTAssertEqual(user["key"] as! String, "u_1")
        XCTAssertEqual(user["n"] as! Int, 7)
        XCTAssertEqual(user["on"] as! Bool, true)
    }
}

final class FingerprintTests: XCTestCase {
    func testFingerprintDeterministicAndKeyOrderIndependent() {
        let a = QuonfigContext(["user": ["b": .string("2"), "a": .string("1")]])
        let b = QuonfigContext(["user": ["a": .string("1"), "b": .string("2")]])
        XCTAssertEqual(a.defaultFingerprint(), b.defaultFingerprint())
        // SHA256 hex = 64 chars
        XCTAssertEqual(a.defaultFingerprint().count, 64)
    }

    func testDifferentContextsDifferentFingerprint() {
        let a = QuonfigContext(["user": ["key": .string("u_1")]])
        let b = QuonfigContext(["user": ["key": .string("u_2")]])
        XCTAssertNotEqual(a.defaultFingerprint(), b.defaultFingerprint())
    }

    func testInjectableFingerprint() {
        let custom: ContextFingerprintFn = { _ in "constant-key" }
        let ctx = QuonfigContext(["user": ["key": .string("u_1")]])
        XCTAssertEqual(custom(ctx), "constant-key")
        XCTAssertEqual(defaultContextFingerprint(ctx), ctx.defaultFingerprint())
    }
}
