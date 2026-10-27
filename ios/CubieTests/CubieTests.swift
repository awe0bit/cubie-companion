import XCTest
import UIKit
@testable import Cubie

final class CubieTests: XCTestCase {
    func testConnectionPolicyUsesPowerNetworkAndThermalSignals() {
        XCTAssertEqual(ConnectionPolicy.interval(overview: true, economy: false, constrained: false, thermal: .nominal), 1)
        XCTAssertEqual(ConnectionPolicy.interval(overview: false, economy: false, constrained: false, thermal: .nominal), 5)
        XCTAssertEqual(ConnectionPolicy.interval(overview: true, economy: false, constrained: false, thermal: .nominal, expensive: true), 5)
        XCTAssertEqual(ConnectionPolicy.interval(overview: true, economy: true, constrained: false, thermal: .nominal), 15)
        XCTAssertEqual(ConnectionPolicy.interval(overview: true, economy: false, constrained: true, thermal: .nominal), 15)
        XCTAssertEqual(ConnectionPolicy.interval(overview: true, economy: false, constrained: false, thermal: .serious), 15)
        XCTAssertEqual(ConnectionPolicy.interval(overview: false, settings: true, economy: false, constrained: false, thermal: .nominal), 15)
        XCTAssertEqual(ConnectionPolicy.retryDelay(failures: 1, jitter: 0), 2)
        XCTAssertEqual(ConnectionPolicy.retryDelay(failures: 99, jitter: 1), 30)
        for code in [301, 302, 401, 403] { XCTAssertTrue(ConnectionPolicy.blocksAutomaticRetry(ConnectionError.http(code))) }
        for code in [429, 503, 530] { XCTAssertFalse(ConnectionPolicy.blocksAutomaticRetry(ConnectionError.http(code))) }
    }

