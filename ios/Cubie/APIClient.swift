import Foundation
import Combine
import Network

enum ConnectionPolicy {
    static func streamIdleTimeout(interval: Int) -> TimeInterval {
        Double(max(8, min(15, max(1, interval)) * 2 + 5))
    }
    static func interval(overview: Bool, settings: Bool = false, economy: Bool,
                         constrained: Bool, thermal: ProcessInfo.ThermalState, expensive: Bool = false) -> Int {
        if economy || constrained || thermal == .serious || thermal == .critical || settings { return 15 }
        return overview && !expensive ? 1 : 5
    }

    static func retryDelay(failures: Int, jitter: Double) -> Double {
        min(30, Double(1 << min(max(failures, 1), 5)) * (1 + min(max(jitter, 0), 1) * 0.2))
    }

    static func blocksAutomaticRetry(_ error: Error) -> Bool {
        switch error {
        case ConnectionError.http(let code): return code == 401 || code == 403 || (300..<400).contains(code)
        case ConnectionError.incompatibleAPI: return true
        default: return false
        }
    }
}

/// System path/power signals only: no ping loops, SSID collection or background keepalive.
@MainActor
final class ConnectionEnvironment: ObservableObject {
    @Published private(set) var revision = 0
    private(set) var available = true
    private(set) var constrained = false
    private(set) var expensive = false
    private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    private let monitor = NWPathMonitor()
    private var signals = Set<AnyCancellable>()

    init() {
        guard !LaunchMode.isUITesting else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.available = path.status != .unsatisfied
                self.constrained = path.isConstrained
                self.expensive = path.isExpensive
                self.revision += 1
            }
        }
        monitor.start(queue: DispatchQueue(label: "corenest.network-path", qos: .utility))
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.thermal = ProcessInfo.processInfo.thermalState
                self.revision += 1
            }.store(in: &signals)
        }
    }

    deinit { monitor.cancel() }
}

enum ConnectionError: LocalizedError {
    case invalidURL, missingToken, accessPair, keychain, unexpectedResponse, incompatibleAPI
    case http(Int), rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入 HTTPS 根地址，不要包含路径、账号、端口、查询参数或片段。"
        case .missingToken: return "请输入该手机独立使用的 API 令牌。"
        case .accessPair: return "Cloudflare Client ID 和 Secret 需要同时填写，或同时留空。"
        case .keychain: return "无法访问钥匙串，请解锁设备后重试。"
        case .unexpectedResponse: return "返回内容不是管理 API 数据，请检查域名与 Access 配置。"
        case .incompatibleAPI: return "管理 API 版本不兼容，请先升级客户端。"
        case .http(401): return "设备令牌无效或已撤销。"
        case .http(403): return "没有访问权限，请检查 Cloudflare Access 与设备权限。"
        case .http(530): return "Cloudflare 隧道暂未连通，请等待设备恢复网络。"
        case .http(let code): return "连接返回 HTTP \(code)，请检查设备与隧道。"
        case .rejected(let code):
            switch code {
            case "preview_mode": return "截图测试模式不会连接真实设备。"
            case "control_not_enabled": return "设备尚未启用远程控制。"
            case "control_unavailable": return "受限控制组件暂不可用。请勿连续重试。"
            case "admin_required": return "当前凭据只有查看权限。"
            case "request_already_seen": return "该请求已经提交，请先刷新服务状态。"
            case "control_cooldown": return "操作过于频繁，请稍候再试；服务启停需间隔 10 秒。"
            case "journal_unavailable": return "设备尚未授予服务事件读取权限。"
            default: return "设备拒绝了本次请求。"
            }
        }
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward API or Access credentials to an authentication redirect.
        completionHandler(nil)
    }
}

private final class StreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func attach(_ value: URLSessionTask) {
        lock.lock(); task = value; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { value.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = task; lock.unlock()
        value?.cancel()
    }
}

final class APIClient {
    private let credentials: ConnectionCredentials
    private let baseURL: URL
    private let session: URLSession
    private let controlSession: URLSession
    private let streamSession: URLSession

    static func normalizedURL(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let url = URL(string: "https://\(host.lowercased())") else {
            throw ConnectionError.invalidURL
        }
        return url
    }

