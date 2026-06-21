import Foundation
import SwiftUI

enum RemotePanelState: Equatable {
    case disabled
    case notConfigured
    case loading
    case healthy
    case warning
    case error
}

enum RemoteAlertSeverity: Int, Comparable, Equatable {
    case none
    case warning
    case error

    static func < (lhs: RemoteAlertSeverity, rhs: RemoteAlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum RemoteAccountState: Equatable {
    case healthy
    case quotaExhausted
    case abnormal

    var label: String {
        switch self {
        case .healthy:
            "正常"
        case .quotaExhausted:
            "配额耗尽"
        case .abnormal:
            "异常"
        }
    }

    var severity: RemoteAlertSeverity {
        switch self {
        case .healthy:
            .none
        case .quotaExhausted:
            .warning
        case .abnormal:
            .error
        }
    }

    var color: Color {
        switch self {
        case .healthy:
            Color(red: 0.61, green: 0.95, blue: 0.68)
        case .quotaExhausted:
            Color(red: 1.0, green: 0.55, blue: 0.25)
        case .abnormal:
            Color(red: 1.0, green: 0.28, blue: 0.30)
        }
    }
}

struct RemoteCodexAccount: Identifiable, Equatable {
    let id: String
    let name: String
    let email: String?
    let label: String?
    let provider: String?
    let accountType: String?
    let authIndex: String?
    let chatgptAccountID: String?
    let status: String?
    let statusMessage: String?
    let successCount: Int
    let failureCount: Int
    let recentFailures: Int
    let state: RemoteAccountState
    let lastRefresh: String?
    let planType: String?
    let quotaWindows: [RemoteQuotaWindow]
    let quotaError: String?
    let unavailable: Bool

    init(
        id: String,
        name: String,
        email: String?,
        label: String?,
        provider: String?,
        accountType: String?,
        authIndex: String?,
        chatgptAccountID: String?,
        status: String?,
        statusMessage: String?,
        successCount: Int,
        failureCount: Int,
        recentFailures: Int,
        state: RemoteAccountState,
        lastRefresh: String?,
        planType: String?,
        quotaWindows: [RemoteQuotaWindow],
        quotaError: String?,
        unavailable: Bool = false
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.label = label
        self.provider = provider
        self.accountType = accountType
        self.authIndex = authIndex
        self.chatgptAccountID = chatgptAccountID
        self.status = status
        self.statusMessage = statusMessage
        self.successCount = successCount
        self.failureCount = failureCount
        self.recentFailures = recentFailures
        self.state = state
        self.lastRefresh = lastRefresh
        self.planType = planType
        self.quotaWindows = quotaWindows
        self.quotaError = quotaError
        self.unavailable = unavailable
    }

    var displayName: String {
        if let label, !label.isEmpty {
            return label
        }
        if let email, !email.isEmpty {
            return email
        }
        return name
    }

    var detailText: String {
        var parts: [String] = []
        if let email, !email.isEmpty, email != displayName {
            parts.append(email)
        }
        if let authIndex, !authIndex.isEmpty {
            parts.append("索引 \(authIndex)")
        }
        parts.append("成功 \(successCount)")
        parts.append("失败 \(failureCount)")
        return parts.joined(separator: " · ")
    }

    var quotaSummaryText: String {
        guard !quotaWindows.isEmpty else {
            if let quotaError, !quotaError.isEmpty {
                return "额度失败"
            }
            return "额度 --"
        }
        return quotaWindows
            .sortedForSummary
            .prefix(2)
            .map { window in
            "\(window.shortLabel) \(window.remainingText)"
        }.joined(separator: "  ")
    }

    var stateReasonText: String {
        switch state {
        case .healthy:
            return "正常"
        case .quotaExhausted:
            return quotaThresholdReason ?? "额度达到阈值"
        case .abnormal:
            return abnormalReason
        }
    }

    var planLabel: String? {
        guard let planType, !planType.isEmpty else {
            return nil
        }
        switch planType.lowercased() {
        case "plus":
            return "Plus"
        case "team":
            return "Team"
        case "free":
            return "Free"
        case "pro":
            return "Pro 20x"
        case "prolite", "pro-lite", "pro_lite":
            return "Pro 5x"
        default:
            return planType
        }
    }

    var withQuotaExhaustion: RemoteCodexAccount {
        if quotaError?.isRemoteAuthFailure == true {
            return replacingState(.abnormal)
        }

        if quotaWindows.contains(where: { $0.reachesThreshold }) {
            return replacingState(.quotaExhausted)
        }

        return self
    }

    static func preservingQuota(
        in currentAccounts: [RemoteCodexAccount],
        from previousAccounts: [RemoteCodexAccount]
    ) -> [RemoteCodexAccount] {
        guard !currentAccounts.isEmpty, !previousAccounts.isEmpty else {
            return currentAccounts
        }

        let previousByID = Dictionary(
            previousAccounts.map { ($0.stableMergeKey, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )

        return currentAccounts.map { account in
            let previous = previousByID[account.stableMergeKey]
            if account.quotaError != nil {
                return account.preservingFailedQuota(from: previous)
            }
            return account.preservingQuota(from: previous)
        }
    }

    func stateAfterMergingFreshQuota(windows: [RemoteQuotaWindow], error: String?) -> RemoteAccountState {
        if error?.isRemoteAuthFailure == true {
            return .abnormal
        }

        if windows.contains(where: { $0.reachesThreshold }) {
            return .quotaExhausted
        }

        if error == nil, !windows.isEmpty, state == .quotaExhausted {
            return .healthy
        }

        return state
    }

    var hasLongTermQuotaExhaustion: Bool {
        quotaWindows.contains { $0.reachesThreshold && !$0.isShortTermWindow }
    }

    func preservingQuota(from previous: RemoteCodexAccount?) -> RemoteCodexAccount {
        guard quotaWindows.isEmpty,
              quotaError == nil,
              let previous else {
            return withQuotaExhaustion
        }
        guard !previous.quotaWindows.isEmpty else {
            return withQuotaExhaustion
        }

        return RemoteCodexAccount(
            id: id,
            name: name,
            email: email,
            label: label,
            provider: provider,
            accountType: accountType,
            authIndex: authIndex,
            chatgptAccountID: chatgptAccountID,
            status: status,
            statusMessage: statusMessage,
            successCount: successCount,
            failureCount: failureCount,
            recentFailures: recentFailures,
            state: stateAfterMergingFreshQuota(windows: previous.quotaWindows, error: previous.quotaError),
            lastRefresh: lastRefresh,
            planType: planType ?? previous.planType,
            quotaWindows: previous.quotaWindows,
            quotaError: previous.quotaError,
            unavailable: unavailable
        ).withQuotaExhaustion
    }

    func preservingFailedQuota(from previous: RemoteCodexAccount?) -> RemoteCodexAccount {
        guard quotaError != nil,
              let previous,
              !previous.quotaWindows.isEmpty else {
            return withQuotaExhaustion
        }

        if quotaError?.isRemoteAuthFailure == true {
            return withQuotaExhaustion
        }

        return RemoteCodexAccount(
            id: id,
            name: name,
            email: email,
            label: label,
            provider: provider,
            accountType: accountType,
            authIndex: authIndex,
            chatgptAccountID: chatgptAccountID,
            status: status,
            statusMessage: statusMessage,
            successCount: successCount,
            failureCount: failureCount,
            recentFailures: recentFailures,
            state: state,
            lastRefresh: lastRefresh,
            planType: planType ?? previous.planType,
            quotaWindows: previous.quotaWindows,
            quotaError: quotaError,
            unavailable: unavailable
        ).withQuotaExhaustion
    }

    private var quotaThresholdReason: String? {
        let reachedWindows = quotaWindows.filter(\.reachesThreshold)
        guard !reachedWindows.isEmpty else {
            return nil
        }

        let preferredWindow = reachedWindows.first { $0.isShortTermWindow } ?? reachedWindows[0]
        return "\(preferredWindow.reasonLabel)已满"
    }

    private var abnormalReason: String {
        if quotaError?.isRemoteAuthFailure == true {
            return "登录已过期"
        }

        if unavailable {
            return "账号不可用"
        }

        if let status, !status.isEmpty {
            let normalizedStatus = status.lowercased()
            let healthyStatuses = ["active", "available", "enabled", "normal", "ready", "ok", "healthy", "valid"]
            if !healthyStatuses.contains(normalizedStatus) {
                return "状态 \(status)"
            }
        }

        if let statusMessage, !statusMessage.isEmpty, statusMessage.lowercased() != "ok" {
            return statusMessage.redactedForDisplay.shortReason
        }

        if recentFailures > 0 {
            return "近期请求失败"
        }

        if failureCount > 0 {
            return "请求失败 \(failureCount)"
        }

        return "账号异常"
    }

    private func replacingState(_ nextState: RemoteAccountState) -> RemoteCodexAccount {
        RemoteCodexAccount(
            id: id,
            name: name,
            email: email,
            label: label,
            provider: provider,
            accountType: accountType,
            authIndex: authIndex,
            chatgptAccountID: chatgptAccountID,
            status: status,
            statusMessage: statusMessage,
            successCount: successCount,
            failureCount: failureCount,
            recentFailures: recentFailures,
            state: nextState,
            lastRefresh: lastRefresh,
            planType: planType,
            quotaWindows: quotaWindows,
            quotaError: quotaError,
            unavailable: unavailable
        )
    }

    private var stableMergeKey: String {
        authIndex?.lowercased()
            ?? chatgptAccountID?.lowercased()
            ?? email?.lowercased()
            ?? id.lowercased()
    }
}

struct RemoteQuotaWindow: Identifiable, Equatable {
    let id: String
    let shortLabel: String
    let remainingPercent: Int?
    let usedPercent: Double?
    let resetText: String?
    let limitReached: Bool

    init(
        id: String,
        shortLabel: String,
        remainingPercent: Int?,
        usedPercent: Double?,
        resetText: String?,
        limitReached: Bool = false
    ) {
        self.id = id
        self.shortLabel = shortLabel
        self.remainingPercent = remainingPercent
        self.usedPercent = usedPercent
        self.resetText = resetText
        self.limitReached = limitReached
    }

    var remainingText: String {
        guard let remainingPercent else {
            return "--"
        }
        return "\(remainingPercent)%"
    }

    var usedText: String {
        guard let usedPercent else {
            return "--"
        }
        return "\(Int(usedPercent.rounded()))%"
    }

    var reachesThreshold: Bool {
        if let usedPercent, usedPercent >= 100 {
            return true
        }
        if let remainingPercent, remainingPercent <= 0 {
            return true
        }
        if usedPercent != nil || remainingPercent != nil {
            return false
        }
        return limitReached
    }

    var isShortTermWindow: Bool {
        shortLabel == "5h" || shortLabel.hasSuffix(" 5h")
    }

    var reasonLabel: String {
        let label = shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if label == "5h" {
            return "5小时额度"
        }
        if label == "7d" {
            return "周额度"
        }
        if label == "30d" {
            return "月额度"
        }
        if label.hasSuffix(" 5h") {
            return label.replacingOccurrences(of: " 5h", with: " 5小时额度")
        }
        if label.hasSuffix(" 7d") {
            return label.replacingOccurrences(of: " 7d", with: " 周额度")
        }
        if label.hasSuffix(" 30d") {
            return label.replacingOccurrences(of: " 30d", with: " 月额度")
        }
        return "\(label)额度"
    }

    var summarySortPriority: Int {
        let label = shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if label == "5h" || label.hasSuffix(" 5h") {
            return 0
        }
        if label == "7d" || label.hasSuffix(" 7d") {
            return 1
        }
        if reachesThreshold {
            return 2
        }
        if label == "30d" || label.hasSuffix(" 30d") {
            return 3
        }
        return 4
    }
}

private extension Array where Element == RemoteQuotaWindow {
    var sortedForSummary: [RemoteQuotaWindow] {
        sorted {
            if $0.summarySortPriority == $1.summarySortPriority {
                return $0.shortLabel < $1.shortLabel
            }
            return $0.summarySortPriority < $1.summarySortPriority
        }
    }
}

private extension String {
    var isRemoteAuthFailure: Bool {
        let lowercased = lowercased()
        return lowercased.contains("401")
            || lowercased.contains("unauthorized")
            || lowercased.contains("认证")
            || lowercased.contains("登录")
            || lowercased.contains("令牌")
            || lowercased.contains("token")
    }

    var shortReason: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else {
            return trimmed
        }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 10)
        return String(trimmed[..<end]) + "..."
    }

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

struct RemoteMonitorSnapshot: Equatable {
    var panelState: RemotePanelState
    var accounts: [RemoteCodexAccount]
    var message: String?
    var lastUpdated: Date?
    var usage24h: Int = 0
    var usage7d: Int = 0
    var usage30d: Int = 0
    var usageMessage: String?
    var usageUnavailableForSource: Bool = false

    static let disabled = RemoteMonitorSnapshot(
        panelState: .disabled,
        accounts: [],
        message: "远程监测未启用",
        lastUpdated: nil
    )

    static let notConfigured = RemoteMonitorSnapshot(
        panelState: .notConfigured,
        accounts: [],
        message: "请在设置中填写 CLIProxyAPI 面板地址和管理密钥",
        lastUpdated: nil
    )

    var alertSeverity: RemoteAlertSeverity {
        Self.poolAlertSeverity(for: accounts)
    }

    var panelSeverity: RemoteAlertSeverity {
        switch panelState {
        case .disabled, .notConfigured, .loading, .healthy:
            return alertSeverity
        case .warning:
            return max(.warning, alertSeverity)
        case .error:
            return .error
        }
    }

    static func poolAlertSeverity(for accounts: [RemoteCodexAccount]) -> RemoteAlertSeverity {
        guard !accounts.isEmpty else {
            return .none
        }

        if accounts.contains(where: { $0.state == .abnormal }) {
            return .error
        }

        let quotaFailureAccounts = accounts.filter { account in
            account.quotaWindows.isEmpty && account.quotaError?.isEmpty == false
        }
        if quotaFailureAccounts.count == accounts.count {
            return .warning
        }
        if accounts.count >= 3, quotaFailureAccounts.count * 2 > accounts.count {
            return .warning
        }

        let quotaAccounts = accounts.filter { $0.state == .quotaExhausted }
        guard !quotaAccounts.isEmpty else {
            return .none
        }

        let healthyCount = accounts.filter { $0.state == .healthy }.count
        if quotaAccounts.count == accounts.count {
            return .warning
        }
        if quotaAccounts.count * 2 > accounts.count {
            return .warning
        }
        if accounts.count >= 3, healthyCount <= 1 {
            return .warning
        }
        if quotaAccounts.contains(where: \.hasLongTermQuotaExhaustion),
           healthyCount * 2 <= accounts.count {
            return .warning
        }

        return .none
    }

    var healthyCount: Int {
        accounts.filter { $0.state == .healthy }.count
    }

    var quotaCount: Int {
        accounts.filter { $0.state == .quotaExhausted }.count
    }

    var abnormalCount: Int {
        accounts.filter { $0.state == .abnormal }.count
    }

    var summaryText: String {
        if accounts.isEmpty {
            return message ?? "暂无远程账号"
        }
        var parts = ["正常 \(healthyCount)"]
        if quotaCount > 0 {
            parts.append("配额耗尽 \(quotaCount)")
        }
        if abnormalCount > 0 {
            parts.append("异常 \(abnormalCount)")
        }
        return parts.joined(separator: " · ")
    }
}

struct CLIProxyAuthFilesResponse: Decodable {
    let files: [CLIProxyAuthFile]
}

struct CLIProxyAuthFile: Decodable {
    let id: String?
    let authIndex: String?
    let name: String?
    let type: String?
    let provider: String?
    let label: String?
    let status: String?
    let statusMessage: String?
    let disabled: Bool?
    let unavailable: Bool?
    let success: Int?
    let failed: Int?
    let recentRequests: [CLIProxyRecentRequest]?
    let email: String?
    let accountType: String?
    let account: String?
    let lastRefresh: String?
    let idToken: CLIProxyIDToken?

    enum CodingKeys: String, CodingKey {
        case id
        case authIndex = "auth_index"
        case authIndexCamel = "authIndex"
        case name
        case type
        case provider
        case label
        case status
        case statusMessage = "status_message"
        case statusMessageCamel = "statusMessage"
        case disabled
        case unavailable
        case success
        case failed
        case recentRequests = "recent_requests"
        case recentRequestsCamel = "recentRequests"
        case email
        case accountType = "account_type"
        case accountTypeCamel = "accountType"
        case account
        case lastRefresh = "last_refresh"
        case lastRefreshCamel = "lastRefresh"
        case idToken = "id_token"
        case idTokenCamel = "idToken"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.flexibleString(for: [.id])
        authIndex = container.flexibleString(for: [.authIndex, .authIndexCamel])
        name = container.flexibleString(for: [.name])
        type = container.flexibleString(for: [.type])
        provider = container.flexibleString(for: [.provider])
        label = container.flexibleString(for: [.label])
        status = container.flexibleString(for: [.status])
        statusMessage = container.flexibleString(for: [.statusMessage, .statusMessageCamel])
        disabled = container.flexibleBool(for: [.disabled])
        unavailable = container.flexibleBool(for: [.unavailable])
        success = container.flexibleInt(for: [.success])
        failed = container.flexibleInt(for: [.failed])
        recentRequests = container.decodeFirst([CLIProxyRecentRequest].self, for: [.recentRequests, .recentRequestsCamel])
        email = container.flexibleString(for: [.email])
        accountType = container.flexibleString(for: [.accountType, .accountTypeCamel])
        account = container.flexibleString(for: [.account])
        lastRefresh = container.flexibleString(for: [.lastRefresh, .lastRefreshCamel])
        idToken = container.decodeFirst(CLIProxyIDToken.self, for: [.idToken, .idTokenCamel])
    }
}

struct CLIProxyIDToken: Decodable {
    let chatgptAccountID: String?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case chatgptAccountID = "chatgpt_account_id"
        case chatgptAccountIDCamel = "chatgptAccountId"
        case planType = "plan_type"
        case planTypeCamel = "planType"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatgptAccountID = try container.decodeIfPresent(String.self, forKey: .chatgptAccountID)
            ?? container.decodeIfPresent(String.self, forKey: .chatgptAccountIDCamel)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
            ?? container.decodeIfPresent(String.self, forKey: .planTypeCamel)
    }
}

struct CLIProxyRecentRequest: Decodable, Equatable {
    let time: String?
    let success: Int?
    let failed: Int?

    enum CodingKeys: String, CodingKey {
        case time
        case success
        case failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = container.flexibleString(for: [.time])
        success = container.flexibleInt(for: [.success])
        failed = container.flexibleInt(for: [.failed])
    }
}

private extension KeyedDecodingContainer {
    func decodeFirst<T: Decodable>(_ type: T.Type, for keys: [Key]) -> T? {
        for key in keys {
            if let value = try? decodeIfPresent(type, forKey: key) {
                return value
            }
        }
        return nil
    }

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

    func flexibleBool(for keys: [Key]) -> Bool? {
        for key in keys {
            if let value = try? decodeIfPresent(Bool.self, forKey: key) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: key) {
                return value != 0
            }
            if let value = try? decodeIfPresent(String.self, forKey: key) {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1", "yes":
                    return true
                case "false", "0", "no":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }
}
