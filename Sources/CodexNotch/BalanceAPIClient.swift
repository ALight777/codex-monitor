import Foundation

typealias BalanceAPIRequestExecutor = @Sendable (
    _ request: URLRequest,
    _ session: URLSession
) async throws -> (Data, URLResponse)

struct BalanceAPIConfiguration: Equatable {
    let panelURL: String
    let username: String
    let secret: String
    let timeout: TimeInterval
    let allowInsecureTLS: Bool
    let accountID: String
    let accountLabel: String?
    let thresholds: BalanceThresholdConfiguration

    init(
        panelURL: String,
        username: String,
        secret: String,
        timeout: TimeInterval,
        allowInsecureTLS: Bool,
        accountID: String = "default",
        accountLabel: String? = nil,
        thresholds: BalanceThresholdConfiguration = BalanceThresholdConfiguration()
    ) {
        self.panelURL = panelURL
        self.username = username
        self.secret = secret
        self.timeout = timeout
        self.allowInsecureTLS = allowInsecureTLS
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.thresholds = thresholds.normalized
    }
}

enum BalanceAPIError: LocalizedError {
    case invalidURL
    case missingKey
    case missingUsername
    case loginRequiresTwoFactor
    case httpStatus(Int, String? = nil)
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
        case .httpStatus(let status, let message):
            if let message,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status == 401 || status == 403
                    ? "认证信息无效或无权限：\(message.redactedForDisplay)"
                    : message.redactedForDisplay
            } else {
                status == 401 || status == 403 ? "认证信息无效或无权限" : "面板返回 HTTP \(status)"
            }
        case .emptyResponse:
            "面板返回空数据"
        case .unsupportedResponse(let message):
            message.isEmpty ? "面板返回格式不兼容" : message.redactedForDisplay
        }
    }
}

final class BalanceAPIClient: NSObject, URLSessionDelegate {
    private let configuration: BalanceAPIConfiguration
    private let requestExecutor: BalanceAPIRequestExecutor

    init(
        configuration: BalanceAPIConfiguration,
        requestExecutor: BalanceAPIRequestExecutor? = nil
    ) {
        self.configuration = configuration
        self.requestExecutor = requestExecutor ?? { request, session in
            try await session.data(for: request)
        }
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
        let quotaDisplay = try await fetchNewAPIQuotaDisplay(baseURL: baseURL, session: session)
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
        let accounts = [try Self.decodeUserAccount(
            selfData,
            source: source,
            quotaDisplay: quotaDisplay,
            accountID: configuration.accountID,
            accountLabel: configuration.accountLabel,
            thresholds: configuration.thresholds
        )]

        return BalanceMonitorSnapshot(
            source: source,
            panelState: Self.panelState(for: accounts, partialMessage: nil),
            accounts: accounts,
            message: accounts.isEmpty ? "没有找到 \(source.title) 账户" : nil,
            lastUpdated: Date()
        )
    }

