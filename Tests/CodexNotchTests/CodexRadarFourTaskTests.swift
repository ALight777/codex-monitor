import Foundation
import Testing
@testable import CodexNotch

func officialFourTaskFixture(_ name: String = "radar-four-task-20261028", extension ext: String = "json") throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

func fourTaskHomepage() throws -> Data {
    try officialFourTaskFixture("radar-four-total-panel-20261028", extension: "html")
}

private func fourTaskSnapshots(source: Data? = nil, homepage: Data? = nil) throws -> [CodexRadarTask: CodexRadarSnapshot] {
    try CodexRadarFourTaskDocument.assemble(homepage: homepage ?? fourTaskHomepage(), source: source ?? officialFourTaskFixture())
        .snapshots(fetchedAt: Date())
}

@Test func radarFourTaskMatchesPublishedTotalsAndCurrentRubrics() throws {
    let snapshots = try fourTaskSnapshots()
    #expect(snapshots.count == 5)
    #expect(snapshots.values.allSatisfy { $0.models.count == 46 && $0.state == .ready && $0.dataSource == .publicFourTask })
    let total = try #require(snapshots[.total])
    #expect(total.models.first?.id == "gpt-6.1-sol|ultra")
    #expect(total.models.first?.scoreText == "126.98")
    #expect(total.models.first?.sampleLabel == "/150")
    #expect(total.monitoredAt == CodexRadarDateParser.parse("2026-10-27T15:16:50.228620+00:00"))
    let low = try #require(total.models.first { $0.id == "gpt-6.1-sol|low" })
    #expect(low.score == 112.5)
    let cost = try #require(low.costUSD)
    #expect(abs(cost - 0.41386) < 0.0000001)
    #expect(low.wallTime == "耗时 14.59 分钟")
    #expect(snapshots[.combined]?.models.first { $0.id == low.id }?.score == 66)
    #expect(snapshots[.combined]?.models.first { $0.id == low.id }?.status == "独立v1")
    #expect(snapshots[.pelican]?.models.contains { $0.status == "可见v2" } == true)
    #expect(snapshots[.total]?.models.filter { $0.label.hasPrefix("GPT-5.6 Terra") }.count == 6)
    #expect(snapshots[.candy]?.models.contains { $0.scoreIsCorrect == false && $0.scoreText == "错误" } == true)
    #expect(!total.models.contains { $0.id == "gpt-6-luna|ultra" })
    let document = try CodexRadarFourTaskDocument.assemble(homepage: fourTaskHomepage(), source: officialFourTaskFixture())
    let restored = try CodexRadarPublicDocument.snapshots(data: document.encode(), fetchedAt: Date())
    #expect(restored[.total]?.models == total.models)
}

@Test func radarFourTaskRejectsChangedWeightsScopeRubricsAndCrossRoundTotals() throws {
    let original = try #require(JSONSerialization.jsonObject(with: officialFourTaskFixture()) as? [String: Any])
    for (key, value) in [("schema", "future/2" as Any), ("protocol", "codex-four-weighted-150-v3"),
                         ("task_weights", ["combined": 50, "pompeii": 50, "pelican": 25, "candy": 25]),
                         ("graded", 183), ("score_snapshot_at", "bad-date"), ("models", ["wrong-model"]),
                         ("rows", [(original["rows"] as! [[String: Any]])[0]])] {
        var source = original; source[key] = value
        #expect(throws: (any Error).self) { try fourTaskSnapshots(source: JSONSerialization.data(withJSONObject: source)) }
    }
    for change in ["rubric", "score", "selector", "execution_id"] {
        var source = original; var rows = source["rows"] as! [[String: Any]]
        var result = rows[0]["combined"] as! [String: Any]
        result[change] = change == "score" ? 70 : change == "execution_id" ? "" : "unknown"
        rows[0]["combined"] = result; source["rows"] = rows
        #expect(throws: (any Error).self) { try fourTaskSnapshots(source: JSONSerialization.data(withJSONObject: source)) }
    }
    let html = String(decoding: try fourTaskHomepage(), as: UTF8.self)
    for changed in [html.replacingOccurrences(of: "<strong>126.98</strong>", with: "<strong>126.97</strong>"),
                    html.replacingOccurrences(of: "gpt-6.1-sol:ultra", with: "gpt-6.1-sol:max")] {
        #expect(throws: (any Error).self) { try fourTaskSnapshots(homepage: Data(changed.utf8)) }
    }
}

