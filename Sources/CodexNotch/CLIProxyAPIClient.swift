import Foundation

struct CLIProxyAPIConfiguration: Equatable, Sendable {
    let panelURL: String
    let managementKey: String
    let timeout: TimeInterval
    let allowInsecureTLS: Bool
}

enum CLIProxyAPIError: LocalizedError {
    case invalidURL
    case missingKey
    case missingAuthIndex
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "面板地址无效"
        case .missingKey:
            "缺少管理密钥"
        case .missingAuthIndex:
            "账号缺少 auth_index"
        case .httpStatus(let status):
            status == 401 || status == 403 ? "管理密钥无效或无权限" : "面板返回 HTTP \(status)"
        case .emptyResponse:
            "面板返回空数据"
        }
    }
}

final class CLIProxyAPIClient: NSObject, URLSessionDelegate {
    private let configuration: CLIProxyAPIConfiguration

    init(configuration: CLIProxyAPIConfiguration) {
        self.configuration = configuration
    }

    func fetchCodexAccounts() async throws -> [RemoteCodexAccount] {
        try await fetchCodexAccounts(dataSource: .cpaManagerPlus)
    }

    func fetchCodexAccounts(dataSource: RemoteCodexDataSource) async throws -> [RemoteCodexAccount] {
        guard !configuration.managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIProxyAPIError.missingKey
        }
        guard let baseURL = Self.managementBaseURL(from: configuration.panelURL) else {
            throw CLIProxyAPIError.invalidURL
        }

        let authFilesData = try await authenticatedGET(
            baseURL.appendingPathComponent("auth-files"),
            timeout: configuration.timeout
        )
        let authFiles = try JSONDecoder().decode(CLIProxyAuthFilesResponse.self, from: authFilesData).files
        guard dataSource == .cpaManagerPlus else {
            return Self.authFileAccounts(from: authFiles)
        }

        guard let inspectionRunData = try? await fetchLatestCodexInspectionRunDetailData(baseURL: baseURL) else {
            return Self.authFileAccounts(from: authFiles)
        }

