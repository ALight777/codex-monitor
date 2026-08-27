import Foundation

struct CodexRadarClient: Sendable {
    static let publicURL = URL(string: "https://codexradar.com/current.json")!
    static let authorizedURL = URL(string: "https://codexradar.com/api/v1/current")!

    let publicEndpoint: URL
    let authorizedEndpoint: URL
    let timeout: TimeInterval

    init(
        publicEndpoint: URL = Self.publicURL,
        authorizedEndpoint: URL = Self.authorizedURL,
        timeout: TimeInterval = 10
    ) {
        self.publicEndpoint = publicEndpoint
        self.authorizedEndpoint = authorizedEndpoint
        self.timeout = timeout
    }

    func fetch(token: String?) async throws -> (data: Data, source: CodexRadarDataSource) {
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty {
            return (try await request(url: authorizedEndpoint, token: token), .authorizedAPI)
        }
        return (try await request(url: publicEndpoint, token: nil), .publicSummary)
    }

    private func request(url: URL, token: String?) async throws -> Data {
        guard Self.isAllowed(url, authorized: token != nil) else {
            throw CodexRadarClientError.disallowedURL
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-monitor/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CodexRadarClientError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw CodexRadarClientError.httpStatus(response.statusCode)
        }
        guard !data.isEmpty else { throw CodexRadarClientError.emptyResponse }
        return data
    }

    static func isAllowed(_ url: URL, authorized: Bool) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "codexradar.com"
            && url.path == (authorized ? "/api/v1/current" : "/current.json")
            && url.user == nil
            && url.password == nil
    }
}

enum CodexRadarClientError: LocalizedError {
    case disallowedURL
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .disallowedURL: "CodexRadar 地址不受信任"
        case .invalidResponse: "CodexRadar 返回了无效响应"
        case .httpStatus(let status): status == 401 ? "CodexRadar Token 无效或未授权" : "CodexRadar HTTP \(status)"
        case .emptyResponse: "CodexRadar 返回空数据"
        }
    }
}
