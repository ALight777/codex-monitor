import Foundation
import Testing
@testable import CodexNotch

func officialThreeTaskFixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "radar-three-task-20261027", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func threeTaskData(score: Double = 100) throws -> Data {
    var payload = try #require(JSONSerialization.jsonObject(with: officialThreeTaskFixture()) as? [String: Any])
    var row = (payload["rows"] as! [[String: Any]])[0]
    var pompeii = row["pompeii"] as! [String: Any]
    pompeii["score100"] = score
    row["pompeii"] = pompeii
    payload["rows"] = [row]
    payload["models"] = ["gpt-6-astra"]
    payload["configurations"] = 1; payload["graded"] = 3; payload["expected"] = 3
    return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
}

func threeTaskCacheData() throws -> Data {
    try CodexRadarThreeTaskDocument(payload: CodexRadarThreeTaskPayload.decode(threeTaskData()), totals: nil).encode()
}

func officialTotalPanelFixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "radar-total-panel-20261027", withExtension: "html", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func threeTaskHomepage(score: Double = 100, announcement: String = "<aside class='speed-site-announcement'><div><h2>新公告</h2><p>实战速度</p></div><a href='https://deng.codexradar.com/'>查看</a></aside>") throws -> Data {
    let json = String(decoding: try threeTaskData(score: score), as: UTF8.self)
    return Data("<html data-radar-station='codex'>\(announcement)<script type='application/json' data-cir-scores>\(json)</script></html>".utf8)
}

@Test func radarThreeTaskMatchesAllOfficialRowsAndSeparateScales() throws {
    let snapshots = try CodexRadarThreeTaskPayload.decode(officialThreeTaskFixture()).snapshots(fetchedAt: Date())
    #expect(snapshots.count == 3)
    #expect(snapshots.values.allSatisfy { $0.models.count == 40 && $0.state == .ready })
    #expect(snapshots[.pompeii]?.models.first?.score == 100)
    #expect(snapshots[.pompeii]?.models.first?.costUSD == 5.968954)
    #expect(snapshots[.pompeii]?.models.first?.wallTime == "耗时 573.5 秒")
    #expect(snapshots[.pelican]?.models.first?.score == 94)
    #expect(snapshots[.pelican]?.models.first?.status == "v2")
    #expect(snapshots[.pelican]?.models.first { $0.id == "gpt-6.1-terra|ultra" }?.status == "v3")
    #expect(snapshots[.candy]?.models.first { $0.id == "gpt-6-luna|low" }?.scoreText == "错误")
    #expect(snapshots[.candy]?.models.first { $0.id == "gpt-6-luna|low" }?.scoreIsCorrect == false)
    #expect(snapshots[.candy]?.models.allSatisfy { $0.score == nil && $0.scoreText != nil } == true)
    #expect(snapshots[.pompeii]?.monitoredAt == CodexRadarDateParser.parse("2026-10-27T01:31:02.710353+00:00"))
}

@Test func radarThreeTaskExtractsOnlyInertOfficialPayloadAndAllowsAdditionalFields() throws {
    let html = try threeTaskHomepage()
    #expect(try CodexRadarThreeTaskPayload.extract(from: html) == threeTaskData())
    let reordered = String(decoding: html, as: UTF8.self).replacingOccurrences(of: "type='application/json' data-cir-scores", with: "data-cir-scores='' type=\"application/json\"")
    #expect(try CodexRadarThreeTaskPayload.extract(from: Data(reordered.utf8)) == threeTaskData())
    for bad in ["<html>login</html>", String(decoding: html, as: UTF8.self).replacingOccurrences(of: "application/json", with: "text/javascript"), String(decoding: html + html, as: UTF8.self)] {
        #expect(throws: CodexRadarClientError.self) { try CodexRadarThreeTaskPayload.extract(from: Data(bad.utf8)) }
    }
}