@Test func radarFourTaskMissingResultsAndIncompleteMetricsStayUnknown() throws {
    var source = try #require(JSONSerialization.jsonObject(with: officialFourTaskFixture()) as? [String: Any])
    var rows = source["rows"] as! [[String: Any]]
    let index = try #require(rows.firstIndex { $0["model"] as? String == "gpt-6.1-sol" && $0["effort"] as? String == "ultra" })
    rows[index]["combined"] = NSNull()
    var pompeii = rows[0]["pompeii"] as! [String: Any]
    pompeii["cost_usd"] = NSNull(); pompeii["model_started_at"] = NSNull()
    rows[0]["pompeii"] = pompeii
    source["rows"] = rows; source["graded"] = 183
    let html = String(decoding: try fourTaskHomepage(), as: UTF8.self).replacingOccurrences(of: "<strong>126.98</strong>", with: "<strong>--</strong>")
    let snapshots = try fourTaskSnapshots(source: JSONSerialization.data(withJSONObject: source), homepage: Data(html.utf8))
    #expect(snapshots[.total]?.state == .stale)
    #expect(snapshots[.total]?.models.first?.score == nil)
    #expect(snapshots[.combined]?.models.first?.status == "待测")
    #expect(snapshots[.pompeii]?.state == .ready)
    let low = try #require(snapshots[.total]?.models.first { $0.id == "gpt-6.1-sol|low" })
    #expect(low.score == 112.5)
    #expect(low.costUSD == nil && low.wallTime == nil)
}

private actor FourTaskTransport {
    enum Mode { case legacy, current, failure }
    var mode: Mode = .current
    var requests: [URLRequest] = []
    func setMode(_ mode: Mode) { self.mode = mode }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let data: Data
        if request.url == CodexRadarClient.newsURL {
            data = try mode == .legacy ? threeTaskHomepage() : fourTaskHomepage()
        } else {
            #expect(request.url == CodexRadarClient.fourTaskURL)
            if mode == .failure { throw URLError(.timedOut) }
            data = try officialFourTaskFixture()
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Test func radarFourTaskFetchSelectsCurrentSourceAndNeverFallsBackToOldFile() async throws {
    let transport = FourTaskTransport()
    let client = CodexRadarClient { try await transport.send($0) }
    let result = await client.fetchPublicData()
    #expect(try CodexRadarPublicDocument.snapshots(data: result.scores.get(), fetchedAt: Date())[.total]?.models.count == 46)
    #expect(await transport.requests.map(\.url) == [CodexRadarClient.newsURL, CodexRadarClient.fourTaskURL])
    await transport.setMode(.failure)
    let failure = await client.fetchPublicData()
    #expect(throws: (any Error).self) { try failure.scores.get() }
    #expect(try CodexRadarNewsParser.decode(failure.homepage.get(), fetchedAt: Date()).items.count == 1)
    #expect(await transport.requests.allSatisfy { $0.url != CodexRadarClient.threeTaskURL && $0.value(forHTTPHeaderField: "Authorization") == nil })
    #expect(!CodexRadarClient.isAllowed(URL(string: "https://codexradar.com/data/codex-four-task-results.json?token=x")!, authorized: false))
}

@MainActor @Test func radarFourTaskUpgradeSwitchRestoreAndFailureKeepOneDataset() async throws {
    let suite = "radar-four-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    defaults.set(true, forKey: "codexRadarEnabled")
    let settings = CodexNotchSettings(defaults: defaults, initialManagementKey: "", initialNewAPIKey: "", initialSubAPIKey: "",
        secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
        launchAtLoginManager: FourTaskLaunchManager(), loadSecretsSynchronously: true)
    let transport = FourTaskTransport()
    await transport.setMode(.legacy)
    var date = Date()
    let client = CodexRadarClient { try await transport.send($0) }
    let model = CodexRadarViewModel(settings: settings, client: client, cacheDirectory: directory, selectionDefaults: defaults, now: { date })
    func wait(_ model: CodexRadarViewModel) async throws {
        for _ in 0..<200 {
            if !model.isRefreshing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Four-task refresh did not finish")
    }
    try await wait(model)
    #expect(model.snapshot.dataSource == .publicThreeTask)
    await transport.setMode(.current)
    model.refreshNow(); try await wait(model)
    #expect(model.availableTasks == [.total, .combined, .pompeii, .pelican, .candy])
    model.selectTask(.combined)
    #expect(model.snapshot.models.count == 46)
    #expect(model.snapshot.dataSource == .publicFourTask)
    let restored = CodexRadarViewModel(settings: settings, client: client, cacheDirectory: directory, selectionDefaults: defaults, now: { date })
    #expect(restored.selectedTask == .combined && !restored.isRefreshing)
    #expect(restored.snapshot.models == model.snapshot.models)
    let before = model.snapshot
    date = date.addingTimeInterval(301)
    await transport.setMode(.failure)
    model.refreshNow(); try await wait(model)
    #expect(model.snapshot.models == before.models && model.snapshot.fetchedAt == before.fetchedAt)
    #expect(model.snapshot.state == .stale)
    #expect(model.snapshot.dataSource == .publicFourTask)
    #expect(model.newsMessage == nil)
    settings.codexRadarEnabled = false
}

private struct FourTaskLaunchManager: LaunchAtLoginManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws {}
}
