import Foundation

struct RateLimitResetCredit: Equatable, Identifiable, Sendable {
    let id: String
    let expiresAt: Date
}

struct RateLimitResetCredits: Equatable, Sendable {
    let availableCount: Int
    let credits: [RateLimitResetCredit]
    let fetchedAt: Date

    var hasExpiryDetails: Bool {
        !credits.isEmpty
    }
}

enum RateLimitResetCreditsDecoder {
    static func decode(_ data: Data, now: Date = Date()) throws -> RateLimitResetCredits? {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Reset-credit response must be a JSON object"
                )
            )
        }

        let countValue = object["availableCount"] ?? object["available_count"]
        let hasCreditsField = object.keys.contains("credits")
        guard countValue != nil || hasCreditsField else {
            return nil
        }

        let rawCredits = object["credits"] as? [[String: Any]] ?? []
        let credits = rawCredits.enumerated().compactMap { index, rawCredit in
            decodeCredit(rawCredit, index: index, now: now)
        }
        .sorted {
            if $0.expiresAt == $1.expiresAt {
                return $0.id < $1.id
            }
            return $0.expiresAt < $1.expiresAt
        }

        let serviceCount = integer(from: countValue)
        return RateLimitResetCredits(
            availableCount: max(0, serviceCount ?? credits.count),
            credits: credits,
            fetchedAt: now
        )
    }

    private static func decodeCredit(
        _ object: [String: Any],
        index: Int,
        now: Date
    ) -> RateLimitResetCredit? {
        let resetType = string(from: object["resetType"] ?? object["reset_type"])
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
        guard resetType == "codexratelimits" else {
            return nil
        }

        guard string(from: object["status"]).lowercased() == "available" else {
            return nil
        }

        guard let expiresAt = date(from: object["expiresAt"] ?? object["expires_at"]),
              expiresAt > now else {
            return nil
        }

        let id = string(from: object["id"])
        let resolvedID = id.isEmpty
            ? "reset-credit-\(index)-\(Int64(expiresAt.timeIntervalSince1970 * 1_000))"
            : id
        return RateLimitResetCredit(id: resolvedID, expiresAt: expiresAt)
    }

    private static func integer(from value: Any?) -> Int? {
        if value is Bool {
            return nil
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func string(from value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func date(from value: Any?) -> Date? {
        if value is Bool {
            return nil
        }
        if let number = value as? NSNumber {
            return date(fromUnixValue: number.doubleValue)
        }
        guard let text = value as? String else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let timestamp = Double(trimmed) {
            return date(fromUnixValue: timestamp)
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: trimmed) {
            return date
        }

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        return plainFormatter.date(from: trimmed)
    }

    private static func date(fromUnixValue value: Double) -> Date? {
        guard value.isFinite else {
            return nil
        }
        let seconds = abs(value) >= 100_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}

enum RateLimitResetCreditsFormatter {
    static func expiryText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }
}
