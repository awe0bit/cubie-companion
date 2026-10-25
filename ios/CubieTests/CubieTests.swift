import XCTest
import UIKit
@testable import Cubie

final class CubieTests: XCTestCase {
    func testPairingOfferStrictValidation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ticket = String(repeating: "a", count: 24) + "." + String(repeating: "b", count: 43)
        func payload(origin: String = "https://board.example.com", expiry: Double = 1_800_000_300, version: Int = 1) -> String {
            return "{\"type\":\"corenest-pair\",\"version\":\(version),\"endpoint\":\"\(origin)\",\"ticket\":\"\(ticket)\",\"expiresAt\":\(expiry)}"
        }
        XCTAssertEqual(try PairingOffer.parse(payload(), now: now).ticket, ticket)
        XCTAssertThrowsError(try PairingOffer.parse(payload(origin: "http://board.example.com"), now: now))
        XCTAssertThrowsError(try PairingOffer.parse(payload(expiry: 1_799_999_999), now: now))
        XCTAssertThrowsError(try PairingOffer.parse(payload(expiry: 1_800_000_999), now: now))
        XCTAssertThrowsError(try PairingOffer.parse(payload(version: 2), now: now))
        XCTAssertThrowsError(try PairingOffer.parse("https://phishing.example.com", now: now))
    }

    func testPairingUsesFreshDeviceCredential() throws {
        let raw = "{\"type\":\"corenest-pair\",\"version\":1,\"endpoint\":\"https://board.example.com\",\"ticket\":\"" +
            String(repeating: "a", count: 24) + "." + String(repeating: "b", count: 43) +
            "\",\"expiresAt\":\(Date().timeIntervalSince1970 + 200)}"
        let offer = try PairingOffer.parse(raw)
        let first = try PairingClient(offer: offer)
        let second = try PairingClient(offer: offer)
        XCTAssertEqual(first.token.count, 43)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertNotNil(first.token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression))
    }

    func testPairingAccessHandoffValidation() throws {
        try PairingAccess(clientID: String(repeating: "a", count: 32) + ".access",
                          clientSecret: String(repeating: "b", count: 64)).validate()
        XCTAssertThrowsError(try PairingAccess(clientID: "short", clientSecret: String(repeating: "b", count: 64)).validate())
        XCTAssertThrowsError(try PairingAccess(clientID: String(repeating: "a", count: 32), clientSecret: "bad\nheader").validate())
    }

    @MainActor func testBrandAssetsAndPrivacyManifestBundled() throws {
        XCTAssertEqual(Brand.name, "CoreNest")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "栖核")
        XCTAssertNotNil(UIImage(named: "CoreNestMark"))
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        XCTAssertEqual(manifest?["NSPrivacyTracking"] as? Bool, false)
    }

    func testNavigationHasThreeStableTabs() {
        XCTAssertEqual(AppTab.allCases.map(\.rawValue), ["overview", "services", "settings"])
    }

    func testHTTPSRootOnly() throws {
        XCTAssertEqual(try APIClient.normalizedURL("https://BOARD.example.com/").host, "board.example.com")
        for value in ["http://board.example.com", "https://u:p@board.example.com", "https://board.example.com/path",
                      "https://board.example.com?q=token", "https://board.example.com#secret", "https://board.example.com:8443"] {
            XCTAssertThrowsError(try APIClient.normalizedURL(value), value)
        }
    }

    func testMissingCredentialsAndAccessPair() {
        XCTAssertThrowsError(try APIClient(ConnectionCredentials(baseURL: "https://board.example.com",
            apiToken: "", accessClientID: "", accessClientSecret: "")))
        XCTAssertThrowsError(try APIClient(ConnectionCredentials(baseURL: "https://board.example.com",
            apiToken: String(repeating: "x", count: 40), accessClientID: "id", accessClientSecret: "")))
    }

    func testUnknownMeasurementIsNotZero() throws {
        let encoded = try JSONEncoder().encode(Demo.status)
        let result = try JSONDecoder().decode(BoardStatus.self, from: encoded)
        XCTAssertNil(result.powerWatts)
        XCTAssertNil(result.fanRPM)
        XCTAssertEqual(Display.bytes(nil), "—")
    }

    func testDateSupportsPythonMicrosecondsAndUTC() {
        XCTAssertNotNil(Display.date("2026-10-25T07:23:10.265387+00:00"))
        XCTAssertNotNil(Display.date("2026-10-25T07:23:10Z"))
    }

    func testBackendWireFormatWithNullAndIntegerMeasurements() throws {
        let raw = #"{"sampledAt":"2025-01-01T00:00:00.123456+00:00","hostname":"corenest-demo","cpuPercent":null,"memoryUsedBytes":1073741824,"memoryTotalBytes":4294967296,"diskUsedBytes":8589934592,"diskTotalBytes":34359738368,"uptimeSeconds":3600.5,"rxBytesPerSecond":null,"txBytesPerSecond":null,"temperatures":[{"name":"cpu-thermal","celsius":48.5}],"powerWatts":null,"fanRPM":null}"#
        let status = try JSONDecoder().decode(BoardStatus.self, from: Data(raw.utf8))
        XCTAssertNil(status.cpuPercent)
        XCTAssertNil(status.rxBytesPerSecond)
        XCTAssertEqual(status.memoryTotalBytes, 4_294_967_296)
        XCTAssertEqual(status.temperatures.first?.name, "cpu-thermal")
    }

    func testProtectedNetworkServices() {
        XCTAssertFalse(Demo.services.first { $0.id == "campus" }!.controllable)
        XCTAssertFalse(Demo.services.first { $0.id == "tunnel" }!.controllable)
    }

    @MainActor func testDemoNeverAllowsMutations() {
        let store = BoardStore()
        store.showDemo()
        XCTAssertTrue(store.demo)
        XCTAssertFalse(store.canControl)
        XCTAssertFalse(store.canReboot)
        XCTAssertNil(store.lastContact)
        XCTAssertEqual(store.servicesSampledAt, Demo.status.sampledAt)
    }
}
