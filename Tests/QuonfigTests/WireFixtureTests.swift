import Foundation
import XCTest

@testable import Quonfig

/// Verifies the SOURCE-DERIVED wire fixtures (Tests/QuonfigTests/Fixtures/*)
/// decode into the exact shapes transcribed from api-delivery's Go types and
/// sdk-javascript. These pin the contract qfg-2t2d.4 (eval loader + ETag/304 +
/// decoder safety) will code against. The structs below are local to the test
/// on purpose — the public Codable surface lands in qfg-2t2d.4.
final class WireFixtureTests: XCTestCase {
    // MARK: Fixture loading

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            XCTFail("missing fixture: Fixtures/\(name)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    // MARK: Local decode models mirroring the wire contract

    struct Envelope: Decodable {
        let evaluations: [String: Eval]
        let meta: Meta
    }

    struct Eval: Decodable {
        let value: WireValue
        let configId: String
        let configType: String
        let valueType: String
        let reason: String?
        let ruleIndex: Int?
        let weightedValueIndex: Int?

        // decodeIfPresent for every optional, per plan §2.3 / §2.10.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = try c.decode(WireValue.self, forKey: .value)
            configId = try c.decode(String.self, forKey: .configId)
            configType = try c.decode(String.self, forKey: .configType)
            valueType = try c.decode(String.self, forKey: .valueType)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            ruleIndex = try c.decodeIfPresent(Int.self, forKey: .ruleIndex)
            weightedValueIndex = try c.decodeIfPresent(Int.self, forKey: .weightedValueIndex)
        }

        enum CodingKeys: String, CodingKey {
            case value, configId, configType, valueType, reason, ruleIndex, weightedValueIndex
        }
    }

    /// The inner Value wrapper — only `type` matters for shape verification.
    struct WireValue: Decodable {
        let type: String
    }

    struct Meta: Decodable {
        let version: String
        let environment: String
        let workspaceId: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decode(String.self, forKey: .version)
            environment = try c.decode(String.self, forKey: .environment)
            workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        }

