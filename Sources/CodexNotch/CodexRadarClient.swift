import Darwin
import Foundation

struct CodexRadarClient: Sendable {
    static let publicSummaryURL = URL(string: "https://codexradar.com/current.json")!
    static let authorizedCurrentURL = URL(string: "https://codexradar.com/api/v1/current")!

    let publicEndpoint: URL
    let authorizedEndpoint: URL
    let tokenProvider: CodexRadarTokenProvider
    let timeout: TimeInterval

    init(
        publicEndpoint: URL = Self.publicSummaryURL,
        authorizedEndpoint: URL = Self.authorizedCurrentURL,
        tokenProvider: CodexRadarTokenProvider = CodexRadarTokenProvider(),
        timeout: TimeInterval = 8
    ) {
        self.publicEndpoint = publicEndpoint
        self.authorizedEndpoint = authorizedEndpoint
        self.tokenProvider = tokenProvider
        self.timeout = timeout
    }

    func fetchSummary() async throws -> CodexRadarFetchResult {
        if let token = tokenProvider.token() {
            let data = try await fetch(endpoint: authorizedEndpoint, source: .authorizedAPI, bearerToken: token)
            return CodexRadarFetchResult(data: data, source: .authorizedAPI)
        }

        let data = try await fetch(endpoint: publicEndpoint, source: .publicSummary, bearerToken: nil)
        return CodexRadarFetchResult(data: data, source: .publicSummary)
    }

    func fetchPublicSummary() async throws -> Data {
        try await fetch(endpoint: publicEndpoint, source: .publicSummary, bearerToken: nil)
    }

    private func fetch(endpoint: URL, source: CodexRadarDataSource, bearerToken: String?) async throws -> Data {
        guard Self.isAllowedURL(endpoint, source: source) else {
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
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

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

    static func isAllowedURL(_ url: URL, source: CodexRadarDataSource) -> Bool {
        switch source {
        case .authorizedAPI:
            isAllowedAuthorizedAPIURL(url)
        case .publicSummary:
            isAllowedPublicSummaryURL(url)
        }
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

    static func isAllowedAuthorizedAPIURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "codexradar.com",
              url.path == "/api/v1/current",
              url.user == nil,
              url.password == nil else {
            return false
        }
        return true
    }
}

struct CodexRadarFetchResult: Sendable {
    let data: Data
    let source: CodexRadarDataSource
}

struct CodexRadarTokenProvider: Sendable {
    static let environmentKey = "CODEXRADAR_API_TOKEN"

    let environment: [String: String]
    let tokenFileURL: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tokenFileURL: URL = Self.defaultTokenFileURL()
    ) {
        self.environment = environment
        self.tokenFileURL = tokenFileURL
    }

    func token() -> String? {
        if let environmentToken = Self.trimmedToken(environment[Self.environmentKey]) {
            return environmentToken
        }
        return Self.trimmedToken(Self.loadSavedToken(from: tokenFileURL))
    }

    static func defaultTokenFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("CodexNotch", isDirectory: true)
            .appendingPathComponent("CodexRadar", isDirectory: true)
            .appendingPathComponent("token")
    }

    static func loadSavedToken(from tokenFileURL: URL = defaultTokenFileURL()) -> String {
        guard let data = try? Data(contentsOf: tokenFileURL) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func saveToken(_ token: String, to tokenFileURL: URL = defaultTokenFileURL()) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = tokenFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)

        guard !trimmed.isEmpty else {
            if FileManager.default.fileExists(atPath: tokenFileURL.path) {
                try FileManager.default.removeItem(at: tokenFileURL)
            }
            return
        }

        try Data(trimmed.utf8).write(to: tokenFileURL, options: .atomic)
        chmod(tokenFileURL.path, S_IRUSR | S_IWUSR)
    }

    private static func trimmedToken(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
            "Codex Radar 只允许读取官方 API 或公开 summary"
        case .invalidResponse:
            "Codex Radar 返回了无效响应"
        case .httpStatus(let status):
            "Codex Radar HTTP \(status)"
        case .emptyResponse:
            "Codex Radar 返回空数据"
        }
    }
}