        do {
            let accounts = try Self.remoteAccounts(
                from: JSONDecoder().decode(CodexInspectionRunDetailResponse.self, from: inspectionRunData).results,
                authFiles: authFiles
            )
            return accounts.isEmpty ? Self.authFileAccounts(from: authFiles) : accounts
        } catch {
            return Self.authFileAccounts(from: authFiles)
        }
    }

    func fetchResetCredits(
        authIndex: String,
        accountID: String?,
        now: Date = Date()
    ) async throws -> RateLimitResetCredits? {
        guard !configuration.managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIProxyAPIError.missingKey
        }
        let normalizedAuthIndex = authIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAuthIndex.isEmpty else {
            throw CLIProxyAPIError.missingAuthIndex
        }

        let baseURL = try managementBaseURL()
        let request = try Self.resetCreditsProxyRequest(
            managementBaseURL: baseURL,
            managementKey: configuration.managementKey,
            authIndex: normalizedAuthIndex,
            accountID: accountID,
            timeout: configuration.timeout
        )
        let data = try await authenticatedData(for: request, timeout: configuration.timeout)
        return try Self.decodeResetCreditsProxyResponse(data, now: now)
    }

    static func resetCreditsProxyRequest(
        managementBaseURL: URL,
        managementKey: String,
        authIndex: String,
        accountID: String?,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
            "OpenAI-Beta": "codex-1",
            "Originator": "Codex Desktop"
        ]
        if let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            headers["Chatgpt-Account-Id"] = accountID
        }

        var request = URLRequest(url: managementBaseURL.appendingPathComponent("api-call"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            CLIProxyAPICallRequest(
                authIndex: authIndex,
                method: "GET",
                url: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
                header: headers
            )
        )
        return request
    }

    private func authenticatedGET(_ endpoint: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(configuration.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return try await authenticatedData(for: request, timeout: timeout)
    }

    private func authenticatedData(for request: URLRequest, timeout: TimeInterval) async throws -> Data {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = timeout
        sessionConfig.timeoutIntervalForResource = timeout
        let session = URLSession(
            configuration: sessionConfig,
            delegate: configuration.allowInsecureTLS ? self : nil,
            delegateQueue: nil
        )
        defer {
            session.finishTasksAndInvalidate()
        }

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw CLIProxyAPIError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw CLIProxyAPIError.emptyResponse
        }
        return data
    }

    private func fetchLatestCodexInspectionRunDetailData(baseURL: URL) async throws -> Data? {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("codex-inspection")
                .appendingPathComponent("runs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: "5")]
        guard let runsEndpoint = components?.url else {
            return nil
        }

        let runsData = try await authenticatedGET(runsEndpoint, timeout: configuration.timeout)
        let runs = try JSONDecoder().decode(CodexInspectionRunsResponse.self, from: runsData)
        guard let run = runs.items.first(where: { $0.status?.lowercased() == "completed" }) ?? runs.items.first else {
            return nil
        }

        return try await authenticatedGET(
            baseURL
                .appendingPathComponent("codex-inspection")
                .appendingPathComponent("runs")
                .appendingPathComponent(String(run.id)),
            timeout: configuration.timeout
        )
    }

    static func decodeCodexInspectionAccounts(
        authFilesData: Data,
        inspectionRunData: Data
    ) throws -> [RemoteCodexAccount] {
        let authFiles = try JSONDecoder().decode(CLIProxyAuthFilesResponse.self, from: authFilesData).files
        let detail = try JSONDecoder().decode(CodexInspectionRunDetailResponse.self, from: inspectionRunData)
        let accounts = remoteAccounts(from: detail.results, authFiles: authFiles)
        return accounts.isEmpty ? authFileAccounts(from: authFiles) : accounts
    }

    func fetchManagerPlusUsageTotals(now: Date = Date()) async throws -> PeriodUsage {
        guard !configuration.managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIProxyAPIError.missingKey
        }
        let baseURL = try managementBaseURL()
        let endMS = Self.milliseconds(from: now)
        let hourMS: Int64 = 60 * 60 * 1_000

        async let day = fetchManagerPlusUsageTotal(
            baseURL: baseURL,
            fromMS: endMS - 24 * hourMS,
            toMS: endMS
        )
        async let week = fetchManagerPlusUsageTotal(
            baseURL: baseURL,
            fromMS: endMS - 7 * 24 * hourMS,
            toMS: endMS
        )
        async let month = fetchManagerPlusUsageTotal(
            baseURL: baseURL,
            fromMS: endMS - 30 * 24 * hourMS,
            toMS: endMS
        )

        let dayTotal = try await day
        let weekTotal = try await week
        let monthTotal = try await month
        return PeriodUsage(day: dayTotal, week: weekTotal, month: monthTotal)
    }

    private func fetchManagerPlusUsageTotal(baseURL: URL, fromMS: Int64, toMS: Int64) async throws -> Int {
        let endpoint = baseURL
            .appendingPathComponent("monitoring")
            .appendingPathComponent("analytics")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(configuration.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            ManagerPlusAnalyticsRequest(
                fromMS: fromMS,
                toMS: toMS,
                filters: ManagerPlusAnalyticsFilters(includeFailed: true),
                include: ManagerPlusAnalyticsInclude(summary: true)
            )
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = configuration.timeout
        sessionConfig.timeoutIntervalForResource = configuration.timeout
        let session = URLSession(
            configuration: sessionConfig,
            delegate: configuration.allowInsecureTLS ? self : nil,
            delegateQueue: nil
        )
        defer {
            session.finishTasksAndInvalidate()
        }

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw CLIProxyAPIError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            return 0
        }
        let decoded = try JSONDecoder().decode(ManagerPlusAnalyticsResponse.self, from: data)
        return decoded.summary?.totalTokens ?? 0
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard configuration.allowInsecureTLS,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    static func managementBaseURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        guard components.user == nil, components.password == nil else {
            return nil
        }

        guard scheme == "https" || scheme == "http" else {
            return nil
        }
        if scheme == "http", !isLocalHost(host) {
            return nil
        }

        components.query = nil
        components.fragment = nil
        components.scheme = scheme

        let path = components.path
        if let range = path.range(of: "/v0/management") {
            components.path = String(path[..<range.upperBound])
        } else {
            components.path = "/v0/management"
        }

        return components.url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    private func managementBaseURL() throws -> URL {
        guard let baseURL = Self.managementBaseURL(from: configuration.panelURL) else {
            throw CLIProxyAPIError.invalidURL
        }
        return baseURL
    }

    private static func milliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func isEnabledCodexAccount(_ file: CLIProxyAuthFile) -> Bool {
        guard file.disabled != true else {
            return false
        }

        let markers = [
            file.provider,
            file.type,
            file.accountType,
            file.name,
            file.id,
            file.account
        ]
        return markers.compactMap { $0?.lowercased() }.contains { $0.contains("codex") }
    }

    private static func authFileAccounts(from files: [CLIProxyAuthFile]) -> [RemoteCodexAccount] {
        files
            .filter(isEnabledCodexAccount(_:))
            .enumerated()
            .map { index, file in
                remoteAccount(from: file, fallbackIndex: index)
            }
            .sorted(by: remoteAccountSort(_:_:))
    }

    private static func remoteAccounts(
        from results: [CodexInspectionResult],
        authFiles: [CLIProxyAuthFile]
    ) -> [RemoteCodexAccount] {
        let filesByAuthIndex = Dictionary(
            authFiles.compactMap { file -> (String, CLIProxyAuthFile)? in
                guard let authIndex = file.authIndex, !authIndex.isEmpty else {
                    return nil
                }
                return (authIndex, file)
            },
            uniquingKeysWith: { current, _ in current }
        )
        let filesByName = Dictionary(
            authFiles.compactMap { file -> (String, CLIProxyAuthFile)? in
                guard let name = file.name, !name.isEmpty else {
                    return nil
                }
                return (name, file)
            },
            uniquingKeysWith: { current, _ in current }
        )

        return results
            .filter(isCodexInspectionResult(_:))
            .enumerated()
            .compactMap { index, result -> RemoteCodexAccount? in
                let file = result.authIndex.flatMap { filesByAuthIndex[$0] }
                    ?? result.fileName.flatMap { filesByName[$0] }
                guard result.disabled != true, file?.disabled != true else {
                    return nil
                }
                return remoteAccount(from: result, authFile: file, fallbackIndex: index)
            }
            .sorted(by: remoteAccountSort(_:_:))
    }

    private static func isCodexInspectionResult(_ result: CodexInspectionResult) -> Bool {
        let markers = [
            result.provider,
            result.fileName,
            result.accountKey,
            result.displayAccount
        ]
        return markers.compactMap { $0?.lowercased() }.contains { $0.contains("codex") }
    }

    private static func remoteAccount(
        from result: CodexInspectionResult,
        authFile file: CLIProxyAuthFile?,
        fallbackIndex: Int
    ) -> RemoteCodexAccount {
        let recentFailures = file?.recentRequests?.reduce(0) { $0 + ($1.failed ?? 0) } ?? 0
        let stableID = result.authIndex
            ?? file?.authIndex
            ?? result.accountId
            ?? result.accountKey
            ?? result.fileName
            ?? "codex-inspection-\(fallbackIndex)"
        let displayAccount = result.displayAccount?.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = file?.email ?? (displayAccount?.contains("@") == true ? displayAccount : nil)
        let statusMessage = result.actionReason ?? file?.statusMessage

        return RemoteCodexAccount(
            id: stableID,
            name: file?.name ?? result.fileName ?? displayAccount ?? "Codex 账号",
            email: email,
            label: file?.label,
            provider: result.provider ?? file?.provider,
            accountType: file?.accountType,
            authIndex: result.authIndex ?? file?.authIndex,
            chatgptAccountID: file?.idToken?.chatgptAccountID,
            status: result.status ?? file?.status,
            statusMessage: statusMessage,
            successCount: file?.success,
            failureCount: file?.failed,
            recentFailures: recentFailures,
            state: inspectionState(from: result),
            lastRefresh: result.createdAtText ?? file?.lastRefresh,
            planType: file?.idToken?.planType ?? planType(fromFileName: result.fileName),
            quotaWindows: inspectionQuotaWindows(from: result),
            quotaError: nil,
            unavailable: false
        )
    }

    private static func inspectionState(from result: CodexInspectionResult) -> RemoteAccountState {
        let action = result.action?.lowercased() ?? ""
        let status = result.status?.lowercased() ?? ""
        let reason = result.actionReason?.lowercased() ?? ""

        if inspectionQuotaWindows(from: result).accountAlertWindows.contains(where: \.reachesThreshold)
            || result.isQuota == true
            || reasonIndicatesQuotaExhaustion(reason) {
            return .quotaExhausted
        }

        if action == "reauth"
            || action == "disable"
            || action == "delete"
            || reason.contains("重新登录")
            || reason.contains("unauthorized")
            || result.statusCode == 401
            || result.statusCode == 403 {
            return .abnormal
        }

        if action == "keep", result.statusCode.map({ (200...299).contains($0) }) != false {
            return .healthy
        }

        let healthyStatuses = ["active", "available", "enabled", "normal", "ready", "ok", "healthy", "valid"]
        if status.isEmpty || healthyStatuses.contains(status) {
            return .healthy
        }

        return .abnormal
    }

    private static func reasonIndicatesQuotaExhaustion(_ reason: String) -> Bool {
        let exhaustedMarkers = [
            "额度达到阈值",
            "额度已满",
            "额度用完",
            "配额耗尽",
            "配额已满",
            "usage_limit_reached",
            "usage limit has been reached",
            "usage limit reached",
            "limit reached",
            "quota exhausted",
            "quota reached",
            "quota exceeded",
            "insufficient_quota"
        ]
        return exhaustedMarkers.contains { reason.contains($0) }
    }

    private static func inspectionQuotaWindows(from result: CodexInspectionResult) -> [RemoteQuotaWindow] {
        if !result.quotaWindows.isEmpty {
            return result.quotaWindows.enumerated().map { index, window in
                let prefix = window.labelName
                let fallbackBaseLabel = inspectionQuotaLabel(from: result.actionReason)
                let fallbackLabel = prefix.map { "\($0) \(fallbackBaseLabel)" } ?? fallbackBaseLabel
                return window.remoteWindow(
                    id: "inspection-\(window.id ?? String(index))",
                    fallbackPrefix: prefix,
                    fallbackLabel: fallbackLabel,
                    limitReached: result.isQuota == true
                )
            }
        }

        guard let usedPercent = result.usedPercent else {
            return []
        }

        let used = min(100, max(0, usedPercent))
        let remaining = Int((100 - used).rounded())
        let label = inspectionQuotaLabel(from: result.actionReason)
        return [
            RemoteQuotaWindow(
                id: "inspection-\(label)",
                shortLabel: label,
                remainingPercent: remaining,
                usedPercent: used,
                resetText: nil,
                limitReached: result.isQuota == true
            )
        ]
    }

    private static func inspectionQuotaLabel(from reason: String?) -> String {
        let text = reason?.lowercased() ?? ""
        if text.contains("5小时") || text.contains("5h") {
            return "5h"
        }
        if text.contains("周") || text.contains("7d") || text.contains("weekly") {
            return "7d"
        }
        if text.contains("月") || text.contains("30d") {
            return "30d"
        }
        return "额度"
    }

    private static func planType(fromFileName fileName: String?) -> String? {
        guard let fileName = fileName?.lowercased() else {
            return nil
        }
        if fileName.contains("prolite") || fileName.contains("pro-lite") {
            return "prolite"
        }
        if fileName.contains("pro") {
            return "pro"
        }
        if fileName.contains("team") {
            return "team"
        }
        if fileName.contains("plus") {
            return "plus"
        }
        return nil
    }

    private static func remoteAccountSort(_ lhs: RemoteCodexAccount, _ rhs: RemoteCodexAccount) -> Bool {
        if lhs.state.severity != rhs.state.severity {
            return lhs.state.severity > rhs.state.severity
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func remoteAccount(from file: CLIProxyAuthFile, fallbackIndex: Int) -> RemoteCodexAccount {
        let status = file.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        let statusMessage = file.statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentFailures = file.recentRequests?.reduce(0) { $0 + ($1.failed ?? 0) } ?? 0
        let recentSuccesses = file.recentRequests?.reduce(0) { $0 + ($1.success ?? 0) } ?? 0
        let state = classify(
            status: status,
            message: statusMessage,
            unavailable: file.unavailable == true,
            failures: file.failed ?? 0,
            recentFailures: recentFailures,
            recentSuccesses: recentSuccesses
        )

        let stableID = file.authIndex ?? file.id ?? file.email ?? file.name ?? "codex-account-\(fallbackIndex)"
        return RemoteCodexAccount(
            id: stableID,
            name: file.name ?? file.id ?? "Codex 账号",
            email: file.email,
            label: file.label,
            provider: file.provider,
            accountType: file.accountType,
            authIndex: file.authIndex,
            chatgptAccountID: file.idToken?.chatgptAccountID,
            status: status,
            statusMessage: statusMessage,
            successCount: file.success,
            failureCount: file.failed,
            recentFailures: recentFailures,
            state: state,
            lastRefresh: file.lastRefresh,
            planType: file.idToken?.planType,
            quotaWindows: [],
            quotaError: nil,
            unavailable: file.unavailable == true
        )
    }

    static func decodeQuotaBody(
        _ data: Data,
        fallbackPlanType: String?
    ) throws -> (planType: String?, windows: [RemoteQuotaWindow]) {
        if let errorText = quotaPayloadErrorText(from: data) {
            throw CLIProxyQuotaResponseError.upstream(errorText)
        }

        let body = try JSONDecoder().decode(CodexQuotaBody.self, from: data)
        guard !body.quotaWindows.isEmpty else {
            throw CLIProxyQuotaResponseError.missingBody(nil)
        }
        return (
            planType: body.normalizedPlanType ?? fallbackPlanType,
            windows: body.quotaWindows
        )
    }

    static func decodeQuotaProxyResponse(
        _ data: Data,
        fallbackPlanType: String?
    ) throws -> (planType: String?, windows: [RemoteQuotaWindow]) {
        let decoded = try JSONDecoder().decode(CLIProxyAPICallResponse.self, from: data)
        guard (200...299).contains(decoded.statusCode) else {
            throw CLIProxyQuotaResponseError.upstream(decoded.errorText ?? "上游 HTTP \(decoded.statusCode)")
        }
        guard let quotaBodyData = decoded.bodyData else {
            throw CLIProxyQuotaResponseError.missingBody(decoded.errorText)
        }
        return try decodeQuotaBody(quotaBodyData, fallbackPlanType: fallbackPlanType)
    }

    static func decodeResetCreditsProxyResponse(
        _ data: Data,
        now: Date = Date()
    ) throws -> RateLimitResetCredits? {
        let decoded = try JSONDecoder().decode(CLIProxyAPICallResponse.self, from: data)
        guard (200...299).contains(decoded.statusCode) else {
            throw CLIProxyResetCreditsResponseError.upstream(
                status: decoded.statusCode,
                message: decoded.errorText
            )
        }
        guard let bodyData = decoded.bodyData else {
            return nil
        }
        return try RateLimitResetCreditsDecoder.decode(bodyData, now: now)
    }

    private static func quotaPayloadErrorText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let error = object["error"] {
            return readableErrorText(from: error)
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    private static func readableErrorText(from value: Any) -> String {
        if let text = value as? String, !text.isEmpty {
            return text
        }

        if let object = value as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let type = object["type"] as? String, !type.isEmpty {
                return type
            }
        }

        return String(describing: value)
    }

    private static func classify(
        status: String?,
        message: String?,
        unavailable: Bool,
        failures: Int,
        recentFailures: Int,
        recentSuccesses: Int
    ) -> RemoteAccountState {
        let combined = [status, message]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        let quotaMarkers = [
            "quota",
            "usage_limit_reached",
            "usage limit",
            "rate limit",
            "429",
            "exceeded",
            "insufficient_quota",
            "额度",
            "配额",
            "用完",
            "限制"
        ]
        if quotaMarkers.contains(where: { combined.contains($0) }) {
            return .quotaExhausted
        }

        let normalizedStatus = status?.lowercased() ?? ""
        let healthyStatuses = ["active", "available", "enabled", "normal", "ready", "ok", "healthy", "valid"]
        let statusLooksHealthy = normalizedStatus.isEmpty || healthyStatuses.contains(normalizedStatus)
        let messageLooksHealthy = (message?.isEmpty ?? true) || message?.lowercased() == "ok"

        if unavailable || !statusLooksHealthy || !messageLooksHealthy {
            return .abnormal
        }

        if failures > 0 && recentFailures >= 2 && recentSuccesses == 0 {
            return .abnormal
        }

        if failures > 0 && recentFailures >= 3 {
            let recentTotal = max(1, recentFailures + recentSuccesses)
            let failureRate = Double(recentFailures) / Double(recentTotal)
            if failureRate >= 0.2 {
                return .abnormal
            }
        }

        return .healthy
    }
}

private struct CodexInspectionRunsResponse: Decodable {
    let items: [CodexInspectionRunSummary]
}

private struct CodexInspectionRunSummary: Decodable {
    let id: Int
    let status: String?
}

private struct CodexInspectionRunDetailResponse: Decodable {
    let results: [CodexInspectionResult]
}

private struct CodexInspectionResult: Decodable {
    let accountKey: String?
    let fileName: String?
    let displayAccount: String?
    let authIndex: String?
    let accountId: String?
    let provider: String?
    let disabled: Bool?
    let status: String?
    let action: String?
    let actionReason: String?
    let actionStatus: String?
    let statusCode: Int?
    let usedPercent: Double?
    let quotaWindows: [CodexQuotaWindow]
    let isQuota: Bool?
    let createdAtMS: Int64?

    enum CodingKeys: String, CodingKey {
        case accountKey
        case fileName
        case displayAccount
        case authIndex
        case accountId
        case provider
        case disabled
        case status
        case action
        case actionReason
        case actionStatus
        case statusCode
        case usedPercent
        case quotaWindows
        case isQuota
        case createdAtMS = "createdAtMs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountKey = Self.flexibleString(from: container, key: .accountKey)
        fileName = Self.flexibleString(from: container, key: .fileName)
        displayAccount = Self.flexibleString(from: container, key: .displayAccount)
        authIndex = Self.flexibleString(from: container, key: .authIndex)
        accountId = Self.flexibleString(from: container, key: .accountId)
        provider = Self.flexibleString(from: container, key: .provider)
        disabled = Self.flexibleBool(from: container, key: .disabled)
        status = Self.flexibleString(from: container, key: .status)
        action = Self.flexibleString(from: container, key: .action)
        actionReason = Self.flexibleString(from: container, key: .actionReason)
        actionStatus = Self.flexibleString(from: container, key: .actionStatus)
        statusCode = Self.flexibleInt(from: container, key: .statusCode)
        usedPercent = Self.flexibleDouble(from: container, key: .usedPercent)
        quotaWindows = (try? container.decodeIfPresent([CodexQuotaWindow].self, forKey: .quotaWindows)) ?? []
        isQuota = Self.flexibleBool(from: container, key: .isQuota)
        createdAtMS = Self.flexibleInt64(from: container, key: .createdAtMS)
    }

    var createdAtText: String? {
        guard let createdAtMS else {
            return nil
        }
        let date = Date(timeIntervalSince1970: Double(createdAtMS) / 1_000)
        let formatter = DateFormatter()
        formatter.dateFormat = "M-d HH:mm"
        return formatter.string(from: date)
    }

    private static func flexibleString(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    private static func flexibleBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1"].contains(normalized) {
                return true
            }
            if ["false", "no", "0"].contains(normalized) {
                return false
            }
        }
        return nil
    }

    private static func flexibleInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key),
           let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Int(number.rounded())
        }
        return nil
    }

    private static func flexibleInt64(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int64? {
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int64(value.rounded())
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key),
           let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Int64(number.rounded())
        }
        return nil
    }

    private static func flexibleDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key),
           let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return number
        }
        return nil
    }
}

