import CoreGraphics

enum IslandMetrics {
    static let shoulderWidth: CGFloat = 148
    static let notchWidth: CGFloat = 224
    static let collapsedHeight: CGFloat = 38
    static let collapsedPillHorizontalPadding: CGFloat = 12
    static let detailHeaderHeight: CGFloat = 22
    static let detailPageSwitcherHeight: CGFloat = 30
    static let detailTopPadding: CGFloat = 44
    static let detailBottomPadding: CGFloat = 18
    static let detailOverlap: CGFloat = 18
    static let minimumDetailHeight: CGFloat = 390
    static let visibleTaskRows = 5

    static var detailHeight: CGFloat {
        detailHeight(taskRows: 2, showsPeriodUsage: true, showsSparkQuota: false)
    }

    static var width: CGFloat {
        shoulderWidth * 2 + notchWidth
    }

    static func detailHeight(taskRows: Int, showsPeriodUsage: Bool, showsSparkQuota: Bool = false) -> CGFloat {
        let rows = max(1, min(visibleTaskRows, taskRows))
        let sparkHeight: CGFloat = showsSparkQuota ? 8 + 32 : 0
        let localTelemetryHeight: CGFloat = 48 + sparkHeight + 52 + 26
        let taskStackHeight = CGFloat(rows) * 34
        let periodHeight: CGFloat = showsPeriodUsage ? 8 + 44 : 0
        let contentHeight = detailTopPadding
            + detailHeaderHeight
            + 10
            + detailPageSwitcherHeight
            + 10
            + localTelemetryHeight
            + 8
            + taskStackHeight
            + periodHeight
            + detailBottomPadding
        return max(minimumDetailHeight, ceil(contentHeight))
    }

    static func remoteDetailHeight(accountRows: Int, usesTallRows: Bool = false) -> CGFloat {
        let rows = max(1, min(4, accountRows))
        let rowHeight: CGFloat = usesTallRows ? 74 : 62
        let accountStackHeight = CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * 7
        let cpaUsageHeight: CGFloat = 47
        let contentHeight = detailTopPadding
            + detailHeaderHeight
            + 10
            + detailPageSwitcherHeight
            + 10
            + 36
            + 8
            + accountStackHeight
            + 8
            + cpaUsageHeight
            + detailBottomPadding
        return max(minimumDetailHeight, ceil(contentHeight))
    }
}