    init(_ credentials: ConnectionCredentials, configuration supplied: URLSessionConfiguration = .ephemeral) throws {
        baseURL = try Self.normalizedURL(credentials.baseURL)
        guard credentials.apiToken.count >= 32,
              credentials.apiToken.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ConnectionError.missingToken
        }
        guard credentials.accessClientID.isEmpty == credentials.accessClientSecret.isEmpty,
              !credentials.accessClientID.contains("\n"), !credentials.accessClientSecret.contains("\n"),
              !credentials.accessClientID.contains("\r"), !credentials.accessClientSecret.contains("\r") else {
            throw ConnectionError.accessPair
        }
        self.credentials = credentials
        let configuration = supplied.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        // Mutation requests must not queue behind periodic telemetry transfers.
        let controlConfiguration = configuration.copy() as! URLSessionConfiguration
        controlConfiguration.httpMaximumConnectionsPerHost = 2
        // Never leave a mutation queued until some later network becomes available.
        controlConfiguration.waitsForConnectivity = false
        controlSession = URLSession(configuration: controlConfiguration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        let streamConfiguration = configuration.copy() as! URLSessionConfiguration
        streamConfiguration.timeoutIntervalForRequest = 45
        streamConfiguration.timeoutIntervalForResource = 120
        streamConfiguration.httpMaximumConnectionsPerHost = 1
        streamSession = URLSession(configuration: streamConfiguration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel(); controlSession.invalidateAndCancel(); streamSession.invalidateAndCancel() }

    func snapshots(interval: Int = 1, adaptive: Bool = false,
                   receive: @MainActor (DashboardSnapshot) throws -> Void) async throws {
        var request = authorizedRequest("events")
        request.timeoutInterval = ConnectionPolicy.streamIdleTimeout(interval: adaptive ? interval : 1)
        if adaptive { request.setValue(String([1, 5, 15].contains(interval) ? interval : 5), forHTTPHeaderField: "X-CoreNest-Interval") }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let cancellation = StreamCancellation()
        try await withTaskCancellationHandler {
        let (bytes, response) = try await streamSession.bytes(for: request)
        cancellation.attach(bytes.task)
        defer { cancellation.cancel() }
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.unexpectedResponse }
        guard response.statusCode == 200 else { throw ConnectionError.http(response.statusCode) }
        guard response.mimeType == "text/event-stream" else { throw ConnectionError.unexpectedResponse }
        var parser = SnapshotEventDecoder()
        for try await byte in bytes {
            try Task.checkCancellation()
            if let snapshot = try parser.append(byte) { try await receive(snapshot) }
        }
        guard parser.complete else { throw ConnectionError.unexpectedResponse }
        } onCancel: { cancellation.cancel() }
    }

    func cancelControls() { controlSession.getAllTasks { $0.forEach { $0.cancel() } } }

    private func authorizedRequest(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1").appendingPathComponent(path))
        request.setValue("Bearer \(credentials.apiToken)", forHTTPHeaderField: "Authorization")
        if !credentials.accessClientID.isEmpty {
            request.setValue(credentials.accessClientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(credentials.accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return request
    }

    func get<T: Decodable>(_ path: String, timeout: TimeInterval? = nil) async throws -> T {
        try await request(path, body: nil, timeout: timeout)
    }

    func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        try await request(path, body: body)
    }

    private func request<T: Decodable>(_ path: String, body: [String: String]?, timeout: TimeInterval? = nil) async throws -> T {
        var request = authorizedRequest(path)
        if let timeout { request.timeoutInterval = max(1, min(12, timeout)) }
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        // No application-level retries, especially for POST with an uncertain outcome.
        let transport = body == nil ? session : controlSession
        let (data, response) = try await transport.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.unexpectedResponse }
        guard response.statusCode == 200 else {
            if let problem = try? JSONDecoder().decode(APIProblem.self, from: data), response.statusCode != 401 {
                throw ConnectionError.rejected(problem.error)
            }
            throw ConnectionError.http(response.statusCode)
        }
        guard data.count < 1_048_576, response.mimeType == "application/json" else {
            throw ConnectionError.unexpectedResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Strict bounded decoder for our single-line JSON event protocol. No unbounded `.lines` allocation.
struct SnapshotEventDecoder {
    private var line = Data()
    private var payload = Data()
    private var event = ""
    private var size = 0
    private(set) var complete = true
    private(set) var received = false

    mutating func append(_ byte: UInt8) throws -> DashboardSnapshot? {
        size += 1
        guard size <= 131_200 else { throw ConnectionError.unexpectedResponse }
        complete = false
        if byte != 10 { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            defer { event = ""; payload.removeAll(keepingCapacity: true); size = 0; complete = true }
            if event == "unavailable" { throw ConnectionError.http(503) }
            guard event == "snapshot", !payload.isEmpty else { return nil }
            let result = try JSONDecoder().decode(DashboardSnapshot.self, from: payload)
            received = true
            return result
        }
        guard let value = String(data: line, encoding: .utf8) else { throw ConnectionError.unexpectedResponse }
        if value.hasPrefix("event: ") { event = String(value.dropFirst(7)) }
        if value.hasPrefix("data: ") {
            guard payload.isEmpty else { throw ConnectionError.unexpectedResponse }
            payload = Data(value.dropFirst(6).utf8)
        }
        return nil
    }
}
