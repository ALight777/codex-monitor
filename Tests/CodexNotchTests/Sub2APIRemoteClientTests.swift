import Foundation
import Testing
@testable import CodexNotch

@Test
func sub2APIQuotaMapsToRemoteCodexAccount() throws {
    let accountData = Data(
        """
        {
          "id": 42,
          "name": "codex-team",
          "platform": "openai",
          "type": "oauth",
          "status": "active",
          "schedulable": true,
          "error_message": "",
          "extra": {
            "email": "codex@example.com",
            "plan_type": "plus"
          }
        }
        """.utf8
    )
    let quotaData = Data(
        """
        {
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": null,
            "secondary_window": {
              "used_percent": 13,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 3600,
              "reset_at": 1785376800
            }
          },
          "rate_limit_reset_credits": {
            "available_count": 2,
            "credits": [
              {"expires_at": "2026-08-01T03:12:00Z"},
              {"expires_at": "2026-08-13T01:59:00Z"}
            ]
          },
          "fetched_at": 1785373200
        }
        """.utf8
    )

    let account = try JSONDecoder().decode(Sub2APIAdminAccount.self, from: accountData)
    let quota = try JSONDecoder().decode(Sub2APIOpenAIQuotaUsage.self, from: quotaData)
    let now = Date(timeIntervalSince1970: 1_785_000_000)
    let remote = Sub2APIRemoteClient.remoteAccount(
        from: account,
        quota: quota,
        quotaError: nil,
        now: now
    )

    #expect(remote.displayName == "codex@example.com")
    #expect(remote.planLabel == "Plus")
    #expect(remote.displayQuotaWindows.count == 1)
    #expect(remote.displayQuotaWindows.first?.shortLabel == "7d")
    #expect(remote.displayQuotaWindows.first?.remainingPercent == 87)
    #expect(remote.resetCredits?.availableCount == 2)
    #expect(remote.resetCredits?.credits.count == 2)
    #expect(remote.state == .healthy)
    #expect(remote.successCount == nil)
    #expect(remote.failureCount == nil)
    #expect(!remote.detailText.contains("成功"))
    #expect(!remote.detailText.contains("失败"))
}

@Test
func remoteSourceMetadataNeverEncodesSecret() throws {
    let source = RemoteAccountSourceConfiguration(
        id: "source-1",
        source: .sub2API,
        label: "主 Sub2API",
        panelURL: "https://sub2.example.com",
        username: "admin@example.com",
        secret: "do-not-persist",
        requestTimeout: 10
    )

    let data = try JSONEncoder().encode(source)
    let text = String(decoding: data, as: UTF8.self)
    let decoded = try JSONDecoder().decode(RemoteAccountSourceConfiguration.self, from: data)

    #expect(!text.contains("do-not-persist"))
    #expect(decoded.secret.isEmpty)
    #expect(decoded.source == .sub2API)
    #expect(decoded.username == "admin@example.com")
}

@Test
func remoteSourceScopingPreventsCrossPanelAccountCollisions() {
    let account = RemoteCodexAccount(
        id: "same-account",
        name: "Codex",
        email: "same@example.com",
        label: nil,
        provider: nil,
        accountType: "oauth",
        authIndex: nil,
        chatgptAccountID: nil,
        status: "active",
        statusMessage: nil,
        successCount: 0,
        failureCount: 0,
        recentFailures: 0,
        state: .healthy,
        lastRefresh: nil,
        planType: "plus",
        quotaWindows: [],
        quotaError: nil
    )
    let first = RemoteAccountSourceConfiguration(id: "first", source: .sub2API, label: "A")
    let second = RemoteAccountSourceConfiguration(id: "second", source: .sub2API, label: "B")

    #expect(account.scoped(to: first).id != account.scoped(to: second).id)
    #expect(account.scoped(to: first).provider == "A")
    #expect(account.scoped(to: second).provider == "B")
}

