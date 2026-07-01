import Combine
import Foundation

@MainActor
final class BalanceMonitorViewModel: ObservableObject {
    @Published private(set) var snapshot: BalanceMonitorSnapshot
    @Published private(set) var isRefreshing = false

    let source: BalanceMonitorSource

    private let settings: CodexNotchSettings
    private var refreshTimer: Timer?
    private var settingsTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingRefresh = false
    private var consecutiveFailures = 0
    private var refreshGeneration = 0
    private var observedSettings: BalanceMonitorSettingsSnapshot?
    private var loadedSettings: BalanceMonitorSettingsSnapshot?

    init(source: BalanceMonitorSource, settings: CodexNotchSettings) {
        self.source = source
        self.settings = settings
        self.snapshot = .disabled(source: source)
        observeSettings()
        refreshSnapshot()
    }

    func refreshNow() {
        consecutiveFailures = 0
        refreshSnapshot(cancelInFlight: true)
    }

    func refresh() {
        refreshSnapshot()
    }

    private func refreshSnapshot(cancelInFlight: Bool = false) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        if cancelInFlight {
            invalidateInFlightRefresh()
        }

        guard settings.balanceMonitorEnabled(for: source) else {
            invalidateInFlightRefresh()
            loadedSettings = nil
            snapshot = .disabled(source: source)
            return
        }
        guard settings.loadSecretsIfNeeded() else {
            invalidateInFlightRefresh()
            loadedSettings = nil
            snapshot = BalanceMonitorSnapshot(
                source: source,
                panelState: .error,
                accounts: [],
                message: settings.secretStorageError ?? "密钥读取失败",
                lastUpdated: Date()
            )
            return
        }

        let settingsSnapshot = BalanceMonitorSettingsSnapshot(source: source, settings: settings)
        let targets = refreshTargets(from: settingsSnapshot)
        guard !settingsSnapshot.accounts.filter(\.enabled).isEmpty,
              !targets.isEmpty else {
            invalidateInFlightRefresh()
            loadedSettings = nil
            snapshot = .notConfigured(source: source)
            return
        }

        guard !isRefreshing else {
            pendingRefresh = true
            return
        }

        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        let canPreserveSnapshot = loadedSettings == settingsSnapshot
        if snapshot.accounts.isEmpty || !canPreserveSnapshot {
            snapshot = BalanceMonitorSnapshot(
                source: source,
                panelState: .loading,
                accounts: [],
                message: "正在读取 \(source.title) 余额",
                lastUpdated: canPreserveSnapshot ? snapshot.lastUpdated : nil
            )
        }

        let source = source
        let totalTimeout = max(8, (targets.compactMap(\.configuration?.timeout).max() ?? 6) * 3 + 3)