@Test func radarThreeTaskRejectsSchemaMismatchDuplicateRowsAndOutOfRangeScores() throws {
    let original = try #require(JSONSerialization.jsonObject(with: threeTaskData()) as? [String: Any])
    for (key, value) in [("schema", "future/2" as Any), ("protocol", "combined-v1"), ("no_combined_score", false), ("graded", 4), ("integrated_verified_at", "invalid"), ("models", ["wrong-model"])] {
        var mutated = original; mutated[key] = value
        #expect(throws: (any Error).self) { try CodexRadarThreeTaskPayload.decode(JSONSerialization.data(withJSONObject: mutated)).snapshots(fetchedAt: Date()) }
    }
    #expect(throws: (any Error).self) { try CodexRadarThreeTaskPayload.decode(threeTaskData(score: 101)).snapshots(fetchedAt: Date()) }
    var duplicate = original
    duplicate["rows"] = (original["rows"] as! [[String: Any]]) + (original["rows"] as! [[String: Any]])
    duplicate["configurations"] = 2; duplicate["expected"] = 6; duplicate["graded"] = 6
    #expect(throws: (any Error).self) { try CodexRadarThreeTaskPayload.decode(JSONSerialization.data(withJSONObject: duplicate)).snapshots(fetchedAt: Date()) }
}

@Test func radarThreeTaskMissingValuesStayUnknownAndZeroIsARealScore() throws {
    var payload = try #require(JSONSerialization.jsonObject(with: threeTaskData(score: 0)) as? [String: Any])
    var rows = payload["rows"] as! [[String: Any]]
    var result = rows[0]["pompeii"] as! [String: Any]
    result["cost_usd"] = NSNull(); result["model_elapsed_seconds"] = NSNull()
    rows[0]["pompeii"] = result
    rows[0]["candy"] = NSNull()
    payload["rows"] = rows; payload["graded"] = 2
    let snapshots = try CodexRadarThreeTaskPayload.decode(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])).snapshots(fetchedAt: Date())
    #expect(snapshots[.pompeii]?.models.first?.score == 0)
    #expect(snapshots[.pompeii]?.models.first?.costUSD == nil)
    #expect(snapshots[.pompeii]?.models.first?.wallTime == nil)
    #expect(snapshots[.candy]?.state == .stale)
    #expect(snapshots[.candy]?.models.first?.scoreText == nil)
    #expect(snapshots[.candy]?.models.first?.status == "待测")
    #expect(snapshots[.pelican]?.state == .ready)
}

@Test func radarCurrentAnnouncementParsesAndRejectsChangedMarkup() throws {
    let news = try CodexRadarNewsParser.decode(threeTaskHomepage(), fetchedAt: Date())
    #expect(news.items.first?.title == "新公告")
    #expect(news.items.first?.summary == "实战速度")
    #expect(news.items.first?.url.absoluteString == "https://deng.codexradar.com/")
    #expect(throws: CodexRadarClientError.self) {
        try CodexRadarNewsParser.decode(threeTaskHomepage(announcement: "<aside class='speed-site-announcement'>unknown</aside>"), fetchedAt: Date())
    }
}

