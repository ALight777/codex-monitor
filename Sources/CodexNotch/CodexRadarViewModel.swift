import Combine
import Darwin
import Foundation

@MainActor
final class CodexRadarViewModel: ObservableObject {
    @Published private(set) var snapshot: CodexRadarSnapshot = .disabled
    @Published private(set) var isRefreshing = false
    @Published private(set) var nextRefreshAt: Date?

    private let settings: CodexNotchSettings
    private let client: CodexRadarClient
    private let cacheDirectory: URL
    private let now: @MainActor () -> Date
    private var refreshTimer: Timer?
    private var settingsTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var generation = 0
    private var observedEnabled: Bool
    private var observedToken: String
    private var lastManualRefreshAt: Date?
    private var retryAt: Date?

    init(
        settings: CodexNotchSettings,
        client: CodexRadarClient = CodexRadarClient(),
        cacheDirectory: URL = CodexRadarCache.defaultDirectory(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.settings = settings
        self.client = client
        self.cacheDirectory = cacheDirectory
        self.now = now
        observedEnabled = settings.codexRadarEnabled
        observedToken = settings.codexRadarAPIToken
        observeSettings()
        loadCacheAndSchedule()
    }

    func refreshNow() {
        guard settings.codexRadarEnabled, !isRefreshing else { return }
        let now = now()
        guard CodexRadarRefreshPolicy.canManualRefresh(lastRefreshAt: lastManualRefreshAt, now: now) else {
            snapshot = snapshot.withState(snapshot.state, message: "刚刚已刷新；手动刷新间隔为 5 分钟")
            return
        }
        refreshFromNetwork(manual: true)
    }

    func refreshIfNeeded() {
        guard settings.codexRadarEnabled else { return }
        let date = now()
        if let retryAt, date < retryAt {
            scheduleNextRefresh()
            return
        }
        let wantsAuthorizedAPI = !settings.codexRadarAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let desiredSource: CodexRadarDataSource = wantsAuthorizedAPI ? .authorizedAPI : .publicMetrics
        if retryAt != nil || snapshot.dataSource != desiredSource
            || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: snapshot.fetchedAt, now: date) {
            refreshFromNetwork()
        } else {
            scheduleNextRefresh()
        }
    }

    private func loadCacheAndSchedule(forceRefresh: Bool = false) {
        refreshTimer?.invalidate()
        nextRefreshAt = nil
        guard settings.codexRadarEnabled else {
            cancelRefresh()
            snapshot = .disabled
            return
        }
        if let cached = CodexRadarCache.load(from: cacheDirectory) {
            let stale = cached.dataSource == .publicSummary
                || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: cached.fetchedAt, now: now())
            snapshot = cached.withState(stale ? .stale : .ready, message: stale ? "缓存已过期，正在后台更新" : nil)
        } else {
            snapshot = .loading
        }
        if forceRefresh { refreshFromNetwork() }
        else { refreshIfNeeded() }
    }

    private func refreshFromNetwork(manual: Bool = false) {
        guard settings.codexRadarEnabled, !isRefreshing else { return }
        refreshTimer?.invalidate()
        nextRefreshAt = nil
        isRefreshing = true
        generation += 1
        let currentGeneration = generation
        let token = settings.codexRadarAPIToken
        let previous = snapshot
        let client = client
        refreshTask = Task { [weak self] in
            do {
                let result = try await client.fetch(token: token, forceRefresh: manual)
                try Task.checkCancellation()
                guard let self, currentGeneration == self.generation else { return }
                let fetchedAt = self.now()
                let next = try CodexRadarSnapshot.decode(data: result.data, fetchedAt: fetchedAt, source: result.source)
                self.isRefreshing = false
                self.refreshTask = nil
                self.retryAt = nil
                if manual { self.lastManualRefreshAt = fetchedAt }
                self.snapshot = next
                do {
                    try CodexRadarCache.save(data: result.data, fetchedAt: fetchedAt, source: result.source, to: self.cacheDirectory)
                } catch {
                    self.snapshot = next.withState(.ready, message: "数据已获取，但本地缓存保存失败")
                }
                self.scheduleNextRefresh()
            } catch {
                guard let self, currentGeneration == self.generation else { return }
                self.isRefreshing = false
                self.refreshTask = nil
                self.lastManualRefreshAt = nil
                self.retryAt = self.now().addingTimeInterval(CodexRadarRefreshPolicy.retryInterval)
                let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).redactedForDisplay
                self.snapshot = previous.hasData
                    ? previous.withState(.stale, message: "\(message)；5 分钟后自动重试，可手动重试")
                    : CodexRadarSnapshot.loading.withState(.error, message: "\(message)；5 分钟后自动重试，可手动重试")
                self.scheduleNextRefresh()
            }
        }
    }

    private func observeSettings() {
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.settingsDidChange() }
            }
            .store(in: &cancellables)
    }

    private func settingsDidChange() {
        let enabled = settings.codexRadarEnabled
        let token = settings.codexRadarAPIToken
        guard enabled != observedEnabled || token != observedToken else { return }
        observedEnabled = enabled
        observedToken = token
        cancelRefresh()
        retryAt = nil
        lastManualRefreshAt = nil
        refreshTimer?.invalidate()
        nextRefreshAt = nil
        if !enabled { snapshot = .disabled }
        settingsTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.loadCacheAndSchedule(forceRefresh: true) }
        }
        timer.tolerance = 0.15
        settingsTimer = timer
    }

    private func scheduleNextRefresh() {
        guard settings.codexRadarEnabled, !isRefreshing else { return }
        refreshTimer?.invalidate()
        let now = now()
        let next = CodexRadarRefreshPolicy.nextRefresh(after: now, lastFetchAt: snapshot.fetchedAt, retryAt: retryAt)
        nextRefreshAt = next
        let interval = max(1, next.timeIntervalSince(now))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
        timer.tolerance = min(30, interval * 0.1)
        refreshTimer = timer
    }

    private func cancelRefresh() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }
}

private enum CodexRadarCache {
    struct Metadata: Codable {
        let fetchedAt: Date
        let source: CodexRadarDataSource
    }

    static func defaultDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("codex监测/CodexRadar", isDirectory: true)
    }

    static func load(from directory: URL) -> CodexRadarSnapshot? {
        let dataURL = directory.appendingPathComponent("current.json")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: dataURL),
              let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData) else { return nil }
        return try? CodexRadarSnapshot.decode(data: data, fetchedAt: metadata.fetchedAt, source: metadata.source)
    }

    static func save(data: Data, fetchedAt: Date, source: CodexRadarDataSource, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)
        let dataURL = directory.appendingPathComponent("current.json")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        try data.write(to: dataURL, options: .atomic)
        try JSONEncoder().encode(Metadata(fetchedAt: fetchedAt, source: source)).write(to: metadataURL, options: .atomic)
        chmod(dataURL.path, S_IRUSR | S_IWUSR)
        chmod(metadataURL.path, S_IRUSR | S_IWUSR)
    }
}
