import Combine
import Darwin
import Foundation

@MainActor
final class CodexRadarViewModel: ObservableObject {
    @Published private(set) var snapshot: CodexRadarSnapshot = .disabled
    @Published private(set) var isRefreshing = false

    private let settings: CodexNotchSettings
    private let client: CodexRadarClient
    private let cacheDirectory: URL
    private var refreshTimer: Timer?
    private var settingsTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var generation = 0
    private var observedEnabled: Bool
    private var observedToken: String
    private var lastManualRefreshAt: Date?

    init(
        settings: CodexNotchSettings,
        client: CodexRadarClient = CodexRadarClient(),
        cacheDirectory: URL = CodexRadarCache.defaultDirectory()
    ) {
        self.settings = settings
        self.client = client
        self.cacheDirectory = cacheDirectory
        observedEnabled = settings.codexRadarEnabled
        observedToken = settings.codexRadarAPIToken
        observeSettings()
        loadCacheAndSchedule()
    }

    func refreshNow() {
        guard settings.codexRadarEnabled else { return }
        let now = Date()
        guard CodexRadarRefreshPolicy.canManualRefresh(lastRefreshAt: lastManualRefreshAt, now: now) else {
            snapshot = snapshot.withState(snapshot.hasData ? .stale : .error, message: "手动刷新间隔为 5 分钟")
            return
        }
        lastManualRefreshAt = now
        refreshFromNetwork(cancelCurrent: true)
    }

    func refreshIfNeeded() {
        guard settings.codexRadarEnabled else { return }
        let wantsAuthorizedAPI = !settings.codexRadarAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let desiredSource: CodexRadarDataSource = wantsAuthorizedAPI ? .authorizedAPI : .publicSummary
        if snapshot.dataSource != desiredSource
            || CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: snapshot.fetchedAt) {
            refreshFromNetwork()
        } else {
            scheduleNextRefresh()
        }
    }

    private func loadCacheAndSchedule() {
        refreshTimer?.invalidate()
        guard settings.codexRadarEnabled else {
            cancelRefresh()
            snapshot = .disabled
            return
        }
        if let cached = CodexRadarCache.load(from: cacheDirectory) {
            let stale = CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: cached.fetchedAt)
            snapshot = cached.withState(stale ? .stale : .ready, message: stale ? "缓存已过期，正在后台更新" : nil)
        } else {
            snapshot = .loading
        }
        refreshIfNeeded()
    }

    private func refreshFromNetwork(cancelCurrent: Bool = false) {
        if cancelCurrent { cancelRefresh() }
        guard settings.codexRadarEnabled, !isRefreshing else { return }
        isRefreshing = true
        generation += 1
        let currentGeneration = generation
        let token = settings.codexRadarAPIToken
        let previous = snapshot
        let client = client
        let directory = cacheDirectory

        refreshTask = Task.detached(priority: .utility) {
            do {
                let result = try await client.fetch(token: token)
                let fetchedAt = Date()
                let next = try CodexRadarSnapshot.decode(data: result.data, fetchedAt: fetchedAt, source: result.source)
                try CodexRadarCache.save(data: result.data, fetchedAt: fetchedAt, source: result.source, to: directory)
                await MainActor.run {
                    guard currentGeneration == self.generation else { return }
                    self.isRefreshing = false
                    self.refreshTask = nil
                    self.snapshot = next
                    self.scheduleNextRefresh(now: fetchedAt)
                }
            } catch {
                await MainActor.run {
                    guard currentGeneration == self.generation else { return }
                    self.isRefreshing = false
                    self.refreshTask = nil
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription.redactedForDisplay
                    self.snapshot = previous.hasData
                        ? previous.withState(.stale, message: message)
                        : CodexRadarSnapshot.loading.withState(.error, message: message)
                    self.scheduleNextRefresh()
                }
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
        settingsTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.loadCacheAndSchedule() }
        }
        timer.tolerance = 0.15
        settingsTimer = timer
    }

    private func scheduleNextRefresh(now: Date = Date()) {
        guard settings.codexRadarEnabled else { return }
        refreshTimer?.invalidate()
        let interval = max(60, CodexRadarRefreshPolicy.nextScheduledRefresh(after: now).timeIntervalSince(now))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshIfNeeded() }
        }
        timer.tolerance = min(300, interval * 0.1)
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
