import Foundation
import XCTest

@testable import Quonfig

/// Duration getter + `string_list` getter (qfg-2agi.14, Swift half).
///
/// The duration cases come from the shared ISO-8601 grammar fixture
/// (`integration-test-data/tests/duration/grammar.yaml`, qfg-2agi.29). CI checks
/// out sdk-swift alone, so the fixture is vendored as
/// `Fixtures/duration-grammar.yaml`; `testVendoredFixtureMatchesIntegrationTestData`
/// fails when the vendored copy drifts from a sibling integration-test-data
/// checkout (and skips when there is no sibling checkout).
final class DurationTests: XCTestCase {
    // MARK: - Fixture loading

    struct Grammar {
        var valid: [(value: String, millis: Int64)] = []
        var invalid: [String] = []
    }

    /// The vendored fixture's text.
    private func vendoredFixtureText() throws -> String {
        guard
            let url = Bundle.module.url(
                forResource: "duration-grammar.yaml", withExtension: nil, subdirectory: "Fixtures")
        else {
            XCTFail("missing fixture: Fixtures/duration-grammar.yaml")
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Minimal reader for the fixture's two line shapes (no YAML dependency):
    ///   - { value: "<yaml double-quoted string>", millis: <int> }
    ///   - "<yaml double-quoted string>"
    private func parseGrammar(_ text: String) throws -> Grammar {
        var grammar = Grammar()
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("valid:") {
                section = "valid"
                continue
            }
            if line.hasPrefix("invalid:") {
                section = "invalid"
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            let item = String(trimmed.dropFirst(2))
            switch section {
            case "valid":
                // { value: "...", millis: N }
                guard let valueStart = item.range(of: "value: \""),
                    let millisRange = item.range(of: ", millis: ")
                else { throw fixtureError("bad valid line: \(line)") }
                let quoted = "\"" + item[valueStart.upperBound..<millisRange.lowerBound]
                let millisText = item[millisRange.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " }"))
                guard let millis = Int64(millisText) else { throw fixtureError("bad millis: \(line)") }
                grammar.valid.append((try unquote(quoted), millis))
            case "invalid":
                grammar.invalid.append(try unquote(item))
            default:
                continue
            }
        }
        return grammar
    }

    /// Decode a YAML double-quoted scalar (the escapes the fixture uses).
    private func unquote(_ quoted: String) throws -> String {
        guard quoted.count >= 2, quoted.first == "\"", quoted.last == "\"" else {
            throw fixtureError("not a double-quoted string: \(quoted)")
        }
        let body = Array(quoted.dropFirst().dropLast())
        var out = ""
        var i = 0
        while i < body.count {
            let c = body[i]
            if c != "\\" {
                out.append(c)
                i += 1
                continue
            }
            guard i + 1 < body.count else { throw fixtureError("dangling escape: \(quoted)") }
            let e = body[i + 1]
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\\": out.append("\\")
            case "\"": out.append("\"")
            case "u":
                guard i + 5 < body.count,
                    let scalar = UInt32(String(body[(i + 2)...(i + 5)]), radix: 16).flatMap(Unicode.Scalar.init)
                else { throw fixtureError("bad \\u escape: \(quoted)") }
                out.unicodeScalars.append(scalar)
                i += 6
                continue
            default:
                throw fixtureError("unsupported escape \\\(e): \(quoted)")
            }
            i += 2
        }
        return out
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "DurationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func grammar() throws -> Grammar {
        let g = try parseGrammar(try vendoredFixtureText())
        // Guard against a reader bug silently producing an empty table.
        XCTAssertGreaterThan(g.valid.count, 10)
        XCTAssertGreaterThan(g.invalid.count, 10)
        return g
    }

    // MARK: - Envelope builders

    private func eval(type: String, value: QuonfigJSONValue) -> Evaluation {
        Evaluation(
            value: WireValue(type: type, value: value),
            configId: "cfg", configType: "config", valueType: type,
            reason: .static, ruleIndex: nil, weightedValueIndex: nil)
    }

    private func store(_ evaluations: [String: Evaluation]) async -> Store {
        let store = Store()
        await store.apply(
            EvalEnvelope(
                evaluations: evaluations,
                meta: EvalMeta(version: "1", environment: "production")))
        return store
    }