        refreshTask = Task.detached(priority: .utility) {
            do {
                let nextSnapshot = try await Self.withTimeout(seconds: totalTimeout) {
                    await Self.fetchCombinedSnapshot(source: source, targets: targets)
                }
                await MainActor.run {
                    guard generation == self.refreshGeneration else {
                        return
                    }
                    guard self.currentSettingsSnapshot() == settingsSnapshot,
                          self.settings.balanceMonitorEnabled(for: self.source) else {
                        self.finishRefreshAndRunPending()
                        if !self.settings.balanceMonitorEnabled(for: self.source) {
                            self.snapshot = .disabled(source: self.source)
                        }
                        return
                    }
                    self.consecutiveFailures = nextSnapshot.accounts.allSatisfy { $0.state == .error }
                        ? self.consecutiveFailures + 1
                        : 0
                    self.isRefreshing = false
                    self.refreshTask = nil
                    self.loadedSettings = settingsSnapshot
                    self.snapshot = nextSnapshot
                    self.scheduleRefresh()
                    self.runPendingRefreshIfNeeded()
                }
            } catch {
                await MainActor.run {
                    guard generation == self.refreshGeneration else {
                        return
                    }
                    guard self.currentSettingsSnapshot() == settingsSnapshot,
                          self.settings.balanceMonitorEnabled(for: self.source) else {
                        self.finishRefreshAndRunPending()
                        if !self.settings.balanceMonitorEnabled(for: self.source) {
                            self.snapshot = .disabled(source: self.source)
                        }
                        return
                    }
                    self.consecutiveFailures += 1
                    self.isRefreshing = false
                    self.refreshTask = nil
                    self.snapshot = BalanceMonitorSnapshot(
                        source: self.source,
                        panelState: .error,
                        accounts: canPreserveSnapshot ? self.snapshot.accounts : [],
                        message: self.localizedMessage(for: error),
                        lastUpdated: Date()
                    )
                    self.scheduleRefresh()
                    self.runPendingRefreshIfNeeded()
                }
            }
        }
    }

    private func observeSettings() {
        observedSettings = BalanceMonitorSettingsSnapshot(source: source, settings: settings)
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    Task { @MainActor in
                        self?.settingsMayHaveChanged()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func settingsMayHaveChanged() {
        let next = BalanceMonitorSettingsSnapshot(source: source, settings: settings)
        guard next != observedSettings else {
            return
        }
        observedSettings = next
        settingsTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.consecutiveFailures = 0
                self?.refreshSnapshot(cancelInFlight: true)
            }
        }
        timer.tolerance = 0.2
        settingsTimer = timer
    }

    private func scheduleRefresh() {
        guard settings.balanceMonitorEnabled(for: source) else {
            return
        }

        let base = settings.balanceRefreshInterval(for: source)
        let interval = BalanceRefreshCadence.refreshInterval(
            base: base,
            consecutiveFailures: consecutiveFailures
        )
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = min(20, interval * 0.2)
        refreshTimer = timer
    }

    private func finishRefreshAndRunPending() {
        isRefreshing = false
        refreshTask = nil
        runPendingRefreshIfNeeded()
    }

    private func invalidateInFlightRefresh() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefresh = false
        isRefreshing = false
    }

    private func runPendingRefreshIfNeeded() {
        guard pendingRefresh else {
            return
        }
        pendingRefresh = false
        refreshSnapshot()
    }

    private func currentSettingsSnapshot() -> BalanceMonitorSettingsSnapshot {
        BalanceMonitorSettingsSnapshot(source: source, settings: settings)
    }

    private func refreshTargets(from snapshot: BalanceMonitorSettingsSnapshot) -> [BalanceRefreshTarget] {
        snapshot.accounts
            .filter(\.enabled)
            .enumerated()
            .map { offset, account in
                let panelURL = account.panelURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let username = account.username.trimmingCharacters(in: .whitespacesAndNewlines)
                let secret = account.secret.trimmingCharacters(in: .whitespacesAndNewlines)
                let missing: String?
                if panelURL.isEmpty {
                    missing = "缺少面板地址"
                } else if username.isEmpty {
                    missing = snapshot.source == .subAPI ? "缺少登录邮箱" : "缺少用户名"
                } else if secret.isEmpty {
                    missing = "缺少密码"
                } else {
                    missing = nil
                }
                let configuration = missing == nil
                    ? BalanceAPIConfiguration(
                        panelURL: panelURL,
                        username: username,
                        secret: secret,
                        timeout: account.requestTimeout,
                        allowInsecureTLS: account.allowInsecureTLS,
                        accountID: account.id,
                        accountLabel: account.configuredLabel,
                        thresholds: account.effectiveThresholds(defaults: snapshot.defaultThresholds)
                    )
                    : nil
                return BalanceRefreshTarget(
                    order: offset,
                    source: snapshot.source,
                    account: account,
                    configuration: configuration,
                    missingMessage: missing
                )
            }
    }

    private func localizedMessage(for error: Error) -> String {
        if error is BalanceRefreshTimeoutError {
            return "\(source.title) 刷新超时"
        }
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        let message = error.localizedDescription
        if message.contains("secure connection") || message.contains("SSL") || message.contains("TLS") {
            return "TLS 连接失败，请检查面板地址、证书或反向代理配置"
        }
        if message.contains("timed out") {
            return "连接超时"
        }
        return message.redactedForDisplay
    }

    nonisolated private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanoseconds = UInt64(max(0.1, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw BalanceRefreshTimeoutError()
            }

            guard let result = try await group.next() else {
                throw BalanceRefreshTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    nonisolated private static func fetchCombinedSnapshot(
        source: BalanceMonitorSource,
        targets: [BalanceRefreshTarget]
    ) async -> BalanceMonitorSnapshot {
        var results: [BalanceRefreshResult] = []

        await withTaskGroup(of: BalanceRefreshResult.self) { group in
            for target in targets {
                group.addTask {
                    guard let configuration = target.configuration else {
                        return BalanceRefreshResult(
                            order: target.order,
                            accounts: [failedAccount(source: source, target: target, message: target.missingMessage ?? "配置不完整")],
                            message: nil,
                            failed: true
                        )
                    }

                    do {
                        let snapshot = try await BalanceAPIClient(configuration: configuration).fetchSnapshot(source: source)
                        return BalanceRefreshResult(
                            order: target.order,
                            accounts: snapshot.accounts,
                            message: snapshot.message.map { "\(target.account.displayLabel)：\($0)" },
                            failed: false
                        )
                    } catch {
                        let message = localizedMessage(source: source, for: error)
                        return BalanceRefreshResult(
                            order: target.order,
                            accounts: [failedAccount(source: source, target: target, message: message)],
                            message: "\(target.account.displayLabel)：\(message)",
                            failed: true
                        )
                    }
                }
            }

            for await result in group {
                results.append(result)
            }
        }

        let orderedResults = results.sorted { $0.order < $1.order }
        var accounts = orderedResults.flatMap(\.accounts)
        let messages = orderedResults.compactMap(\.message)
        let allFailed = !orderedResults.isEmpty && orderedResults.allSatisfy(\.failed)
        accounts.sort { lhs, rhs in
            if lhs.state != rhs.state {
                return lhs.state.sortRank > rhs.state.sortRank
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        let panelState: BalancePanelState
        if accounts.isEmpty {
            panelState = .warning
        } else if allFailed || accounts.contains(where: { $0.state == .error }) {
            panelState = .error
        } else if accounts.contains(where: { $0.state == .warning }) {
            panelState = .warning
        } else {
            panelState = .healthy
        }

        return BalanceMonitorSnapshot(
            source: source,
            panelState: panelState,
            accounts: accounts,
            message: messages.isEmpty ? nil : messages.joined(separator: "；"),
            lastUpdated: Date()
        )
    }

    nonisolated private static func failedAccount(
        source: BalanceMonitorSource,
        target: BalanceRefreshTarget,
        message: String
    ) -> BalanceAccount {
        BalanceAccount(
            id: "\(source.rawValue)-\(target.account.id)-failed",
            source: source,
            name: target.account.displayLabel,
            kind: "读取失败",
            statusCode: nil,
            amountText: "--",
            usedText: nil,
            requestCount: nil,
            updatedAt: message,
            state: .error,
            stateReason: "读取失败"
        )
    }

    nonisolated private static func localizedMessage(source: BalanceMonitorSource, for error: Error) -> String {
        if error is BalanceRefreshTimeoutError {
            return "\(source.title) 刷新超时"
        }
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized.redactedForDisplay
        }
        let message = error.localizedDescription
        if message.contains("secure connection") || message.contains("SSL") || message.contains("TLS") {
            return "TLS 连接失败，请检查面板地址、证书或反向代理配置"
        }
        if message.contains("timed out") {
            return "连接超时"
        }
        return message.redactedForDisplay
    }
}

private struct BalanceRefreshTimeoutError: Error {}

private struct BalanceMonitorSettingsSnapshot: Equatable {
    let enabled: Bool
    let source: BalanceMonitorSource
    let accounts: [BalanceAccountConfiguration]
    let defaultThresholds: BalanceThresholdConfiguration
    let refreshInterval: TimeInterval

    @MainActor
    init(source: BalanceMonitorSource, settings: CodexNotchSettings) {
        enabled = settings.balanceMonitorEnabled(for: source)
        self.source = source
        accounts = settings.balanceAccounts(for: source)
        defaultThresholds = settings.balanceDefaultThresholds(for: source)
        refreshInterval = settings.balanceRefreshInterval(for: source)
    }
}

private struct BalanceRefreshTarget: Equatable {
    let order: Int
    let source: BalanceMonitorSource
    let account: BalanceAccountConfiguration
    let configuration: BalanceAPIConfiguration?
    let missingMessage: String?
}

private struct BalanceRefreshResult {
    let order: Int
    let accounts: [BalanceAccount]
    let message: String?
    let failed: Bool
}

private extension BalanceAccountState {
    var sortRank: Int {
        switch self {
        case .error:
            return 2
        case .warning:
            return 1
        case .healthy:
            return 0
        }
    }
}
