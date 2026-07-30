import Foundation

typealias Sub2APIRequestExecutor = @Sendable (
    _ request: URLRequest,
    _ session: URLSession
) async throws -> (Data, URLResponse)

struct Sub2APIRemoteConfiguration: Equatable, Sendable {
    let panelURL: String
    let adminEmail: String
    let adminPassword: String
    let timeout: TimeInterval
    let allowInsecureTLS: Bool
}

enum Sub2APIRemoteError: LocalizedError {
    case invalidURL
    case missingEmail
    case missingPassword
    case twoFactorRequired
    case httpStatus(Int, String?)
    case emptyResponse
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Sub2API 面板地址无效"
        case .missingEmail:
            return "缺少 Sub2API 管理员邮箱"
        case .missingPassword:
            return "缺少 Sub2API 管理员密码"
        case .twoFactorRequired:
            return "Sub2API 管理员账号启用了二次验证，暂不支持自动登录"
        case .httpStatus(let status, let message):
            if status == 401 || status == 403 {
                return "Sub2API 管理员认证无效或无权限"
            }
            if let message, !message.isEmpty {
                return "Sub2API 返回 HTTP \(status)：\(message.redactedForDisplay)"
            }
            return "Sub2API 返回 HTTP \(status)"
        case .emptyResponse:
            return "Sub2API 返回空数据"
        case .invalidResponse(let message):
            return message.isEmpty ? "Sub2API 返回格式不兼容" : message.redactedForDisplay
        }
    }
}