    // MARK: - Fixture drift

    func testVendoredFixtureMatchesIntegrationTestData() throws {
        let sibling = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // QuonfigTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // sdk-swift
            .deletingLastPathComponent()  // monorepo root
            .appendingPathComponent("integration-test-data/tests/duration/grammar.yaml")
        guard FileManager.default.fileExists(atPath: sibling.path) else {
            throw XCTSkip("no sibling integration-test-data checkout at \(sibling.path)")
        }
        let upstream = try String(contentsOf: sibling, encoding: .utf8)
        XCTAssertEqual(
            try vendoredFixtureText(), upstream,
            "Fixtures/duration-grammar.yaml drifted from integration-test-data; copy it over")
    }

    // MARK: - Duration grammar (public getter path)

    func testValidDurationsReturnExpectedMillis() async throws {
        let g = try grammar()
        var evals: [String: Evaluation] = [:]
        for (i, c) in g.valid.enumerated() {
            evals["d\(i)"] = eval(type: "duration", value: .string(c.value))
        }
        let s = await store(evals)
        for (i, c) in g.valid.enumerated() {
            let seconds = s.duration("d\(i)", default: -1)
            XCTAssertEqual(
                Int64((seconds * 1000).rounded()), c.millis,
                "duration(\(c.value.debugDescription)) seconds=\(seconds)")
            let d = s.details("d\(i)")
            XCTAssertEqual(d.reason, .static, "details(\(c.value.debugDescription)).reason")
            XCTAssertEqual(d.value, .string(c.value), "details(\(c.value.debugDescription)).value")
        }
    }

    func testInvalidDurationsReturnDefaultAndErrorDetails() async throws {
        let g = try grammar()
        var evals: [String: Evaluation] = [:]
        for (i, value) in g.invalid.enumerated() {
            evals["d\(i)"] = eval(type: "duration", value: .string(value))
        }
        let s = await store(evals)
        for (i, value) in g.invalid.enumerated() {
            XCTAssertEqual(s.duration("d\(i)", default: 7.5), 7.5, "duration(\(value.debugDescription))")
            let d = s.details("d\(i)")
            XCTAssertEqual(d.reason, .error, "details(\(value.debugDescription)).reason")
            // The raw malformed string is never surfaced as the value.
            XCTAssertNil(d.value, "details(\(value.debugDescription)).value")
        }
    }

    func testDurationDefaultsForAbsentWrongTypeAndNonStringWire() async {
        let s = await store([
            "str": eval(type: "string", value: .string("PT5S")),
            "num": eval(type: "duration", value: .int(5000)),
            "obj": eval(type: "duration", value: .object(["definition": .string("PT5S")])),
        ])
        XCTAssertEqual(s.duration("missing", default: 3), 3)
        // A string config holding an ISO string is not a duration config.
        XCTAssertEqual(s.duration("str", default: 3), 3)
        XCTAssertEqual(s.duration("num", default: 3), 3)
        XCTAssertEqual(s.duration("obj", default: 3), 3)
    }

    func testDurationLogExposureVariant() async {
        let s = await store(["d": eval(type: "duration", value: .string("PT1.5S"))])
        XCTAssertEqual(s.duration("d", default: 0, logExposure: false), 1.5)
    }

    // MARK: - string_list getter

    func testStringListGetter() async {
        let s = await store([
            "hosts": eval(type: "string_list", value: .array([.string("a"), .string("b")])),
            "empty": eval(type: "string_list", value: .array([])),
            "mixed": eval(type: "string_list", value: .array([.string("a"), .int(1)])),
            "str": eval(type: "string", value: .string("a")),
        ])
        XCTAssertEqual(s.stringList("hosts", default: ["x"]), ["a", "b"])
        XCTAssertEqual(s.stringList("empty", default: ["x"]), [])
        XCTAssertEqual(s.stringList("mixed", default: ["x"]), ["x"])
        XCTAssertEqual(s.stringList("str", default: ["x"]), ["x"])
        XCTAssertEqual(s.stringList("missing", default: ["x"]), ["x"])
        XCTAssertEqual(s.stringList("hosts", default: [], logExposure: false), ["a", "b"])
    }
}