private struct ManagerPlusAnalyticsRequest: Encodable {
    let fromMS: Int64
    let toMS: Int64
    let filters: ManagerPlusAnalyticsFilters
    let include: ManagerPlusAnalyticsInclude

    enum CodingKeys: String, CodingKey {
        case fromMS = "from_ms"
        case toMS = "to_ms"
        case filters
        case include
    }
}

private struct ManagerPlusAnalyticsFilters: Encodable {
    let includeFailed: Bool

    enum CodingKeys: String, CodingKey {
        case includeFailed = "include_failed"
    }
}

private struct ManagerPlusAnalyticsInclude: Encodable {
    let summary: Bool
}

private struct ManagerPlusAnalyticsResponse: Decodable {
    let summary: ManagerPlusAnalyticsSummary?
}

private struct CLIProxyAPICallRequest: Encodable {
    let authIndex: String
    let method: String
    let url: String
    let header: [String: String]
}

private struct ManagerPlusAnalyticsSummary: Decodable {
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int.self, forKey: .totalTokens) {
            totalTokens = value
            return
        }
        if let value = try? container.decode(Double.self, forKey: .totalTokens) {
            totalTokens = Int(value.rounded())
            return
        }
        if let value = try? container.decode(String.self, forKey: .totalTokens),
           let number = Double(value) {
            totalTokens = Int(number.rounded())
            return
        }
        totalTokens = 0
    }
}

