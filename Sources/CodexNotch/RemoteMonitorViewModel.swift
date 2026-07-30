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
    private let resetCreditsCache = RemoteResetCreditsCache()

    init(settings: CodexNotchSettings) {
        self.settings = settings
        observeSettings()
        refreshRemoteSnapshot()
    }

    func refreshNow() {
        consecutiveFailures = 0
        refreshRemoteSnapshot(cancelInFlight: true, forceResetCreditsRefresh: true)
    }

    func refresh() {
        refreshRemoteSnapshot()
    }

    private func refreshRemoteSnapshot(
        cancelInFlight: Bool = false,
        forceResetCreditsRefresh: Bool = false
    ) {
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

        let settingsSnapshot = RemoteMonitorSettingsSnapshot(settings: settings)
        let sourceSelection = currentSourceSelection()
        guard sourceSelection.enabledCount > 0 else {
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
        let previousAccounts = canPreserveSnapshot ? snapshot.accounts : []
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
                usageUnavailableForSource: false,
                usageSources: canPreserveSnapshot ? snapshot.usageSources : []
            )
        }

        refreshTask = Task.detached(priority: .utility) {
            do {
                let result = try await RemoteCodexMultiSourceProvider(
                    sources: sourceSelection.connections,
                    initialOutcomes: sourceSelection.configurationFailures,
                    resetCreditsCache: self.resetCreditsCache,
                    forceResetCreditsRefresh: forceResetCreditsRefresh
                ).fetchCore()
                await MainActor.run {
                    guard generation == self.refreshGeneration else {
                        return
                    }
                    guard self.settings.remoteMonitorEnabled,
                          RemoteMonitorSettingsSnapshot(settings: self.settings) == settingsSnapshot else {
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
                    let mergedAccounts = RemoteAccountSnapshotMerger.merge(
                        current: result.accounts,
                        previous: previousAccounts,
                        failedSourceIDs: result.failedSourceIDs
                    )
                    let accounts = RemoteCodexAccount.preservingQuota(
                        in: mergedAccounts,
                        from: previousAccounts
                    )
                    self.snapshot = self.snapshot(
                        from: accounts,
                        usageResult: result.usageResult,
                        usageMessageOverride: result.usageMessage,
                        usageUnavailableForSource: result.usageUnavailableForSource,
                        usageSources: result.usageSources,
                        panelMessage: result.panelMessage,
                        hasSourceFailures: result.hasSourceFailures
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
                          RemoteMonitorSettingsSnapshot(settings: self.settings) == settingsSnapshot else {
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
                        usageUnavailableForSource: canPreserveSnapshot ? self.snapshot.usageUnavailableForSource : false,
                        usageSources: canPreserveSnapshot ? self.snapshot.usageSources : []
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
        usageUnavailableForSource: Bool = false,
        usageSources: [RemoteUsageSourceCoverage] = [],
        panelMessage: String? = nil,
        hasSourceFailures: Bool = false
    ) -> RemoteMonitorSnapshot {
        let state: RemotePanelState
        if accounts.isEmpty {
            state = hasSourceFailures ? .error : .warning
        } else {
            switch RemoteMonitorSnapshot.poolAlertSeverity(for: accounts) {
            case .error:
                state = .error
            case .warning:
                state = .warning
            case .none:
                state = hasSourceFailures ? .warning : .healthy
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
            usageMessage = usageMessageOverride ?? "用量刷新失败，已沿用旧值"
        case nil:
            usage = nil
            usageMessage = usageMessageOverride ?? snapshot.usageMessage
        }

        return RemoteMonitorSnapshot(
            panelState: state,
            accounts: accounts,
            message: panelMessage ?? (accounts.isEmpty ? "没有找到已启用的 Codex 账号" : nil),
            lastUpdated: Date(),
            usage24h: usage?.day ?? snapshot.usage24h,
            usage7d: usage?.week ?? snapshot.usage7d,
            usage30d: usage?.month ?? snapshot.usage30d,
            usageMessage: usageMessage,
            usageUnavailableForSource: usageUnavailableForSource,
            usageSources: usageSources
        )
    }

    private func currentSourceSelection() -> RemoteMonitorSourceSelection {
        let enabledSources = settings.remoteAccountSources.filter(\.enabled)
        var connections: [RemoteMonitorSourceConnection] = []
        var failures: [RemoteSourceFetchOutcome] = []
        for source in enabledSources {
            if let connection = RemoteMonitorSourceConnection(source: source) {
                connections.append(connection)
            } else {
                failures.append(
                    .configurationFailure(
                        source: source,
                        message: source.configurationIssue ?? "配置不完整"
                    )
                )
            }
        }
        return RemoteMonitorSourceSelection(
            enabledCount: enabledSources.count,
            connections: connections,
            configurationFailures: failures
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

}

private struct RemoteRefreshTimeoutError: LocalizedError {
    var errorDescription: String? {
        "远程刷新超时"
    }
}

struct RemoteCodexFetchResult {
    let accounts: [RemoteCodexAccount]
    let usageResult: Result<PeriodUsage, Error>
    let usageMessage: String?
    let usageUnavailableForSource: Bool
    let usageSources: [RemoteUsageSourceCoverage]
    let panelMessage: String?
    let hasSourceFailures: Bool
    let failedSourceIDs: Set<String>
}

private struct RemoteMonitorSourceSelection: Sendable {
    let enabledCount: Int
    let connections: [RemoteMonitorSourceConnection]
    let configurationFailures: [RemoteSourceFetchOutcome]
}

private struct RemoteMonitorSourceConnection: Equatable, Sendable {
    let source: RemoteAccountSourceConfiguration
    let connection: RemoteMonitorConnectionConfiguration

    init?(source: RemoteAccountSourceConfiguration) {
        let panelURL = source.panelURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.configurationIssue == nil else {
            return nil
        }
        self.source = source
        switch source.source {
        case .cliProxyAPI, .cpaManagerPlus:
            connection = .cliProxy(
                CLIProxyAPIConfiguration(
                    panelURL: panelURL,
                    managementKey: source.secret,
                    timeout: source.requestTimeout,
                    allowInsecureTLS: source.allowInsecureTLS
                )
            )
        case .sub2API:
            let email = source.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty else {
                return nil
            }
            connection = .sub2API(
                Sub2APIRemoteConfiguration(
                    panelURL: panelURL,
                    adminEmail: email,
                    adminPassword: source.secret,
                    timeout: source.requestTimeout,
                    allowInsecureTLS: source.allowInsecureTLS
                )
            )
        }
    }
}

private struct RemoteCodexMultiSourceProvider: Sendable {
    let sources: [RemoteMonitorSourceConnection]
    let initialOutcomes: [RemoteSourceFetchOutcome]
    let resetCreditsCache: RemoteResetCreditsCache
    let forceResetCreditsRefresh: Bool

    func fetchCore() async throws -> RemoteCodexFetchResult {
        let fetchedOutcomes = await withTaskGroup(
            of: RemoteSourceFetchOutcome.self,
            returning: [RemoteSourceFetchOutcome].self
        ) { group in
            for source in sources {
                group.addTask {
                    await fetch(source)
                }
            }
            var values: [RemoteSourceFetchOutcome] = []
            for await outcome in group {
                values.append(outcome)
            }
            return values
        }
        let outcomes = initialOutcomes + fetchedOutcomes

        return RemoteMultiSourceOutcomeAggregator.aggregate(outcomes)
    }

    private func fetch(_ source: RemoteMonitorSourceConnection) async -> RemoteSourceFetchOutcome {
        do {
            let timeout = RemoteRefreshTimeoutPolicy.budget(
                for: source.source.source,
                requestTimeout: source.connection.timeout
            )
            let success = try await RemoteOperationTimeout.value(seconds: timeout) {
                try await fetchSuccess(source)
            }
            return RemoteSourceFetchOutcome(
                source: source.source,
                success: success,
                failureMessage: nil
            )
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return RemoteSourceFetchOutcome(
                source: source.source,
                success: nil,
                failureMessage: "\(source.source.displayLabel)：\(reason.redactedForDisplay)"
            )
        }
    }

    private func fetchSuccess(
        _ source: RemoteMonitorSourceConnection
    ) async throws -> RemoteSourceFetchSuccess {
            let accounts: [RemoteCodexAccount]
            var usage: PeriodUsage?
            var usageError: String?
            let supportsUsage = source.source.source.supportsTokenUsage

            switch (source.source.source, source.connection) {
            case (.cliProxyAPI, .cliProxy(let configuration)):
                accounts = try await CLIProxyAPIClient(configuration: configuration)
                    .fetchCodexAccounts(dataSource: .cliProxyAPI)
            case (.cpaManagerPlus, .cliProxy(let configuration)):
                let client = CLIProxyAPIClient(configuration: configuration)
                let coreAccounts = try await client.fetchCodexAccounts(dataSource: .cpaManagerPlus)
                let resetCreditsTimeout = RemoteResetCreditsEnrichmentCoordinator
                    .timeoutBudget(forRequestTimeout: configuration.timeout)
                accounts = await RemoteResetCreditsEnrichmentCoordinator(
                    loader: RemoteResetCreditsLoader(cache: resetCreditsCache),
                    timeoutBudget: resetCreditsTimeout
                ).enrich(
                    accounts: coreAccounts,
                    dataSource: .cpaManagerPlus,
                    panelURL: configuration.panelURL,
                    cacheScopeID: source.source.id,
                    forceRefresh: forceResetCreditsRefresh
                ) { authIndex, accountID in
                    try await CLIProxyAPIClient(configuration: configuration).fetchResetCredits(
                        authIndex: authIndex,
                        accountID: accountID
                    )
                }
                do {
                    usage = try await client.fetchManagerPlusUsageTotals()
                } catch {
                    usageError = ((error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription).redactedForDisplay
                }
            case (.sub2API, .sub2API(let configuration)):
                let snapshot = try await Sub2APIRemoteClient(configuration: configuration)
                    .fetchCodexSnapshot()
                accounts = snapshot.accounts
                usage = snapshot.usage
                usageError = snapshot.usageError
            default:
                throw RemoteMonitorConfigurationError.incompatibleSource
            }

            return RemoteSourceFetchSuccess(
                accounts: accounts.map { $0.scoped(to: source.source) },
                usage: usage,
                supportsUsage: supportsUsage,
                usageError: usageError
            )
    }
}

enum RemoteMultiSourceOutcomeAggregator {
    static func aggregate(_ outcomes: [RemoteSourceFetchOutcome]) -> RemoteCodexFetchResult {
        let successes = outcomes.compactMap(\.success)
        let failures = outcomes.compactMap(\.failureMessage)

        let accounts = successes
            .flatMap(\.accounts)
            .sorted {
                if $0.provider == $1.provider {
                    return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                return ($0.provider ?? "").localizedCaseInsensitiveCompare($1.provider ?? "") == .orderedAscending
            }
        let usageOutcomes = outcomes.filter(\.supportsUsage)
        let expectedUsageScopeIDs = Set(usageOutcomes.map(\.usageScopeID))
        let usageAggregation = RemoteUsageAggregator.aggregate(
            usageOutcomes.compactMap { outcome in
                guard let usage = outcome.success?.usage else {
                    return nil
                }
                return RemoteUsageContribution(
                    sourceID: outcome.source.id,
                    scopeID: outcome.usageScopeID,
                    usage: usage
                )
            },
            expectedScopeIDs: expectedUsageScopeIDs
        )
        let usage = usageAggregation.usage
        let supportsUsage = !usageOutcomes.isEmpty
        let hasUsageFailures = !usageAggregation.missingScopeIDs.isEmpty
        let usageSources = outcomes
            .map {
                $0.usageCoverage(
                    duplicateUsageSourceIDs: usageAggregation.duplicateSourceIDs
                )
            }
            .sorted {
                $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
        var usageMessages: [String] = []
        if hasUsageFailures {
            usageMessages.append(
                usageAggregation.includedScopeIDs.isEmpty
                    ? "用量刷新失败，已沿用旧值"
                    : "部分数据源用量刷新失败，已沿用上次完整统计"
            )
        } else if !supportsUsage {
            usageMessages.append("已启用的数据源未提供 Token 用量")
        }
        if !usageAggregation.duplicateSourceIDs.isEmpty {
            usageMessages.append("重复面板的用量已自动去重")
        }
        let usageMessage = usageMessages.isEmpty ? nil : usageMessages.joined(separator: "；")
        let panelMessage = failures.isEmpty
            ? nil
            : "\(failures.count) 个数据源刷新失败：" + failures.joined(separator: "；")

        return RemoteCodexFetchResult(
            accounts: accounts,
            usageResult: hasUsageFailures
                ? .failure(RemoteUsageRefreshError())
                : .success(usage),
            usageMessage: usageMessage,
            usageUnavailableForSource: !supportsUsage,
            usageSources: usageSources,
            panelMessage: panelMessage,
            hasSourceFailures: !failures.isEmpty,
            failedSourceIDs: Set(
                outcomes.compactMap { outcome in
                    outcome.success == nil ? outcome.source.id : nil
                }
            )
        )
    }
}

struct RemoteSourceFetchOutcome: Sendable {
    let source: RemoteAccountSourceConfiguration
    let success: RemoteSourceFetchSuccess?
    let failureMessage: String?

    var supportsUsage: Bool {
        source.source.supportsTokenUsage
    }

    var usageScopeID: String {
        source.usageScopeID ?? source.id
    }

    func usageCoverage(
        duplicateUsageSourceIDs: Set<String>
    ) -> RemoteUsageSourceCoverage {
        let state: RemoteUsageCoverageState
        let message: String?
        if let success {
            if !success.supportsUsage {
                state = .unavailable
                message = "该数据源未提供 Token 用量接口"
            } else if duplicateUsageSourceIDs.contains(source.id) {
                state = .duplicate
                message = "与同一面板的其他数据源重复，未重复计入"
            } else if success.usage != nil {
                state = .included
                message = nil
            } else {
                state = .failed
                message = success.usageError ?? "用量刷新失败"
            }
        } else if source.source == .cliProxyAPI {
            state = .unavailable
            message = "该数据源未提供 Token 用量接口"
        } else {
            state = .failed
            message = failureMessage
        }
        return RemoteUsageSourceCoverage(
            id: source.id,
            label: source.displayLabel,
            source: source.source,
            state: state,
            message: message
        )
    }

    static func configurationFailure(
        source: RemoteAccountSourceConfiguration,
        message: String
    ) -> RemoteSourceFetchOutcome {
        RemoteSourceFetchOutcome(
            source: source,
            success: nil,
            failureMessage: "\(source.displayLabel)：\(message)"
        )
    }
}

struct RemoteSourceFetchSuccess: Sendable {
    let accounts: [RemoteCodexAccount]
    let usage: PeriodUsage?
    let supportsUsage: Bool
    let usageError: String?
}

struct RemoteUsageContribution: Equatable, Sendable {
    let sourceID: String
    let scopeID: String
    let usage: PeriodUsage
}

struct RemoteUsageAggregation: Equatable, Sendable {
    let usage: PeriodUsage
    let duplicateSourceIDs: Set<String>
    let includedScopeIDs: Set<String>
    let missingScopeIDs: Set<String>
}

enum RemoteUsageAggregator {
    static func aggregate(
        _ contributions: [RemoteUsageContribution],
        expectedScopeIDs: Set<String> = []
    ) -> RemoteUsageAggregation {
        var seenScopes: Set<String> = []
        var duplicateSourceIDs: Set<String> = []
        var usage = PeriodUsage.zero

        for contribution in contributions {
            guard seenScopes.insert(contribution.scopeID).inserted else {
                duplicateSourceIDs.insert(contribution.sourceID)
                continue
            }
            usage = PeriodUsage.saturatedSum(usage, contribution.usage)
        }

        return RemoteUsageAggregation(
            usage: usage,
            duplicateSourceIDs: duplicateSourceIDs,
            includedScopeIDs: seenScopes,
            missingScopeIDs: expectedScopeIDs.subtracting(seenScopes)
        )
    }
}

private struct RemoteUsageRefreshError: Error {}

enum RemoteRefreshTimeoutPolicy {
    static func budget(
        for source: RemoteCodexDataSource,
        requestTimeout: TimeInterval
    ) -> TimeInterval {
        let timeout = max(3, requestTimeout)
        switch source {
        case .sub2API:
            return Sub2APIRemoteClient.refreshBudget(forRequestTimeout: timeout)
        case .cliProxyAPI, .cpaManagerPlus:
            return max(10, timeout * 4)
        }
    }
}

private enum RemoteMonitorConnectionConfiguration: Equatable, Sendable {
    case cliProxy(CLIProxyAPIConfiguration)
    case sub2API(Sub2APIRemoteConfiguration)

    var timeout: TimeInterval {
        switch self {
        case .cliProxy(let configuration):
            configuration.timeout
        case .sub2API(let configuration):
            configuration.timeout
        }
    }
}

private enum RemoteMonitorConfigurationError: Error {
    case incompatibleSource
}

enum RemoteOperationTimeout {
    static func value<T: Sendable>(
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

enum RemoteAccountSnapshotMerger {
    static func merge(
        current: [RemoteCodexAccount],
        previous: [RemoteCodexAccount],
        failedSourceIDs: Set<String>
    ) -> [RemoteCodexAccount] {
        guard !previous.isEmpty, !failedSourceIDs.isEmpty else {
            return sorted(current)
        }
        let currentIDs = Set(current.map(\.id))
        let preserved = previous.filter { account in
            guard !currentIDs.contains(account.id),
                  let sourceID = sourceID(from: account.id) else {
                return false
            }
            return failedSourceIDs.contains(sourceID)
        }
        return sorted(current + preserved)
    }

    private static func sourceID(from accountID: String) -> String? {
        guard let separator = accountID.range(of: "::") else {
            return nil
        }
        return String(accountID[..<separator.lowerBound])
    }

    private static func sorted(_ accounts: [RemoteCodexAccount]) -> [RemoteCodexAccount] {
        accounts.sorted {
            if $0.provider == $1.provider {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return ($0.provider ?? "").localizedCaseInsensitiveCompare($1.provider ?? "") == .orderedAscending
        }
    }
}

private extension PeriodUsage {
    static func saturatedSum(_ lhs: PeriodUsage, _ rhs: PeriodUsage) -> PeriodUsage {
        PeriodUsage(
            day: saturatedAdd(lhs.day, rhs.day),
            week: saturatedAdd(lhs.week, rhs.week),
            month: saturatedAdd(lhs.month, rhs.month)
        )
    }

    static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = max(0, lhs).addingReportingOverflow(max(0, rhs))
        return overflow ? Int.max : value
    }
}

private struct RemoteMonitorSettingsSnapshot: Equatable {
    let remoteMonitorEnabled: Bool
    let remoteAccountSources: [RemoteAccountSourceConfiguration]
    let cliproxyRefreshInterval: TimeInterval

    @MainActor
    init(settings: CodexNotchSettings) {
        remoteMonitorEnabled = settings.remoteMonitorEnabled
        remoteAccountSources = settings.remoteAccountSources
        cliproxyRefreshInterval = settings.cliproxyRefreshInterval
    }
}
