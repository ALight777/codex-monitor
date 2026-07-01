import Combine
import Foundation

@MainActor
final class UsageViewModel: ObservableObject {
    private enum DetailCadence {
        static let activeRefreshInterval: TimeInterval = 15
        static let idleRefreshInterval: TimeInterval = 90
        static let summaryContextTaskLimit = 4
        static let detailContextTaskLimit = 12
    }

    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var isRefreshing = false

    private let store: CodexUsageStore
    private let settings: CodexNotchSettings
    private var fastTimer: Timer?
    private var usageTimer: Timer?
    private var appServerRateLimitTimer: Timer?
    private var pendingSnapshotTimer: Timer?
    private var pendingUsageTimer: Timer?
    private var watcherRefreshTimer: Timer?
    private var settingsChangeTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var completionFollowUpTimers: [Timer] = []
    private var fileChangeRefreshTimers: [Timer] = []
    private var fileWatchers: [CodexFileWatcher] = []
    private var watchedPaths: [String] = []
    private var isRefreshingSnapshot = false
    private var isRefreshingUsage = false
    private var isRefreshingWatchPaths = false
    private var pendingSnapshotRefresh = false
    private var pendingSnapshotBypassFastCache = false
    private var pendingUsageRefresh = false
    private var pendingWatchPathsRefresh = false
    private var lastFileChangeRefreshScheduledAt: Date = .distantPast
    private var watcherRefreshGeneration = 0
    private var observedSettings: LocalUsageSettingsSnapshot?
    private var isDetailVisible = false

    init(store: CodexUsageStore = CodexUsageStore(), settings: CodexNotchSettings = CodexNotchSettings()) {
        self.store = store
        self.settings = settings
        refresh(bypassFastCache: true)
        scheduleUsageRefresh(after: 20)
        scheduleWatcherRefresh(after: 20)
        scheduleAppServerRateLimitRefresh(after: 30)
        observeSettings()
    }

    func setDetailVisible(_ visible: Bool) {
        guard isDetailVisible != visible else {
            return
        }
        isDetailVisible = visible
        fastTimer?.invalidate()
        fastTimer = nil
        pendingSnapshotTimer?.invalidate()
        pendingSnapshotTimer = nil

        if visible {
            refresh(bypassFastCache: true)
        } else if !isRefreshingSnapshot {
            scheduleFastRefresh()
        }
    }

    func refresh(bypassFastCache: Bool = false) {
        guard !isRefreshingSnapshot else {
            pendingSnapshotRefresh = true
            pendingSnapshotBypassFastCache = pendingSnapshotBypassFastCache || bypassFastCache
            return
        }
        fastTimer?.invalidate()
        fastTimer = nil
        pendingSnapshotTimer?.invalidate()
        pendingSnapshotTimer = nil
        isRefreshingSnapshot = true
        updateRefreshingState()
        let fallbackUsage = currentUsage
        let rateLimitSource = settings.rateLimitSource
        let taskHistoryRange = settings.taskHistoryRange
        let contextTaskLimit = currentContextTaskLimit

        Task.detached(priority: .utility) { [store, fallbackUsage, bypassFastCache, rateLimitSource, taskHistoryRange, contextTaskLimit] in
            let nextSnapshot = store.loadSnapshot(
                includePeriodUsage: false,
                fallbackUsage: fallbackUsage,
                bypassFastCache: bypassFastCache,
                rateLimitSource: rateLimitSource,
                taskHistoryRange: taskHistoryRange,
                contextTaskLimit: contextTaskLimit
            )
            await MainActor.run {
                let wasRunning = self.snapshot.isRunning
                var mergedSnapshot = self.stabilizedSnapshot(nextSnapshot)
                if mergedSnapshot.usage1h == nil {
                    mergedSnapshot.usage1h = self.snapshot.usage1h
                }
                mergedSnapshot.usage24h = self.snapshot.usage24h
                mergedSnapshot.usage7d = self.snapshot.usage7d
                mergedSnapshot.usage30d = self.snapshot.usage30d
                mergedSnapshot.tasks = mergedSnapshot.tasks.map {
                    $0.withTodaySharePercent(totalTokens: mergedSnapshot.usage24h)
                }
                mergedSnapshot.monitorStats.lastUsageDurationMs = self.snapshot.monitorStats.lastUsageDurationMs
                mergedSnapshot.monitorStats.watchedPathCount = self.snapshot.monitorStats.watchedPathCount
                self.snapshot = mergedSnapshot
                self.isRefreshingSnapshot = false
                self.updateRefreshingState()
                let shouldRefreshAgain = self.pendingSnapshotRefresh
                let shouldBypassFastCache = self.pendingSnapshotBypassFastCache
                self.pendingSnapshotRefresh = false
                self.pendingSnapshotBypassFastCache = false
                if wasRunning && !self.snapshot.isRunning {
                    self.scheduleCompletionFollowUp()
                }
                if shouldRefreshAgain {
                    self.schedulePendingSnapshotRefresh(bypassFastCache: shouldBypassFastCache)
                } else {
                    self.scheduleFastRefresh()
                }
            }
        }
    }

