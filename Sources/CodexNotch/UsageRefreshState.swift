import Foundation

enum UsageRefreshCompletion: Equatable {
    case schedulePending(scheduleNext: Bool)
    case finished(scheduleNext: Bool)
}

struct UsageRefreshQueue {
    private(set) var isActive = false
    private(set) var hasPendingRequest = false
    private var activeScheduleNext = false
    private var pendingScheduleNext = false

    mutating func request(scheduleNext: Bool) -> Bool {
        guard !isActive else {
            hasPendingRequest = true
            pendingScheduleNext = pendingScheduleNext || scheduleNext
            return false
        }

        isActive = true
        activeScheduleNext = scheduleNext
        return true
    }

    mutating func complete() -> UsageRefreshCompletion {
        precondition(isActive, "Cannot complete an inactive usage refresh")

        isActive = false
        let shouldScheduleNext = activeScheduleNext || pendingScheduleNext
        activeScheduleNext = false
        pendingScheduleNext = false

        guard hasPendingRequest else {
            return .finished(scheduleNext: shouldScheduleNext)
        }

        hasPendingRequest = false
        return .schedulePending(scheduleNext: shouldScheduleNext)
    }

    mutating func cancelPending() {
        hasPendingRequest = false
        pendingScheduleNext = false
    }
}

struct PeriodUsageLoadState {
    private(set) var hasSuccessfulValue = false
    private(set) var consecutiveFailures = 0
    private(set) var lastSuccessfulAt: Date?

    @discardableResult
    mutating func record(_ usage: PeriodUsage?, completedAt: Date) -> Bool {
        guard usage != nil else {
            consecutiveFailures += 1
            return false
        }

        hasSuccessfulValue = true
        consecutiveFailures = 0
        lastSuccessfulAt = completedAt
        return true
    }
}

enum TaskCompletionDetector {
    static func completedRunningTaskIDs(
        previous: [CodexTask],
        current: [CodexTask]
    ) -> Set<String> {
        let previousRunning = Set(
            previous.lazy
                .filter { $0.status == .running }
                .map(\.id)
        )
        let currentRunning = Set(
            current.lazy
                .filter { $0.status == .running }
                .map(\.id)
        )
        return previousRunning.subtracting(currentRunning)
    }
}

enum SystemActivityRefreshCadence {
    static let debounceDelay: TimeInterval = 1
}

enum FileChangeRefreshCadence {
    static let quietDelay: TimeInterval = 1

    static func fireDate(
        now: Date,
        burstStartedAt: Date,
        maximumDelay: TimeInterval
    ) -> Date {
        let boundedMaximumDelay = max(quietDelay, maximumDelay)
        return min(
            now.addingTimeInterval(quietDelay),
            burstStartedAt.addingTimeInterval(boundedMaximumDelay)
        )
    }
}

enum PeriodUsageDisplay {
    static func text(tokens: Int, hasLoaded: Bool) -> String {
        hasLoaded ? Formatters.compactTokens(tokens) : "--"
    }
}
