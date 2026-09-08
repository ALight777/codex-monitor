import Foundation

struct CodexRadarNewsItem: Codable, Equatable, Sendable, Identifiable {
    var id: String { url.absoluteString + title }
    let title: String
    let summary: String?
    let url: URL
}

struct CodexRadarNewsSnapshot: Codable, Equatable, Sendable {
    let items: [CodexRadarNewsItem]
    let fetchedAt: Date
}

enum CodexRadarNewsParser {
    // The current homepage publishes its latest news in a server-rendered announcement.
    // Extract only that section; never execute HTML or load embedded resources.
    static func decode(_ data: Data, fetchedAt: Date) throws -> CodexRadarNewsSnapshot {
        guard let html = String(data: data, encoding: .utf8),
              html.contains("data-radar-station") || html.contains("site-announcement") else {
            throw CodexRadarClientError.invalidResponse
        }
        guard let section = element(className: "site-announcement", in: html),
              let heading = element(className: "site-announcement-headline", in: section),
              !plainText(heading).isEmpty else {
            return CodexRadarNewsSnapshot(items: [], fetchedAt: fetchedAt)
        }
        let lead = element(className: "site-announcement-lead", in: section).map(plainText)
        let detail = element(className: "site-announcement-reset-detail", in: section).map(plainText)
        let summary = [lead, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let link = firstMatch(#"(?is)<a\b[^>]*class\s*=\s*["'][^"']*\bsite-announcement-(?:source|source-link)\b[^"']*["'][^>]*>"#, in: section)
        let href = link.flatMap { firstMatch(#"(?is)\bhref\s*=\s*["']([^"']+)["']"#, in: $0, group: 1) }
        let url = href.flatMap { safeURL(decodeEntities($0)) } ?? CodexRadarSnapshot.siteURL
        return CodexRadarNewsSnapshot(items: [CodexRadarNewsItem(
            title: plainText(heading), summary: summary.isEmpty ? nil : summary, url: url
        )], fetchedAt: fetchedAt)
    }

    static func safeURL(_ value: String) -> URL? {
        guard let url = URL(string: value, relativeTo: CodexRadarSnapshot.siteURL)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }

    private static func element(className: String, in html: String) -> String? {
        let name = NSRegularExpression.escapedPattern(for: className)
        let pattern = "(?is)<([a-z][a-z0-9]*)\\b[^>]*\\bclass\\s*=\\s*[\"'][^\"']*(?<![\\w-])\(name)(?![\\w-])[^\"']*[\"'][^>]*>(.*?)</\\1\\s*>"
        return firstMatch(pattern, in: html, group: 2)
    }

    private static func firstMatch(_ pattern: String, in value: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: group), in: value) else { return nil }
        return String(value[range])
    }

    private static func plainText(_ html: String) -> String {
        let text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeEntities(text).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–"]
        let regex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-z]+);"#)
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let bodyRange = Range(match.range(at: 1), in: text), let wholeRange = Range(match.range, in: result) else { continue }
            let body = String(text[bodyRange])
            var replacement = named[body]
            if body.hasPrefix("#") {
                let hex = body.hasPrefix("#x")
                let number = UInt32(body.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10)
                replacement = number.flatMap(UnicodeScalar.init).map(String.init)
            }
            if let replacement { result.replaceSubrange(wholeRange, with: replacement) }
        }
        return result
    }
}