private struct CLIProxyAPICallResponse: Decodable {
    let statusCode: Int
    let bodyData: Data?
    let errorText: String?

    enum CodingKeys: String, CodingKey {
        case statusCodeSnake = "status_code"
        case statusCodeCamel = "statusCode"
        case body
        case bodyTextSnake = "body_text"
        case bodyTextCamel = "bodyText"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = Self.flexibleStatusCode(from: container)

        for key in [CodingKeys.body, .bodyTextSnake, .bodyTextCamel] {
            if let payload = Self.payload(from: container, key: key),
               payload.data != nil || payload.errorText != nil {
                bodyData = payload.data
                errorText = payload.errorText
                return
            }
        }

        bodyData = nil
        errorText = nil
    }

    private static func flexibleStatusCode(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> Int {
        for key in [CodingKeys.statusCodeSnake, .statusCodeCamel] {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let status = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return status
            }
        }
        return 0
    }

    private static func payload(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> (data: Data?, errorText: String?)? {
        guard container.contains(key), (try? container.decodeNil(forKey: key)) != true else {
            return nil
        }

        if let bodyText = try? container.decode(String.self, forKey: key) {
            let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            guard let data = trimmed.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return (nil, trimmed)
            }
            return (data, readableErrorText(from: data))
        }

        if let object = try? container.decode(JSONValue.self, forKey: key),
           let data = try? JSONEncoder().encode(object) {
            return (data, readableErrorText(from: data))
        }

        return nil
    }

