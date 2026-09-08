import Foundation

struct CodexRadarClient: Sendable {
    // The website's live software-engineering scores replaced the static current.json feed.
    static let publicURL = URL(string: "https://codexradar.com/api/intelligence-efficiency-metrics")!
    static let authorizedURL = URL(string: "https://codexradar.com/api/v1/current")!
    static let visualURL = URL(string: "https://codexradar.com/api/visual-spatial-reasoning")!
    static let newsURL = URL(string: "https://codexradar.com/")!

    let publicEndpoint: URL
    let authorizedEndpoint: URL
    let timeout: TimeInterval
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        publicEndpoint: URL = Self.publicURL,
        authorizedEndpoint: URL = Self.authorizedURL,
        timeout: TimeInterval = 15,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = Self.send
    ) {
        self.publicEndpoint = publicEndpoint
        self.authorizedEndpoint = authorizedEndpoint
        self.timeout = timeout
        self.transport = transport
    }

    func fetch(token: String?, forceRefresh: Bool = false) async throws -> (data: Data, source: CodexRadarDataSource) {
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty {
            return (try await request(url: authorizedEndpoint, token: token), .authorizedAPI)
        }
        var components = URLComponents(url: publicEndpoint, resolvingAgainstBaseURL: false)!
        if forceRefresh { components.queryItems = [URLQueryItem(name: "refresh", value: "1")] }
        return (try await request(url: components.url!, token: nil), .publicMetrics)
    }

    func fetchVisual(forceRefresh: Bool = false) async throws -> Data {
        let url = forceRefresh ? URL(string: Self.visualURL.absoluteString + "?refresh=1")! : Self.visualURL
        return try await request(url: url, token: nil)
    }

    func fetchNews() async throws -> Data {
        try await request(url: Self.newsURL, token: nil)
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
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "codexradar.com"
            && (authorized ? url.path == "/api/v1/current"
                : ["/api/intelligence-efficiency-metrics", "/api/visual-spatial-reasoning", "/"].contains(url.path))
            && (url.port == nil || url.port == 443)
            && (url.query == nil || (!authorized && url.path != "/" && url.query == "refresh=1"))
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

    var errorDescription: String? {
        switch self {
        case .disallowedURL: "CodexRadar 地址不受信任"
        case .invalidResponse: "CodexRadar 返回了无效响应"
        case .httpStatus(let status): status == 401 ? "CodexRadar Token 无效或未授权" : "CodexRadar HTTP \(status)"
        case .emptyResponse: "CodexRadar 返回空数据"
        case .staleResponse: "CodexRadar 暂时只返回过期缓存"
        }
    }
}
