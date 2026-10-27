import Foundation

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

final class APIClient {
    private let credentials: ConnectionCredentials
    private let baseURL: URL
    private let session: URLSession
    private let controlSession: URLSession

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
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        // Mutation requests must not queue behind periodic telemetry transfers.
        let controlConfiguration = configuration.copy() as! URLSessionConfiguration
        controlConfiguration.httpMaximumConnectionsPerHost = 2
        controlSession = URLSession(configuration: controlConfiguration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel(); controlSession.invalidateAndCancel() }

    func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(path, body: nil)
    }

    func post<T: Decodable>(_ path: String, body: [String: String]) async throws -> T {
        try await request(path, body: body)
    }

    private func request<T: Decodable>(_ path: String, body: [String: String]?) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1").appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(credentials.apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !credentials.accessClientID.isEmpty {
            request.setValue(credentials.accessClientID, forHTTPHeaderField: "CF-Access-Client-Id")
            request.setValue(credentials.accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
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
