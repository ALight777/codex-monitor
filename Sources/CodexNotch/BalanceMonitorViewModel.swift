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

        let panelURL = settings.balancePanelURL(for: source)
        let key = settings.balanceManagementKey(for: source)
        let username = settings.balanceUsername(for: source)
        let settingsSnapshot = BalanceMonitorSettingsSnapshot(source: source, settings: settings)
        guard !panelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

        let configuration = currentConfiguration(panelURL: panelURL, key: key)
        let source = source
        let totalTimeout = max(8, configuration.timeout * 3)

        refreshTask = Task.detached(priority: .utility) {
            do {
                let nextSnapshot = try await Self.withTimeout(seconds: totalTimeout) {
                    try await BalanceAPIClient(configuration: configuration).fetchSnapshot(source: source)
                }
                await MainActor.run {
                    guard generation == self.refreshGeneration else {
                        return
                    }
                    guard self.currentConfiguration() == configuration,
                          self.settings.balanceMonitorEnabled(for: self.source) else {
                        self.finishRefreshAndRunPending()
                        if !self.settings.balanceMonitorEnabled(for: self.source) {
                            self.snapshot = .disabled(source: self.source)
                        }
                        return
                    }
                    self.consecutiveFailures = 0
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
                    guard self.currentConfiguration() == configuration,
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
                self?.refreshSnapshot()
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
        refreshSnapshot()
    }

    private func currentConfiguration(panelURL: String, key: String) -> BalanceAPIConfiguration {
        BalanceAPIConfiguration(
            panelURL: panelURL,
            username: settings.balanceUsername(for: source),
            secret: key,
            timeout: settings.balanceRequestTimeout(for: source),
            allowInsecureTLS: settings.balanceAllowInsecureTLS(for: source)
        )
    }

    private func currentConfiguration() -> BalanceAPIConfiguration? {
        let panelURL = settings.balancePanelURL(for: source)
        let key = settings.balanceManagementKey(for: source)
        let username = settings.balanceUsername(for: source)
        guard !panelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return currentConfiguration(panelURL: panelURL, key: key)
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
}

private struct BalanceRefreshTimeoutError: Error {}

private struct BalanceMonitorSettingsSnapshot: Equatable {
    let enabled: Bool
    let panelURL: String
    let key: String
    let username: String
    let refreshInterval: TimeInterval
    let requestTimeout: TimeInterval
    let allowInsecureTLS: Bool

    @MainActor
    init(source: BalanceMonitorSource, settings: CodexNotchSettings) {
        enabled = settings.balanceMonitorEnabled(for: source)
        panelURL = settings.balancePanelURL(for: source)
        key = settings.balanceManagementKey(for: source)
        username = settings.balanceUsername(for: source)
        refreshInterval = settings.balanceRefreshInterval(for: source)
        requestTimeout = settings.balanceRequestTimeout(for: source)
        allowInsecureTLS = settings.balanceAllowInsecureTLS(for: source)
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
