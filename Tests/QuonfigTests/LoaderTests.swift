import Foundation
import XCTest

@testable import Quonfig

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Loader behaviour: URL shape, HTTP Basic auth, ETag conditional GET, 304/204
/// no-change handling, case-insensitive header read, failover, and the `+`-never-
/// passes URL encoding. URLSession is injected via the `HTTPClient` protocol so
/// every request/response is observable.
final class LoaderTests: XCTestCase {
    // MARK: Mock client

    /// One scripted response per call, in order. Captures every request seen.
    final class MockClient: HTTPClient, @unchecked Sendable {
        struct Response {
            let status: Int
            let headers: [String: String]
            let body: Data
        }
        private let lock = NSLock()
        private var responses: [Response]
        private(set) var requests: [URLRequest] = []
        /// If set, all calls throw this until `responses` is reached.
        var throwUntilIndex: Int = -1

        init(_ responses: [Response]) { self.responses = responses }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock()
            defer { lock.unlock() }
            let idx = requests.count
            requests.append(request)
            if idx <= throwUntilIndex {
                throw URLError(.cannotConnectToHost)
            }
            guard !responses.isEmpty else {
                throw URLError(.badServerResponse)
            }
            let r = responses.removeFirst()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: r.status,
                httpVersion: "HTTP/1.1", headerFields: r.headers)!
            return (r.body, http)
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: nil, subdirectory: "Fixtures")
        else {
            XCTFail("missing fixture: Fixtures/\(name)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func sampleContext() -> QuonfigContext {
        QuonfigContext(["user": ["key": .string("u_123"), "email": .string("a@b.com")]])
    }

    private let apiURL = URL(string: "https://primary.quonfig.com")!

    // MARK: URL + auth shape

    func testRequestURLAuthAndHeaders() async throws {
        let body = try fixtureData("eval-with-context.response.json")
        let mock = MockClient([.init(status: 200, headers: ["ETag": "etag-1"], body: body)])
        let loader = Loader(
            sdkKey: "qf_ck_production_example", context: sampleContext(),
            apiURLs: [apiURL], collectContextMode: .periodicExample, client: mock)

        _ = try await loader.load()

        let req = try XCTUnwrap(mock.requests.first)
        let urlString = try XCTUnwrap(req.url?.absoluteString)
        XCTAssertTrue(urlString.hasPrefix(
            "https://primary.quonfig.com/api/v2/configs/eval-with-context/"))
        XCTAssertTrue(urlString.hasSuffix("?collectContextMode=PERIODIC_EXAMPLE"))
        XCTAssertEqual(req.httpMethod, "GET")

        // HTTP Basic with username "u" -> base64("u:" + key). This is how
        // api-delivery's auth.go classifies a frontend key.
        let expectedAuth = "Basic " + Data("u:qf_ck_production_example".utf8).base64EncodedString()
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), expectedAuth)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertTrue((req.value(forHTTPHeaderField: "User-Agent") ?? "").hasPrefix("Quonfig-Swift/"))
        // No If-None-Match on the first request (no cache yet).
        XCTAssertNil(req.value(forHTTPHeaderField: "If-None-Match"))
    }

    /// The encoded context segment must be base64url with NO `+` (Unleash #67 —
    /// the server decodes `+` as a space, corrupting the context).
    func testEncodedContextHasNoPlus() async throws {
        // A context whose canonical JSON base64 would contain '+' under standard
        // base64; base64url maps it to '-' and we percent-encode the rest.
        let ctx = QuonfigContext(["u": ["k": .string(">>>>>>")]])
        let body = try fixtureData("eval-with-context.response.json")
        let mock = MockClient([.init(status: 200, headers: ["ETag": "e"], body: body)])
        let loader = Loader(sdkKey: "k", context: ctx, apiURLs: [apiURL], client: mock)
        _ = try await loader.load()

        let segment = try XCTUnwrap(mock.requests.first?.url?.absoluteString)
        XCTAssertFalse(segment.contains("+"), "encoded context must never contain a raw '+'")
    }

    // MARK: ETag conditional GET + 304

    func testETagCapturedThenReplayedAnd304ReturnsCachedEnvelope() async throws {
        let body = try fixtureData("eval-with-context.response.json")
        let mock = MockClient([
            .init(status: 200, headers: ["ETag": "9f8b3c1d"], body: body),
            .init(status: 304, headers: [:], body: Data()),
        ])
        let loader = Loader(sdkKey: "k", context: sampleContext(), apiURLs: [apiURL], client: mock)

        let first = try await loader.load()
        XCTAssertFalse(first.notModified)
        XCTAssertEqual(first.envelope.evaluations.count, 5)

        let second = try await loader.load()
        XCTAssertTrue(second.notModified)
        // The 304 path returns the payload cached for THIS url (loader.ts contract).
        XCTAssertEqual(second.envelope, first.envelope)

        // The second request echoed the minted ETag verbatim.
        XCTAssertEqual(mock.requests.count, 2)
        XCTAssertEqual(mock.requests[1].value(forHTTPHeaderField: "If-None-Match"), "9f8b3c1d")
    }

    /// Some proxies return 204 in place of 304 — treat identically (Unleash #24).
    func test204TreatedAsNoChange() async throws {
        let body = try fixtureData("eval-with-context.response.json")
        let mock = MockClient([
            .init(status: 200, headers: ["ETag": "e1"], body: body),
            .init(status: 204, headers: [:], body: Data()),
        ])
        let loader = Loader(sdkKey: "k", context: sampleContext(), apiURLs: [apiURL], client: mock)

        let first = try await loader.load()
        let second = try await loader.load()
        XCTAssertTrue(second.notModified)
        XCTAssertEqual(second.envelope, first.envelope)
    }

    /// ETag header read must be case-insensitive (Unleash #6 — lowercase proxies).
    func testLowercaseETagHeaderIsRead() async throws {
        let body = try fixtureData("eval-with-context.response.json")
        let mock = MockClient([
            .init(status: 200, headers: ["etag": "lower-etag"], body: body),
            .init(status: 304, headers: [:], body: Data()),
        ])
        let loader = Loader(sdkKey: "k", context: sampleContext(), apiURLs: [apiURL], client: mock)

        _ = try await loader.load()
        let second = try await loader.load()
        XCTAssertTrue(second.notModified)
        XCTAssertEqual(mock.requests[1].value(forHTTPHeaderField: "If-None-Match"), "lower-etag")
    }

    /// A 304 with no cached entry is impossible in practice; surface an error so
    /// the URL fails over rather than serving the wrong context.
    func test304WithoutCacheThrows() async throws {
        let mock = MockClient([.init(status: 304, headers: [:], body: Data())])
        let loader = Loader(sdkKey: "k", context: sampleContext(), apiURLs: [apiURL], client: mock)
        do {
            _ = try await loader.load()
            XCTFail("expected failure")
        } catch let QuonfigLoaderError.allURLsFailed(msg) {
            XCTAssertTrue(msg.contains("notModifiedWithoutCache"))
        }
    }

    // MARK: Failover

    func testFailoverToSecondURL() async throws {
        let body = try fixtureData("eval-with-context.response.json")
        let secondary = URL(string: "https://secondary.quonfig.com")!
        let mock = MockClient([.init(status: 200, headers: ["ETag": "e"], body: body)])
        mock.throwUntilIndex = 0 // first call (primary) throws, second (secondary) succeeds

        let loader = Loader(
            sdkKey: "k", context: sampleContext(),
            apiURLs: [apiURL, secondary], client: mock)

        let result = try await loader.load()
        XCTAssertFalse(result.notModified)
        XCTAssertEqual(mock.requests.count, 2)
        XCTAssertTrue(mock.requests[0].url!.absoluteString.contains("primary."))
        XCTAssertTrue(mock.requests[1].url!.absoluteString.contains("secondary."))
    }

    func testAllURLsFailSurfacesError() async throws {
        let mock = MockClient([])
        mock.throwUntilIndex = 5
        let loader = Loader(sdkKey: "k", context: sampleContext(), apiURLs: [apiURL], client: mock)
        do {
            _ = try await loader.load()
            XCTFail("expected failure")
        } catch let QuonfigLoaderError.allURLsFailed(msg) {
            XCTAssertFalse(msg.isEmpty)
        }
    }

    // MARK: Non-2xx

    func testNon2xxThrowsHTTPStatus() async throws {
        let mock = MockClient([.init(status: 503, headers: [:], body: Data())])
        let loader = Loader(sdkKey: "k", context: sampleContext(), apiURLs: [apiURL], client: mock)
        do {
            _ = try await loader.load()
            XCTFail("expected failure")
        } catch let QuonfigLoaderError.allURLsFailed(msg) {
            XCTAssertTrue(msg.contains("503"))
        }
    }

    /// A server that drops the ETag forgets the cache entry, so the next poll is
    /// a full GET (no stale revalidation) — mirrors loader.ts.
    func testMissingETagDropsCache() async throws {
        let body = try fixtureData("eval-with-context.response.json")
        let mock = MockClient([
            .init(status: 200, headers: ["ETag": "e1"], body: body),
            .init(status: 200, headers: [:], body: body), // no ETag this time
            .init(status: 200, headers: ["ETag": "e2"], body: body),
        ])
        let loader = Loader(sdkKey: "k", context: sampleContext(), apiURLs: [apiURL], client: mock)

        _ = try await loader.load()
        _ = try await loader.load() // server drops ETag -> cache forgotten
        _ = try await loader.load()

        // Third request must NOT carry If-None-Match (cache was dropped).
        XCTAssertNil(mock.requests[2].value(forHTTPHeaderField: "If-None-Match"))
    }
}
