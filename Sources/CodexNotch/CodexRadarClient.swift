import Foundation

struct CodexRadarClient: Sendable {
    static let authorizedURL = URL(string: "https://codexradar.com/api/v1/current")!
    static let threeTaskURL = URL(string: "https://codexradar.com/data/codex-three-task-results.json")!
    static let fourTaskURL = URL(string: "https://codexradar.com/data/codex-four-task-results.json")!
    static let newsURL = URL(string: "https://codexradar.com/")!

    let authorizedEndpoint: URL
    let timeout: TimeInterval
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        authorizedEndpoint: URL = Self.authorizedURL,
        timeout: TimeInterval = 15,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = Self.send
    ) {
        self.authorizedEndpoint = authorizedEndpoint
        self.timeout = timeout
        self.transport = transport
    }

    func fetchAuthorized(token: String) async throws -> Data {
        try await request(url: authorizedEndpoint, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func fetchHomepage() async throws -> Data {
        try await request(url: Self.newsURL, token: nil)
    }

    func fetchPublicData() async -> (homepage: Result<Data, Error>, scores: Result<Data, Error>) {
        do {
            let html = try await fetchHomepage()
            do {
                if Self.links(to: Self.fourTaskURL, in: html) {
                    let source = try await request(url: Self.fourTaskURL, token: nil)
                    let document = try CodexRadarFourTaskDocument.assemble(homepage: html, source: source)
                    return (.success(html), .success(try document.encode()))
                }
                let source: Data
                if let embedded = try? CodexRadarThreeTaskPayload.extract(from: html) {
                    source = embedded
                } else if Self.links(to: Self.threeTaskURL, in: html) {
                    source = try await request(url: Self.threeTaskURL, token: nil)
                } else {
                    throw CodexRadarClientError.unsupportedFormat
                }
                let document = try CodexRadarThreeTaskDocument.assemble(homepage: html, source: source)
                return (.success(html), .success(try document.encode()))
            } catch { return (.success(html), .failure(error)) }
        } catch { return (.failure(error), .failure(error)) }
    }

    private static func links(to endpoint: URL, in data: Data) -> Bool {
        guard data.count <= 8_000_000, let html = String(data: data, encoding: .utf8) else { return false }
        let pattern = #"(?is)<a\b[^>]*\bhref\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).contains { match in
            guard let range = Range(match.range(at: 1), in: html) else { return false }
            return URL(string: String(html[range]), relativeTo: Self.newsURL)?.absoluteURL == endpoint
        }
    }

    private func request(url: URL, token: String?) async throws -> Data {
        guard Self.isAllowed(url, authorized: token != nil) else {
            throw CodexRadarClientError.disallowedURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(url.path == "/" ? "text/html" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-monitor/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await transport(request)
        guard let response = response as? HTTPURLResponse else {
            throw CodexRadarClientError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw CodexRadarClientError.httpStatus(response.statusCode)
        }
        if token == nil, let cacheStatus = response.value(forHTTPHeaderField: "X-Codex-Cache")?.uppercased(),
           cacheStatus.hasPrefix("STALE") || cacheStatus == "ERROR" {
            throw CodexRadarClientError.staleResponse
        }
        guard !data.isEmpty else { throw CodexRadarClientError.emptyResponse }
        return data
    }

    static func isAllowed(_ url: URL, authorized: Bool) -> Bool {
        return url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "codexradar.com"
            && (authorized ? url.path == "/api/v1/current"
                : ["/", threeTaskURL.path, fourTaskURL.path].contains(url.path))
            && (url.port == nil || url.port == 443)
            && url.query == nil
            && url.user == nil
            && url.password == nil
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}

enum CodexRadarClientError: LocalizedError {
    case disallowedURL
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse
    case staleResponse
    case unsupportedFormat
    case inconsistentSources

    var errorDescription: String? {
        switch self {
        case .disallowedURL: "CodexRadar 地址不受信任"
        case .invalidResponse: "CodexRadar 返回了无效响应"
        case .httpStatus(let status): status == 401 ? "CodexRadar Token 无效或未授权" : "CodexRadar HTTP \(status)"
        case .emptyResponse: "CodexRadar 返回空数据"
        case .inconsistentSources: "CodexRadar 首页与分项数据暂不一致，保留上次有效缓存"
        case .unsupportedFormat: "CodexRadar 官网数据格式已变化，需更新应用适配"
        case .staleResponse: "CodexRadar 暂时只返回过期缓存"
        }
    }
}