@Test
func remoteSourceScopingPreventsCrossPanelQuotaReuse() {
    func account(id: String, remaining: Int?) -> RemoteCodexAccount {
        RemoteCodexAccount(
            id: id,
            name: "Codex",
            email: "same@example.com",
            label: nil,
            provider: nil,
            accountType: "oauth",
            authIndex: "shared-index",
            chatgptAccountID: nil,
            status: "active",
            statusMessage: nil,
            successCount: nil,
            failureCount: nil,
            recentFailures: 0,
            state: .healthy,
            lastRefresh: nil,
            planType: "plus",
            quotaWindows: remaining.map {
                [
                    RemoteQuotaWindow(
                        id: "weekly",
                        shortLabel: "7d",
                        remainingPercent: $0,
                        usedPercent: Double(100 - $0),
                        resetText: nil
                    )
                ]
            } ?? [],
            quotaError: nil
        )
    }

    let first = RemoteAccountSourceConfiguration(id: "first", source: .sub2API, label: "A")
    let second = RemoteAccountSourceConfiguration(id: "second", source: .sub2API, label: "B")
    let previous = [
        account(id: "same-account", remaining: 80).scoped(to: first),
        account(id: "same-account", remaining: 25).scoped(to: second)
    ]
    let current = [
        account(id: "same-account", remaining: nil).scoped(to: first),
        account(id: "same-account", remaining: nil).scoped(to: second)
    ]

    let merged = RemoteCodexAccount.preservingQuota(in: current, from: previous)
    #expect(merged[0].displayQuotaWindows.first?.remainingPercent == 80)
    #expect(merged[1].displayQuotaWindows.first?.remainingPercent == 25)
}

@Test
func duplicatePanelUsageIsCountedOnce() {
    let result = RemoteUsageAggregator.aggregate([
        RemoteUsageContribution(
            sourceID: "first",
            scopeID: "sub2API|https://panel.example.com",
            usage: PeriodUsage(day: 10, week: 20, month: 30)
        ),
        RemoteUsageContribution(
            sourceID: "duplicate",
            scopeID: "sub2API|https://panel.example.com",
            usage: PeriodUsage(day: 10, week: 20, month: 30)
        ),
        RemoteUsageContribution(
            sourceID: "other",
            scopeID: "cpaManagerPlus|https://other.example.com",
            usage: PeriodUsage(day: 1, week: 2, month: 3)
        )
    ])

    #expect(result.usage == PeriodUsage(day: 11, week: 22, month: 33))
    #expect(result.duplicateSourceIDs == ["duplicate"])
}

@Test
func sub2APIRemoteRefreshGetsBatchAwareTimeoutBudget() {
    #expect(RemoteRefreshTimeoutPolicy.budget(for: .sub2API, requestTimeout: 6) == 75)
    #expect(RemoteRefreshTimeoutPolicy.budget(for: .sub2API, requestTimeout: 30) == 180)
    #expect(RemoteRefreshTimeoutPolicy.budget(for: .cpaManagerPlus, requestTimeout: 6) == 24)
}

@Test
func sub2APIUsageTrendAggregatesRollingWindows() throws {
    let timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 7,
        day: 30,
        hour: 12,
        minute: 30
    )))
    let points = [
        Sub2APIUsageTrendPoint(date: "2026-07-30 12:00", totalTokens: 100),
        Sub2APIUsageTrendPoint(date: "2026-07-29 12:00", totalTokens: 200),
        Sub2APIUsageTrendPoint(date: "2026-07-23 12:00", totalTokens: 300),
        Sub2APIUsageTrendPoint(date: "2026-06-30 12:00", totalTokens: 400),
        Sub2APIUsageTrendPoint(date: "2026-06-30 11:00", totalTokens: 500)
    ]

    let usage = Sub2APIRemoteClient.periodUsage(
        from: points,
        now: now,
        timeZone: timeZone
    )

    #expect(usage.day == 100)
    #expect(usage.week == 300)
    #expect(usage.month == 600)
}