final class Sub2APIRemoteClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let configuration: Sub2APIRemoteConfiguration
    private let requestExecutor: Sub2APIRequestExecutor

    init(
        configuration: Sub2APIRemoteConfiguration,
        requestExecutor: Sub2APIRequestExecutor? = nil
    ) {
        self.configuration = configuration
        self.requestExecutor = requestExecutor ?? { request, session in
            try await session.data(for: request)
        }
    }

    static func refreshBudget(forRequestTimeout requestTimeout: TimeInterval) -> TimeInterval {
        min(180, max(75, max(3, requestTimeout) * 8))
    }

    func fetchCodexAccounts(now: Date = Date()) async throws -> [RemoteCodexAccount] {
        try await fetchCodexSnapshot(now: now).accounts
    }

    func fetchCodexSnapshot(now: Date = Date()) async throws -> Sub2APIRemoteSnapshot {
        let email = configuration.adminEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            throw Sub2APIRemoteError.missingEmail
        }
        guard !configuration.adminPassword.isEmpty else {
            throw Sub2APIRemoteError.missingPassword
        }
        guard let baseURL = BalanceAPIClient.apiBaseURL(from: configuration.panelURL) else {
            throw Sub2APIRemoteError.invalidURL
        }

        let session = makeSession()
        defer {
            session.finishTasksAndInvalidate()
        }

        let token = try await login(baseURL: baseURL, session: session)
        let accounts = try await fetchAccountList(baseURL: baseURL, token: token, session: session)
            .filter { account in
                account.platform.lowercased() == "openai"
                    && account.type.lowercased() == "oauth"
                    && account.parentAccountID == nil
                    && account.status.lowercased() != "inactive"
            }

        async let enrichedAccounts = enrichWithQuota(
            accounts,
            baseURL: baseURL,
            token: token,
            session: session,
            now: now
        )
        async let usageOutcome = fetchUsageOutcome(
            accounts: accounts,
            baseURL: baseURL,
            token: token,
            session: session,
            now: now
        )
        let (remoteAccounts, remoteUsageOutcome) = await (enrichedAccounts, usageOutcome)
        return Sub2APIRemoteSnapshot(
            accounts: remoteAccounts,
            usage: remoteUsageOutcome.usage,
            usageError: remoteUsageOutcome.errorMessage
        )
    }

    private func login(baseURL: URL, session: URLSession) async throws -> String {
        let endpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("auth")
            .appendingPathComponent("login")
        let body = try JSONEncoder().encode(
            Sub2APIAdminLoginRequest(
                email: configuration.adminEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                password: configuration.adminPassword
            )
        )
        let data = try await requestData(
            endpoint,
            method: "POST",
            body: body,
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            session: session
        )
        let response = try decodeEnvelope(Sub2APIAdminLoginData.self, from: data)
        if response.requiresTwoFactor == true {
            throw Sub2APIRemoteError.twoFactorRequired
        }
        let token = response.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw Sub2APIRemoteError.invalidResponse("登录响应缺少 access_token")
        }
        return token
    }

    private func fetchAccountList(
        baseURL: URL,
        token: String,
        session: URLSession
    ) async throws -> [Sub2APIAdminAccount] {
        let pageSize = 200
        let maximumPages = 100
        var page = 1
        var accounts: [Sub2APIAdminAccount] = []
        var seenIDs: Set<Int64> = []

        while true {
            let response = try await fetchAccountPage(
                page: page,
                pageSize: pageSize,
                baseURL: baseURL,
                token: token,
                session: session
            )
            for account in response.items where seenIDs.insert(account.id).inserted {
                accounts.append(account)
            }

            let pages = max(1, response.pages ?? page)
            guard pages <= maximumPages else {
                throw Sub2APIRemoteError.invalidResponse("Sub2API 账号分页数量异常")
            }
            guard page < pages else {
                return accounts
            }
            page += 1
        }
    }

    private func fetchAccountPage(
        page: Int,
        pageSize: Int,
        baseURL: URL,
        token: String,
        session: URLSession
    ) async throws -> Sub2APIPaginatedAccounts {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("v1")
                .appendingPathComponent("admin")
                .appendingPathComponent("accounts"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "platform", value: "openai"),
            URLQueryItem(name: "sort_by", value: "name"),
            URLQueryItem(name: "sort_order", value: "asc"),
            URLQueryItem(name: "lite", value: "true")
        ]
        guard let endpoint = components?.url else {
            throw Sub2APIRemoteError.invalidURL
        }
        let data = try await requestData(
            endpoint,
            method: "GET",
            headers: bearerHeaders(token),
            session: session
        )
        return try decodeEnvelope(Sub2APIPaginatedAccounts.self, from: data)
    }

    private func fetchUsageOutcome(
        accounts: [Sub2APIAdminAccount],
        baseURL: URL,
        token: String,
        session: URLSession,
        now: Date
    ) async -> Sub2APIUsageOutcome {
        guard !accounts.isEmpty else {
            return Sub2APIUsageOutcome(usage: .zero, errorMessage: nil)
        }

        let queue = Sub2APIAccountWorkQueue(accounts: accounts)
        let workerCount = min(6, accounts.count)
        let deadline = Date().addingTimeInterval(Self.workBudget(forRequestTimeout: configuration.timeout))
        let outcomes = await withTaskGroup(
            of: [Sub2APIAccountUsageOutcome].self,
            returning: [Sub2APIAccountUsageOutcome].self
        ) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var values: [Sub2APIAccountUsageOutcome] = []
                    while !Task.isCancelled,
                          Date() < deadline,
                          let item = await queue.next() {
                        do {
                            let usage = try await self.fetchPeriodUsage(
                                accountID: item.account.id,
                                baseURL: baseURL,
                                token: token,
                                session: session,
                                now: now
                            )
                            values.append(
                                Sub2APIAccountUsageOutcome(
                                    accountID: item.account.id,
                                    usage: usage,
                                    errorMessage: nil
                                )
                            )
                        } catch {
                            let message = (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
                            values.append(
                                Sub2APIAccountUsageOutcome(
                                    accountID: item.account.id,
                                    usage: nil,
                                    errorMessage: message.redactedForDisplay
                                )
                            )
                        }
                    }
                    return values
                }
            }
            var values: [Sub2APIAccountUsageOutcome] = []
            for await workerValues in group {
                values.append(contentsOf: workerValues)
            }
            return values
        }

        let failedCount = outcomes.filter { $0.usage == nil }.count
            + max(0, accounts.count - outcomes.count)
        guard failedCount == 0 else {
            return Sub2APIUsageOutcome(
                usage: nil,
                errorMessage: "\(failedCount) 个 Codex 账号用量刷新失败"
            )
        }
        let usage = outcomes.compactMap(\.usage).reduce(.zero, Self.sumPeriodUsage)
        return Sub2APIUsageOutcome(usage: usage, errorMessage: nil)
    }

    private static func workBudget(forRequestTimeout requestTimeout: TimeInterval) -> TimeInterval {
        let overall = refreshBudget(forRequestTimeout: requestTimeout)
        return max(30, overall - max(3, requestTimeout) - 10)
    }

    private static func sumPeriodUsage(_ lhs: PeriodUsage, _ rhs: PeriodUsage) -> PeriodUsage {
        PeriodUsage(
            day: saturatedAdd(lhs.day, rhs.day),
            week: saturatedAdd(lhs.week, rhs.week),
            month: saturatedAdd(lhs.month, rhs.month)
        )
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflow ? Int.max : value
    }

    private func fetchPeriodUsage(
        accountID: Int64,
        baseURL: URL,
        token: String,
        session: URLSession,
        now: Date
    ) async throws -> PeriodUsage {
        let timeZone = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startDate = calendar.date(byAdding: .day, value: -30, to: now)
            ?? now.addingTimeInterval(-2_592_000)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("v1")
                .appendingPathComponent("admin")
                .appendingPathComponent("dashboard")
                .appendingPathComponent("trend"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "start_date", value: formatter.string(from: startDate)),
            URLQueryItem(name: "end_date", value: formatter.string(from: now)),
            URLQueryItem(name: "granularity", value: "hour"),
            URLQueryItem(name: "timezone", value: timeZone.identifier),
            URLQueryItem(name: "account_id", value: String(accountID))
        ]
        guard let endpoint = components?.url else {
            throw Sub2APIRemoteError.invalidURL
        }

        let data = try await requestData(
            endpoint,
            method: "GET",
            headers: bearerHeaders(token),
            session: session
        )
        let response = try decodeEnvelope(Sub2APIUsageTrendResponse.self, from: data)
        return Self.periodUsage(from: response.trend, now: now, timeZone: timeZone)
    }

    static func periodUsage(
        from points: [Sub2APIUsageTrendPoint],
        now: Date,
        timeZone: TimeZone
    ) -> PeriodUsage {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let dayStart = currentHour.addingTimeInterval(-86_400)
        let weekStart = currentHour.addingTimeInterval(-604_800)
        let monthStart = currentHour.addingTimeInterval(-2_592_000)

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var day: Int64 = 0
        var week: Int64 = 0
        var month: Int64 = 0
        for point in points {
            guard let bucketDate = formatter.date(from: point.date),
                  bucketDate <= currentHour,
                  bucketDate > monthStart else {
                continue
            }
            let tokens = max(0, point.totalTokens)
            month = saturatedAdd(month, tokens)
            if bucketDate > weekStart {
                week = saturatedAdd(week, tokens)
            }
            if bucketDate > dayStart {
                day = saturatedAdd(day, tokens)
            }
        }
        return PeriodUsage(
            day: Int(clamping: day),
            week: Int(clamping: week),
            month: Int(clamping: month)
        )
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }

    private func enrichWithQuota(
        _ accounts: [Sub2APIAdminAccount],
        baseURL: URL,
        token: String,
        session: URLSession,
        now: Date
    ) async -> [RemoteCodexAccount] {
        guard !accounts.isEmpty else {
            return []
        }

        var output = Array<RemoteCodexAccount?>(repeating: nil, count: accounts.count)
        let queue = Sub2APIAccountWorkQueue(accounts: accounts)
        let workerCount = min(8, accounts.count)
        let deadline = Date().addingTimeInterval(Self.workBudget(forRequestTimeout: configuration.timeout))
        let outcomes = await withTaskGroup(
            of: [Sub2APIQuotaOutcome].self,
            returning: [Sub2APIQuotaOutcome].self
        ) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var values: [Sub2APIQuotaOutcome] = []
                    while !Task.isCancelled,
                          Date() < deadline,
                          let item = await queue.next() {
                        do {
                            let endpoint = baseURL
                                .appendingPathComponent("api")
                                .appendingPathComponent("v1")
                                .appendingPathComponent("admin")
                                .appendingPathComponent("openai")
                                .appendingPathComponent("accounts")
                                .appendingPathComponent(String(item.account.id))
                                .appendingPathComponent("quota")
                            let data = try await self.requestData(
                                endpoint,
                                method: "GET",
                                headers: self.bearerHeaders(token),
                                session: session
                            )
                            let usage = try self.decodeEnvelope(Sub2APIOpenAIQuotaUsage.self, from: data)
                            values.append(
                                Sub2APIQuotaOutcome(
                                    index: item.index,
                                    usage: usage,
                                    errorMessage: nil
                                )
                            )
                        } catch {
                            let message = (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
                            values.append(
                                Sub2APIQuotaOutcome(
                                    index: item.index,
                                    usage: nil,
                                    errorMessage: message.redactedForDisplay
                                )
                            )
                        }
                    }
                    return values
                }
            }
            var values: [Sub2APIQuotaOutcome] = []
            for await workerValues in group {
                values.append(contentsOf: workerValues)
            }
            return values
        }

        for outcome in outcomes {
            output[outcome.index] = Self.remoteAccount(
                from: accounts[outcome.index],
                quota: outcome.usage,
                quotaError: outcome.errorMessage,
                now: now
            )
        }

        return accounts.enumerated().map { index, account in
            output[index] ?? Self.remoteAccount(
                from: account,
                quota: nil,
                quotaError: Task.isCancelled ? "刷新已取消" : "额度刷新超时",
                now: now
            )
        }
    }

    static func remoteAccount(
        from account: Sub2APIAdminAccount,
        quota: Sub2APIOpenAIQuotaUsage?,
        quotaError: String?,
        now: Date
    ) -> RemoteCodexAccount {
        let normalizedStatus = account.status.lowercased()
        let isAbnormal = !["active", "available", "enabled", "normal", "ready", "ok", "healthy", "valid"]
            .contains(normalizedStatus)
        let statusMessage = [
            account.errorMessage,
            account.tempUnschedulableReason
        ]
        .compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        .first
        let windows = quota?.rateLimit?.remoteWindows(now: now) ?? []
        let resetCredits = quota?.rateLimitResetCredits?.remoteCredits(now: now)
        let accountState: RemoteAccountState =
            (isAbnormal || !account.schedulable) ? .abnormal : .healthy

        return RemoteCodexAccount(
            id: "sub2api-\(account.id)",
            name: account.name,
            email: account.email,
            label: nil,
            provider: "sub2api",
            accountType: account.type,
            authIndex: nil,
            chatgptAccountID: nil,
            status: account.status,
            statusMessage: statusMessage,
            successCount: nil,
            failureCount: nil,
            recentFailures: 0,
            state: accountState,
            lastRefresh: quota?.fetchedAt.map(String.init),
            planType: quota?.planType ?? account.planType,
            quotaWindows: windows,
            quotaError: quotaError,
            unavailable: isAbnormal || !account.schedulable,
            resetCredits: resetCredits
        )
        .withQuotaExhaustion
    }

    private func makeSession() -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout
        sessionConfiguration.httpCookieAcceptPolicy = .always
        sessionConfiguration.httpShouldSetCookies = true
        return URLSession(
            configuration: sessionConfiguration,
            delegate: configuration.allowInsecureTLS ? self : nil,
            delegateQueue: nil
        )
    }

    private func requestData(
        _ endpoint: URL,
        method: String,
        body: Data? = nil,
        headers: [String: String],
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = configuration.timeout
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await requestExecutor(request, session)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw Sub2APIRemoteError.httpStatus(
                httpResponse.statusCode,
                Self.responseMessage(from: data)
            )
        }
        guard !data.isEmpty else {
            throw Sub2APIRemoteError.emptyResponse
        }
        return data
    }

    private func decodeEnvelope<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let envelope = try JSONDecoder().decode(Sub2APIEnvelope<T>.self, from: data)
        guard envelope.code == 0 else {
            throw Sub2APIRemoteError.invalidResponse(envelope.message)
        }
        guard let value = envelope.data else {
            throw Sub2APIRemoteError.invalidResponse("响应缺少 data")
        }
        return value
    }

    private func bearerHeaders(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json"
        ]
    }

    private static func responseMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
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
}