    private static func readableErrorText(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let type = error["type"] as? String, !type.isEmpty {
                return type
            }
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        if let message = object["message"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }
}

private enum CLIProxyResetCreditsResponseError: LocalizedError {
    case upstream(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .upstream(let status, let message):
            let prefix = status > 0
                ? "重置次数上游返回 HTTP \(status)"
                : "重置次数代理响应缺少上游状态码"
            guard let message, !message.isEmpty else {
                return prefix
            }
            return "\(prefix)：\(message)"
        }
    }
}

private enum CLIProxyQuotaResponseError: LocalizedError {
    case upstream(String)
    case missingBody(String?)

    var errorDescription: String? {
        switch self {
        case .upstream(let message):
            return message
        case .missingBody(let message):
            return message?.isEmpty == false ? message : "暂无额度数据"
        }
    }
}

private enum JSONValue: Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var object: [String: JSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        var arrayContainer = try? decoder.unkeyedContainer()
        if arrayContainer != nil {
            var array: [JSONValue] = []
            while arrayContainer?.isAtEnd == false {
                array.append(try arrayContainer!.decode(JSONValue.self))
            }
            self = .array(array)
            return
        }

        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try single.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let object):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in object {
                try container.encode(value, forKey: DynamicCodingKey(stringValue: key))
            }
        case .array(let array):
            var container = encoder.unkeyedContainer()
            for value in array {
                try container.encode(value)
            }
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .number(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .bool(let bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

private struct CodexQuotaBody: Decodable {
    let normalizedPlanType: String?
    let quotaWindows: [RemoteQuotaWindow]

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case planTypeCamel = "planType"
        case rateLimit = "rate_limit"
        case rateLimitCamel = "rateLimit"
        case rateLimits = "rate_limits"
        case rateLimitsCamel = "rateLimits"
        case codeReviewRateLimit = "code_review_rate_limit"
        case codeReviewRateLimitCamel = "codeReviewRateLimit"
        case additionalRateLimits = "additional_rate_limits"
        case additionalRateLimitsCamel = "additionalRateLimits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        normalizedPlanType = try container.decodeIfPresent(String.self, forKey: .planType)
            ?? container.decodeIfPresent(String.self, forKey: .planTypeCamel)

        let rateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
            ?? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimitCamel)
            ?? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimits)
            ?? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimitsCamel)
        let codeReviewRateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .codeReviewRateLimit)
            ?? container.decodeIfPresent(CodexRateLimit.self, forKey: .codeReviewRateLimitCamel)
        let additionalRateLimits = try container.decodeIfPresent([CodexAdditionalRateLimit].self, forKey: .additionalRateLimits)
            ?? container.decodeIfPresent([CodexAdditionalRateLimit].self, forKey: .additionalRateLimitsCamel)

        var windows = rateLimit?.remoteWindows(prefix: nil) ?? []
        windows.append(contentsOf: codeReviewRateLimit?.remoteWindows(prefix: "CR") ?? [])
        for (index, limit) in (additionalRateLimits ?? []).enumerated() {
            guard let rateLimit = limit.rateLimit else {
                continue
            }
            windows.append(contentsOf: rateLimit.remoteWindows(prefix: limit.shortName ?? "限额\(index + 1)"))
        }
        quotaWindows = windows
    }
}

