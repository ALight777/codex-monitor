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

    static func estimatedCostUSD(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else {
            return "≈--"
        }
        if value == 0 {
            return "≈$0.00"
        }
        if value < 0.01 {
            return String(format: "≈$%.4f", value)
        }
        if value < 100 {
            return String(format: "≈$%.2f", value)
        }
        return String(format: "≈$%.0f", value)
    }

    static func percent(_ value: Int?) -> String {
        guard let value else {
            return "--"
        }
        return "\(value)%"
    }

    static func quotaResetTime(_ date: Date?, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        guard let date else {
            return "--"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
                  calendar.isDate(date, inSameDayAs: tomorrow) {
            formatter.dateFormat = "'明天' HH:mm"
        } else {
            formatter.dateFormat = "M月d日"
        }
        return formatter.string(from: date)
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