struct Sub2APIRemoteSnapshot: Sendable {
    let accounts: [RemoteCodexAccount]
    let usage: PeriodUsage?
    let usageError: String?
}

private struct Sub2APIUsageOutcome: Sendable {
    let usage: PeriodUsage?
    let errorMessage: String?
}

private struct Sub2APIAccountUsageOutcome: Sendable {
    let accountID: Int64
    let usage: PeriodUsage?
    let errorMessage: String?
}

private struct Sub2APIAccountWorkItem: Sendable {
    let index: Int
    let account: Sub2APIAdminAccount
}

private actor Sub2APIAccountWorkQueue {
    private let accounts: [Sub2APIAdminAccount]
    private var nextIndex = 0

    init(accounts: [Sub2APIAdminAccount]) {
        self.accounts = accounts
    }

    func next() -> Sub2APIAccountWorkItem? {
        guard nextIndex < accounts.count else {
            return nil
        }
        defer {
            nextIndex += 1
        }
        return Sub2APIAccountWorkItem(
            index: nextIndex,
            account: accounts[nextIndex]
        )
    }
}

private struct Sub2APIAdminLoginRequest: Encodable {
    let email: String
    let password: String
}

private struct Sub2APIEnvelope<T: Decodable>: Decodable {
    let code: Int
    let message: String
    let data: T?
}