private struct CodexAdditionalRateLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: CodexRateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case limitNameCamel = "limitName"
        case meteredFeature = "metered_feature"
        case meteredFeatureCamel = "meteredFeature"
        case rateLimit = "rate_limit"
        case rateLimitCamel = "rateLimit"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitName = try container.decodeIfPresent(String.self, forKey: .limitName)
            ?? container.decodeIfPresent(String.self, forKey: .limitNameCamel)
        meteredFeature = try container.decodeIfPresent(String.self, forKey: .meteredFeature)
            ?? container.decodeIfPresent(String.self, forKey: .meteredFeatureCamel)
        rateLimit = try container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
            ?? container.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimitCamel)
    }

    var shortName: String? {
        let raw = limitName ?? meteredFeature
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 8 {
            return trimmed
        }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 8)
        return String(trimmed[..<end])
    }
}

private struct CodexRateLimit: Decodable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: CodexQuotaWindow?
    let secondaryWindow: CodexQuotaWindow?
    let quotaWindows: [CodexQuotaWindow]

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case limitReachedCamel = "limitReached"
        case primaryWindow = "primary_window"
        case primaryWindowCamel = "primaryWindow"
        case primary = "primary"
        case secondaryWindow = "secondary_window"
        case secondaryWindowCamel = "secondaryWindow"
        case secondary = "secondary"
        case windows
        case quotaWindows
        case quotaWindowsSnake = "quota_windows"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowed = Self.flexibleBool(from: container, keys: [.allowed])
        limitReached = Self.flexibleBool(from: container, keys: [.limitReached, .limitReachedCamel])
        primaryWindow = try container.decodeIfPresent(CodexQuotaWindow.self, forKey: .primaryWindow)
            ?? container.decodeIfPresent(CodexQuotaWindow.self, forKey: .primaryWindowCamel)
            ?? container.decodeIfPresent(CodexQuotaWindow.self, forKey: .primary)
        secondaryWindow = try container.decodeIfPresent(CodexQuotaWindow.self, forKey: .secondaryWindow)
            ?? container.decodeIfPresent(CodexQuotaWindow.self, forKey: .secondaryWindowCamel)
            ?? container.decodeIfPresent(CodexQuotaWindow.self, forKey: .secondary)
        quotaWindows = (try? container.decodeIfPresent([CodexQuotaWindow].self, forKey: .windows))
            ?? (try? container.decodeIfPresent([CodexQuotaWindow].self, forKey: .quotaWindows))
            ?? (try? container.decodeIfPresent([CodexQuotaWindow].self, forKey: .quotaWindowsSnake))
            ?? []
    }

    func remoteWindows(prefix: String?) -> [RemoteQuotaWindow] {
        let reached = limitReached == true || allowed == false
        if !quotaWindows.isEmpty {
            return quotaWindows.enumerated().map { index, window in
                window.remoteWindow(
                    id: "\(prefix ?? "code")-window-\(window.id ?? String(index))",
                    fallbackPrefix: prefix,
                    fallbackLabel: prefix ?? "额度",
                    limitReached: reached
                )
            }
        }
        let primary = primaryWindow?.remoteWindow(
            id: "\(prefix ?? "code")-primary",
            fallbackPrefix: prefix,
            fallbackLabel: prefix == nil ? "5h" : "\(prefix!) 5h",
            limitReached: reached
        )
        let secondary = secondaryWindow?.remoteWindow(
            id: "\(prefix ?? "code")-secondary",
            fallbackPrefix: prefix,
            fallbackLabel: prefix == nil ? "7d" : "\(prefix!) 7d",
            limitReached: reached
        )
        return [primary, secondary].compactMap { $0 }
    }

    private static func flexibleBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Bool? {
        for key in keys {
            if let value = try? container.decode(Bool.self, forKey: key) {
                return value
            }
            if let value = try? container.decode(Int.self, forKey: key) {
                return value != 0
            }
            if let value = try? container.decode(String.self, forKey: key) {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["true", "yes", "1"].contains(normalized) {
                    return true
                }
                if ["false", "no", "0"].contains(normalized) {
                    return false
                }
            }
        }
        return nil
    }
}