@MainActor @Test(arguments: ["software", "visual", "comprehensive", "bench"])
func radarThreeTaskMigratesOldChoicesAndSwitchesLocally(_ oldChoice: String) async throws {
    let suite = "radar-three-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    defaults.set(true, forKey: "codexRadarEnabled")
    defaults.set(oldChoice, forKey: "codexRadarDimension")
    defaults.set(true, forKey: "codexRadarBenchMigrationV1")
    let settings = CodexNotchSettings(defaults: defaults, initialManagementKey: "", initialNewAPIKey: "", initialSubAPIKey: "",
        secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
        launchAtLoginManager: ThreeTaskLaunchManager(), loadSecretsSynchronously: true)
    let transport = ThreeTaskTransport()
    let client = CodexRadarClient { try await transport.send($0) }
    let model = CodexRadarViewModel(settings: settings, client: client, cacheDirectory: directory, selectionDefaults: defaults)
    for _ in 0..<200 {
        if !model.isRefreshing { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.snapshot.state == .ready)
    #expect(model.selectedTask == .pompeii)
    #expect(defaults.object(forKey: "codexRadarDimension") == nil)
    #expect(defaults.object(forKey: "codexRadarBenchMigrationV1") == nil)
    model.selectTask(.pelican)
    #expect(model.snapshot.models.first?.score == 94)
    model.selectTask(.candy)
    #expect(model.snapshot.models.first?.scoreText == "正确")
    let restored = CodexRadarViewModel(settings: settings, client: client, cacheDirectory: directory, selectionDefaults: defaults)
    #expect(restored.selectedTask == .candy)
    #expect(restored.snapshot.models == model.snapshot.models)
    #expect(!restored.isRefreshing)
    #expect(await transport.requests.count == 1)
    #expect(await transport.requests.allSatisfy { $0.url == CodexRadarClient.newsURL && $0.value(forHTTPHeaderField: "Authorization") == nil })
    settings.codexRadarEnabled = false
}

private actor ThreeTaskTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        return (try threeTaskHomepage(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private struct ThreeTaskLaunchManager: LaunchAtLoginManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws {}
}

@Test func radarPublishedTotalMatchesHomepageAndUsesThreeTaskTotals() throws {
    let document = try CodexRadarThreeTaskDocument.assemble(homepage: officialTotalPanelFixture(), source: officialThreeTaskFixture())
    let snapshots = try document.snapshots(fetchedAt: Date())
    #expect(snapshots.count == 4)
    let first = try #require(snapshots[.total]?.models.first)
    #expect(first.score == 147)
    #expect(first.costUSD == 5.968954 + 3.184942 + 0.415844)
    #expect(first.wallTime == "耗时 1870.9 秒")
    #expect(first.sampleLabel == "/150")
    let restored = try CodexRadarThreeTaskDocument.decode(document.encode()).snapshots(fetchedAt: Date())
    #expect(restored[.total]?.models == snapshots[.total]?.models)
}

@Test func radarRejectsMismatchedHomepageTotalsAndChangedPolicy() throws {
    let html = String(decoding: try officialTotalPanelFixture(), as: UTF8.self)
    for changed in [html.replacingOccurrences(of: "<strong>147.0</strong>", with: "<strong>100.0</strong>"),
                    html.replacingOccurrences(of: "三题等权，总分换算为150分", with: "新规则"),
                    html.replacingOccurrences(of: "gpt-6-astra:ultra", with: "missing:ultra")] {
        #expect(throws: CodexRadarClientError.self) {
            try CodexRadarThreeTaskDocument.assemble(homepage: Data(changed.utf8), source: officialThreeTaskFixture())
        }
    }
    let independent = try CodexRadarThreeTaskDocument.assemble(homepage: threeTaskHomepage(), source: threeTaskData())
    #expect(try independent.snapshots(fetchedAt: Date())[.total] == nil)
}

@Test func radarExternalJSONFetchIsAnonymousAndCurrentEndpointOnly() async throws {
    let transport = ExternalThreeTaskTransport()
    let result = await CodexRadarClient { try await transport.send($0) }.fetchPublicData()
    let snapshots = try CodexRadarThreeTaskDocument.decode(result.scores.get()).snapshots(fetchedAt: Date())
    #expect(snapshots[.total]?.models.count == 40)
    #expect(await transport.requests.map(\.url) == [CodexRadarClient.newsURL, CodexRadarClient.threeTaskURL])
    #expect(await transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
}

private actor ExternalThreeTaskTransport {
    private var failed = false
    func failScores() { failed = true }
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        if failed && request.url == CodexRadarClient.threeTaskURL { throw URLError(.timedOut) }
        var data = try request.url == CodexRadarClient.newsURL ? officialTotalPanelFixture() : officialThreeTaskFixture()
        if failed {
            data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "看模型在实战中的速度表现", with: "更新后的公告").utf8)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor @Test func radarTotalDefaultsAndScoreFailurePreservesDataWhileNewsUpdates() async throws {
    let suite = "radar-total-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    defaults.set(true, forKey: "codexRadarEnabled")
    let settings = CodexNotchSettings(defaults: defaults, initialManagementKey: "", initialNewAPIKey: "", initialSubAPIKey: "",
        secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
        launchAtLoginManager: ThreeTaskLaunchManager(), loadSecretsSynchronously: true)
    let transport = ExternalThreeTaskTransport()
    let model = CodexRadarViewModel(settings: settings, client: CodexRadarClient { try await transport.send($0) },
        cacheDirectory: directory, selectionDefaults: defaults)
    func wait() async throws {
        for _ in 0..<200 {
            if !model.isRefreshing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Total refresh did not finish")
    }
    try await wait()
    #expect(model.selectedTask == .total)
    #expect(model.availableTasks.count == 4)
    #expect(model.snapshot.models.first?.score == 147)
    let original = model.snapshot
    await transport.failScores()
    model.refreshNow()
    try await wait()
    #expect(model.snapshot.state == .stale)
    #expect(model.snapshot.models == original.models)
    #expect(model.snapshot.fetchedAt == original.fetchedAt)
    #expect(model.news?.items.first?.title == "更新后的公告")
    #expect(model.newsMessage == nil)
    #expect(model.nextRefreshAt != nil)
    settings.codexRadarEnabled = false
}