private struct Sub2APIAdminLoginData: Decodable {
    let accessToken: String?
    let requiresTwoFactor: Bool?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case requiresTwoFactor = "requires_2fa"
    }
}

private struct Sub2APIPaginatedAccounts: Decodable {
    let items: [Sub2APIAdminAccount]
    let page: Int?
    let pages: Int?
    let total: Int?
}

private struct Sub2APIUsageTrendResponse: Decodable {
    let trend: [Sub2APIUsageTrendPoint]
}

struct Sub2APIUsageTrendPoint: Decodable, Sendable {
    let date: String
    let totalTokens: Int64

    enum CodingKeys: String, CodingKey {
        case date
        case totalTokens = "total_tokens"
    }
}

struct Sub2APIAdminAccount: Decodable, Sendable {
    let id: Int64
    let name: String
    let email: String?
    let platform: String
    let type: String
    let status: String
    let errorMessage: String?
    let schedulable: Bool
    let tempUnschedulableReason: String?
    let parentAccountID: Int64?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case platform
        case type
        case status
        case errorMessage = "error_message"
        case schedulable
        case tempUnschedulableReason = "temp_unschedulable_reason"
        case parentAccountID = "parent_account_id"
        case extra
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Codex \(id)"
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        schedulable = try container.decodeIfPresent(Bool.self, forKey: .schedulable) ?? false
        tempUnschedulableReason = try container.decodeIfPresent(String.self, forKey: .tempUnschedulableReason)
        parentAccountID = try container.decodeIfPresent(Int64.self, forKey: .parentAccountID)
        let extra = try container.decodeIfPresent([String: Sub2APIJSONValue].self, forKey: .extra) ?? [:]
        email = extra.string(for: ["email", "account_email", "user_email"])
        planType = extra.string(for: ["plan_type", "planType", "plan"])
    }
}