    @MainActor private func controlStore(confirm: Bool = true, fail: Bool = false) throws -> BoardStore {
        let caps = try JSONDecoder().decode(Capabilities.self, from: Data(#"{"apiVersion":1,"role":"admin","serviceControl":true,"deviceReboot":false,"rawLogs":false,"dockerControl":false,"ledControl":false,"powerMeasurement":false,"fanRPM":false,"managementInventory":true,"deviceInventory":true,"snapshotBundle":true,"adaptiveStreaming":true}"#.utf8))
        let bundle = DashboardSnapshot(status: Demo.status, services: ServiceList(sampledAt: Demo.status.sampledAt,
            services: [BoardService(id: "panel", unit: "1panel-core.service", name: "Panel", state: "inactive", controllable: true)]),
            network: Demo.network, capabilities: caps, management: Demo.management, inventory: Demo.inventory)
        let initial = try JSONEncoder().encode(bundle)
        var changed = try JSONSerialization.jsonObject(with: initial) as! [String: Any]
        var services = changed["services"] as! [String: Any]
        var item = (services["services"] as! [[String: Any]])[0]
        item["state"] = "active"
        services["services"] = [item]
        services["sampledAt"] = "2026-10-25T07:23:11Z"
        changed["services"] = services
        let confirmed = try JSONSerialization.data(withJSONObject: changed)
        ControlProtocol.prepare(initial: initial, confirmed: confirm ? confirmed : initial, fail: fail)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlProtocol.self]
        let client = try APIClient(ConnectionCredentials(baseURL: "https://control.example.com",
            apiToken: String(repeating: "t", count: 40), accessClientID: "", accessClientSecret: ""), configuration: configuration)
        return BoardStore(testClient: client, confirmationDelays: [0, 0])
    }

    @MainActor func testServiceControlConfirmsFreshStateAndPostsOnlyOnce() async throws {
        let store = try controlStore()
        await store.refresh()
        let service = try XCTUnwrap(store.services.first)
        XCTAssertTrue(store.serviceActionAllowed(service, action: "start"))
        XCTAssertFalse(store.serviceActionAllowed(service, action: "stop"))
        await store.act(service: service, action: "start")
        XCTAssertEqual(ControlProtocol.posts, 1)
        XCTAssertEqual(store.operation?.phase, .confirmed)
        XCTAssertEqual(store.services.first?.state, "active")
        XCTAssertFalse(store.operating)
        XCTAssertTrue(store.controlsCoolingDown)
    }

    @MainActor func testUncertainMutationIsNotRetriedOrReportedAsSuccess() async throws {
        let store = try controlStore(fail: true)
        await store.refresh()
        await store.act(service: try XCTUnwrap(store.services.first), action: "start")
        XCTAssertEqual(ControlProtocol.posts, 1)
        XCTAssertEqual(store.operation?.phase, .uncertain)
        XCTAssertFalse(store.operating)
    }

    @MainActor func testAcceptedButUnchangedStateRemainsUnconfirmed() async throws {
        let store = try controlStore(confirm: false)
        await store.refresh()
        await store.act(service: try XCTUnwrap(store.services.first), action: "start")
        XCTAssertEqual(ControlProtocol.posts, 1)
        XCTAssertEqual(store.operation?.phase, .uncertain)
        XCTAssertEqual(store.services.first?.state, "inactive")
    }

    @MainActor func testNoNetworkDoesNotPollAndPauseDisablesControl() async throws {
        let store = try controlStore()
        await store.receiveLiveUpdates(interval: 15, networkAvailable: false)
        XCTAssertEqual(ControlProtocol.requests, 0)
        XCTAssertEqual(store.connectionPhase, .offline)
        XCTAssertTrue(store.stale)
        store.pauseConnection()
        XCTAssertEqual(store.connectionPhase, .paused)
        XCTAssertFalse(store.canControl)
    }

    @MainActor func testRefreshCoalescesPollAndPullIntoOneSnapshotRequest() async throws {
        let caps = try JSONDecoder().decode(Capabilities.self, from: Data(#"{"apiVersion":1,"role":"viewer","serviceControl":false,"deviceReboot":false,"rawLogs":false,"dockerControl":false,"ledControl":false,"powerMeasurement":false,"fanRPM":false,"managementInventory":true,"deviceInventory":true,"snapshotBundle":true}"#.utf8))
        let body = try JSONEncoder().encode(DashboardSnapshot(status: Demo.status,
            services: ServiceList(sampledAt: Demo.status.sampledAt, services: Demo.services),
            network: Demo.network, capabilities: caps, management: Demo.management, inventory: Demo.inventory))
        SnapshotProtocol.prepare(body)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SnapshotProtocol.self]
        let credentials = ConnectionCredentials(baseURL: "https://board.example.com", apiToken: String(repeating: "v", count: 40), accessClientID: "", accessClientSecret: "")
        let client = try APIClient(credentials, configuration: config)
        let store = BoardStore(testClient: client)
        async let poll: Void = store.refresh()
        async let pull: Void = store.refresh(manual: true)
        _ = await (poll, pull)
        XCTAssertEqual(SnapshotProtocol.requestCount, 1)
        XCTAssertEqual(store.status?.hostname, Demo.status.hostname)
        XCTAssertEqual(store.management?.leds.count, 2)
        XCTAssertFalse(store.refreshing)
        XCTAssertFalse(store.userRefreshing)
        XCTAssertNil(store.error)
    }
    func testLEDReadbackIsAuthoritativeAndProtectsAgainstOldSamples() throws {
        let readback = LEDReadback(id: "demo:blue", mode: "off", sampledAt: "2026-10-27T00:00:06.123Z")
        XCTAssertTrue(readback.valid)
        XCTAssertTrue(readback.isNewer(than: "2026-10-27T00:00:05Z"))
        XCTAssertFalse(readback.isNewer(than: "2026-10-27T00:00:07Z"))
        let result = Demo.management.applying([readback])
        XCTAssertEqual(result.leds.first?.mode, "off")
        XCTAssertEqual(result.leds.last?.mode, Demo.management.leds.last?.mode)
        XCTAssertEqual(result.containers.count, Demo.management.containers.count)
        XCTAssertEqual(result.leds.first?.controllable, false)
        XCTAssertFalse(LEDReadback(id: "x", mode: "unknown", sampledAt: readback.sampledAt).valid)
        let old = try JSONDecoder().decode(Accepted.self, from: Data(#"{"accepted":true}"#.utf8))
        XCTAssertNil(old.led)
    }
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

    func testNavigationHasFourStableTabs() {
        XCTAssertEqual(AppTab.allCases.map(\.rawValue), ["overview", "services", "devices", "settings"])
    }

    func testRealtimeDecoderHandlesFragmentedUTF8HeartbeatsAndConsecutiveEvents() throws {
        let caps = try JSONDecoder().decode(Capabilities.self, from: Data(#"{"apiVersion":1,"role":"viewer","serviceControl":false,"deviceReboot":false,"rawLogs":false,"dockerControl":false,"ledControl":false,"powerMeasurement":false,"fanRPM":false,"liveSnapshots":true}"#.utf8))
        let bundle = DashboardSnapshot(status: Demo.status, services: ServiceList(sampledAt: Demo.status.sampledAt, services: Demo.services),
            network: Demo.network, capabilities: caps, management: Demo.management, inventory: Demo.inventory)
        let data = try JSONEncoder().encode(bundle)
        var parser = SnapshotEventDecoder()
        var count = 0
        let frame = Data("event: snapshot\r\ndata: ".utf8) + data + Data("\r\n\r\n: heartbeat\n\n".utf8)
        for byte in frame + frame {
            if let result = try parser.append(byte) {
                count += 1
                XCTAssertEqual(result.management?.leds.first?.name, "蓝色状态灯")
            }
        }
        XCTAssertEqual(count, 2)
        XCTAssertTrue(parser.complete)
    }

    func testRealtimeDecoderRejectsOversizeMalformedAndUnavailableEvents() {
        for bytes in [Data(repeating: 65, count: 131_201), Data("event: snapshot\ndata: not-json\n\n".utf8),
                      Data("event: unavailable\ndata: {}\n\n".utf8)] {
            var parser = SnapshotEventDecoder()
            XCTAssertThrowsError(try bytes.forEach { _ = try parser.append($0) })
        }
        var partial = SnapshotEventDecoder()
        _ = try? partial.append(65)
        XCTAssertFalse(partial.complete)
    }

    @MainActor func testManagementFixturesAndBridgeDoNotGrantControl() throws {
        let store = BoardStore()
        store.showDemo()
        XCTAssertFalse(store.managementReady)
        XCTAssertEqual(store.management?.leds.first?.modeText, "跟随系统")
        XCTAssertTrue(store.management?.containers.allSatisfy { !$0.controllable } == true)
        let snapshot = RuntimeBridge.snapshot(store)
        XCTAssertNotNil(snapshot["management"])
        XCTAssertFalse(RuntimeBridge.json(store).contains("clientSecret"))
    }

    func testReleaseVersionComparisonIsNumericAndStrict() {
        XCTAssertTrue(AppRelease.newer("0.10.0", than: "0.9.9"))
        XCTAssertFalse(AppRelease.newer("0.6.0", than: "0.6.0"))
        for invalid in ["1.2", "-1.2.3", "1.2.3-beta", "1..3", "999999999999.0.0", "１.２.３"] {
            XCTAssertNil(AppRelease.parts(invalid), invalid)
        }
    }

    func testReleaseRequiresCorrectPlatformRepositoryAndChecksums() throws {
        let raw = #"{"tag_name":"v0.7.0","body":"Notes","draft":false,"prerelease":false,"html_url":"https://github.com/awe0bit/cubie-companion/releases/tag/v0.7.0","assets":[{"name":"CoreNest-0.7.0-iOS-unsigned.ipa","browser_download_url":"https://github.com/awe0bit/cubie-companion/releases/download/v0.7.0/CoreNest-0.7.0-iOS-unsigned.ipa"},{"name":"SHA256SUMS.txt","browser_download_url":"https://github.com/awe0bit/cubie-companion/releases/download/v0.7.0/SHA256SUMS.txt"}]}"#
        func release(_ value: String) throws -> AppRelease { try JSONDecoder().decode(AppRelease.self, from: Data(value.utf8)) }
        XCTAssertTrue(try release(raw).eligible)
        XCTAssertFalse(try release(raw.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true")).eligible)
        XCTAssertFalse(try release(raw.replacingOccurrences(of: "iOS-unsigned.ipa", with: "Android.apk")).eligible)
        XCTAssertFalse(try release(raw.replacingOccurrences(of: "SHA256SUMS.txt", with: "missing.txt")).eligible)
        XCTAssertFalse(try release(raw.replacingOccurrences(of: "github.com", with: "other.example.com")).eligible)
        XCTAssertFalse(AppRelease.trusted(URL(string: "https://github.com/awe0bit/other/releases/tag/v1.0.0")!))
        XCTAssertFalse(AppRelease.trusted(URL(string: "http://github.com/awe0bit/cubie-companion/releases/tag/v1.0.0")!))
    }

    @MainActor func testRuntimeSnapshotExcludesCredentialsAndAddresses() throws {
        let store = BoardStore()
        store.showDemo()
        let snapshot = RuntimeBridge.snapshot(store)
        XCTAssertEqual(snapshot["demo"] as? Bool, true)
        let json = RuntimeBridge.json(store)
        XCTAssertNotNil(json.data(using: .utf8))
        for key in ["endpoint", "apiToken", "accessClientID", "accessClientSecret", "baseURL", "credentials"] {
            XCTAssertNil(snapshot[key])
            XCTAssertFalse(json.contains("\"\(key)\""))
        }
        XCTAssertTrue(json.contains("stateText"))
        XCTAssertTrue(json.contains("inventory"))
    }

    func testHardwareWireFormatAndOldCapabilityCompatibility() throws {
        let raw = #"{"sampledAt":"2026-01-01T09:41:00Z","board":{"model":"Fixture board","architecture":"aarch64","kernel":"Linux","cpuCores":4,"memoryBytes":4294967296},"devices":[{"id":"usb:fixture","category":"usb","name":"Fixture camera","node":"1-2","bus":"usb","driver":"uvcvideo","state":"detected","vendorID":"1234","productID":"5678","speedMbps":480}]}"#
        let inventory = try JSONDecoder().decode(DeviceInventory.self, from: Data(raw.utf8))
        XCTAssertEqual(inventory.devices.first?.stateText, "已识别")
        XCTAssertNil(inventory.devices.first?.capacityBytes)
        XCTAssertEqual(inventory.board.cpuCores, 4)
        let old = #"{"apiVersion":1,"role":"viewer","serviceControl":false,"deviceReboot":false,"rawLogs":false,"dockerControl":false,"ledControl":false,"powerMeasurement":false,"fanRPM":false}"#
        XCTAssertNil(try JSONDecoder().decode(Capabilities.self, from: Data(old.utf8)).deviceInventory)
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
        XCTAssertEqual(Demo.status.memoryTotalBytes, Demo.inventory.board.memoryBytes)
    }
}

private final class SnapshotProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func prepare(_ value: Data) { lock.lock(); defer { lock.unlock() }; body = value; count = 0 }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "board.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; let data = Self.body; Self.lock.unlock()
        guard request.url?.path == "/v1/snapshot", request.httpMethod == "GET" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ControlProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var initial = Data(), confirmed = Data()
    private static var fail = false, postCount = 0, requestCount = 0
    static var posts: Int { lock.lock(); defer { lock.unlock() }; return postCount }
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return requestCount }
    static func prepare(initial: Data, confirmed: Data, fail: Bool) {
        lock.lock(); defer { lock.unlock() }
        Self.initial = initial; Self.confirmed = confirmed; Self.fail = fail; postCount = 0; requestCount = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "control.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let isPost = request.httpMethod == "POST"
        if isPost { Self.postCount += 1 }
        let fail = Self.fail && isPost
        let body = isPost ? Data(#"{"accepted":true}"#.utf8) : Self.postCount > 0 ? Self.confirmed : Self.initial
        Self.lock.unlock()
        if fail { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        guard isPost ? request.url?.path == "/v1/services/panel/actions" : request.url?.path == "/v1/snapshot" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
