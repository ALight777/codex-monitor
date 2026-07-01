import Foundation

struct CodexRadarClient: Sendable {
    static let publicSummaryURL = URL(string: "https://codexradar.com/current.json")!

    let endpoint: URL
    let timeout: TimeInterval

    init(endpoint: URL = Self.publicSummaryURL, timeout: TimeInterval = 8) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    func fetchPublicSummary() async throws -> Data {
        guard Self.isAllowedPublicSummaryURL(endpoint) else {
            throw CodexRadarClientError.disallowedURL
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let session = URLSession(configuration: configuration)
        defer {
            session.finishTasksAndInvalidate()
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-monitor/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexRadarClientError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw CodexRadarClientError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw CodexRadarClientError.emptyResponse
        }
        return data
    }

    static func isAllowedPublicSummaryURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "codexradar.com",
              url.path == "/current.json",
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }
}

enum CodexRadarClientError: LocalizedError {
    case disallowedURL
    case invalidResponse
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .disallowedURL:
            "Codex Radar 只允许读取公开 current.json"
        case .invalidResponse:
            "Codex Radar 返回了无效响应"
        case .httpStatus(let status):
            "Codex Radar HTTP \(status)"
        case .emptyResponse:
            "Codex Radar 返回空数据"
        }
    }
}