private struct CodexQuotaWindow: Decodable {
    let id: String?
    let labelName: String?
    let usedPercent: Double?
    let limitWindowSeconds: Double?
    let resetAfterSeconds: Double?
    let resetAt: Double?
    let resetLabel: String?

    enum CodingKeys: String, CodingKey {
        case id
        case labelParams
        case usedPercent = "used_percent"
        case usedPercentCamel = "usedPercent"
        case limitWindowSeconds = "limit_window_seconds"
        case limitWindowSecondsCamel = "limitWindowSeconds"
        case windowMinutes = "window_minutes"
        case windowMinutesCamel = "windowMinutes"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAfterSecondsCamel = "resetAfterSeconds"
        case resetAt = "reset_at"
        case resetAtCamel = "resetAt"
        case resetLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        labelName = try container.decodeIfPresent(CodexQuotaWindowLabelParams.self, forKey: .labelParams)?.name
        usedPercent = Self.decodeNumber(from: container, keys: [.usedPercent, .usedPercentCamel])
        let seconds = Self.decodeNumber(from: container, keys: [.limitWindowSeconds, .limitWindowSecondsCamel])
        let minutes = Self.decodeNumber(from: container, keys: [.windowMinutes, .windowMinutesCamel])
        limitWindowSeconds = seconds ?? minutes.map { $0 * 60 }
        resetAfterSeconds = Self.decodeNumber(from: container, keys: [.resetAfterSeconds, .resetAfterSecondsCamel])
        resetAt = Self.decodeNumber(from: container, keys: [.resetAt, .resetAtCamel])
        resetLabel = try container.decodeIfPresent(String.self, forKey: .resetLabel)
    }

