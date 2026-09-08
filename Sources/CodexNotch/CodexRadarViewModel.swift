import Combine
import Darwin
import Foundation

@MainActor
final class CodexRadarViewModel: ObservableObject {
    @Published private(set) var snapshot: CodexRadarSnapshot = .disabled
    @Published private(set) var news: CodexRadarNewsSnapshot?
    @Published private(set) var newsMessage: String?
    @Published private(set) var selectedDimension: CodexRadarDimension
    @Published private(set) var isRefreshing = false
    @Published private(set) var nextRefreshAt: Date?

    private let settings: CodexNotchSettings
    private let client: CodexRadarClient
    private let cacheDirectory: URL
    private let selectionDefaults: UserDefaults
    private let now: @MainActor () -> Date
    private var softwareSnapshot: CodexRadarSnapshot = .loading
    private var visualSnapshot: CodexRadarSnapshot = .loading
    private var authorizedSnapshot: CodexRadarSnapshot?
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
        selectionDefaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.settings = settings
        self.client = client
        self.cacheDirectory = cacheDirectory
        self.selectionDefaults = selectionDefaults
        self.now = now
        selectedDimension = selectionDefaults.string(forKey: "codexRadarDimension")
            .flatMap(CodexRadarDimension.init(rawValue:)) ?? .comprehensive
        observedEnabled = settings.codexRadarEnabled
        observedToken = settings.codexRadarAPIToken
        observeSettings()
        loadCacheAndSchedule()
    }

    func selectDimension(_ dimension: CodexRadarDimension) {
        selectedDimension = dimension
        selectionDefaults.set(dimension.rawValue, forKey: "codexRadarDimension")
        updateDisplayedSnapshot()
    }

    func refreshNow() {
        guard settings.codexRadarEnabled, !isRefreshing else { return }
        guard CodexRadarRefreshPolicy.canManualRefresh(lastRefreshAt: lastManualRefreshAt, now: now()) else {
            snapshot = snapshot.withState(snapshot.state, message: "刚刚已刷新；手动刷新间隔为 5 分钟")
            return
        }
        refreshFromNetwork(manual: true)
    }

    private var oldestFetchAt: Date? {
        [softwareSnapshot.fetchedAt, visualSnapshot.fetchedAt, news?.fetchedAt].compactMap { $0 }.min()
    }

    func refreshIfNeeded() {
        guard settings.codexRadarEnabled else { return }
        if let retryAt, now() < retryAt {
            scheduleNextRefresh()
            return
        }
        if retryAt != nil || softwareSnapshot.dataSource != .publicMetrics
            || visualSnapshot.dataSource != .publicVisual || news == nil
            || (!settings.codexRadarAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && authorizedSnapshot == nil)
            || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: oldestFetchAt, now: now()) {
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
        func loaded(_ directory: URL) -> CodexRadarSnapshot {
            guard let cached = CodexRadarCache.load(from: directory) else { return .loading }
            let stale = cached.dataSource == .publicSummary
                || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: cached.fetchedAt, now: now())
            return cached.withState(stale ? .stale : .ready, message: stale ? "缓存已过期，正在后台更新" : nil)
        }
        softwareSnapshot = loaded(cacheDirectory)
        visualSnapshot = loaded(cacheDirectory.appendingPathComponent("visual"))
        news = CodexRadarCache.loadNews(from: cacheDirectory)
        newsMessage = nil
        updateDisplayedSnapshot()
        if forceRefresh { refreshFromNetwork() }
        else { refreshIfNeeded() }
    }

    private func updateDisplayedSnapshot() {
        guard settings.codexRadarEnabled else { snapshot = .disabled; return }
        switch selectedDimension {
        case .software: snapshot = softwareSnapshot
        case .visual: snapshot = visualSnapshot
        case .comprehensive: snapshot = .comprehensive(software: softwareSnapshot, visual: visualSnapshot)
        }
        if isRefreshing && snapshot.models.isEmpty {
            snapshot = snapshot.withState(.loading, message: "正在读取此维度的评分")
        }
        if let authorizedSnapshot {
            snapshot.quotaRows = authorizedSnapshot.quotaRows
            snapshot.quotaUpdatedAt = authorizedSnapshot.quotaUpdatedAt
            if authorizedSnapshot.state != .ready {
                snapshot.message = [snapshot.message, authorizedSnapshot.message].compactMap { $0 }.joined(separator: "；")
            }
        }
    }

    private nonisolated static func capture(_ action: @Sendable () async throws -> Data) async -> Result<Data, Error> {
        do { return .success(try await action()) }
        catch { return .failure(error) }
    }

    private func refreshFromNetwork(manual: Bool = false) {
        guard settings.codexRadarEnabled, !isRefreshing else { return }
        refreshTimer?.invalidate()
        nextRefreshAt = nil
        isRefreshing = true
        updateDisplayedSnapshot()
        generation += 1
        let currentGeneration = generation
        let token = settings.codexRadarAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = client
        refreshTask = Task { [weak self] in
            async let software = Self.capture { try await client.fetch(token: nil, forceRefresh: manual).data }
            async let visual = Self.capture { try await client.fetchVisual(forceRefresh: manual) }
            async let newsResult = Self.capture { try await client.fetchNews() }
            async let authorized: Result<Data, Error>? = token.isEmpty ? nil : Self.capture { try await client.fetch(token: token).data }
            let results = await (software, visual, newsResult, authorized)
            guard let self, !Task.isCancelled, currentGeneration == self.generation else { return }
            let fetchedAt = self.now()
            let softwareResult = self.applyScores(results.0, source: .publicMetrics, previous: self.softwareSnapshot,
                                                  directory: self.cacheDirectory, fetchedAt: fetchedAt)
            let visualResult = self.applyScores(results.1, source: .publicVisual, previous: self.visualSnapshot,
                                                directory: self.cacheDirectory.appendingPathComponent("visual"), fetchedAt: fetchedAt)
            self.softwareSnapshot = softwareResult.snapshot
            self.visualSnapshot = visualResult.snapshot
            var failed = !softwareResult.succeeded || !visualResult.succeeded
            if let result = results.3 {
                let authorizedResult = self.applyScores(result, source: .authorizedAPI, previous: self.authorizedSnapshot ?? .loading,
                                                         directory: self.cacheDirectory.appendingPathComponent("authorized"), fetchedAt: fetchedAt)
                self.authorizedSnapshot = authorizedResult.snapshot
                failed = failed || !authorizedResult.succeeded
            }
            do {
                self.news = try CodexRadarNewsParser.decode(results.2.get(), fetchedAt: fetchedAt)
                self.newsMessage = nil
                do { try CodexRadarCache.saveNews(self.news!, to: self.cacheDirectory) }
                catch { self.newsMessage = "新闻已获取，但本地缓存保存失败" }
            } catch {
                failed = true
                self.newsMessage = "新闻暂未更新，5 分钟后重试"
            }
            self.isRefreshing = false
            self.refreshTask = nil
            self.retryAt = failed ? fetchedAt.addingTimeInterval(CodexRadarRefreshPolicy.retryInterval) : nil
            if failed { self.lastManualRefreshAt = nil }
            else if manual { self.lastManualRefreshAt = fetchedAt }
            self.updateDisplayedSnapshot()
            self.scheduleNextRefresh()
        }
    }

    private func applyScores(_ result: Result<Data, Error>, source: CodexRadarDataSource,
                             previous: CodexRadarSnapshot, directory: URL, fetchedAt: Date)
        -> (snapshot: CodexRadarSnapshot, succeeded: Bool) {
        do {
            let data = try result.get()
            var next = try CodexRadarSnapshot.decode(data: data, fetchedAt: fetchedAt, source: source)
            do { try CodexRadarCache.save(data: data, fetchedAt: fetchedAt, source: source, to: directory) }
            catch { next = next.withState(.ready, message: "数据已获取，但本地缓存保存失败") }
            return (next, true)
        } catch {
            let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription).redactedForDisplay
            var failed = previous.withState(previous.hasData ? .stale : .error,
                    message: "\(message)；5 分钟后自动重试，可手动重试")
            if !previous.hasData { failed.dataSource = source }
            return (failed, false)
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
        authorizedSnapshot = nil
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
        let date = now()
        let next = CodexRadarRefreshPolicy.nextRefresh(after: date, lastFetchAt: oldestFetchAt, retryAt: retryAt)
        nextRefreshAt = next
        let interval = max(1, next.timeIntervalSince(date))
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

    static func loadNews(from directory: URL) -> CodexRadarNewsSnapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("news.json")) else { return nil }
        return try? JSONDecoder().decode(CodexRadarNewsSnapshot.self, from: data)
    }

    static func saveNews(_ news: CodexRadarNewsSnapshot, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)
        let url = directory.appendingPathComponent("news.json")
        try JSONEncoder().encode(news).write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
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
