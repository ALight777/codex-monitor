import Combine
import Foundation

@MainActor
final class RemoteMonitorViewModel: ObservableObject {
    @Published private(set) var snapshot: RemoteMonitorSnapshot = .disabled
    @Published private(set) var isRefreshing = false

    private let settings: CodexNotchSettings
    private var refreshTimer: Timer?
    private var settingsTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingRefresh = false
    private var consecutiveFailures = 0
    private var refreshGeneration = 0
    private var observedSettings: RemoteMonitorSettingsSnapshot?
    private var loadedSettings: RemoteMonitorSettingsSnapshot?

    init(settings: CodexNotchSettings) {
        self.settings = settings
        observeSettings()
        refreshRemoteSnapshot()
    }

    func refreshNow() {
        consecutiveFailures = 0
        refreshRemoteSnapshot(cancelInFlight: true)
    }

    func refresh() {
        refreshRemoteSnapshot()
    }

    private func refreshRemoteSnapshot(cancelInFlight: Bool = false) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        if cancelInFlight {
            invalidateInFlightRefresh()
        }

        guard settings.remoteMonitorEnabled else {
            invalidateInFlightRefresh()
            loadedSettings = nil
            snapshot = .disabled
            return
        }
        guard settings.loadSecretsIfNeeded() else {
            invalidateInFlightRefresh()
            loadedSettings = nil
            snapshot = RemoteMonitorSnapshot(
                panelState: .error,
                accounts: [],
                message: settings.cliproxyKeychainError ?? settings.secretStorageError ?? "密钥读取失败",
                lastUpdated: Date(),
                usage24h: 0,
                usage7d: 0,
                usage30d: 0,
                usageMessage: nil,
                usageUnavailableForSource: false
            )
            return
        }

        let panelURL = settings.cliproxyPanelURL
        let key = settings.cliproxyManagementKey
        let dataSource = settings.remoteCodexDataSource
        let settingsSnapshot = RemoteMonitorSettingsSnapshot(settings: settings)
        guard !panelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            invalidateInFlightRefresh()
            loadedSettings = nil
            snapshot = .notConfigured
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
        let previousAccounts = canPreserveSnapshot && dataSource == .cpaManagerPlus ? snapshot.accounts : []
        if snapshot.accounts.isEmpty || !canPreserveSnapshot {
            snapshot = RemoteMonitorSnapshot(
                panelState: .loading,
                accounts: [],
                message: "正在读取远程账号",
                lastUpdated: canPreserveSnapshot ? snapshot.lastUpdated : nil,
                usage24h: canPreserveSnapshot ? snapshot.usage24h : 0,
                usage7d: canPreserveSnapshot ? snapshot.usage7d : 0,
                usage30d: canPreserveSnapshot ? snapshot.usage30d : 0,
                usageMessage: nil,
                usageUnavailableForSource: false
            )
        }

        let configuration = CLIProxyAPIConfiguration(
            panelURL: panelURL,
            managementKey: key,
            timeout: settings.cliproxyRequestTimeout,
            allowInsecureTLS: settings.cliproxyAllowInsecureTLS
        )
        let totalTimeout = max(10, configuration.timeout * 4)

