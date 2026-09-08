import Foundation
import Testing
@testable import CodexNotch

private func softwareData(score: Double = 100, cost: String = "6") -> Data {
    Data("""
    {"schema":3,"benchmark_id":"deep-swe","source_updated_at":"2026-09-08T01:00:00Z","points":[
      {"model":"gpt-example","effort":"max","iq":\(score),"passed":200,"total":300,"average_price_usd":\(cost),"average_minutes":30},
      {"model":"gpt-software-only","effort":"high","iq":120,"passed":80,"total":100}
    ]}
    """.utf8)
}

private let visualData = Data(#"""
{"schema":1,"benchmark_id":"pompeii-adjacency","source_updated_at":"2026-09-08T00:00:00Z","points":[
  {"model":"gpt-example","effort":"max","iq":150,"passed":95.8,"valid_tasks":100,"benchmark_tasks":120,"average_price_usd":2,"average_minutes":10}
]}
"""#.utf8)

private let newsHTML = Data(#"""
<html data-radar-station="codex"><section class='site-announcement site-announcement-reset'>
<strong class='site-announcement-headline'>新公告 &amp; &#x1F680;</strong>
<span class='site-announcement-lead'>预计北京时间 <em>10:00</em></span>
<p class='site-announcement-reset-detail'>以官方状态为准。<script>ignore()</script></p>
<a href='https://example.com/news?id=1&amp;lang=zh' class='site-announcement-source'>原文</a>
</section><h2>Other page content</h2></html>
"""#.utf8)

@Test func codexRadarCompositeMatchesWebsiteWeightsAndOlderTimestamp() throws {
    let software = try CodexRadarSnapshot.decode(data: softwareData(), fetchedAt: Date(), source: .publicMetrics)
    let visual = try CodexRadarSnapshot.decode(data: visualData, fetchedAt: Date(), source: .publicVisual)
    let composite = CodexRadarSnapshot.comprehensive(software: software, visual: visual)
    #expect(composite.models.count == 1)
    #expect(composite.models.first?.score == 112.5)
    #expect(composite.models.first?.costUSD == 5)
    #expect(composite.models.first?.averageMinutes == 25)
    #expect(composite.models.first?.validTasks == 400)
    #expect(composite.models.first?.passed == nil)
    #expect(composite.monitoredAt == visual.monitoredAt)
    #expect(visual.models.first?.passed == nil)
    #expect(visual.models.first?.sampleLabel == "覆盖 100/120 题")
    #expect(composite.state == .ready)
    #expect(CodexRadarSnapshot.comprehensive(software: software, visual: visual.withState(.stale)).state == .stale)
}

@Test func codexRadarCompositeDoesNotInventMissingCostsOrUseWrongEfforts() throws {
    let software = try CodexRadarSnapshot.decode(data: softwareData(cost: "null"), fetchedAt: Date(), source: .publicMetrics)
    let visual = try CodexRadarSnapshot.decode(data: visualData, fetchedAt: Date(), source: .publicVisual)
    #expect(CodexRadarSnapshot.comprehensive(software: software, visual: visual).models.first?.costUSD == nil)
    let different = Data(String(decoding: visualData, as: UTF8.self).replacingOccurrences(of: #""max""#, with: #""high""#).utf8)
    let otherEffort = try CodexRadarSnapshot.decode(data: different, fetchedAt: Date(), source: .publicVisual)
    let empty = CodexRadarSnapshot.comprehensive(software: software, visual: otherEffort)
    #expect(empty.models.isEmpty)
    #expect(empty.state == .error)
}

@Test func codexRadarWeightedSchemaPreservesWeightsAndRejectsZeroCoverage() throws {
    let weighted = Data(#"{"schema":2,"benchmark_id":"deep-swe","source_updated_at":"2026-09-08T01:00:00Z","points":[{"model":"gpt-example","effort":"max","iq":100,"weighted_passed":20.5,"weighted_total":30.5,"total":999}]}"#.utf8)
    let snapshot = try CodexRadarSnapshot.decode(data: weighted, fetchedAt: Date(), source: .publicMetrics)
    #expect(snapshot.models.first?.validTasks == 30.5)
    let empty = Data(String(decoding: visualData, as: UTF8.self).replacingOccurrences(of: #""valid_tasks":100"#, with: #""valid_tasks":0"#).utf8)
    #expect(throws: (any Error).self) { try CodexRadarSnapshot.decode(data: empty, fetchedAt: Date(), source: .publicVisual) }
}

@Test func codexRadarBoundsMalformedCountsAndMatchesMinimumWebsiteWeight() throws {
    let malformed = Data(String(decoding: softwareData(), as: UTF8.self)
        .replacingOccurrences(of: "\"passed\":200", with: "\"passed\":\"inf\"")
        .replacingOccurrences(of: "\"average_minutes\":30", with: "\"average_minutes\":\"nan\"").utf8)
    let safe = try CodexRadarSnapshot.decode(data: malformed, fetchedAt: Date(), source: .publicMetrics)
    let score = try #require(safe.models.first { $0.id == "gpt-example|max" })
    #expect(score.passed == nil)
    #expect(score.averageMinutes == nil)
    let invalidCount = Data(String(decoding: visualData, as: UTF8.self)
        .replacingOccurrences(of: "\"valid_tasks\":100", with: "\"valid_tasks\":1e100").utf8)
    #expect(throws: (any Error).self) { try CodexRadarSnapshot.decode(data: invalidCount, fetchedAt: Date(), source: .publicVisual) }
    let weighted = Data(#"{"schema":2,"benchmark_id":"deep-swe","source_updated_at":"2026-09-08T01:00:00Z","points":[{"model":"gpt-example","effort":"max","iq":100,"weighted_total":0.5}]}"#.utf8)
    let software = try CodexRadarSnapshot.decode(data: weighted, fetchedAt: Date(), source: .publicMetrics)
    let visual = try CodexRadarSnapshot.decode(data: visualData, fetchedAt: Date(), source: .publicVisual)
    let expected = 15100.0 / 101.0
    let composite = CodexRadarSnapshot.comprehensive(software: software, visual: visual)
    #expect(composite.models.first?.score == expected)
}

@Test func codexRadarNewsExtractsCurrentAnnouncementWithoutRunningHTML() throws {
    let date = Date()
    let news = try CodexRadarNewsParser.decode(newsHTML, fetchedAt: date)
    #expect(news.items.count == 1)
    #expect(news.items.first?.title == "新公告 & 🚀")
    #expect(news.items.first?.summary == "预计北京时间 10:00\n以官方状态为准。")
    #expect(news.items.first?.url.absoluteString == "https://example.com/news?id=1&lang=zh")
    #expect(news.fetchedAt == date)
    let unsafe = Data(String(decoding: newsHTML, as: UTF8.self).replacingOccurrences(of: "https://example.com/news?id=1&amp;lang=zh", with: "javascript:alert(1)").utf8)
    #expect(try CodexRadarNewsParser.decode(unsafe, fetchedAt: date).items.first?.url == CodexRadarSnapshot.siteURL)
    #expect(CodexRadarNewsParser.safeURL("https://user:password@example.com") == nil)
    #expect(CodexRadarNewsParser.safeURL("/news/new")?.absoluteString == "https://codexradar.com/news/new")
    #expect(throws: (any Error).self) { try CodexRadarNewsParser.decode(Data("<html>502</html>".utf8), fetchedAt: date) }
    #expect(try CodexRadarNewsParser.decode(Data(#"<html data-radar-station="codex"></html>"#.utf8), fetchedAt: date).items.isEmpty)
}

@MainActor
@Suite struct CodexRadarDimensionLifecycleTests {
    @Test func codexRadarSwitchesLocallyAndRestoresSelectionAndAllCaches() async throws {
        let context = try DimensionTestContext()
        defer { context.cleanUp() }
        let model = context.model()
        try await wait(model)
        #expect(model.selectedDimension == .comprehensive)
        #expect(model.snapshot.models.first?.score == 112.5)
        #expect(model.news?.items.first?.title == "新公告 & 🚀")
        let calls = await context.transport.requests.count
        model.selectDimension(.visual)
        #expect(model.snapshot.models.first?.score == 150)
        model.selectDimension(.software)
        #expect(model.snapshot.models.contains { $0.score == 100 })
        #expect(await context.transport.requests.count == calls)
        let reloaded = context.model()
        #expect(reloaded.selectedDimension == .software)
        #expect(!reloaded.isRefreshing)
        reloaded.selectDimension(.visual)
        #expect(reloaded.snapshot.models.first?.score == 150)
        #expect(reloaded.news == model.news)
        #expect(await context.transport.requests.count == calls)
    }

    @Test func codexRadarOneFeedFailureRetainsOnlyItsCacheAndRetries() async throws {
        let context = try DimensionTestContext()
        defer { context.cleanUp() }
        let model = context.model()
        try await wait(model)
        let originalNews = model.news
        await context.transport.change(score: 140, failVisual: true, failNews: true)
        context.date.addTimeInterval(301)
        model.refreshNow()
        try await wait(model)
        #expect(model.snapshot.state == .stale)
        #expect(model.snapshot.models.first?.score == 142.5)
        #expect(model.news == originalNews)
        #expect(model.newsMessage != nil)
        #expect(model.nextRefreshAt == context.date.addingTimeInterval(300))
        model.selectDimension(.software)
        #expect(model.snapshot.state == .ready)
        #expect(model.snapshot.models.first?.score == 140)
        model.selectDimension(.visual)
        #expect(model.snapshot.state == .stale)
        #expect(model.snapshot.models.first?.score == 150)
        await context.transport.change(score: 140, failVisual: false, failNews: false)
        context.date.addTimeInterval(300)
        model.refreshIfNeeded()
        try await wait(model)
        #expect(model.snapshot.state == .ready)
        #expect(model.newsMessage == nil)
        #expect(model.news?.fetchedAt == context.date)
    }

    @Test func codexRadarTokenOnlyGoesToOptionalAuthorizedFeed() async throws {
        let context = try DimensionTestContext()
        defer { context.cleanUp() }
        context.settings.codexRadarAPIToken = "test-radar-token"
        let model = context.model()
        try await wait(model)
        let requests = await context.transport.requests
        #expect(requests.count == 4)
        let authorized = try #require(requests.first { $0.url?.path == CodexRadarClient.authorizedURL.path })
        #expect(authorized.value(forHTTPHeaderField: "Authorization") == "Bearer test-radar-token")
        #expect(requests.filter { $0.url?.path != authorized.url?.path }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(model.snapshot.models.first?.score == 112.5)
        #expect(model.snapshot.quotaRows.first?.tier == "Plus")
    }

    private func wait(_ model: CodexRadarViewModel) async throws {
        for _ in 0..<300 {
            if !model.isRefreshing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Dimension refresh did not finish")
    }
}

private actor DimensionTestTransport {
    var requests: [URLRequest] = []
    private var score = 100.0
    private var failVisual = false
    private var failNews = false
    func change(score: Double, failVisual: Bool, failNews: Bool) {
        self.score = score; self.failVisual = failVisual; self.failNews = failNews
    }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let data: Data
        switch request.url?.path {
        case CodexRadarClient.visualURL.path:
            if failVisual { throw URLError(.timedOut) }
            data = visualData
        case "/":
            if failNews { throw URLError(.notConnectedToInternet) }
            data = newsHTML
        case CodexRadarClient.authorizedURL.path:
            data = Data(#"{"model_iq":{"quota_radar":{"rows":[{"tier":"Plus","five_h":20}]}}}"#.utf8)
        default: data = softwareData(score: score)
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private final class DimensionTestContext {
    let suite = "radar-dimensions-\(UUID())"
    let defaults: UserDefaults
    let directory: URL
    let settings: CodexNotchSettings
    let transport = DimensionTestTransport()
    var date = ISO8601DateFormatter().date(from: "2026-09-08T01:30:00Z")!
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults.set(true, forKey: "codexRadarEnabled")
        settings = CodexNotchSettings(defaults: defaults, initialManagementKey: "", initialNewAPIKey: "", initialSubAPIKey: "",
            secretStores: SecretStoreFactory(keychain: MemorySecretStore(), database: MemorySecretStore()),
            launchAtLoginManager: DimensionLaunchManager(), loadSecretsSynchronously: true)
    }
    func model() -> CodexRadarViewModel {
        let transport = transport
        return CodexRadarViewModel(settings: settings, client: CodexRadarClient { try await transport.send($0) },
                                    cacheDirectory: directory, selectionDefaults: defaults, now: { self.date })
    }
    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct DimensionLaunchManager: LaunchAtLoginManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws {}
}
