import Foundation

struct BalanceAPIConfiguration: Equatable {
    let panelURL: String
    let username: String
    let secret: String
    let timeout: TimeInterval
    let allowInsecureTLS: Bool
}

enum BalanceAPIError: LocalizedError {
    case invalidURL
    case missingKey
    case missingUsername
    case loginRequiresTwoFactor
    case httpStatus(Int)
    case emptyResponse
    case unsupportedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "面板地址无效"
        case .missingKey:
            "缺少认证信息"
        case .missingUsername:
            "缺少登录用户名"
        case .loginRequiresTwoFactor:
            "账号需要二次验证，暂不支持自动登录"
        case .httpStatus(let status):
            status == 401 || status == 403 ? "认证信息无效或无权限" : "面板返回 HTTP \(status)"
        case .emptyResponse:
            "面板返回空数据"
        case .unsupportedResponse(let message):
            message.isEmpty ? "面板返回格式不兼容" : message.redactedForDisplay
        }
    }
}

final class BalanceAPIClient: NSObject, URLSessionDelegate {
    private let configuration: BalanceAPIConfiguration

    init(configuration: BalanceAPIConfiguration) {
        self.configuration = configuration
    }

    func fetchSnapshot(source: BalanceMonitorSource) async throws -> BalanceMonitorSnapshot {
        guard let baseURL = Self.apiBaseURL(from: configuration.panelURL) else {
            throw BalanceAPIError.invalidURL
        }

        switch source {
        case .newAPI:
            return try await fetchNewAPISnapshot(baseURL: baseURL, source: source)
        case .subAPI:
            return try await fetchSubAPISnapshot(baseURL: baseURL, source: source)
        }
    }

    private func fetchNewAPISnapshot(
        baseURL: URL,
        source: BalanceMonitorSource
    ) async throws -> BalanceMonitorSnapshot {
        let session = makeSession()
        defer {
            session.finishTasksAndInvalidate()
        }
        let userID = try await loginToNewAPI(baseURL: baseURL, session: session)
        let managementHeaders = Self.newAPIManagementHeaders(userID: userID)

        let selfEndpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("user")
            .appendingPathComponent("self")
        let selfData = try await requestData(
            selfEndpoint,
            method: "GET",
            headers: managementHeaders,
            session: session,
            timeout: configuration.timeout
        )
        var accounts = [try Self.decodeUserAccount(selfData, source: source)]
        var partialMessage: String?

        if let channelEndpoint = Self.channelListURL(baseURL: baseURL),
           !channelEndpoint.absoluteString.isEmpty {
            do {
                let channelData = try await requestData(
                    channelEndpoint,
                    method: "GET",
                    headers: managementHeaders,
                    session: session,
                    timeout: configuration.timeout
                )
                let channels = try Self.decodeChannelAccounts(channelData, source: source)
                accounts.append(contentsOf: channels)
            } catch {
                partialMessage = "渠道列表读取失败：\(Self.localizedMessage(for: error))"
            }
        }

        return BalanceMonitorSnapshot(
            source: source,
            panelState: Self.panelState(for: accounts, partialMessage: partialMessage),
            accounts: accounts,
            message: partialMessage ?? (accounts.isEmpty ? "没有找到 \(source.title) 账户" : nil),
            lastUpdated: Date()
        )
    }

    private func fetchSubAPISnapshot(
        baseURL: URL,
        source: BalanceMonitorSource
    ) async throws -> BalanceMonitorSnapshot {
        let session = makeSession()
        defer {
            session.finishTasksAndInvalidate()
        }
        let token = try await loginToSubAPI(baseURL: baseURL, session: session)
        let headers = Self.bearerHeaders(token: token)

        let profileEndpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("user")
            .appendingPathComponent("profile")
        let profileData = try await requestData(
            profileEndpoint,
            method: "GET",
            headers: headers,
            session: session,
            timeout: configuration.timeout
        )
        var accounts = [try Self.decodeSubAPIProfileAccount(profileData)]
        var partialMessage: String?

        let quotasEndpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("user")
            .appendingPathComponent("platform-quotas")
        do {
            let quotasData = try await requestData(
                quotasEndpoint,
                method: "GET",
                headers: headers,
                session: session,
                timeout: configuration.timeout
            )
            accounts.append(contentsOf: try Self.decodeSubAPIPlatformQuotaAccounts(quotasData))
        } catch {
            partialMessage = "平台配额读取失败：\(Self.localizedMessage(for: error))"
        }

        return BalanceMonitorSnapshot(
            source: source,
            panelState: Self.panelState(for: accounts, partialMessage: partialMessage),
            accounts: accounts,
            message: partialMessage ?? (accounts.isEmpty ? "没有找到 Sub2API 用户余额" : nil),
            lastUpdated: Date()
        )
    }

