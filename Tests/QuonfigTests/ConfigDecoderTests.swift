import Foundation
import XCTest

@testable import Quonfig

/// Decoder safety for the public `Config.swift` Codable surface.
///
/// Pins the §2.3/§2.10 rules against the SOURCE-DERIVED fixture:
///   - every server-optional field uses `decodeIfPresent` — proven by a
///     field-strip test that removes one optional at a time and asserts the
///     envelope still decodes;
///   - an unknown `reason` decodes to `.error`, never failing the envelope.
final class ConfigDecoderTests: XCTestCase {
    private func fixtureData(_ name: String) throws -> Data {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: nil, subdirectory: "Fixtures")
        else {
            XCTFail("missing fixture: Fixtures/\(name)")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    private func fixtureJSON(_ name: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: try fixtureData(name))
        return obj as! [String: Any]
    }

    private func encode(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: Happy path against the pinned fixture

    func testEnvelopeDecodesFromPinnedFixture() throws {
        let env = try JSONDecoder().decode(
            EvalEnvelope.self, from: try fixtureData("eval-with-context.response.json"))

        XCTAssertEqual(env.evaluations.count, 5)
        XCTAssertEqual(env.meta.version, "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4")
        XCTAssertEqual(env.meta.environment, "production")
        // ServeHTTP builds Meta with only Version+Environment -> workspaceId absent.
        XCTAssertNil(env.meta.workspaceId)

        let stat = try XCTUnwrap(env.evaluations["new-checkout"])
        XCTAssertEqual(stat.reason, .static)
        XCTAssertEqual(stat.value.type, "bool")
        XCTAssertEqual(stat.value.value, .bool(true))
        XCTAssertNil(stat.ruleIndex)  // STATIC omits indexes
        XCTAssertNil(stat.weightedValueIndex)

        let target = try XCTUnwrap(env.evaluations["button-color"])
        XCTAssertEqual(target.reason, .targetingMatch)
        XCTAssertEqual(target.ruleIndex, 0)
        XCTAssertNil(target.weightedValueIndex)
        XCTAssertEqual(target.value.value, .string("green"))

        let split = try XCTUnwrap(env.evaluations["checkout-experiment"])
        XCTAssertEqual(split.reason, .split)
        XCTAssertEqual(split.ruleIndex, 1)
        XCTAssertEqual(split.weightedValueIndex, 2)

        let intCfg = try XCTUnwrap(env.evaluations["rate-limit"])
        XCTAssertEqual(intCfg.value.value, .int(250))  // int stays exact, not double

        let json = try XCTUnwrap(env.evaluations["pricing"])
        if case .object(let obj)? = json.value.value {
            XCTAssertEqual(obj["currency"], .string("USD"))
            XCTAssertEqual(obj["trial"], .bool(true))
            XCTAssertEqual(obj["tiers"], .array([.int(9), .int(29), .int(99)]))
        } else {
            XCTFail("pricing value should decode to an object")
        }
    }

    // MARK: Field-strip — every server-optional must be decodeIfPresent

    /// Removes one optional field at a time from the fixture and asserts the
    /// envelope STILL decodes. A non-optional decode would throw here. (§2.10
    /// Flagsmith #70/#28, Unleash #83/#84.)
    func testFieldStripEveryOptionalDecodes() throws {
        let optionalEvalFields = ["reason", "ruleIndex", "weightedValueIndex"]
        let optionalMetaFields = ["workspaceId"]  // already absent, but assert present-then-stripped too

        for field in optionalEvalFields {
            var root = try fixtureJSON("eval-with-context.response.json")
            var evals = root["evaluations"] as! [String: Any]
            // Strip the field from EVERY evaluation that carries it.
            for (k, v) in evals {
                var e = v as! [String: Any]
                e.removeValue(forKey: field)
                evals[k] = e
            }
            root["evaluations"] = evals
            XCTAssertNoThrow(
                try JSONDecoder().decode(EvalEnvelope.self, from: try encode(root)),
                "stripping eval optional \(field) must not break decode")
        }

        // Inject then strip a workspaceId on meta to prove decodeIfPresent there.
        for field in optionalMetaFields {
            var root = try fixtureJSON("eval-with-context.response.json")
            var meta = root["meta"] as! [String: Any]
            meta[field] = "ws_injected"
            root["meta"] = meta
            let withField = try JSONDecoder().decode(EvalEnvelope.self, from: try encode(root))
            XCTAssertEqual(withField.meta.workspaceId, "ws_injected")

            meta.removeValue(forKey: field)
            root["meta"] = meta
            let withoutField = try JSONDecoder().decode(EvalEnvelope.self, from: try encode(root))
            XCTAssertNil(withoutField.meta.workspaceId)
        }
    }

    // MARK: Unknown reason -> ERROR, never a decode failure

    func testUnknownReasonDecodesAsError() throws {
        var root = try fixtureJSON("eval-with-context.response.json")
        var evals = root["evaluations"] as! [String: Any]
        var e = evals["new-checkout"] as! [String: Any]
        e["reason"] = "QUANTUM_SUPERPOSITION"  // never emitted by the server
        evals["new-checkout"] = e
        root["evaluations"] = evals

        let env = try JSONDecoder().decode(EvalEnvelope.self, from: try encode(root))
        XCTAssertEqual(env.evaluations["new-checkout"]?.reason, .error)
    }

    func testReasonWireInitMapsKnownAndUnknown() {
        XCTAssertEqual(EvaluationReason(wire: "STATIC"), .static)
        XCTAssertEqual(EvaluationReason(wire: "TARGETING_MATCH"), .targetingMatch)
        XCTAssertEqual(EvaluationReason(wire: "SPLIT"), .split)
        XCTAssertEqual(EvaluationReason(wire: "DEFAULT"), .default)
        XCTAssertEqual(EvaluationReason(wire: "ERROR"), .error)
        XCTAssertEqual(EvaluationReason(wire: "totally-unknown"), .error)
    }
}
