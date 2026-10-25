import Foundation
import CryptoKit
import Security

struct PairingOffer: Decodable {
    let type: String
    let version: Int
    let endpoint: String
    let ticket: String
    let expiresAt: Double

    static func parse(_ text: String, now: Date = Date()) throws -> PairingOffer {
        guard text.utf8.count <= 1024,
              let offer = try? JSONDecoder().decode(PairingOffer.self, from: Data(text.utf8)),
              offer.type == "corenest-pair", offer.version == 1,
              offer.ticket.range(of: "^[a-f0-9]{24}\\.[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              offer.expiresAt.isFinite, offer.expiresAt > now.timeIntervalSince1970,
              offer.expiresAt <= now.timeIntervalSince1970 + 330 else {
            throw ConnectionError.rejected("二维码无效或已过期。请在部署终端生成新的配对码。")
        }
        _ = try APIClient.normalizedURL(offer.endpoint)
        return offer
    }
}

struct PairingResult: Decodable {
    let state: String
    let deviceId: String?
    let verificationCode: String?
}

final class PairingClient {
    let offer: PairingOffer
    let token: String
    private let session: URLSession
    private let base: URL

    init(offer: PairingOffer) throws {
        self.offer = offer
        base = try APIClient.normalizedURL(offer.endpoint)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ConnectionError.keychain
        }
        token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 18
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func begin(name: String) async throws -> PairingResult {
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return try await request("request", body: ["ticket": offer.ticket, "tokenSHA256": hash, "name": name])
    }

    func result() async throws -> PairingResult { try await request("result", body: nil) }

    private func request(_ path: String, body: [String: String]?) async throws -> PairingResult {
        var request = URLRequest(url: base.appendingPathComponent("v1/pairing/" + path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        } else {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        // Never retry a registration automatically. Redirects and certificate bypasses are forbidden.
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.unexpectedResponse }
        guard response.statusCode == 200 else {
            if [301, 302, 303, 307, 308, 403].contains(response.statusCode) {
                throw ConnectionError.rejected("HTTPS 入口被 Cloudflare Access 拦截。请先完成手机专用接入配置，不要关闭 Access。")
            }
            throw ConnectionError.http(response.statusCode)
        }
        guard response.mimeType == "application/json", data.count < 16384 else {
            throw ConnectionError.unexpectedResponse
        }
        return try JSONDecoder().decode(PairingResult.self, from: data)
    }
}