    func refreshAll() {
        refresh(bypassFastCache: true)
        refreshUsageTotals()
        refreshAppServerRateLimits()
    }

    private func refreshUsageTotals() {
        guard !isRefreshingUsage else {
            pendingUsageRefresh = true
            return
        }
        usageTimer?.invalidate()
        usageTimer = nil
        pendingUsageTimer?.invalidate()
        pendingUsageTimer = nil
        isRefreshingUsage = true
        updateRefreshingState()

        Task.detached(priority: .utility) { [store] in
            let startedAt = Date()
            let usage = store.loadUsageTotals()
            let durationMs = max(0, Int((Date().timeIntervalSince(startedAt) * 1_000).rounded()))
            await MainActor.run {
                if let usage {
                    self.snapshot.usage24h = usage.day
                    self.snapshot.usage7d = usage.week
                    self.snapshot.usage30d = usage.month
                    self.snapshot.tasks = self.snapshot.tasks.map {
                        $0.withTodaySharePercent(totalTokens: usage.day)
                    }
                }
                self.snapshot.monitorStats.lastUsageDurationMs = durationMs
                self.isRefreshingUsage = false
                self.updateRefreshingState()
                let shouldRefreshAgain = self.pendingUsageRefresh
                self.pendingUsageRefresh = false
                if shouldRefreshAgain {
                    self.schedulePendingUsageRefresh()
                } else {
                    self.scheduleUsageRefresh()
                }
            }
        }
    }

    private func scheduleFastRefresh() {
        let interval = currentFastRefreshInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = interval * 0.35
        fastTimer = timer
    }

