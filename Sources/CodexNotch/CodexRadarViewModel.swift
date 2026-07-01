import Combine
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
    private var pendingRefresh = false
    private var refreshGeneration = 0
    private var observedEnabled: Bool
    private var lastManualRefreshAt: Date?

    init(
        settings: CodexNotchSettings,
        client: CodexRadarClient = CodexRadarClient(),
        cacheDirectory: URL = CodexRadarCache.defaultDirectory()
    ) {
        self.settings = settings
        self.client = client
        self.cacheDirectory = cacheDirectory
        self.observedEnabled = settings.codexRadarEnabled
        observeSettings()
        loadCacheAndSchedule()
    }

    func refreshNow() {
        guard settings.codexRadarEnabled else {
            snapshot = .disabled
            return
        }

        let now = Date()
        guard CodexRadarRefreshPolicy.canManualRefresh(lastManualRefreshAt: lastManualRefreshAt, now: now) else {
            snapshot = snapshot.withState(
                snapshot.hasDisplayData ? .stale : .error,
                message: "手动刷新过于频繁，5 分钟后可再次刷新"
            )
            return
        }
        lastManualRefreshAt = now
        refreshFromNetwork(cancelInFlight: true)
    }

    func refreshIfNeeded(now: Date = Date()) {
        guard settings.codexRadarEnabled else {
            snapshot = .disabled
            return
        }

        if CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: snapshot.lastFetchAt, now: now) {
            refreshFromNetwork()
        } else {
            scheduleNextRefresh(now: now)
        }
    }

    private func loadCacheAndSchedule() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        guard settings.codexRadarEnabled else {
            invalidateInFlightRefresh()
            snapshot = .disabled
            return
        }

        if let cached = CodexRadarCache.load(from: cacheDirectory) {
            snapshot = cached.snapshot.withState(
                CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: cached.snapshot.lastFetchAt) ? .stale : .ready,
                message: CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: cached.snapshot.lastFetchAt) ? "数据可能已过期，正在后台刷新" : nil
            )
        } else {
            snapshot = .loading
        }

        refreshIfNeeded()
    }

    private func refreshFromNetwork(cancelInFlight: Bool = false) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        if cancelInFlight {
            invalidateInFlightRefresh()
        }

        guard settings.codexRadarEnabled else {
            invalidateInFlightRefresh()
            snapshot = .disabled
            return
        }

        guard !isRefreshing else {
            pendingRefresh = true
            return
        }

        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        let client = client
        let cacheDirectory = cacheDirectory
        let previousSnapshot = snapshot
        if !previousSnapshot.hasDisplayData {
            snapshot = .loading
        }

        refreshTask = Task.detached(priority: .utility) {
            do {
                let result = try await client.fetchSummary()
                let fetchedAt = Date()
                let nextSnapshot = try CodexRadarSnapshot.decodePublicSummary(
                    from: result.data,
                    fetchedAt: fetchedAt,
                    dataSource: result.source
                )
                try CodexRadarCache.save(data: result.data, fetchedAt: fetchedAt, source: result.source, to: cacheDirectory)
                await MainActor.run {
                    guard generation == self.refreshGeneration else {
                        return
                    }
                    self.isRefreshing = false
                    self.refreshTask = nil
                    self.snapshot = nextSnapshot
                    self.scheduleNextRefresh(now: fetchedAt)
                    self.runPendingRefreshIfNeeded()
                }
            } catch {
                await MainActor.run {
                    guard generation == self.refreshGeneration else {
                        return
                    }
                    self.isRefreshing = false
                    self.refreshTask = nil
                    self.snapshot = previousSnapshot.hasDisplayData
                        ? previousSnapshot.withState(.stale, message: "数据可能已过期：\(self.localizedMessage(for: error))")
                        : CodexRadarSnapshot.loading.withState(.error, message: self.localizedMessage(for: error))
                    self.scheduleNextRefresh()
                    self.runPendingRefreshIfNeeded()
                }
            }
        }
    }

    private func observeSettings() {
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
        let nextEnabled = settings.codexRadarEnabled
        guard nextEnabled != observedEnabled else {
            return
        }
        observedEnabled = nextEnabled
        settingsTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.loadCacheAndSchedule()
            }
        }
        timer.tolerance = 0.15
        settingsTimer = timer
    }

    private func scheduleNextRefresh(now: Date = Date()) {
        guard settings.codexRadarEnabled else {
            return
        }

        refreshTimer?.invalidate()
        let next = CodexRadarRefreshPolicy.nextScheduledRefresh(after: now)
        let interval = max(60, next.timeIntervalSince(now))
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.refreshIfNeeded()
            }
        }
        timer.tolerance = min(300, interval * 0.1)
        refreshTimer = timer
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
        refreshIfNeeded()
    }

    private func localizedMessage(for error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }
        let message = error.localizedDescription
        if message.contains("timed out") {
            return "连接超时"
        }
        return message.redactedForDisplay
    }
}

private struct CodexRadarCacheEntry {
    let snapshot: CodexRadarSnapshot
}

private enum CodexRadarCache {
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("CodexNotch", isDirectory: true)
            .appendingPathComponent("CodexRadar", isDirectory: true)
    }

    static func load(from directory: URL) -> CodexRadarCacheEntry? {
        let dataURL = directory.appendingPathComponent("current.json")
        let metadataURL = directory.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: dataURL) else {
            return nil
        }
        let metadata = loadMetadata(from: metadataURL)
        guard let snapshot = try? CodexRadarSnapshot.decodePublicSummary(
            from: data,
            fetchedAt: metadata?.lastFetchAt,
            dataSource: metadata?.source ?? .publicSummary
        ) else {
            return nil
        }
        return CodexRadarCacheEntry(snapshot: snapshot)
    }

    static func save(data: Data, fetchedAt: Date, source: CodexRadarDataSource, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("current.json"), options: .atomic)

        let metadata = CodexRadarCacheMetadata(lastFetchAt: fetchedAt, source: source)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private static func loadMetadata(from url: URL) -> CodexRadarCacheMetadata? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexRadarCacheMetadata.self, from: data)
    }
}

private struct CodexRadarCacheMetadata: Codable {
    let lastFetchAt: Date
    let source: CodexRadarDataSource?
}