    private func loginToNewAPI(baseURL: URL, session: URLSession) async throws -> String {
        let username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw BalanceAPIError.missingUsername
        }
        guard !configuration.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BalanceAPIError.missingKey
        }
        let loginEndpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("user")
            .appendingPathComponent("login")
        let data = try await requestData(
            loginEndpoint,
            method: "POST",
            body: try Self.newAPILoginBody(for: configuration),
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json"
            ],
            session: session,
            timeout: configuration.timeout
        )
        return try Self.validateNewAPILoginResponse(data)
    }

    private func loginToSubAPI(baseURL: URL, session: URLSession) async throws -> String {
        let username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw BalanceAPIError.missingUsername
        }
        guard !configuration.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BalanceAPIError.missingKey
        }
        let loginEndpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("auth")
            .appendingPathComponent("login")
        let data = try await requestData(
            loginEndpoint,
            method: "POST",
            body: try Self.subAPILoginBody(for: configuration),
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json"
            ],
            session: session,
            timeout: configuration.timeout
        )
        return try Self.validateSubAPILoginResponse(data)
    }

    private func makeSession() -> URLSession {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = configuration.timeout
        sessionConfig.timeoutIntervalForResource = configuration.timeout
        sessionConfig.httpCookieAcceptPolicy = .always
        sessionConfig.httpShouldSetCookies = true
        return URLSession(
            configuration: sessionConfig,
            delegate: configuration.allowInsecureTLS ? self : nil,
            delegateQueue: nil
        )
    }

    private func requestData(
        _ endpoint: URL,
        method: String,
        body: Data? = nil,
        headers: [String: String],
        session: URLSession,
        timeout: TimeInterval
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw BalanceAPIError.httpStatus(httpResponse.statusCode)
        }
        guard !data.isEmpty else {
            throw BalanceAPIError.emptyResponse
        }
        return data
    }

    private static func panelState(for accounts: [BalanceAccount], partialMessage: String?) -> BalancePanelState {
        var state: BalancePanelState
        if accounts.isEmpty {
            state = .warning
        } else if accounts.contains(where: { $0.state == .error }) {
            state = .error
        } else if accounts.contains(where: { $0.state == .warning }) {
            state = .warning
        } else {
            state = .healthy
        }
        if partialMessage != nil, state == .healthy {
            state = .warning
        }
        return state
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

    static func apiBaseURL(from input: String) -> URL? {
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

        guard scheme == "https" || scheme == "http" else {
            return nil
        }
        if scheme == "http", !isLocalHost(host) {
            return nil
        }

        components.scheme = scheme
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func channelListURL(baseURL: URL) -> URL? {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("api")
                .appendingPathComponent("channel")
                .appendingPathComponent(""),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "page_size", value: "100")
        ]
        return components?.url
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    static func decodeUserAccount(
        _ data: Data,
        source: BalanceMonitorSource
    ) throws -> BalanceAccount {
        let user = try decodePayload(NewAPIUserData.self, from: data)
        return user.balanceAccount(source: source)
    }

    static func decodeChannelAccounts(
        _ data: Data,
        source: BalanceMonitorSource
    ) throws -> [BalanceAccount] {
        if let list = try? decodePayload(NewAPIChannelListData.self, from: data) {
            return list.items.map { $0.balanceAccount(source: source) }
        }
        if let channels = try? decodePayload([NewAPIChannelData].self, from: data) {
            return channels.map { $0.balanceAccount(source: source) }
        }
        throw BalanceAPIError.unsupportedResponse("渠道余额格式不兼容")
    }

    static func newAPILoginBody(for configuration: BalanceAPIConfiguration) throws -> Data {
        let username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = configuration.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw BalanceAPIError.missingUsername
        }
        guard !password.isEmpty else {
            throw BalanceAPIError.missingKey
        }
        return try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password
        ])
    }

    static func newAPIManagementHeaders(userID: String) -> [String: String] {
        [
            "Accept": "application/json",
            "New-Api-User": userID
        ]
    }

    static func bearerHeaders(token: String) -> [String: String] {
        [
            "Accept": "application/json",
            "Authorization": "Bearer \(token)"
        ]
    }

    static func subAPILoginBody(for configuration: BalanceAPIConfiguration) throws -> Data {
        let username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = configuration.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw BalanceAPIError.missingUsername
        }
        guard !password.isEmpty else {
            throw BalanceAPIError.missingKey
        }
        return try JSONSerialization.data(withJSONObject: [
            "email": username,
            "password": password
        ])
    }

    @discardableResult
    static func validateNewAPILoginResponse(_ data: Data) throws -> String {
        let envelope = try decodePayload(NewAPILoginData.self, from: data)
        if envelope.requireTwoFactor == true {
            throw BalanceAPIError.loginRequiresTwoFactor
        }
        guard let userID = envelope.id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !userID.isEmpty else {
            throw BalanceAPIError.unsupportedResponse("NewAPI 登录响应缺少用户 ID")
        }
        return userID
    }

    static func validateSubAPILoginResponse(_ data: Data) throws -> String {
        let payload = try decodeSubAPIPayload(SubAPILoginData.self, from: data)
        if payload.requiresTwoFactor == true {
            throw BalanceAPIError.loginRequiresTwoFactor
        }
        guard let token = payload.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw BalanceAPIError.unsupportedResponse("Sub2API 登录响应缺少 access token")
        }
        return token
    }

    static func decodeSubAPIProfileAccount(_ data: Data) throws -> BalanceAccount {
        try decodeSubAPIPayload(SubAPIUserData.self, from: data).balanceAccount()
    }

    static func decodeSubAPIPlatformQuotaAccounts(_ data: Data) throws -> [BalanceAccount] {
        if let list = try? decodeSubAPIPayload(SubAPIPlatformQuotaListData.self, from: data) {
            return list.platformQuotas.map { $0.balanceAccount() }
        }
        if let quotas = try? decodeSubAPIPayload([SubAPIPlatformQuotaData].self, from: data) {
            return quotas.map { $0.balanceAccount() }
        }
        throw BalanceAPIError.unsupportedResponse("Sub2API 平台配额格式不兼容")
    }

    private static func decodePayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(NewAPIEnvelope<T>.self, from: data) {
            if envelope.success == false {
                throw BalanceAPIError.unsupportedResponse((envelope.message ?? "").redactedForDisplay)
            }
            if let payload = envelope.data {
                return payload
            }
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func decodeSubAPIPayload<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(SubAPIEnvelope<T>.self, from: data) {
            if let code = envelope.code, code != 0 {
                throw BalanceAPIError.unsupportedResponse((envelope.message ?? "").redactedForDisplay)
            }
            if let payload = envelope.data {
                return payload
            }
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func localizedMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized.redactedForDisplay
        }
        return error.localizedDescription.redactedForDisplay
    }
}

