import Foundation
import Combine

struct AppRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let html_url: URL
    let assets: [Asset]
    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var ipa: URL? {
        assets.first { $0.name == "CoreNest-\(version)-iOS-unsigned.ipa" && Self.trusted($0.browser_download_url) }?.browser_download_url
    }
    var eligible: Bool {
        !draft && !prerelease && Self.parts(version) != nil && Self.trusted(html_url) && ipa != nil &&
        assets.contains { $0.name == "SHA256SUMS.txt" && Self.trusted($0.browser_download_url) }
    }
    static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
        url.port == nil && url.query == nil && url.fragment == nil &&
        url.path.hasPrefix("/awe0bit/cubie-companion/releases/")
    }
    static func parts(_ value: String) -> [Int]? {
        let values = value.split(separator: ".", omittingEmptySubsequences: false)
        guard values.count == 3, values.allSatisfy({ !$0.isEmpty && $0.count <= 8 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = values.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }
    static func newer(_ lhs: String, than rhs: String) -> Bool {
        guard let a = parts(lhs), let b = parts(rhs) else { return false }
        return b.lexicographicallyPrecedes(a)
    }
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking, current, unpublished, available(AppRelease), failed
    }
    @Published private(set) var state: State = .idle
    private var lastCheck: Date?
    private let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    func check(force: Bool = false) async {
        guard state != .checking else { return }
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 3600 { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/awe0bit/cubie-companion/releases?per_page=50")!)
            request.timeoutInterval = 15
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("CoreNest/\(Brand.version)", forHTTPHeaderField: "User-Agent")
            // Public release request has no board/Cloudflare credential headers.
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 2_000_000 else {
                state = .failed; return
            }
            let releases = try JSONDecoder().decode([AppRelease].self, from: data)
                .filter(\.eligible).sorted { AppRelease.newer($0.version, than: $1.version) }
            lastCheck = Date()
            guard let latest = releases.first else { state = .unpublished; return }
            state = AppRelease.newer(latest.version, than: Brand.version) ? .available(latest) : .current
        } catch { state = Task.isCancelled ? .idle : .failed }
    }
}
