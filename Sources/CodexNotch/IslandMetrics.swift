import CoreGraphics

struct IslandLayout: Equatable {
    let shoulderWidth: CGFloat
    let notchWidth: CGFloat
    let collapsedHeight: CGFloat

    var width: CGFloat {
        shoulderWidth * 2 + notchWidth
    }
}

enum IslandMetrics {
    static let shoulderWidth: CGFloat = 72
    static let notchWidth: CGFloat = 224
    static let minimumNotchWidth: CGFloat = 160
    static let maximumNotchWidth: CGFloat = 320
    static let notchAdjustmentLimit: CGFloat = 40
    static let collapsedHeight: CGFloat = 38
    static let detailHeaderHeight: CGFloat = 22
    static let detailPageSwitcherHeight: CGFloat = 30
    static let detailTopPadding: CGFloat = 44
    static let detailBottomPadding: CGFloat = 18
    static let detailOverlap: CGFloat = 18
    static let quotaResetTopMargin: CGFloat = 7
    static let quotaResetTextHeight: CGFloat = 10
    static let quotaResetHeaderGap: CGFloat = 9
    static let minimumDetailHeight: CGFloat = 250
    static let visibleTaskRows = 4

    static var detailHeight: CGFloat {
        detailHeight(taskRows: 2, showsPeriodUsage: true)
    }

    static var width: CGFloat {
        shoulderWidth * 2 + notchWidth
    }

    static func detailObscuredTopHeight(
        safeAreaTop: CGFloat,
        collapsedHeight: CGFloat = collapsedHeight
    ) -> CGFloat {
        let detailTopDistanceFromScreenTop = collapsedHeight - detailOverlap
        return max(detailOverlap, safeAreaTop - detailTopDistanceFromScreenTop, 0)
    }

    static func quotaResetTopPadding(
        safeAreaTop: CGFloat,
        collapsedHeight: CGFloat = collapsedHeight
    ) -> CGFloat {
        detailObscuredTopHeight(safeAreaTop: safeAreaTop, collapsedHeight: collapsedHeight) + quotaResetTopMargin
    }

    static func detailContentTopPadding(
        safeAreaTop: CGFloat,
        collapsedHeight: CGFloat = collapsedHeight
    ) -> CGFloat {
        max(
            detailTopPadding,
            quotaResetTopPadding(safeAreaTop: safeAreaTop, collapsedHeight: collapsedHeight) + quotaResetTextHeight + quotaResetHeaderGap
        )
    }

    static func detailHeight(
        taskRows: Int,
        showsPeriodUsage: Bool,
        topPadding: CGFloat = detailTopPadding
    ) -> CGFloat {
        let rows = max(1, min(visibleTaskRows, taskRows))
        let taskStackHeight = CGFloat(rows) * 48 + CGFloat(max(0, rows - 1)) * 7
        let periodHeight: CGFloat = showsPeriodUsage ? 10 + 47 : 0
        let contentHeight = topPadding
            + detailHeaderHeight
            + 10
            + detailPageSwitcherHeight
            + 10
            + taskStackHeight
            + periodHeight
            + detailBottomPadding
        return max(minimumDetailHeight, ceil(contentHeight))
    }

    static func combinedDetailHeight(
        accountRows: Int?,
        showsPeriodUsage: Bool,
        usesTallRemoteRows: Bool = false,
        topPadding: CGFloat = detailTopPadding
    ) -> CGFloat {
        let localHeight = detailHeight(
            taskRows: visibleTaskRows,
            showsPeriodUsage: showsPeriodUsage,
            topPadding: topPadding
        )
        guard let accountRows else {
            return localHeight
        }
        return max(
            localHeight,
            remoteDetailHeight(
                accountRows: accountRows,
                usesTallRows: usesTallRemoteRows,
                topPadding: topPadding
            )
        )
    }

    static func remoteDetailHeight(
        accountRows: Int,
        usesTallRows: Bool = false,
        topPadding: CGFloat = detailTopPadding
    ) -> CGFloat {
        let rows = max(1, min(4, accountRows))
        let rowHeight: CGFloat = usesTallRows ? 74 : 62
        let accountStackHeight = CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * 7
        let cpaUsageHeight: CGFloat = 47
        let contentHeight = topPadding
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