@Test
func normalizedUsageScopeDeduplicatesEquivalentPanelURLs() {
    let root = RemoteAccountSourceConfiguration(
        id: "root",
        source: .cpaManagerPlus,
        panelURL: "https://panel.example.com",
        secret: "secret"
    )
    let managementPage = RemoteAccountSourceConfiguration(
        id: "page",
        source: .cpaManagerPlus,
        panelURL: "https://PANEL.example.com:443/management.html",
        secret: "secret"
    )
    let sub2Root = RemoteAccountSourceConfiguration(
        id: "sub2-root",
        source: .sub2API,
        panelURL: "https://sub2.example.com",
        username: "admin@example.com",
        secret: "password"
    )
    let sub2APIPath = RemoteAccountSourceConfiguration(
        id: "sub2-api",
        source: .sub2API,
        panelURL: "https://sub2.example.com/api/v1/admin",
        username: "admin@example.com",
        secret: "password"
    )

    #expect(root.usageScopeID == managementPage.usageScopeID)
    #expect(sub2Root.usageScopeID == sub2APIPath.usageScopeID)
}

@Test
func usageAggregationSaturatesInsteadOfOverflowing() {
    let result = RemoteUsageAggregator.aggregate([
        RemoteUsageContribution(
            sourceID: "first",
            scopeID: "first",
            usage: PeriodUsage(day: Int.max, week: Int.max, month: Int.max)
        ),
        RemoteUsageContribution(
            sourceID: "second",
            scopeID: "second",
            usage: PeriodUsage(day: 1, week: 1, month: 1)
        )
    ])

    #expect(result.usage == PeriodUsage(day: Int.max, week: Int.max, month: Int.max))
}

@Test
func failedRemoteSourceKeepsItsPreviousAccounts() {
    let firstSource = RemoteAccountSourceConfiguration(id: "first", source: .sub2API, label: "A")
    let secondSource = RemoteAccountSourceConfiguration(id: "second", source: .sub2API, label: "B")
    let firstAccount = testRemoteAccount(id: "1").scoped(to: firstSource)
    let secondAccount = testRemoteAccount(id: "2").scoped(to: secondSource)

    let merged = RemoteAccountSnapshotMerger.merge(
        current: [secondAccount],
        previous: [firstAccount, secondAccount],
        failedSourceIDs: ["first"]
    )

    #expect(Set(merged.map(\.id)) == Set([firstAccount.id, secondAccount.id]))
}

@Test
func multiSourceAggregationKeepsSuccessfulSourcesWhenOneFails() {
    let cpaSource = RemoteAccountSourceConfiguration(
        id: "cpa",
        source: .cpaManagerPlus,
        label: "CPA",
        panelURL: "https://cpa.example.com",
        secret: "secret"
    )
    let sub2Source = RemoteAccountSourceConfiguration(
        id: "sub2",
        source: .sub2API,
        label: "Sub2",
        panelURL: "https://sub2.example.com",
        username: "admin@example.com",
        secret: "secret"
    )
    let cliSource = RemoteAccountSourceConfiguration(
        id: "cli",
        source: .cliProxyAPI,
        label: "CLI",
        panelURL: "https://cli.example.com",
        secret: "secret"
    )
    let cpaAccount = testRemoteAccount(id: "cpa-account").scoped(to: cpaSource)
    let cliAccount = testRemoteAccount(id: "cli-account").scoped(to: cliSource)

    let result = RemoteMultiSourceOutcomeAggregator.aggregate([
        RemoteSourceFetchOutcome(
            source: cpaSource,
            success: RemoteSourceFetchSuccess(
                accounts: [cpaAccount],
                usage: PeriodUsage(day: 10, week: 20, month: 30),
                supportsUsage: true,
                usageError: nil
            ),
            failureMessage: nil
        ),
        .configurationFailure(source: sub2Source, message: "认证信息不完整"),
        RemoteSourceFetchOutcome(
            source: cliSource,
            success: RemoteSourceFetchSuccess(
                accounts: [cliAccount],
                usage: nil,
                supportsUsage: false,
                usageError: nil
            ),
            failureMessage: nil
        )
    ])

    #expect(Set(result.accounts.map(\.id)) == Set([cpaAccount.id, cliAccount.id]))
    #expect(result.failedSourceIDs == ["sub2"])
    #expect(result.hasSourceFailures)
    #expect(result.panelMessage?.contains("认证信息不完整") == true)
    #expect(result.usageSources.first(where: { $0.id == "cpa" })?.state == .included)
    #expect(result.usageSources.first(where: { $0.id == "sub2" })?.state == .failed)
    #expect(result.usageSources.first(where: { $0.id == "cli" })?.state == .unavailable)
    switch result.usageResult {
    case .success:
        Issue.record("部分用量源失败时不应覆盖上一次完整统计")
    case .failure:
        break
    }
}