    private func fetchNewAPIQuotaDisplay(baseURL: URL, session: URLSession) async throws -> NewAPIQuotaDisplay {
        let statusEndpoint = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("status")
        let statusData = try await requestData(
            statusEndpoint,
            method: "GET",
            headers: [
                "Accept": "application/json"
            ],
            session: session,
            timeout: configuration.timeout
        )
        return try Self.decodeNewAPIQuotaDisplay(statusData)
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
        let accounts = [try Self.decodeSubAPIProfileAccount(
            profileData,
            accountID: configuration.accountID,
            accountLabel: configuration.accountLabel,
            thresholds: configuration.thresholds
        )]

        return BalanceMonitorSnapshot(
            source: source,
            panelState: Self.panelState(for: accounts, partialMessage: nil),
            accounts: accounts,
            message: nil,
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

        let (data, response) = try await requestExecutor(request, session)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw BalanceAPIError.httpStatus(
                httpResponse.statusCode,
                Self.httpFailureMessage(statusCode: httpResponse.statusCode, data: data)
            )
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
        guard components.user == nil, components.password == nil else {
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

    private static func isLocalHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    static func decodeUserAccount(
        _ data: Data,
        source: BalanceMonitorSource,
        quotaDisplay: NewAPIQuotaDisplay = .default,
        accountID: String = "self",
        accountLabel: String? = nil,
        thresholds: BalanceThresholdConfiguration = BalanceThresholdConfiguration()
    ) throws -> BalanceAccount {
        let user = try decodePayload(NewAPIUserData.self, from: data)
        return user.balanceAccount(
            source: source,
            quotaDisplay: quotaDisplay,
            accountID: accountID,
            accountLabel: accountLabel,
            thresholds: thresholds
        )
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

    static func decodeNewAPIQuotaDisplay(_ data: Data) throws -> NewAPIQuotaDisplay {
        try decodePayload(NewAPIStatusData.self, from: data).quotaDisplay
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
        guard isValidEmail(username) else {
            throw BalanceAPIError.unsupportedResponse("Sub2API 登录邮箱格式不正确")
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

    static func decodeSubAPIProfileAccount(
        _ data: Data,
        accountID: String = "self",
        accountLabel: String? = nil,
        thresholds: BalanceThresholdConfiguration = BalanceThresholdConfiguration()
    ) throws -> BalanceAccount {
        try decodeSubAPIPayload(SubAPIUserData.self, from: data).balanceAccount(
            accountID: accountID,
            accountLabel: accountLabel,
            thresholds: thresholds
        )
    }

    static func httpFailureMessage(statusCode: Int, data: Data) -> String {
        let decoder = JSONDecoder()
        let message = (try? decoder.decode(HTTPErrorEnvelope.self, from: data).message)
            ?? (try? decoder.decode(SubAPIEnvelope<EmptyPayload>.self, from: data).message)
            ?? (String(data: data, encoding: .utf8) ?? "")
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("LoginRequest.Email"),
           trimmed.contains("email") {
            return "Sub2API 登录邮箱格式不正确"
        }
        return trimmed.isEmpty ? "面板返回 HTTP \(statusCode)" : trimmed
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

    private static func isValidEmail(_ input: String) -> Bool {
        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        return input.range(of: pattern, options: .regularExpression) != nil
    }
}

private struct HTTPErrorEnvelope: Decodable {
    let message: String?
}

private struct EmptyPayload: Decodable {}

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

struct NewAPIQuotaDisplay: Equatable {
    enum DisplayType: String {
        case usd = "USD"
        case cny = "CNY"
        case custom = "CUSTOM"
        case tokens = "TOKENS"
    }

    static let `default` = NewAPIQuotaDisplay(
        quotaPerUnit: 500_000,
        displayType: .usd,
        exchangeRate: 1,
        customSymbol: "¤",
        customExchangeRate: 1
    )

    let quotaPerUnit: Double
    let displayType: DisplayType
    let exchangeRate: Double
    let customSymbol: String
    let customExchangeRate: Double

    func quotaText(_ quota: Int) -> String {
        switch displayType {
        case .tokens:
            return Formatters.compactTokens(quota)
        case .usd:
            return String(format: "$%.2f", quotaValue(quota))
        case .cny:
            return String(format: "¥%.2f", quotaValue(quota) * exchangeRate)
        case .custom:
            return customSymbol + String(format: "%.2f", quotaValue(quota) * customExchangeRate)
        }
    }

    func quotaAmount(_ quota: Int) -> Double {
        switch displayType {
        case .tokens:
            return Double(quota)
        case .usd:
            return quotaValue(quota)
        case .cny:
            return quotaValue(quota) * exchangeRate
        case .custom:
            return quotaValue(quota) * customExchangeRate
        }
    }

    var unitKey: String {
        switch displayType {
        case .tokens:
            return "TOKENS"
        case .usd:
            return "USD"
        case .cny:
            return "CNY"
        case .custom:
            return "CUSTOM-\(customSymbol)"
        }
    }

    var unitSymbol: String {
        switch displayType {
        case .tokens:
            return ""
        case .usd:
            return "$"
        case .cny:
            return "¥"
        case .custom:
            return customSymbol
        }
    }

    private func quotaValue(_ quota: Int) -> Double {
        Double(quota) / max(1, quotaPerUnit)
    }
}

private struct NewAPIStatusData: Decodable {
    let quotaPerUnit: Double?
    let quotaDisplayType: String?
    let displayInCurrency: Bool?
    let usdExchangeRate: Double?
    let customCurrencySymbol: String?
    let customCurrencyExchangeRate: Double?

    enum CodingKeys: String, CodingKey {
        case quotaPerUnit = "quota_per_unit"
        case quotaPerUnitCamel = "quotaPerUnit"
        case quotaDisplayType = "quota_display_type"
        case quotaDisplayTypeCamel = "quotaDisplayType"
        case displayInCurrency = "display_in_currency"
        case displayInCurrencyCamel = "displayInCurrency"
        case usdExchangeRate = "usd_exchange_rate"
        case usdExchangeRateCamel = "usdExchangeRate"
        case customCurrencySymbol = "custom_currency_symbol"
        case customCurrencySymbolCamel = "customCurrencySymbol"
        case customCurrencyExchangeRate = "custom_currency_exchange_rate"
        case customCurrencyExchangeRateCamel = "customCurrencyExchangeRate"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quotaPerUnit = container.flexibleDouble(for: [.quotaPerUnit, .quotaPerUnitCamel])
        quotaDisplayType = container.flexibleString(for: [.quotaDisplayType, .quotaDisplayTypeCamel])
        displayInCurrency = container.flexibleBool(for: [.displayInCurrency, .displayInCurrencyCamel])
        usdExchangeRate = container.flexibleDouble(for: [.usdExchangeRate, .usdExchangeRateCamel])
        customCurrencySymbol = container.flexibleString(for: [.customCurrencySymbol, .customCurrencySymbolCamel])
        customCurrencyExchangeRate = container.flexibleDouble(for: [.customCurrencyExchangeRate, .customCurrencyExchangeRateCamel])
    }

    var quotaDisplay: NewAPIQuotaDisplay {
        let normalizedType = quotaDisplayType?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let displayType: NewAPIQuotaDisplay.DisplayType
        if let normalizedType,
           let type = NewAPIQuotaDisplay.DisplayType(rawValue: normalizedType) {
            displayType = type
        } else if displayInCurrency == true {
            displayType = .cny
        } else {
            displayType = .usd
        }

        return NewAPIQuotaDisplay(
            quotaPerUnit: quotaPerUnit.flatMap { $0 > 0 ? $0 : nil } ?? NewAPIQuotaDisplay.default.quotaPerUnit,
            displayType: displayType,
            exchangeRate: usdExchangeRate.flatMap { $0 > 0 ? $0 : nil } ?? 1,
            customSymbol: customCurrencySymbol?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? customCurrencySymbol!
                : NewAPIQuotaDisplay.default.customSymbol,
            customExchangeRate: customCurrencyExchangeRate.flatMap { $0 > 0 ? $0 : nil } ?? 1
        )
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

    func balanceAccount(
        source: BalanceMonitorSource,
        quotaDisplay: NewAPIQuotaDisplay,
        accountID: String,
        accountLabel: String?,
        thresholds: BalanceThresholdConfiguration
    ) -> BalanceAccount {
        let statusState: BalanceAccountState = status == nil || status == 1 ? .healthy : .warning
        let balanceAmount = quota.map(quotaDisplay.quotaAmount(_:))
        let thresholdState = thresholds.state(for: balanceAmount)
        let state = statusState.combined(with: thresholdState)
        let statusReason = statusState == .warning ? "账号状态异常" : nil
        let configuredLabel = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = configuredLabel?.isEmpty == false
            ? configuredLabel!
            : (displayName ?? username ?? "\(source.title) 用户")
        return BalanceAccount(
            id: "\(source.rawValue)-\(accountID)",
            source: source,
            name: name,
            kind: "用户额度",
            statusCode: status,
            amountText: quota.map(quotaDisplay.quotaText(_:)) ?? "--",
            usedText: usedQuota.map(quotaDisplay.quotaText(_:)),
            requestCount: requestCount,
            updatedAt: nil,
            state: state,
            stateReason: thresholds.stateReason(for: balanceAmount) ?? statusReason,
            balanceAmount: balanceAmount,
            balanceUnitKey: balanceAmount == nil ? nil : quotaDisplay.unitKey,
            balanceUnitSymbol: balanceAmount == nil ? nil : quotaDisplay.unitSymbol
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
            state: state,
            stateReason: state == .warning ? "渠道状态异常" : nil,
            balanceAmount: balance,
            balanceUnitKey: balance == nil ? nil : "USD",
            balanceUnitSymbol: balance == nil ? nil : "$",
            usedTokenCount: usedQuota
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

    func balanceAccount(
        accountID: String,
        accountLabel: String?,
        thresholds: BalanceThresholdConfiguration
    ) -> BalanceAccount {
        let normalizedStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let statusState: BalanceAccountState = normalizedStatus == nil || normalizedStatus == "active" ? .healthy : .warning
        let thresholdState = thresholds.state(for: balance)
        let state = statusState.combined(with: thresholdState)
        let statusReason = statusState == .warning ? "状态异常" : nil
        let roleText = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "admin" ? "管理员余额" : "用户余额"
        let details = [
            concurrency.map { "并发 \($0)" },
            Self.statusDetailText(for: normalizedStatus)
        ].compactMap { $0 }.joined(separator: " · ")
        let configuredLabel = accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = configuredLabel?.isEmpty == false
            ? configuredLabel!
            : (email ?? username ?? "用户 \(id.map(String.init) ?? "")")
        return BalanceAccount(
            id: "subapi-user-\(accountID)",
            source: .subAPI,
            name: name,
            kind: roleText,
            statusCode: nil,
            amountText: balance.map(BalanceMonitorSnapshot.currencyText(_:)) ?? "--",
            usedText: nil,
            requestCount: nil,
            updatedAt: details.isEmpty ? nil : details,
            state: state,
            stateReason: thresholds.stateReason(for: balance) ?? statusReason,
            balanceAmount: balance,
            balanceUnitKey: balance == nil ? nil : "USD",
            balanceUnitSymbol: balance == nil ? nil : "$"
        )
    }

    private static func statusDetailText(for normalizedStatus: String?) -> String? {
        guard let normalizedStatus else {
            return nil
        }
        if normalizedStatus == "active" {
            return "状态 active"
        }
        return "状态异常"
    }
}

private extension BalanceAccountState {
    func combined(with other: BalanceAccountState) -> BalanceAccountState {
        if self == .error || other == .error {
            return .error
        }
        if self == .warning || other == .warning {
            return .warning
        }
        return .healthy
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