    private func schedulePendingSnapshotRefresh(bypassFastCache: Bool) {
        fastTimer?.invalidate()
        fastTimer = nil
        pendingSnapshotTimer?.invalidate()

        let interval = currentFastRefreshInterval
        let delay = RefreshCadence.pendingSnapshotDelay(for: interval)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.pendingSnapshotTimer = nil
                self?.refresh(bypassFastCache: bypassFastCache)
            }
        }
        timer.tolerance = min(1, delay * 0.35)
        pendingSnapshotTimer = timer
    }

    private func scheduleUsageRefresh(after delay: TimeInterval? = nil) {
        usageTimer?.invalidate()
        let interval = delay ?? settings.usageRefreshInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUsageTotals()
            }
        }
        timer.tolerance = min(30, max(5, interval * 0.35))
        usageTimer = timer
    }

    private func schedulePendingUsageRefresh() {
        usageTimer?.invalidate()
        usageTimer = nil
        pendingUsageTimer?.invalidate()

        let delay = RefreshCadence.pendingUsageDelay(for: settings.usageRefreshInterval)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.pendingUsageTimer = nil
                self?.refreshUsageTotals()
            }
        }
        timer.tolerance = min(5, delay * 0.35)
        pendingUsageTimer = timer
    }

    private func scheduleWatcherRefresh(after delay: TimeInterval? = nil) {
        watcherRefreshTimer?.invalidate()
        let interval = delay ?? settings.watcherRefreshInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWatchPaths()
            }
        }
        timer.tolerance = min(30, max(3, interval * 0.35))
        watcherRefreshTimer = timer
    }

    private func scheduleCompletionFollowUp() {
        completionFollowUpTimers.forEach { $0.invalidate() }
        completionFollowUpTimers = [8, 30].map { delay in
            let timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh(bypassFastCache: true)
                }
            }
            timer.tolerance = min(5, TimeInterval(delay) * 0.35)
            return timer
        }
    }

    private func scheduleAppServerRateLimitRefresh(after delay: TimeInterval? = nil) {
        appServerRateLimitTimer?.invalidate()
        appServerRateLimitTimer = nil
        guard settings.rateLimitSource == .appServerFirst else {
            return
        }

        let interval = delay ?? 5 * 60
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAppServerRateLimits()
            }
        }
        timer.tolerance = min(60, max(10, interval * 0.35))
        appServerRateLimitTimer = timer
    }

    private func refreshAppServerRateLimits() {
        appServerRateLimitTimer?.invalidate()
        appServerRateLimitTimer = nil
        guard settings.rateLimitSource == .appServerFirst else {
            return
        }

        Task.detached(priority: .utility) { [store] in
            let refreshed = store.refreshAppServerRateLimits() != nil
            await MainActor.run {
                if refreshed {
                    self.refresh(bypassFastCache: true)
                }
                self.scheduleAppServerRateLimitRefresh()
            }
        }
    }

    private func refreshWatchPaths() {
        guard !isRefreshingWatchPaths else {
            pendingWatchPathsRefresh = true
            return
        }
        isRefreshingWatchPaths = true
        watcherRefreshGeneration += 1
        let generation = watcherRefreshGeneration
        Task.detached(priority: .utility) { [store] in
            let paths = store.rateLimitWatchPaths()
            await MainActor.run {
                guard generation == self.watcherRefreshGeneration else {
                    return
                }
                self.isRefreshingWatchPaths = false
                self.installFileWatchers(for: paths)
                self.snapshot.monitorStats.watchedPathCount = self.watchedPaths.count
                let shouldRefreshAgain = self.pendingWatchPathsRefresh
                self.pendingWatchPathsRefresh = false
                if shouldRefreshAgain {
                    self.refreshWatchPaths()
                } else {
                    self.scheduleWatcherRefresh()
                }
            }
        }
    }

    private func installFileWatchers(for paths: [String]) {
        let normalizedPaths = Array(Set(paths.filter { !$0.isEmpty })).sorted()
        guard normalizedPaths != watchedPaths else {
            return
        }

        fileWatchers.forEach { $0.cancel() }
        fileWatchers.removeAll()

        var installedPaths: [String] = []
        var installedWatchers: [CodexFileWatcher] = []

        for path in normalizedPaths {
            guard let watcher = CodexFileWatcher(path: path, onChange: { [weak self] in
                Task { @MainActor in
                    self?.scheduleFileChangeRefresh()
                }
            }) else {
                continue
            }
            installedPaths.append(path)
            installedWatchers.append(watcher)
        }

        watchedPaths = installedPaths
        fileWatchers = installedWatchers
    }

    private func scheduleFileChangeRefresh() {
        let now = Date()
        guard now.timeIntervalSince(lastFileChangeRefreshScheduledAt) >= settings.fileChangeRefreshMinimumGap else {
            return
        }
        lastFileChangeRefreshScheduledAt = now

        fileChangeRefreshTimers.forEach { $0.invalidate() }
        let delay = max(1, settings.fileChangeRefreshMinimumGap)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(bypassFastCache: true)
                self?.refreshWatchPaths()
            }
        }
        timer.tolerance = min(5, delay * 0.35)
        fileChangeRefreshTimers = [timer]
    }

    private func observeSettings() {
        observedSettings = LocalUsageSettingsSnapshot(settings: settings)
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
        let next = LocalUsageSettingsSnapshot(settings: settings)
        guard next != observedSettings else {
            return
        }
        observedSettings = next
        scheduleSettingsRefresh()
    }

    private func scheduleSettingsRefresh() {
        settingsChangeTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.settingsDidChange()
            }
        }
        timer.tolerance = 0.15
        settingsChangeTimer = timer
    }

    private func settingsDidChange() {
        settingsChangeTimer?.invalidate()
        settingsChangeTimer = nil
        fastTimer?.invalidate()
        fastTimer = nil
        usageTimer?.invalidate()
        usageTimer = nil
        appServerRateLimitTimer?.invalidate()
        appServerRateLimitTimer = nil
        pendingSnapshotTimer?.invalidate()
        pendingSnapshotTimer = nil
        pendingUsageTimer?.invalidate()
        pendingUsageTimer = nil
        watcherRefreshTimer?.invalidate()
        watcherRefreshTimer = nil

        refresh(bypassFastCache: true)
        refreshUsageTotals()
        refreshWatchPaths()
        scheduleAppServerRateLimitRefresh(after: 30)
    }

    private var currentUsage: PeriodUsage {
        PeriodUsage(
            day: snapshot.usage24h,
            week: snapshot.usage7d,
            month: snapshot.usage30d
        )
    }

    private var currentFastRefreshInterval: TimeInterval {
        let foldedInterval = snapshot.isRunning ? settings.activeRefreshInterval : settings.idleRefreshInterval
        guard isDetailVisible else {
            return foldedInterval
        }

        let detailInterval = snapshot.isRunning
            ? DetailCadence.activeRefreshInterval
            : DetailCadence.idleRefreshInterval
        return min(foldedInterval, detailInterval)
    }

    private var currentContextTaskLimit: Int {
        isDetailVisible ? DetailCadence.detailContextTaskLimit : DetailCadence.summaryContextTaskLimit
    }

    private func updateRefreshingState() {
        isRefreshing = isRefreshingSnapshot || isRefreshingUsage
    }

    private func stabilizedSnapshot(_ next: UsageSnapshot) -> UsageSnapshot {
        var snapshot = next
        let previous = self.snapshot

        if snapshot.primaryPercent == nil {
            snapshot.primaryPercent = previous.primaryPercent
            snapshot.primaryResetsAt = previous.primaryResetsAt
        }
        if snapshot.secondaryPercent == nil {
            snapshot.secondaryPercent = previous.secondaryPercent
            snapshot.secondaryResetsAt = previous.secondaryResetsAt
        }

        if snapshot.errorMessage != nil,
           snapshot.usage1h == nil,
           snapshot.usage24h == 0,
           snapshot.usage7d == 0,
           snapshot.usage30d == 0,
           previous.usage30d > 0 {
            snapshot.usage1h = previous.usage1h
            snapshot.usage24h = previous.usage24h
            snapshot.usage7d = previous.usage7d
            snapshot.usage30d = previous.usage30d
        }

        if snapshot.errorMessage != nil {
            if snapshot.sparkQuotaWindows.isEmpty {
                snapshot.sparkQuotaWindows = previous.sparkQuotaWindows
            }
            if snapshot.tasks.isEmpty {
                snapshot.tasks = previous.tasks.map { task in
                    CodexTask(
                        id: task.id,
                        title: task.title,
                        status: task.status == .running ? .recent : task.status,
                        detail: task.detail,
                        tokenCount: task.tokenCount,
                        updatedAt: task.updatedAt,
                        activeSubagentCount: task.activeSubagentCount,
                        delta10mTokens: task.delta10mTokens,
                        delta1hTokens: task.delta1hTokens,
                        todayTokens: task.todayTokens,
                        todaySharePercent: task.todaySharePercent,
                        contextInputTokens: task.contextInputTokens,
                        contextWindowTokens: task.contextWindowTokens,
                        contextPercent: task.contextPercent,
                        contextUpdatedAt: task.contextUpdatedAt
                    )
                }
            }
            snapshot.isRunning = false
            snapshot.errorMessage = nil
        }

        return snapshot
    }
}

private struct LocalUsageSettingsSnapshot: Equatable {
    let activeRefreshInterval: TimeInterval
    let idleRefreshInterval: TimeInterval
    let usageRefreshInterval: TimeInterval
    let watcherRefreshInterval: TimeInterval
    let fileChangeRefreshMinimumGap: TimeInterval
    let rateLimitSource: RateLimitSourcePreference
    let taskHistoryRange: TaskHistoryRange

    @MainActor
    init(settings: CodexNotchSettings) {
        activeRefreshInterval = settings.activeRefreshInterval
        idleRefreshInterval = settings.idleRefreshInterval
        usageRefreshInterval = settings.usageRefreshInterval
        watcherRefreshInterval = settings.watcherRefreshInterval
        fileChangeRefreshMinimumGap = settings.fileChangeRefreshMinimumGap
        rateLimitSource = settings.rateLimitSource
        taskHistoryRange = settings.taskHistoryRange
    }
}

@MainActor
final class OverlayState: ObservableObject {
    @Published var isExpanded = false
}