@Test
func incompleteRemoteSourceReportsConfigurationIssue() {
    let source = RemoteAccountSourceConfiguration(
        id: "sub2",
        source: .sub2API,
        enabled: true,
        label: "Sub2",
        panelURL: "https://sub2.example.com",
        username: "",
        secret: "",
        requestTimeout: 6
    )

    #expect(source.configurationIssue == "缺少管理员密码")
}

@Test
func sub2APIRemoteClientPaginatesAndFiltersUsageByAccount() async throws {
    let timeZone = TimeZone.current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 7,
        day: 30,
        hour: 12,
        minute: 30
    )))
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let bucket = formatter.string(from: calendar.dateInterval(of: .hour, for: now)?.start ?? now)

    let responder = TestHTTPResponder { request in
        let url = try #require(request.url)
        let path = url.path
        if path.hasSuffix("/api/v1/auth/login") {
            return jsonData(
                #"{"code":0,"message":"success","data":{"access_token":"token","requires_2fa":false}}"#
            )
        }
        if path.hasSuffix("/api/v1/admin/accounts") {
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "page" })?
                .value
            if page == "1" {
                return jsonData(
                    """
                    {"code":0,"message":"success","data":{"items":[
                      {"id":1,"name":"first","platform":"openai","type":"oauth","status":"active","schedulable":true,"extra":{"email":"first@example.com","plan_type":"plus"}}
                    ],"page":1,"pages":2,"total":2}}
                    """
                )
            }
            return jsonData(
                """
                {"code":0,"message":"success","data":{"items":[
                  {"id":2,"name":"second","platform":"openai","type":"oauth","status":"active","schedulable":false,"temp_unschedulable_reason":"上游暂停","extra":{"email":"second@example.com","plan_type":"team"}}
                ],"page":2,"pages":2,"total":2}}
                """
            )
        }
        if path.hasSuffix("/quota") {
            return jsonData(
                """
                {"code":0,"message":"success","data":{
                  "plan_type":"plus",
                  "rate_limit":{"allowed":true,"limit_reached":false,"primary_window":null,"secondary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_after_seconds":3600,"reset_at":0}},
                  "rate_limit_reset_credits":{"available_count":2},
                  "fetched_at":1785373200
                }}
                """
            )
        }
        if path.hasSuffix("/api/v1/admin/dashboard/trend") {
            let accountID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "account_id" })?
                .value
            let tokens = accountID == "1" ? 100 : 200
            return jsonData(
                #"{"code":0,"message":"success","data":{"trend":[{"date":"\#(bucket)","total_tokens":\#(tokens)}]}}"#
            )
        }
        Issue.record("Unexpected Sub2API request: \(url.absoluteString)")
        return jsonData(#"{"code":1,"message":"unexpected","data":null}"#)
    }
    let client = Sub2APIRemoteClient(
        configuration: Sub2APIRemoteConfiguration(
            panelURL: "https://sub2.example.com",
            adminEmail: "admin@example.com",
            adminPassword: "password",
            timeout: 3,
            allowInsecureTLS: false
        ),
        requestExecutor: { request, session in
            try await responder.execute(request, session: session)
        }
    )

    let snapshot = try await client.fetchCodexSnapshot(now: now)
    let requests = await responder.requests()
    let accountPages = requests
        .filter { $0.url?.path.hasSuffix("/api/v1/admin/accounts") == true }
        .compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "page" })?
                .value
        }
    let trendRequests = requests.filter {
        $0.url?.path.hasSuffix("/api/v1/admin/dashboard/trend") == true
    }

    #expect(snapshot.accounts.count == 2)
    #expect(snapshot.accounts.first(where: { $0.email == "second@example.com" })?.state == .abnormal)
    #expect(snapshot.accounts.allSatisfy { $0.resetCredits?.availableCount == 2 })
    #expect(snapshot.usage == PeriodUsage(day: 300, week: 300, month: 300))
    #expect(Set(accountPages) == Set(["1", "2"]))
    #expect(trendRequests.count == 2)
    #expect(trendRequests.allSatisfy { request in
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "account_id" && $0.value != nil }) == true
    })
}