        enum CodingKeys: String, CodingKey { case version, environment, workspaceId }
    }

    // MARK: eval-with-context envelope

    func testEvalEnvelopeDecodes() throws {
        let env = try JSONDecoder().decode(
            Envelope.self, from: try fixtureData("eval-with-context.response.json"))

        XCTAssertEqual(env.meta.version, "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4")
        XCTAssertEqual(env.meta.environment, "production")
        // ServeHTTP builds Meta with only Version+Environment -> workspaceId omitted.
        XCTAssertNil(env.meta.workspaceId)
        XCTAssertEqual(env.evaluations.count, 5)
    }

    func testStaticReasonOmitsIndexes() throws {
        let env = try JSONDecoder().decode(
            Envelope.self, from: try fixtureData("eval-with-context.response.json"))
        let e = try XCTUnwrap(env.evaluations["new-checkout"])
        XCTAssertEqual(e.reason, "STATIC")
        XCTAssertEqual(e.value.type, "bool")
        XCTAssertEqual(e.valueType, "bool")
        XCTAssertEqual(e.configType, "feature_flag")
        // omitempty: STATIC carries no indexes.
        XCTAssertNil(e.ruleIndex)
        XCTAssertNil(e.weightedValueIndex)
    }

    func testTargetingMatchCarriesRuleIndexOnly() throws {
        let env = try JSONDecoder().decode(
            Envelope.self, from: try fixtureData("eval-with-context.response.json"))
        let e = try XCTUnwrap(env.evaluations["button-color"])
        XCTAssertEqual(e.reason, "TARGETING_MATCH")
        XCTAssertEqual(e.ruleIndex, 0)
        XCTAssertNil(e.weightedValueIndex)
    }

    func testSplitCarriesBothIndexes() throws {
        let env = try JSONDecoder().decode(
            Envelope.self, from: try fixtureData("eval-with-context.response.json"))
        let e = try XCTUnwrap(env.evaluations["checkout-experiment"])
        XCTAssertEqual(e.reason, "SPLIT")
        XCTAssertEqual(e.ruleIndex, 1)
        XCTAssertEqual(e.weightedValueIndex, 2)
        XCTAssertEqual(e.valueType, "weighted_values")
    }

    func testReasonEnumValuesAreServerSet() throws {
        // The wire carries exactly the three server reasons (eval_context.go).
        let env = try JSONDecoder().decode(
            Envelope.self, from: try fixtureData("eval-with-context.response.json"))
        let reasons = Set(env.evaluations.values.compactMap(\.reason))
        XCTAssertTrue(reasons.isSubset(of: ["STATIC", "TARGETING_MATCH", "SPLIT"]))
    }

    // MARK: ETag / 304 exchange

    struct ETagExchange: Decodable {
        struct Resp: Decodable {
            let status: Int
            let headers: [String: String]
        }
        struct Req: Decodable {
            let method: String
            let path: String
            let headers: [String: String]
        }
        let request: Req
        let initial200: Resp
        let conditionalRequest: Req
        let notModified304: Resp
    }

    func testETagExchangeShape() throws {
        let ex = try JSONDecoder().decode(
            ETagExchange.self, from: try fixtureData("etag-exchange.json"))

        XCTAssertEqual(ex.initial200.status, 200)
        let etag = try XCTUnwrap(ex.initial200.headers["ETag"])
        XCTAssertFalse(etag.isEmpty)

        // The conditional request echoes the minted ETag verbatim.
        XCTAssertEqual(ex.conditionalRequest.headers["If-None-Match"], etag)
        XCTAssertEqual(ex.notModified304.status, 304)
        // 304 body is empty (server returns no payload).
        XCTAssertTrue(ex.request.path.contains("/api/v2/configs/eval-with-context/"))
        XCTAssertTrue(ex.request.path.contains("collectContextMode=PERIODIC_EXAMPLE"))
    }

    // MARK: telemetry POST body

    struct TelemetryBody: Decodable {
        struct Event: Decodable { let summaries: Summaries }
        struct Summaries: Decodable {
            let start: Int64
            let end: Int64
            let summaries: [Summary]
        }
        struct Summary: Decodable {
            let key: String
            let type: String
            let counters: [Counter]
        }
        struct Counter: Decodable {
            let configRowIndex: Int
            let conditionalValueIndex: Int
            let configId: String
            let reason: String?
            let ruleIndex: Int?
            let weightedValueIndex: Int?
            let selectedValue: [String: AnyHashableDecode]
            let count: Int

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                configRowIndex = try c.decode(Int.self, forKey: .configRowIndex)
                conditionalValueIndex = try c.decode(Int.self, forKey: .conditionalValueIndex)
                configId = try c.decode(String.self, forKey: .configId)
                reason = try c.decodeIfPresent(String.self, forKey: .reason)
                ruleIndex = try c.decodeIfPresent(Int.self, forKey: .ruleIndex)
                weightedValueIndex = try c.decodeIfPresent(Int.self, forKey: .weightedValueIndex)
                selectedValue = try c.decode([String: AnyHashableDecode].self, forKey: .selectedValue)
                count = try c.decode(Int.self, forKey: .count)
            }

            enum CodingKeys: String, CodingKey {
                case configRowIndex, conditionalValueIndex, configId, reason
                case ruleIndex, weightedValueIndex, selectedValue, count
            }
        }
        let instanceHash: String
        let clientName: String
        let clientVersion: String
        let events: [Event]
    }

    /// Minimal AnyDecodable so `selectedValue: { <type>: <value> }` decodes for
    /// any scalar without committing to a value model here.
    struct AnyHashableDecode: Decodable {}

    func testTelemetryBodyShape() throws {
        let body = try JSONDecoder().decode(
            TelemetryBody.self, from: try fixtureData("telemetry-post.body.json"))

        // clientName is "swift" per plan §2.3.
        XCTAssertEqual(body.clientName, "swift")
        XCTAssertEqual(body.clientVersion, "0.0.1")
        XCTAssertFalse(body.instanceHash.isEmpty)

        let event = try XCTUnwrap(body.events.first)
        XCTAssertLessThanOrEqual(event.summaries.start, event.summaries.end)

        let summaries = event.summaries.summaries
        XCTAssertEqual(summaries.count, 2)

        let first = try XCTUnwrap(summaries.first { $0.key == "new-checkout" })
        XCTAssertEqual(first.type, "feature_flag")
        let counter = try XCTUnwrap(first.counters.first)
        XCTAssertEqual(counter.count, 17)
        XCTAssertEqual(counter.reason, "STATIC")
        // STATIC counter omits indexes.
        XCTAssertNil(counter.ruleIndex)
        // selectedValue is keyed by the config value type ("bool").
        XCTAssertNotNil(counter.selectedValue["bool"])

        let targeted = try XCTUnwrap(summaries.first { $0.key == "button-color" })
        let tc = try XCTUnwrap(targeted.counters.first)
        XCTAssertEqual(tc.ruleIndex, 0)
        XCTAssertNotNil(tc.selectedValue["string"])
    }
}