    func remoteWindow(
        id: String,
        fallbackPrefix: String?,
        fallbackLabel: String,
        limitReached: Bool
    ) -> RemoteQuotaWindow {
        let used = usedPercent.map { min(100, max(0, $0)) }
        let remaining = used.map { Int((100 - $0).rounded()) }
        return RemoteQuotaWindow(
            id: id,
            shortLabel: shortLabel(prefix: fallbackPrefix) ?? fallbackLabel,
            remainingPercent: remaining,
            usedPercent: used,
            resetText: resetText,
            limitReached: limitReached
        )
    }

    private func shortLabel(prefix: String?) -> String? {
        guard let limitWindowSeconds else {
            return nil
        }
        let label: String
        if abs(limitWindowSeconds - 18_000) < 60 {
            label = "5h"
        } else if abs(limitWindowSeconds - 604_800) < 3_600 {
            label = "7d"
        } else if abs(limitWindowSeconds - 2_592_000) < 3_600 {
            label = "30d"
        } else {
            label = durationLabel(seconds: limitWindowSeconds)
        }
        guard let prefix, !prefix.isEmpty else {
            return label
        }
        return "\(prefix) \(label)"
    }

    private func durationLabel(seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded > 0, rounded % 86_400 == 0 {
            return "\(rounded / 86_400)d"
        }
        if rounded > 0, rounded % 3_600 == 0 {
            return "\(rounded / 3_600)h"
        }
        if rounded > 0, rounded % 60 == 0 {
            return "\(rounded / 60)m"
        }
        return "\(rounded)s"
    }

    private var resetText: String? {
        if let resetLabel, !resetLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return resetLabel
        }

        let date: Date?
        if let resetAt, resetAt > 0 {
            date = Date(timeIntervalSince1970: resetAt)
        } else if let resetAfterSeconds, resetAfterSeconds > 0 {
            date = Date().addingTimeInterval(resetAfterSeconds)
        } else {
            date = nil
        }
        guard let date else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "M-d HH:mm"
        return formatter.string(from: date)
    }

    private static func decodeNumber(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Double? {
        for key in keys {
            if let value = try? container.decode(Double.self, forKey: key) {
                return value
            }
            if let string = try? container.decode(String.self, forKey: key),
               let value = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }
}

private struct CodexQuotaWindowLabelParams: Decodable {
    let name: String?
}