@Test
func sub2APIBalanceClientOnlyRequestsCurrentUserProfile() async throws {
    let responder = TestHTTPResponder { request in
        let path = try #require(request.url?.path)
        if path.hasSuffix("/api/v1/auth/login") {
            return jsonData(
                #"{"code":0,"message":"success","data":{"access_token":"token","user":{"id":1,"email":"user@example.com","role":"user","balance":12.5,"status":"active"}}}"#
            )
        }
        if path.hasSuffix("/api/v1/user/profile") {
            return jsonData(
                #"{"code":0,"message":"success","data":{"id":1,"email":"user@example.com","role":"user","balance":12.5,"concurrency":3,"status":"active"}}"#
            )
        }
        Issue.record("Unexpected Sub2API balance request: \(path)")
        return jsonData(#"{"code":1,"message":"unexpected","data":null}"#)
    }
    let client = BalanceAPIClient(
        configuration: BalanceAPIConfiguration(
            panelURL: "https://sub2.example.com",
            username: "user@example.com",
            secret: "password",
            timeout: 3,
            allowInsecureTLS: false
        ),
        requestExecutor: { request, session in
            try await responder.execute(request, session: session)
        }
    )

    let snapshot = try await client.fetchSnapshot(source: .subAPI)
    let requests = await responder.requests()
    let paths = requests.compactMap(\.url?.path)

    #expect(snapshot.accounts.count == 1)
    #expect(paths == ["/api/v1/auth/login", "/api/v1/user/profile"])
    #expect(!paths.contains(where: { $0.contains("platform-quotas") }))
}

private func testRemoteAccount(id: String) -> RemoteCodexAccount {
    RemoteCodexAccount(
        id: id,
        name: "Codex \(id)",
        email: "\(id)@example.com",
        label: nil,
        provider: nil,
        accountType: "oauth",
        authIndex: nil,
        chatgptAccountID: nil,
        status: "active",
        statusMessage: nil,
        successCount: nil,
        failureCount: nil,
        recentFailures: 0,
        state: .healthy,
        lastRefresh: nil,
        planType: "plus",
        quotaWindows: [],
        quotaError: nil
    )
}

private func jsonData(_ value: String) -> Data {
    Data(value.utf8)
}

private actor TestHTTPResponder {
    typealias Handler = @Sendable (URLRequest) throws -> Data

    private let handler: Handler
    private var recordedRequests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func execute(
        _ request: URLRequest,
        session: URLSession
    ) throws -> (Data, URLResponse) {
        recordedRequests.append(request)
        let data = try handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}