private struct NewAPIEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let message: String?
    let data: T?
}

private struct NewAPILoginData: Decodable {
    let id: String?
    let requireTwoFactor: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case userIDCamel = "userId"
        case requireTwoFactor = "require_2fa"
        case requireTwoFactorCamel = "require2FA"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(for: [.id, .userID, .userIDCamel])
        requireTwoFactor = container.flexibleBool(for: [.requireTwoFactor, .requireTwoFactorCamel])
    }
}

private struct SubAPIEnvelope<T: Decodable>: Decodable {
    let code: Int?
    let message: String?
    let data: T?
}

private struct SubAPILoginData: Decodable {
    let accessToken: String?
    let requiresTwoFactor: Bool?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessTokenCamel = "accessToken"
        case requiresTwoFactor = "requires_2fa"
        case requiresTwoFactorCamel = "requires2FA"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = container.flexibleString(for: [.accessToken, .accessTokenCamel])
        requiresTwoFactor = container.flexibleBool(for: [.requiresTwoFactor, .requiresTwoFactorCamel])
    }
}

private struct NewAPIUserData: Decodable {
    let username: String?
    let displayName: String?
    let quota: Int?
    let usedQuota: Int?
    let requestCount: Int?
    let status: Int?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case quota
        case usedQuota = "used_quota"
        case usedQuotaCamel = "usedQuota"
        case requestCount = "request_count"
        case requestCountCamel = "requestCount"
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = container.flexibleString(for: [.username])
        displayName = container.flexibleString(for: [.displayName, .displayNameCamel])
        quota = container.flexibleInt(for: [.quota])
        usedQuota = container.flexibleInt(for: [.usedQuota, .usedQuotaCamel])
        requestCount = container.flexibleInt(for: [.requestCount, .requestCountCamel])
        status = container.flexibleInt(for: [.status])
    }

    func balanceAccount(source: BalanceMonitorSource) -> BalanceAccount {
        let state: BalanceAccountState = status == nil || status == 1 ? .healthy : .warning
        return BalanceAccount(
            id: "\(source.rawValue)-self",
            source: source,
            name: displayName ?? username ?? "\(source.title) 用户",
            kind: "用户额度",
            statusCode: status,
            amountText: quota.map(Formatters.compactTokens(_:)) ?? "--",
            usedText: usedQuota.map(Formatters.compactTokens(_:)),
            requestCount: requestCount,
            updatedAt: nil,
            state: state
        )
    }
}

