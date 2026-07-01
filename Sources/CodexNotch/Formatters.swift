import Foundation

enum Formatters {
    static func compactTokens(_ value: Int) -> String {
        let absolute = abs(value)
        if absolute >= 100_000_000 {
            return String(format: "%.1f亿", Double(value) / 100_000_000)
        }
        if absolute >= 10_000 {
            return String(format: "%.0f万", Double(value) / 10_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1f千", Double(value) / 1_000)
        }
        return "\(value)"
    }

    static func compactTokensEnglish(_ value: Int) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    static func percent(_ value: Int?) -> String {
        guard let value else {
            return "--"
        }
        return "\(value)%"
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "--"
        }
        return String(format: "%.1f%%", value)
    }

    static func quotaResetText(
        _ resetAt: Int?,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String? {
        guard let resetAt, resetAt > Int(now.timeIntervalSince1970) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(resetAt)))) 恢复"
    }

    static func signedCompactTokens(_ value: Int?) -> String {
        guard let value else {
            return "--"
        }
        guard value > 0 else {
            return "0"
        }
        return "+\(compactTokens(value))"
    }

    static func signedCompactTokensEnglish(_ value: Int?) -> String {
        guard let value else {
            return "--"
        }
        guard value > 0 else {
            return "0"
        }
        return "+\(compactTokensEnglish(value))"
    }

    static func compactTokenRatio(_ numerator: Int?, _ denominator: Int?) -> String {
        guard let numerator, let denominator, denominator > 0 else {
            return "--"
        }
        return "\(compactTokens(numerator))/\(compactTokens(denominator))"
    }

    static func shortTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "未命名任务"
        }
        if trimmed.count <= 22 {
            return trimmed
        }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 22)
        return String(trimmed[..<end]) + "..."
    }

    static func relativeAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)秒"
        }
        if seconds < 3600 {
            return "\(seconds / 60)分钟"
        }
        if seconds < 86400 {
            return "\(seconds / 3600)小时"
        }
        return "\(seconds / 86400)天"
    }
}
