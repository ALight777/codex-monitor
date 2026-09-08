import Foundation
import Testing
@testable import CodexNotch

private let radarMetrics = Data(#"""
{"schema":3,"benchmark_id":"deep-swe","source_updated_at":"2026-09-07T13:51:58Z","points":[
 {"model":"gpt-6-astra","effort":"ultra","iq":113.11,"passed":138,"total":183,"average_price_usd":8.45,"average_minutes":21.3},
 {"model":"gpt-5.6-sol","effort":"max","iq":"106.7","passed":"239","total":"336","average_price_usd":"5.5","average_minutes":"30.1"},
 {"model":"gpt-5.6-luna","effort":"low","iq":0,"passed":0,"total":112,"average_price_usd":null,"average_minutes":null},
 {"model":"other-provider","effort":"high","iq":150}
]}
"""#.utf8)

@Test func codexRadarLiveMetricsDecodeAndKeepSourceTimestamp() throws {
    let fetchedAt = Date()
    let snapshot = try CodexRadarSnapshot.decode(data: radarMetrics, fetchedAt: fetchedAt, source: .publicMetrics)
    #expect(snapshot.models.count == 3)
    #expect(snapshot.models.first?.label == "gpt-6-astra ultra")
    #expect(snapshot.models.first?.score == 113.11)
    #expect(snapshot.models.first?.tasks == 183)
    #expect(snapshot.models.first?.costUSD == 8.45)
    #expect(snapshot.models.first?.wallTime == "均时 21.3 分钟")
    #expect(snapshot.models[1].passed == 239)
    #expect(snapshot.models[1].costUSD == 5.5)
    #expect(snapshot.models.last?.score == 0)
    #expect(snapshot.models.last?.costUSD == nil)
    #expect(snapshot.displayUpdatedAt == ISO8601DateFormatter().date(from: "2026-09-07T13:51:58Z"))
    #expect(snapshot.fetchedAt == fetchedAt)
    #expect(snapshot.prediction == nil)
    #expect(snapshot.quotaRows.isEmpty)
}

@Test func codexRadarRejectsUnrecognizedAndEmptyMetrics() {
    for json in ["{}", "<html>upstream error</html>",
        #"{"schema":3,"benchmark_id":"deep-swe","source_updated_at":"2026-09-07T13:51:58Z","points":[]}"#,
        String(decoding: radarMetrics, as: UTF8.self).replacingOccurrences(of: "deep-swe", with: "another-benchmark"),
        String(decoding: radarMetrics, as: UTF8.self).replacingOccurrences(of: "2026-09-07T13:51:58Z", with: "invalid")
    ] {
        #expect(throws: (any Error).self) {
            try CodexRadarSnapshot.decode(data: Data(json.utf8), fetchedAt: Date(), source: .publicMetrics)
        }
    }
}

@Test func codexRadarLegacyTimestampUsesModelTimeInsteadOfFetchTime() throws {
    let data = Data(#"{"monitored_at":"2026-09-02T12:11:35Z","model_iq":{"updated_at":"2026-09-06T07:06:03Z","latest":{"model":"gpt-5.6-sol","score":109}}}"#.utf8)
    let snapshot = try CodexRadarSnapshot.decode(data: data, fetchedAt: Date(), source: .publicSummary)
    #expect(snapshot.displayUpdatedAt == ISO8601DateFormatter().date(from: "2026-09-06T07:06:03Z"))
}

@Test func codexRadarHourlyAndFailureSchedulesDoNotWaitUntilTomorrow() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-09-07T13:00:00Z"))
    #expect(!CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: now, now: now.addingTimeInterval(3599)))
    #expect(CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: now, now: now.addingTimeInterval(3600)))
    #expect(CodexRadarRefreshPolicy.nextRefresh(after: now, lastFetchAt: now) == now.addingTimeInterval(3600))
    #expect(CodexRadarRefreshPolicy.nextRefresh(after: now, lastFetchAt: now, retryAt: now.addingTimeInterval(300)) == now.addingTimeInterval(300))
    #expect(CodexRadarRefreshPolicy.shouldRefresh(lastFetchAt: now.addingTimeInterval(1), now: now))
}

@Test func codexRadarManualRequestRefreshesSharedCacheWithoutSendingCredentials() async throws {
    let transport = RadarTestTransport()
    let client = CodexRadarClient { try await transport.send($0) }
    let result = try await client.fetch(token: "  ", forceRefresh: true)
    #expect(result.source == .publicMetrics)
    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString == "https://codexradar.com/api/intelligence-efficiency-metrics?refresh=1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    _ = try await client.fetch(token: " test-token ", forceRefresh: true)
    let authorized = try #require(await transport.requests.last)
    #expect(authorized.url == CodexRadarClient.authorizedURL)
    #expect(authorized.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
}

@Test func codexRadarStaleEdgeResponsesAreFailures() async throws {
    let client = CodexRadarClient { request in
        (radarMetrics, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                      headerFields: ["X-Codex-Cache": "STALE-ERROR"])!)
    }
    await #expect(throws: CodexRadarClientError.self) { try await client.fetch(token: nil) }
    #expect(!CodexRadarClient.isAllowed(URL(string: "https://codexradar.com:444/api/intelligence-efficiency-metrics")!, authorized: false))
    #expect(!CodexRadarClient.isAllowed(URL(string: "https://codexradar.com/api/v1/current?refresh=1")!, authorized: true))
}

@MainActor
@Suite struct CodexRadarRefreshLifecycleTests {
    @Test func codexRadarMigratesRecentLegacyCacheAndAutomaticallyFetchesAgain() async throws {
        let context = try RadarTestContext()
        defer { context.cleanUp() }
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
        try Data(#"{"status":"legacy"}"#.utf8).write(to: context.directory.appendingPathComponent("current.json"))
        try JSONSerialization.data(withJSONObject: ["fetchedAt": context.date.timeIntervalSinceReferenceDate, "source": "publicSummary"])
            .write(to: context.directory.appendingPathComponent("metadata.json"))
        let transport = RadarTestTransport()
        let model = context.model(transport)
        try await waitForRefresh(model)
        #expect(model.snapshot.dataSource == .publicMetrics)
        #expect(model.snapshot.models.first?.label == "gpt-6-astra ultra")
        #expect(try Data(contentsOf: context.directory.appendingPathComponent("current.json")) == radarMetrics)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: context.directory.appendingPathComponent("metadata.json"))) as? [String: Any]
        #expect(metadata?["source"] as? String == "publicMetrics")
        let attributes = try FileManager.default.attributesOfItem(atPath: context.directory.appendingPathComponent("current.json").path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(model.nextRefreshAt == context.date.addingTimeInterval(3600))
        context.date.addTimeInterval(3600)
        model.refreshIfNeeded()
        try await waitForRefresh(model)
        #expect(await transport.softwareRequests.count == 2)
        #expect(model.snapshot.fetchedAt == context.date)
    }

    @Test func codexRadarFailedManualRefreshRetainsCacheAndAllowsImmediateRetry() async throws {
        let context = try RadarTestContext()
        defer { context.cleanUp() }
        let transport = RadarTestTransport()
        let model = context.model(transport)
        try await waitForRefresh(model)
        let original = model.snapshot
        await transport.setFailure(true)
        model.refreshNow()
        try await waitForRefresh(model)
        #expect(model.snapshot.state == .stale)
        #expect(model.snapshot.models == original.models)
        #expect(model.snapshot.fetchedAt == original.fetchedAt)
        #expect(model.nextRefreshAt == context.date.addingTimeInterval(300))
        #expect(try Data(contentsOf: context.directory.appendingPathComponent("current.json")) == radarMetrics)
        model.refreshIfNeeded()
        #expect(await transport.softwareRequests.count == 2)
        await transport.setFailure(false)
        model.refreshNow()
        try await waitForRefresh(model)
        #expect(await transport.softwareRequests.count == 3)
        #expect(model.snapshot.state == .ready)
        model.refreshNow()
        #expect(await transport.softwareRequests.count == 3)
        #expect(model.snapshot.state == .ready)
    }

    @Test func codexRadarRetriesFailureEvenWhenPreviousFetchWasRecent() async throws {
        let context = try RadarTestContext()
        defer { context.cleanUp() }
        let transport = RadarTestTransport()
        let model = context.model(transport)
        try await waitForRefresh(model)
        await transport.setFailure(true)
        model.refreshNow()
        try await waitForRefresh(model)
        context.date.addTimeInterval(300)
        await transport.setFailure(false)
        model.refreshIfNeeded()
        try await waitForRefresh(model)
        #expect(await transport.softwareRequests.count == 3)
        #expect(model.snapshot.state == .ready)
    }

    @Test func codexRadarDiskFailureStillDisplaysFreshNetworkData() async throws {
        let context = try RadarTestContext()
        defer { context.cleanUp() }
        // A file in place of the cache directory deterministically prevents persistence.
        try Data().write(to: context.directory)
        let model = context.model(RadarTestTransport())
        try await waitForRefresh(model)
        #expect(model.snapshot.state == .ready)
        #expect(model.snapshot.models.count == 3)
        #expect(model.snapshot.message?.contains("缓存保存失败") == true)
    }

    @Test func codexRadarTimerActuallyFetchesWithoutManualRefresh() async throws {
        let context = try RadarTestContext()
        defer { context.cleanUp() }
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
        try radarMetrics.write(to: context.directory.appendingPathComponent("current.json"))
        try JSONSerialization.data(withJSONObject: ["fetchedAt": context.date.addingTimeInterval(-3599).timeIntervalSinceReferenceDate, "source": "publicMetrics"])
            .write(to: context.directory.appendingPathComponent("metadata.json"))
        let visualDirectory = context.directory.appendingPathComponent("visual")
        try FileManager.default.createDirectory(at: visualDirectory, withIntermediateDirectories: true)
        try radarVisualMetrics.write(to: visualDirectory.appendingPathComponent("current.json"))
        try JSONSerialization.data(withJSONObject: ["fetchedAt": context.date.addingTimeInterval(-3599).timeIntervalSinceReferenceDate, "source": "publicVisual"])
            .write(to: visualDirectory.appendingPathComponent("metadata.json"))
        try JSONEncoder().encode(CodexRadarNewsSnapshot(items: [], fetchedAt: context.date.addingTimeInterval(-3599)))
            .write(to: context.directory.appendingPathComponent("news.json"))
        let transport = RadarTestTransport()
        let model = context.model(transport)
        #expect(!model.isRefreshing)
        #expect(await transport.softwareRequests.isEmpty)
        context.date.addTimeInterval(2)
        for _ in 0..<300 {
            if model.snapshot.fetchedAt == context.date { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.softwareRequests.count == 1)
        #expect(model.snapshot.fetchedAt == context.date)
    }

    @Test func codexRadarDisablingCancelsLateResponseBeforeCacheWrite() async throws {
        let context = try RadarTestContext()
        defer { context.cleanUp() }
        let transport = RadarDelayedTransport()
        let model = CodexRadarViewModel(settings: context.settings,
            client: CodexRadarClient { try await transport.send($0) },
            cacheDirectory: context.directory, selectionDefaults: context.defaults, now: { context.date })
        for _ in 0..<100 {
            if await transport.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.started)
        context.settings.codexRadarEnabled = false
        for _ in 0..<100 {
            if model.snapshot.state == .disabled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await transport.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.snapshot.state == .disabled)
        #expect(!model.isRefreshing)
        #expect(model.nextRefreshAt == nil)
        #expect(!FileManager.default.fileExists(atPath: context.directory.appendingPathComponent("current.json").path))
    }

    private func waitForRefresh(_ model: CodexRadarViewModel) async throws {
        for _ in 0..<200 {
            if !model.isRefreshing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Radar refresh did not complete")
    }
}

private actor RadarTestTransport {
    var requests: [URLRequest] = []
    var softwareRequests: [URLRequest] { requests.filter { $0.url?.path == CodexRadarClient.publicURL.path } }
    private var shouldFail = false
    func setFailure(_ value: Bool) { shouldFail = value }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return (radarResponseData(request), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor RadarDelayedTransport {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        if request.url?.path != CodexRadarClient.publicURL.path {
            return (radarResponseData(request), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        started = true
        await withCheckedContinuation { continuation = $0 }
        return (radarResponseData(request), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private final class RadarTestContext {
    let suite = "radar-refresh-tests-\(UUID())"
    let defaults: UserDefaults
    let directory: URL
    let settings: CodexNotchSettings
    var date = ISO8601DateFormatter().date(from: "2026-09-07T13:00:00Z")!

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults.set(true, forKey: "codexRadarEnabled")
        defaults.set("software", forKey: "codexRadarDimension")
        settings = CodexNotchSettings(
            defaults: defaults, initialManagementKey: "", initialNewAPIKey: "", initialSubAPIKey: "",
            secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
            launchAtLoginManager: RadarLaunchAtLoginManager(), loadSecretsSynchronously: true
        )
    }

    func model(_ transport: RadarTestTransport) -> CodexRadarViewModel {
        CodexRadarViewModel(settings: settings, client: CodexRadarClient { try await transport.send($0) },
                            cacheDirectory: directory, selectionDefaults: defaults, now: { self.date })
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct RadarLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws {}
}

private let radarVisualMetrics = Data(#"""
{"schema":1,"benchmark_id":"pompeii-adjacency","source_updated_at":"2026-09-07T13:50:00Z","points":[
 {"model":"gpt-6-astra","effort":"ultra","iq":140,"passed":12.7,"valid_tasks":20,"benchmark_tasks":86,"average_price_usd":2,"average_minutes":5}
]}
"""#.utf8)

private func radarResponseData(_ request: URLRequest) -> Data {
    switch request.url?.path {
    case CodexRadarClient.visualURL.path: return radarVisualMetrics
    case "/": return Data(#"<html data-radar-station="codex"><section class="site-announcement"><strong class="site-announcement-headline">Test news</strong></section></html>"#.utf8)
    default: return radarMetrics
    }
}
