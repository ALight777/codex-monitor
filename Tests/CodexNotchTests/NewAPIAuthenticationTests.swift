import Foundation
import Testing
@testable import CodexNotch

private actor NewAPIRequestLog {
    var paths: [String] = []
    func append(_ path: String) { paths.append(path) }
}

@Test func newAPIPollingNeverLogsInOrKeepsCookies() async throws {
    let log = NewAPIRequestLog()
    let configuration = BalanceAPIConfiguration(
        panelURL: "https://newapi.example.com", username: "", secret: "example-pat",
        timeout: 6, allowInsecureTLS: false, newAPIUsesAccessToken: true
    )
    for _ in 0..<3 {
        let client = BalanceAPIClient(configuration: configuration) { request, session in
            let path = try #require(request.url?.path)
            await log.append(path)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(!session.configuration.httpShouldSetCookies)
            #expect(session.configuration.httpCookieStorage == nil)
            let body: String
            if path == "/api/status" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
                body = #"{"success":true,"data":{"quota_per_unit":500000,"quota_display_type":"USD"}}"#
            } else {
                #expect(path == "/api/user/self")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer example-pat")
                #expect(request.value(forHTTPHeaderField: "New-Api-User") == nil)
                body = #"{"success":true,"data":{"id":42,"username":"owner","quota":1000000,"used_quota":0,"request_count":4}}"#
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let snapshot = try await client.fetchSnapshot(source: .newAPI)
        #expect(snapshot.accounts.count == 1)
        #expect(snapshot.accounts.first?.amountText == "$2.00")
    }
    #expect(await log.paths == Array(repeating: ["/api/status", "/api/user/self"], count: 3).flatMap { $0 })
}

@Test func oldNewAPIPasswordIsBlockedBeforeAnyNetworkRequest() async throws {
    let client = BalanceAPIClient(configuration: .init(
        panelURL: "https://newapi.example.com", username: "owner", secret: "old-password",
        timeout: 6, allowInsecureTLS: false
    )) { _, _ in
        Issue.record("Legacy password must never be sent")
        throw URLError(.cancelled)
    }
    do {
        _ = try await client.fetchSnapshot(source: .newAPI)
        Issue.record("Expected migration notice")
    } catch { #expect(error.localizedDescription.contains("PAT")) }
}

@Test func rejectedPATNeverFallsBackToPasswordLogin() async throws {
    let log = NewAPIRequestLog()
    let client = BalanceAPIClient(configuration: .init(
        panelURL: "https://newapi.example.com", username: "owner", secret: "expired-pat",
        timeout: 6, allowInsecureTLS: false, newAPIUsesAccessToken: true
    )) { request, _ in
        await log.append(request.url!.path)
        let isStatus = request.url!.path == "/api/status"
        let body = isStatus ? #"{"success":true,"data":{}}"# : #"{"success":false,"message":"expired"}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: isStatus ? 200 : 401, httpVersion: nil, headerFields: nil)!)
    }
    await #expect(throws: (any Error).self) { _ = try await client.fetchSnapshot(source: .newAPI) }
    #expect(await log.paths == ["/api/status", "/api/user/self"])
}

@Test func newAPILegacyMetadataCannotReinterpretPasswordAsPAT() throws {
    let old = BalanceAccountConfiguration(source: .newAPI, panelURL: "https://example.com", username: "owner", secret: "private-password")
    let encoded = try JSONEncoder().encode(old)
    let decoded = try JSONDecoder().decode(BalanceAccountConfiguration.self, from: encoded)
    #expect(decoded.newAPIUsesAccessToken != true)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("private-password"))
    var pat = old
    pat.newAPIUsesAccessToken = true
    #expect(pat.credentialBindingID != old.credentialBindingID)
    pat.newAPIUserID = "42"
    #expect(try JSONDecoder().decode(BalanceAccountConfiguration.self, from: JSONEncoder().encode(pat)).newAPIUserID == "42")
}

@Test func newAPIPATSupportsOptionalLegacyIDAndRejectsModelKeys() throws {
    let headers = try BalanceAPIClient.newAPIAccessTokenHeaders(token: "Bearer example-pat", userID: "42")
    #expect(headers["New-Api-User"] == "42")
    #expect(headers["Authorization"] == "Bearer example-pat")
    #expect(throws: (any Error).self) { try BalanceAPIClient.newAPIAccessTokenHeaders(token: "sk-model-key", userID: "") }
    #expect(throws: (any Error).self) { try BalanceAPIClient.newAPIAccessTokenHeaders(token: "example-pat", userID: "owner") }
}