private enum Sub2APIJSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: Sub2APIJSONValue])
    case array([Sub2APIJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: Sub2APIJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([Sub2APIJSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }
}

private extension Dictionary where Key == String, Value == Sub2APIJSONValue {
    func string(for keys: [String]) -> String? {
        for key in keys {
            guard case .string(let value)? = self[key] else {
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

struct Sub2APIOpenAIQuotaUsage: Decodable, Sendable {
    let planType: String?
    let rateLimit: Sub2APIRateLimit?
    let rateLimitResetCredits: Sub2APIResetCredits?
    let fetchedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case rateLimitResetCredits = "rate_limit_reset_credits"
        case fetchedAt = "fetched_at"
    }
}

struct Sub2APIRateLimit: Decodable, Sendable {
    let allowed: Bool
    let limitReached: Bool
    let primaryWindow: Sub2APIRateLimitWindow?
    let secondaryWindow: Sub2APIRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    func remoteWindows(now: Date) -> [RemoteQuotaWindow] {
        let reached = limitReached || !allowed
        return [
            primaryWindow?.remoteWindow(
                id: "sub2api-primary",
                fallbackLabel: "额度",
                limitReached: reached,
                now: now
            ),
            secondaryWindow?.remoteWindow(
                id: "sub2api-secondary",
                fallbackLabel: "额度",
                limitReached: reached,
                now: now
            )
        ]
        .compactMap { $0 }
    }
}

struct Sub2APIRateLimitWindow: Decodable, Sendable {
    let usedPercent: Double
    let limitWindowSeconds: Int64
    let resetAfterSeconds: Int64
    let resetAt: Int64

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    func remoteWindow(
        id: String,
        fallbackLabel: String,
        limitReached: Bool,
        now: Date
    ) -> RemoteQuotaWindow {
        let used = min(100, max(0, usedPercent))
        let remaining = Int((100 - used).rounded())
        return RemoteQuotaWindow(
            id: id,
            shortLabel: shortLabel ?? fallbackLabel,
            remainingPercent: remaining,
            usedPercent: used,
            resetText: resetText(now: now),
            limitReached: limitReached
        )
    }

    private var shortLabel: String? {
        switch limitWindowSeconds {
        case 17_940...18_060:
            "5h"
        case 601_200...608_400:
            "7d"
        case 2_588_400...2_595_600:
            "30d"
        default:
            limitWindowSeconds > 0 ? Self.durationLabel(seconds: limitWindowSeconds) : nil
        }
    }

    private func resetText(now: Date) -> String? {
        let date: Date?
        if resetAt > 0 {
            date = Date(timeIntervalSince1970: TimeInterval(resetAt))
        } else if resetAfterSeconds > 0 {
            date = now.addingTimeInterval(TimeInterval(resetAfterSeconds))
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

    private static func durationLabel(seconds: Int64) -> String {
        if seconds % 86_400 == 0 {
            return "\(seconds / 86_400)d"
        }
        if seconds % 3_600 == 0 {
            return "\(seconds / 3_600)h"
        }
        if seconds % 60 == 0 {
            return "\(seconds / 60)m"
        }
        return "\(seconds)s"
    }
}

struct Sub2APIResetCredits: Decodable, Sendable {
    let availableCount: Int
    let credits: [Sub2APIResetCredit]

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try container.decodeIfPresent(Int.self, forKey: .availableCount) ?? 0
        credits = try container.decodeIfPresent([Sub2APIResetCredit].self, forKey: .credits) ?? []
    }

    func remoteCredits(now: Date) -> RateLimitResetCredits {
        let values = credits.enumerated().compactMap { index, credit -> RateLimitResetCredit? in
            guard let expiresAt = credit.expiryDate, expiresAt > now else {
                return nil
            }
            return RateLimitResetCredit(
                id: "sub2api-reset-\(index)-\(Int(expiresAt.timeIntervalSince1970))",
                expiresAt: expiresAt
            )
        }
        return RateLimitResetCredits(
            availableCount: max(0, availableCount),
            credits: values.sorted { $0.expiresAt < $1.expiresAt },
            fetchedAt: now
        )
    }
}

struct Sub2APIResetCredit: Decodable, Sendable {
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case expiresAt = "expires_at"
    }

    var expiryDate: Date? {
        guard let expiresAt else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: expiresAt) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: expiresAt)
    }
}

private struct Sub2APIQuotaOutcome: Sendable {
    let index: Int
    let usage: Sub2APIOpenAIQuotaUsage?
    let errorMessage: String?
}