private struct NewAPIChannelListData: Decodable {
    let items: [NewAPIChannelData]
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case items
        case total
    }
}

private struct NewAPIChannelData: Decodable {
    let id: Int?
    let name: String?
    let status: Int?
    let balance: Double?
    let usedQuota: Int?
    let balanceUpdatedTime: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case balance
        case usedQuota = "used_quota"
        case usedQuotaCamel = "usedQuota"
        case balanceUpdatedTime = "balance_updated_time"
        case balanceUpdatedTimeCamel = "balanceUpdatedTime"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleInt(for: [.id])
        name = container.flexibleString(for: [.name])
        status = container.flexibleInt(for: [.status])
        balance = container.flexibleDouble(for: [.balance])
        usedQuota = container.flexibleInt(for: [.usedQuota, .usedQuotaCamel])
        balanceUpdatedTime = container.flexibleInt(for: [.balanceUpdatedTime, .balanceUpdatedTimeCamel])
    }

    func balanceAccount(source: BalanceMonitorSource) -> BalanceAccount {
        let state: BalanceAccountState = status == nil || status == 1 ? .healthy : .warning
        return BalanceAccount(
            id: "\(source.rawValue)-channel-\(id.map(String.init) ?? name ?? UUID().uuidString)",
            source: source,
            name: name ?? "渠道 \(id.map(String.init) ?? "")",
            kind: "渠道余额",
            statusCode: status,
            amountText: balance.map(BalanceMonitorSnapshot.currencyText(_:)) ?? "--",
            usedText: usedQuota.map(Formatters.compactTokens(_:)),
            requestCount: nil,
            updatedAt: balanceUpdatedTime.map { "更新 \($0)" },
            state: state
        )
    }
}

private struct SubAPIPlatformQuotaListData: Decodable {
    let platformQuotas: [SubAPIPlatformQuotaData]

    enum CodingKeys: String, CodingKey {
        case platformQuotas = "platform_quotas"
        case platformQuotasCamel = "platformQuotas"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platformQuotas = (try? container.decodeIfPresent([SubAPIPlatformQuotaData].self, forKey: .platformQuotas))
            ?? (try? container.decodeIfPresent([SubAPIPlatformQuotaData].self, forKey: .platformQuotasCamel))
            ?? []
    }
}

private struct SubAPIPlatformQuotaData: Decodable {
    let platform: String?
    let dailyUsageUSD: Double?
    let dailyLimitUSD: Double?
    let weeklyUsageUSD: Double?
    let weeklyLimitUSD: Double?
    let monthlyUsageUSD: Double?
    let monthlyLimitUSD: Double?

    enum CodingKeys: String, CodingKey {
        case platform
        case dailyUsageUSD = "daily_usage_usd"
        case dailyLimitUSD = "daily_limit_usd"
        case weeklyUsageUSD = "weekly_usage_usd"
        case weeklyLimitUSD = "weekly_limit_usd"
        case monthlyUsageUSD = "monthly_usage_usd"
        case monthlyLimitUSD = "monthly_limit_usd"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platform = container.flexibleString(for: [.platform])
        dailyUsageUSD = container.flexibleDouble(for: [.dailyUsageUSD])
        dailyLimitUSD = container.flexibleDouble(for: [.dailyLimitUSD])
        weeklyUsageUSD = container.flexibleDouble(for: [.weeklyUsageUSD])
        weeklyLimitUSD = container.flexibleDouble(for: [.weeklyLimitUSD])
        monthlyUsageUSD = container.flexibleDouble(for: [.monthlyUsageUSD])
        monthlyLimitUSD = container.flexibleDouble(for: [.monthlyLimitUSD])
    }

