import Foundation
import SwiftUI

enum BalancePanelState: Equatable {
    case disabled
    case notConfigured
    case loading
    case healthy
    case warning
    case error
}

enum BalanceAccountState: Equatable {
    case healthy
    case warning
    case error

    var label: String {
        switch self {
        case .healthy:
            "正常"
        case .warning:
            "提醒"
        case .error:
            "异常"
        }
    }

    var color: Color {
        switch self {
        case .healthy:
            Color(red: 0.61, green: 0.95, blue: 0.68)
        case .warning:
            Color(red: 1.0, green: 0.55, blue: 0.25)
        case .error:
            Color(red: 1.0, green: 0.28, blue: 0.30)
        }
    }

    var severity: RemoteAlertSeverity {
        switch self {
        case .healthy:
            .none
        case .warning:
            .warning
        case .error:
            .error
        }
    }
}

struct BalanceThresholdConfiguration: Codable, Equatable {
    var warningThreshold: Double? = nil
    var alertThreshold: Double? = nil

    var normalized: BalanceThresholdConfiguration {
        guard let warningThreshold,
              let alertThreshold,
              alertThreshold > warningThreshold else {
            return self
        }
        return BalanceThresholdConfiguration(
            warningThreshold: alertThreshold,
            alertThreshold: warningThreshold
        )
    }

    func state(for balance: Double?) -> BalanceAccountState {
        guard let balance else {
            return .healthy
        }
        let thresholds = normalized
        if let alertThreshold = thresholds.alertThreshold,
           balance < alertThreshold {
            return .error
        }
        if let warningThreshold = thresholds.warningThreshold,
           balance < warningThreshold {
            return .warning
        }
        return .healthy
    }

    var summaryText: String {
        let thresholds = normalized
        var parts: [String] = []
        if let warningThreshold = thresholds.warningThreshold {
            parts.append("提醒 \(Self.thresholdText(warningThreshold))")
        }
        if let alertThreshold = thresholds.alertThreshold {
            parts.append("告警 \(Self.thresholdText(alertThreshold))")
        }
        return parts.isEmpty ? "不提醒" : parts.joined(separator: " · ")
    }

    private static func thresholdText(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct BalanceAccountConfiguration: Identifiable, Codable, Equatable {
    var id: String
    var source: BalanceMonitorSource
    var enabled: Bool
    var label: String
    var panelURL: String
    var username: String
    var secret: String = ""
    var secretReadFailed: Bool = false
    var allowInsecureTLS: Bool
    var requestTimeout: TimeInterval
    var usesDefaultThresholds: Bool
    var warningThreshold: Double?
    var alertThreshold: Double?

    init(
        id: String = UUID().uuidString,
        source: BalanceMonitorSource,
        enabled: Bool = true,
        label: String = "",
        panelURL: String = "",
        username: String = "",
        secret: String = "",
        allowInsecureTLS: Bool = false,
        requestTimeout: TimeInterval = 6,
        usesDefaultThresholds: Bool = true,
        warningThreshold: Double? = nil,
        alertThreshold: Double? = nil
    ) {
        self.id = id
        self.source = source
        self.enabled = enabled
        self.label = label
        self.panelURL = panelURL
        self.username = username
        self.secret = secret
        self.secretReadFailed = false
        self.allowInsecureTLS = allowInsecureTLS
        self.requestTimeout = requestTimeout
        self.usesDefaultThresholds = usesDefaultThresholds
        self.warningThreshold = warningThreshold
        self.alertThreshold = alertThreshold
    }

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case enabled
        case label
        case panelURL
        case username
        case allowInsecureTLS
        case requestTimeout
        case usesDefaultThresholds
        case warningThreshold
        case alertThreshold
    }

    var displayLabel: String {
        if let configuredLabel {
            return configuredLabel
        }
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUsername.isEmpty {
            return trimmedUsername
        }
        return "\(source.title) 账户"
    }

    var configuredLabel: String? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLabel.isEmpty {
            return trimmedLabel
        }
        return nil
    }

    func effectiveThresholds(defaults: BalanceThresholdConfiguration) -> BalanceThresholdConfiguration {
        usesDefaultThresholds
            ? defaults.normalized
            : BalanceThresholdConfiguration(
                warningThreshold: warningThreshold,
                alertThreshold: alertThreshold
            ).normalized
    }

    func thresholdSummary(defaults: BalanceThresholdConfiguration) -> String {
        let prefix = usesDefaultThresholds ? "默认" : "自定义"
        return "\(prefix)：\(effectiveThresholds(defaults: defaults).summaryText)"
    }
}

struct BalanceAccount: Identifiable, Equatable {
    let id: String
    let source: BalanceMonitorSource
    let name: String
    let kind: String
    let statusCode: Int?
    let amountText: String
    let usedText: String?
    let requestCount: Int?
    let updatedAt: String?
    let state: BalanceAccountState
    let balanceAmount: Double?
    let balanceUnitKey: String?
    let balanceUnitSymbol: String?
    let usedTokenCount: Int?

