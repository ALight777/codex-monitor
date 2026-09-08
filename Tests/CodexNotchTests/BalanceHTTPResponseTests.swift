import Foundation
import Testing
@testable import CodexNotch

private func readFailure(
    status: Int, body: String, headers: [String: String] = ["Content-Type": "text/html"]
) async throws -> String {
    let client = BalanceAPIClient(configuration: .init(
        panelURL: "https://newapi.example.com", username: "", secret: "example-pat",
        timeout: 6, allowInsecureTLS: false, newAPIUsesAccessToken: true
    )) { request, _ in
        #expect(request.url?.path == "/api/status")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    do {
        _ = try await client.fetchSnapshot(source: .newAPI)
        Issue.record("Expected a response failure before attempting the authenticated endpoint")
        return ""
    } catch { return error.localizedDescription }
}

@Test func newAPIRegionRestrictionShowsHTTPStatusWithoutHTMLOrTokenBlame() async throws {
    let message = try await readFailure(status: 451, body: #"<!DOCTYPE html><html lang="zh"><h1>本站点不向中国大陆地区提供服务</h1><script>private-page-data</script></html>"#)
    #expect(message.contains("站点限制访问（HTTP 451）"))
    #expect(message.contains("不向中国大陆地区提供服务"))
    #expect(message.contains("GET /api/status"))
    #expect(!message.contains("<!DOCTYPE"))
    #expect(!message.contains("private-page-data"))
    #expect(!message.contains("认证信息无效"))
}

@Test func newAPIHTMLSuccessAndGatewayErrorsAreReadable() async throws {
    for status in [200, 403, 404, 502, 503] {
        let message = try await readFailure(status: status, body: "<!DOCTYPE html><html><h1>upstream page</h1></html>")
        #expect(message.contains("HTTP \(status)"))
        #expect(message.contains("网页"))
        #expect(!message.contains("<html>"))
        #expect(!message.contains("认证信息无效"))
    }
}

@Test func newAPIHTMLIsDetectedWithAMisleadingContentType() async throws {
    let message = try await readFailure(status: 200, body: " \n<!doctype HTML><html>page</html>", headers: ["Content-Type": "application/json"])
    #expect(message.contains("接口返回网页"))
}

@Test func newAPIRedirectDoesNotExposeLocationOrTryLoggingIn() async throws {
    let message = try await readFailure(status: 302, body: "", headers: ["Location": "https://other.example.com/login?access_token=do-not-display"])
    #expect(message.contains("重定向（HTTP 302）"))
    #expect(!message.contains("do-not-display"))
}

@Test func newAPISecurityBlockIsDistinctFromRejectedPAT() async throws {
    let json = #"{"type":"https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/","status":403,"detail":"blocked","request_token":"do-not-display"}"#
    let blocked = try await readFailure(status: 403, body: json, headers: ["Content-Type": "application/json"])
    #expect(blocked.contains("Cloudflare 1010"))
    #expect(!blocked.contains("认证信息无效"))
    #expect(!blocked.contains("do-not-display"))
    let challenge = try await readFailure(status: 403, body: "<html>challenge</html>", headers: ["Content-Type": "text/html", "cf-mitigated": "challenge"])
    #expect(challenge.contains("浏览器安全验证"))
}

@Test func newAPIJSONAuthenticationErrorsKeepStatusAndRedactSecrets() async throws {
    let message = try await readFailure(status: 401, body: #"{"message":"expired; Bearer example-private-token"}"#, headers: ["Content-Type": "application/json"])
    #expect(message.contains("认证信息无效或无权限（HTTP 401）"))
    #expect(message.contains("expired"))
    #expect(message.contains("GET /api/status"))
    #expect(!message.contains("example-private-token"))
}