    func balanceAccount() -> BalanceAccount {
        let windows = [
            ("日", dailyUsageUSD, dailyLimitUSD),
            ("周", weeklyUsageUSD, weeklyLimitUSD),
            ("30天", monthlyUsageUSD, monthlyLimitUSD)
        ]
        let remainingValues = windows.compactMap { _, usage, limit -> Double? in
            guard let limit else {
                return nil
            }
            return max(0, limit - (usage ?? 0))
        }
        let exhausted = windows.contains { _, usage, limit in
            guard let limit else {
                return false
            }
            return (usage ?? 0) >= limit
        }
        let details = windows.compactMap { label, usage, limit -> String? in
            guard let usage else {
                return nil
            }
            if let limit {
                return "\(label) \(BalanceMonitorSnapshot.currencyText(usage))/\(BalanceMonitorSnapshot.currencyText(limit))"
            }
            return "\(label) 已用 \(BalanceMonitorSnapshot.currencyText(usage))"
        }.joined(separator: " · ")
        let platformName = platform?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = platformName?.isEmpty == false ? platformName! : "平台配额"

        return BalanceAccount(
            id: "subapi-quota-\(displayName)",
            source: .subAPI,
            name: displayName,
            kind: "平台配额",
            statusCode: nil,
            amountText: remainingValues.min().map(BalanceMonitorSnapshot.currencyText(_:)) ?? "不限",
            usedText: nil,
            requestCount: nil,
            updatedAt: details.isEmpty ? nil : details,
            state: exhausted ? .warning : .healthy
        )
    }
}

private struct SubAPIUserData: Decodable {
    let id: Int?
    let email: String?
    let username: String?
    let role: String?
    let balance: Double?
    let concurrency: Int?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case username
        case role
        case balance
        case concurrency
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleInt(for: [.id])
        email = container.flexibleString(for: [.email])
        username = container.flexibleString(for: [.username])
        role = container.flexibleString(for: [.role])
        balance = container.flexibleDouble(for: [.balance])
        concurrency = container.flexibleInt(for: [.concurrency])
        status = container.flexibleString(for: [.status])
    }

    func balanceAccount() -> BalanceAccount {
        let normalizedStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let state: BalanceAccountState = normalizedStatus == nil || normalizedStatus == "active" ? .healthy : .warning
        let roleText = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "admin" ? "管理员余额" : "用户余额"
        let details = [
            concurrency.map { "并发 \($0)" },
            normalizedStatus.map { "状态 \($0)" }
        ].compactMap { $0 }.joined(separator: " · ")
        return BalanceAccount(
            id: "subapi-user-\(id.map(String.init) ?? email ?? username ?? UUID().uuidString)",
            source: .subAPI,
            name: email ?? username ?? "用户 \(id.map(String.init) ?? "")",
            kind: roleText,
            statusCode: nil,
            amountText: balance.map(BalanceMonitorSnapshot.currencyText(_:)) ?? "--",
            usedText: nil,
            requestCount: nil,
            updatedAt: details.isEmpty ? nil : details,
            state: state
        )
    }
}

private extension KeyedDecodingContainer {
    func flexibleString(for keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return String(value)
            }
        }
        return nil
    }

    func flexibleInt(for keys: [Key]) -> Int? {
        for key in keys {
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return Int(value.rounded())
            }
            if let value = try? decodeIfPresent(String.self, forKey: key),
               let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return Int(number.rounded())
            }
        }
        return nil
    }

    func flexibleDouble(for keys: [Key]) -> Double? {
        for key in keys {
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }
            if let value = try? decodeIfPresent(String.self, forKey: key),
               let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return number
            }
        }
        return nil
    }

    func flexibleBool(for keys: [Key]) -> Bool? {
        for key in keys {
            if let value = try? decodeIfPresent(Bool.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value != 0
            }
            if let value = try? decodeIfPresent(String.self, forKey: key) {
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

private extension String {
    var redactedForDisplay: String {
        var redacted = self
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)(token|authorization|api[_ -]?key|password|secret)\s*[:= ]+\s*[A-Za-z0-9._~+/=-]{6,}"#,
            #"sk-[A-Za-z0-9_-]{6,}"#,
            #"Bearer\s+[A-Za-z0-9._~+/=-]{8,}"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: "[已隐藏]"
            )
        }

        return redacted
    }
}
