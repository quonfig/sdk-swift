import Foundation
import Network

/// A tiny in-process HTTP server (Network.framework) that serves the pinned
/// `eval-with-context` fixture for the test-swift demo, so the app runs end-to-end
/// with NO external api-delivery. On every eval request it flips the
/// `new-checkout` flag and bumps `rate-limit`, returning a fresh `ETag` so the
/// SDK's poll loop observes a real change each tick — exactly what the demo is
/// meant to show (poll-driven updates).
///
/// This is a demo/test scaffold, not production code: it parses just enough HTTP
/// to answer the SDK's GET (eval) and POST (telemetry). It listens on loopback on
/// an OS-assigned port and reports that port back so the client can target
/// `http://127.0.0.1:<port>`.
final class FixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.quonfig.test-swift.fixture-server")
    private let lock = NSLock()

    /// The base envelope JSON object, mutated per request to simulate change.
    private var envelope: [String: Any]
    /// Monotonic counter folded into the ETag and the mutated values.
    private var tick = 0

    /// The actual bound port (resolved after `start`).
    private(set) var port: UInt16 = 0

    init(fixtureURL: URL) throws {
        let data = try Data(contentsOf: fixtureURL)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureServerError.badFixture
        }
        self.envelope = obj

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to loopback on an OS-assigned port.
        self.listener = try NWListener(using: params, on: .any)
    }

    /// Start listening; calls `onReady` with the bound port once up.
    func start(onReady: @escaping @Sendable (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let p = self.listener.port {
                self.port = p.rawValue
                onReady(p.rawValue)
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(on: conn, buffer: Data())
    }

    /// Accumulate bytes until we have the request head (we don't need the body for
    /// our purposes), then respond and close.
    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var acc = buffer
            if let data { acc.append(data) }

            let headEnd = acc.range(of: Data("\r\n\r\n".utf8))
            if headEnd != nil || isComplete || error != nil {
                let response = self.response(forRequestHead: acc)
                conn.send(
                    content: response,
                    completion: .contentProcessed { _ in
                        conn.cancel()
                    })
            } else {
                self.receive(on: conn, buffer: acc)
            }
        }
    }

    private func response(forRequestHead head: Data) -> Data {
        let text = String(decoding: head, as: UTF8.self)
        let firstLine = text.split(separator: "\r\n").first.map(String.init) ?? ""

        // Telemetry POST -> 200 with empty JSON (the SDK ignores the body).
        if firstLine.hasPrefix("POST") {
            return Self.httpResponse(status: 200, statusText: "OK", body: Data("{}".utf8))
        }

        // eval GET -> the mutated envelope + a fresh ETag.
        let (body, etag) = mutatedEnvelopeBody()
        return Self.httpResponse(
            status: 200, statusText: "OK", body: body,
            extraHeaders: ["ETag": etag])
    }

    /// Produce the next envelope body, flipping `new-checkout` and bumping
    /// `rate-limit` so each poll observes a change, with a unique ETag.
    private func mutatedEnvelopeBody() -> (Data, String) {
        lock.lock()
        defer { lock.unlock() }
        tick += 1

        if var evals = envelope["evaluations"] as? [String: Any] {
            // Flip new-checkout on/off each tick.
            if var nc = evals["new-checkout"] as? [String: Any] {
                nc["value"] = ["type": "bool", "value": tick % 2 == 1]
                evals["new-checkout"] = nc
            }
            // Bump rate-limit so a numeric value visibly moves.
            if var rl = evals["rate-limit"] as? [String: Any] {
                rl["value"] = ["type": "int", "value": 250 + tick]
                evals["rate-limit"] = rl
            }
            envelope["evaluations"] = evals
        }

        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data("{}".utf8)
        return (body, "fixture-etag-\(tick)")
    }

    private static func httpResponse(
        status: Int, statusText: String, body: Data,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (k, v) in extraHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

enum FixtureServerError: Error { case badFixture }