    init(
        id: String,
        source: BalanceMonitorSource,
        name: String,
        kind: String,
        statusCode: Int?,
        amountText: String,
        usedText: String?,
        requestCount: Int?,
        updatedAt: String?,
        state: BalanceAccountState,
        balanceAmount: Double? = nil,
        balanceUnitKey: String? = nil,
        balanceUnitSymbol: String? = nil,
        usedTokenCount: Int? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name
        self.kind = kind
        self.statusCode = statusCode
        self.amountText = amountText
        self.usedText = usedText
        self.requestCount = requestCount
        self.updatedAt = updatedAt
        self.state = state
        self.balanceAmount = balanceAmount
        self.balanceUnitKey = balanceUnitKey
        self.balanceUnitSymbol = balanceUnitSymbol
        self.usedTokenCount = usedTokenCount
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(source.title) 账户" : name
    }

    var detailText: String {
        var parts = [kind]
        if let usedText {
            parts.append("已用 \(usedText)")
        }
        if let usedTokenCount {
            parts.append("已用Token \(Formatters.compactTokens(usedTokenCount))")
        }
        if let requestCount {
            parts.append("请求 \(requestCount)")
        }
        if let updatedAt, !updatedAt.isEmpty {
            parts.append(updatedAt)
        }
        return parts.joined(separator: " · ")
    }
}

struct BalanceMonitorSnapshot: Equatable {
    var source: BalanceMonitorSource
    var panelState: BalancePanelState
    var accounts: [BalanceAccount]
    var message: String?
    var lastUpdated: Date?

    static func disabled(source: BalanceMonitorSource) -> BalanceMonitorSnapshot {
        BalanceMonitorSnapshot(
            source: source,
            panelState: .disabled,
            accounts: [],
            message: "\(source.title) 监测未启用",
            lastUpdated: nil
        )
    }

    static func notConfigured(source: BalanceMonitorSource) -> BalanceMonitorSnapshot {
        BalanceMonitorSnapshot(
            source: source,
            panelState: .notConfigured,
            accounts: [],
            message: "请在设置中填写 \(source.title) 地址和认证信息",
            lastUpdated: nil
        )
    }

    var panelSeverity: RemoteAlertSeverity {
        switch panelState {
        case .disabled, .notConfigured, .loading, .healthy:
            return accountSeverity
        case .warning:
            return max(.warning, accountSeverity)
        case .error:
            return .error
        }
    }

    var healthyCount: Int {
        accounts.filter { $0.state == .healthy }.count
    }

    var warningCount: Int {
        accounts.filter { $0.state == .warning }.count
    }

    var errorCount: Int {
        accounts.filter { $0.state == .error }.count
    }

    var totalAmountText: String {
        let groups = Dictionary(grouping: accounts.compactMap { account -> BalanceAmountGroup? in
            guard let amount = account.balanceAmount,
                  let key = account.balanceUnitKey,
                  let symbol = account.balanceUnitSymbol else {
                return nil
            }
            return BalanceAmountGroup(key: key, symbol: symbol, amount: amount)
        }, by: \.key)

        let totals = groups
            .map { key, values in
                BalanceAmountGroup(
                    key: key,
                    symbol: values.first?.symbol ?? "",
                    amount: values.reduce(0) { $0 + $1.amount }
                )
            }
            .sorted { $0.key < $1.key }

        if totals.count == 1,
           let total = totals.first {
            return total.displayText
        }
        if totals.count == 2 {
            return totals.map(\.displayText).joined(separator: " + ")
        }
        if totals.count > 2 {
            return "多币种 \(totals.count) 类"
        }

        let values = accounts.compactMap { account -> Double? in
            guard account.amountText.hasPrefix("$") else {
                return nil
            }
            return Double(account.amountText.dropFirst())
        }
        guard !values.isEmpty else {
            return accounts.first?.amountText ?? "--"
        }
        return Self.currencyText(values.reduce(0, +))
    }

    var summaryText: String {
        if accounts.isEmpty {
            return message ?? "暂无账户"
        }
        var parts = ["正常 \(healthyCount)"]
        if warningCount > 0 {
            parts.append("提醒 \(warningCount)")
        }
        if errorCount > 0 {
            parts.append("异常 \(errorCount)")
        }
        return parts.joined(separator: " · ")
    }

    private var accountSeverity: RemoteAlertSeverity {
        accounts.reduce(.none) { max($0, $1.state.severity) }
    }

    static func currencyText(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

private struct BalanceAmountGroup: Equatable {
    let key: String
    let symbol: String
    let amount: Double

    var displayText: String {
        if key == "TOKENS" {
            return Formatters.compactTokens(Int(amount.rounded()))
        }
        return symbol + String(format: "%.2f", amount)
    }
}
