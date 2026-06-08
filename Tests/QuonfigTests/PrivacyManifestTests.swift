import XCTest

@testable import Quonfig

/// Verifies the App Store privacy manifest is actually wired into the SPM resource
/// bundle (plan §1, §2.10). The Statsig trap (#7) is shipping `PrivacyInfo.xcprivacy`
/// at the repo root but NOT into `Package.swift` resources, so SPM consumers never
/// bundle it. This test fails if the manifest stops landing in `Bundle.module`, and
/// asserts the declared contents (NSPrivacyTracking=false, empty tracking domains,
/// UserDefaults CA92.1, no FileTimestamp, honest collected data types).
final class PrivacyManifestTests: XCTestCase {
    private func manifestURL() throws -> URL {
        // Quonfig's OWN resource bundle (built by SPM from the `.process` rule).
        // NOTE: a test target's `Bundle.module` is the *test* bundle, so we reach
        // into the Quonfig module's accessor to assert the manifest shipped with the
        // library, which is the whole point (Statsig trap #7).
        return try XCTUnwrap(
            PrivacyManifest.url,
            "PrivacyInfo.xcprivacy is NOT in Quonfig's Bundle.module — the resource is not wired into Package.swift (Statsig trap #7)."
        )
    }

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: try manifestURL())
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any], "Privacy manifest is not a plist dictionary.")
    }

    func testManifestIsBundled() throws {
        // The whole point: it must resolve out of the built bundle.
        XCTAssertNoThrow(try manifestURL())
    }

    func testNSPrivacyTrackingIsExplicitlyFalse() throws {
        let plist = try manifest()
        let tracking = try XCTUnwrap(
            plist["NSPrivacyTracking"] as? Bool,
            "NSPrivacyTracking must be present (Statsig omits it — Apple wants it present)."
        )
        XCTAssertFalse(tracking, "NSPrivacyTracking must be false.")
    }

    func testTrackingDomainsIsEmpty() throws {
        let plist = try manifest()
        let domains = try XCTUnwrap(
            plist["NSPrivacyTrackingDomains"] as? [Any],
            "NSPrivacyTrackingDomains must be present as an (empty) array."
        )
        // Populating this broke Flagsmith v3.6.0 for ATT-declined users (#57).
        XCTAssertTrue(domains.isEmpty, "NSPrivacyTrackingDomains must be EMPTY.")
    }

    func testUserDefaultsReasonDeclaredAndNoFileTimestamp() throws {
        let plist = try manifest()
        let apiTypes = try XCTUnwrap(
            plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "NSPrivacyAccessedAPITypes must be present."
        )

        // UserDefaults CA92.1 is mandatory (Persistence uses our own suite).
        let userDefaults = apiTypes.first {
            ($0["NSPrivacyAccessedAPIType"] as? String) == "NSPrivacyAccessedAPICategoryUserDefaults"
        }
        let ud = try XCTUnwrap(userDefaults, "UserDefaults required-reason API not declared.")
        let reasons = try XCTUnwrap(ud["NSPrivacyAccessedAPITypeReasons"] as? [String])
        XCTAssertEqual(reasons, ["CA92.1"], "UserDefaults reason must be CA92.1.")

        // FileTimestamp (C617.1) must NOT be declared: the persistence audit confirms
        // the file cache never reads contentModificationDate/stat (recency is the
        // in-record `savedAt`). Declaring an API we don't use is wrong too.
        let hasFileTimestamp = apiTypes.contains {
            ($0["NSPrivacyAccessedAPIType"] as? String) == "NSPrivacyAccessedAPICategoryFileTimestamp"
        }
        XCTAssertFalse(
            hasFileTimestamp,
            "FileTimestamp must NOT be declared — the file cache does not read timestamps."
        )
    }

    func testCollectedDataTypesAreHonest() throws {
        let plist = try manifest()
        let collected = try XCTUnwrap(
            plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]],
            "NSPrivacyCollectedDataTypes must be present."
        )
        let typeIds = collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertTrue(typeIds.contains("NSPrivacyCollectedDataTypeUserID"), "Must declare User ID.")
        XCTAssertTrue(typeIds.contains("NSPrivacyCollectedDataTypeDeviceID"), "Must declare Device ID.")

        // Every declared type is linked:true / tracking:false (context on the eval URL).
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        }
    }
}