        refreshTask = Task.detached(priority: .utility) {
            do {
                let result = try await Self.withTimeout(seconds: totalTimeout) {
                    try await RemoteCodexProvider(
                        dataSource: dataSource,
                        configuration: configuration
                    ).fetch()
                }
                await MainActor.run {
                    guard generation == self.refreshGeneration else {
                        return
                    }
                    guard self.settings.remoteMonitorEnabled,
                          self.settings.remoteCodexDataSource == dataSource,
                          self.currentConfiguration() == configuration else {
                        self.finishRefreshAndRunPending()
                        if !self.settings.remoteMonitorEnabled {
                            self.snapshot = .disabled
                        }
                        return
                    }
                    self.consecutiveFailures = 0
                    self.isRefreshing = false
                    self.refreshTask = nil
                    self.loadedSettings = settingsSnapshot
                    let accounts = RemoteCodexAccount.preservingQuota(
                        in: result.accounts,
                        from: previousAccounts
                    )
                    self.snapshot = self.snapshot(
                        from: accounts,
                        usageResult: result.usageResult,
                        usageMessageOverride: result.usageMessage,
                        usageUnavailableForSource: result.usageUnavailableForSource
                    )
                    self.scheduleStatusRefresh()
                    self.runPendingRefreshIfNeeded()
                }
            } catch {
                await MainActor.run {
                    guard generation == self.refreshGeneration else {
                        return
                    }
                    guard self.settings.remoteMonitorEnabled,
                          self.settings.remoteCodexDataSource == dataSource,
                          self.currentConfiguration() == configuration else {
                        self.finishRefreshAndRunPending()
                        if !self.settings.remoteMonitorEnabled {
                            self.snapshot = .disabled
                        }
                        return
                    }
                    self.consecutiveFailures += 1
                    self.isRefreshing = false
                    self.refreshTask = nil
                    self.snapshot = RemoteMonitorSnapshot(
                        panelState: .error,
                        accounts: canPreserveSnapshot ? self.snapshot.accounts : [],
                        message: self.localizedMessage(for: error),
                        lastUpdated: Date(),
                        usage24h: canPreserveSnapshot ? self.snapshot.usage24h : 0,
                        usage7d: canPreserveSnapshot ? self.snapshot.usage7d : 0,
                        usage30d: canPreserveSnapshot ? self.snapshot.usage30d : 0,
                        usageMessage: canPreserveSnapshot ? self.snapshot.usageMessage : nil,
                        usageUnavailableForSource: canPreserveSnapshot ? self.snapshot.usageUnavailableForSource : false
                    )
                    self.scheduleStatusRefresh()
                    self.runPendingRefreshIfNeeded()
                }
            }
        }
    }

    private func observeSettings() {
        observedSettings = RemoteMonitorSettingsSnapshot(settings: settings)
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
        let next = RemoteMonitorSettingsSnapshot(settings: settings)
        guard next != observedSettings else {
            return
        }
        observedSettings = next
        scheduleSettingsRefresh()
    }

    private func scheduleSettingsRefresh() {
        settingsTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.consecutiveFailures = 0
                self?.refreshRemoteSnapshot()
            }
        }
        timer.tolerance = 0.2
        settingsTimer = timer
    }

    private func scheduleStatusRefresh() {
        guard settings.remoteMonitorEnabled else {
            return
        }

        let base = settings.cliproxyRefreshInterval
        let interval = consecutiveFailures == 0 ? base : min(300, base * Double(consecutiveFailures + 1))
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
        refreshRemoteSnapshot()
    }

    private func snapshot(
        from accounts: [RemoteCodexAccount],
        usageResult: Result<PeriodUsage, Error>? = nil,
        usageMessageOverride: String? = nil,
        usageUnavailableForSource: Bool = false
    ) -> RemoteMonitorSnapshot {
        let state: RemotePanelState
        if accounts.isEmpty {
            state = .warning
        } else {
            switch RemoteMonitorSnapshot.poolAlertSeverity(for: accounts) {
            case .error:
                state = .error
            case .warning:
                state = .warning
            case .none:
                state = .healthy
            }
        }

        let usage: PeriodUsage?
        let usageMessage: String?
        switch usageResult {
        case .success(let value):
            usage = value
            usageMessage = usageMessageOverride
        case .failure:
            usage = nil
            usageMessage = "用量刷新失败，已沿用旧值"
        case nil:
            usage = nil
            usageMessage = usageMessageOverride ?? snapshot.usageMessage
        }

        return RemoteMonitorSnapshot(
            panelState: state,
            accounts: accounts,
            message: accounts.isEmpty ? "没有找到已启用的 Codex 账号" : nil,
            lastUpdated: Date(),
            usage24h: usage?.day ?? snapshot.usage24h,
            usage7d: usage?.week ?? snapshot.usage7d,
            usage30d: usage?.month ?? snapshot.usage30d,
            usageMessage: usageMessage,
            usageUnavailableForSource: usageUnavailableForSource
        )
    }

    private func currentConfiguration() -> CLIProxyAPIConfiguration? {
        let panelURL = settings.cliproxyPanelURL
        let key = settings.cliproxyManagementKey
        guard !panelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return CLIProxyAPIConfiguration(
            panelURL: panelURL,
            managementKey: key,
            timeout: settings.cliproxyRequestTimeout,
            allowInsecureTLS: settings.cliproxyAllowInsecureTLS
        )
    }

    private func localizedMessage(for error: Error) -> String {
        if error is RemoteRefreshTimeoutError {
            return "远程刷新超时"
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
        return message
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
                throw RemoteRefreshTimeoutError()
            }

            guard let result = try await group.next() else {
                throw RemoteRefreshTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }
}

private struct RemoteRefreshTimeoutError: Error {}

private struct RemoteCodexFetchResult {
    let accounts: [RemoteCodexAccount]
    let usageResult: Result<PeriodUsage, Error>
    let usageMessage: String?
    let usageUnavailableForSource: Bool
}

private struct RemoteCodexProvider {
    let dataSource: RemoteCodexDataSource
    let configuration: CLIProxyAPIConfiguration

    func fetch() async throws -> RemoteCodexFetchResult {
        let client = CLIProxyAPIClient(configuration: configuration)
        let accounts = try await client.fetchCodexAccounts(dataSource: dataSource)
        switch dataSource {
        case .cpaManagerPlus:
            let usageResult: Result<PeriodUsage, Error>
            do {
                usageResult = .success(try await client.fetchManagerPlusUsageTotals())
            } catch {
                usageResult = .failure(error)
            }
            return RemoteCodexFetchResult(
                accounts: accounts,
                usageResult: usageResult,
                usageMessage: nil,
                usageUnavailableForSource: false
            )
        case .cliProxyAPI:
            return RemoteCodexFetchResult(
                accounts: accounts,
                usageResult: .success(.zero),
                usageMessage: "CLIProxyAPI 模式仅显示账号状态，历史用量需 CPA Manager Plus",
                usageUnavailableForSource: true
            )
        }
    }
}

private struct RemoteMonitorSettingsSnapshot: Equatable {
    let remoteMonitorEnabled: Bool
    let remoteCodexDataSource: RemoteCodexDataSource
    let cliproxyPanelURL: String
    let cliproxyManagementKey: String
    let cliproxyRefreshInterval: TimeInterval
    let cliproxyRequestTimeout: TimeInterval
    let cliproxyAllowInsecureTLS: Bool

    @MainActor
    init(settings: CodexNotchSettings) {
        remoteMonitorEnabled = settings.remoteMonitorEnabled
        remoteCodexDataSource = settings.remoteCodexDataSource
        cliproxyPanelURL = settings.cliproxyPanelURL
        cliproxyManagementKey = settings.cliproxyManagementKey
        cliproxyRefreshInterval = settings.cliproxyRefreshInterval
        cliproxyRequestTimeout = settings.cliproxyRequestTimeout
        cliproxyAllowInsecureTLS = settings.cliproxyAllowInsecureTLS
    }
}
