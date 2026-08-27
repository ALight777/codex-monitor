import AppKit

enum ScreenNotchGeometry {
    static func inferredNotchWidth(
        leftArea: CGRect,
        rightArea: CGRect,
        fallback: CGFloat = IslandMetrics.notchWidth
    ) -> CGFloat {
        guard !leftArea.isEmpty,
              !rightArea.isEmpty,
              leftArea.maxX.isFinite,
              rightArea.minX.isFinite else {
            return fallback
        }

        let gap = (rightArea.minX - leftArea.maxX).rounded()
        guard gap >= IslandMetrics.minimumNotchWidth,
              gap <= IslandMetrics.maximumNotchWidth else {
            return fallback
        }
        return gap
    }

    static func adjustedNotchWidth(base: CGFloat, adjustment: CGFloat) -> CGFloat {
        let clampedAdjustment = min(
            IslandMetrics.notchAdjustmentLimit,
            max(-IslandMetrics.notchAdjustmentLimit, adjustment.rounded())
        )
        return min(
            IslandMetrics.maximumNotchWidth,
            max(IslandMetrics.minimumNotchWidth, (base + clampedAdjustment).rounded())
        )
    }

    static func layout(
        leftArea: CGRect,
        rightArea: CGRect,
        safeAreaTop: CGFloat,
        adjustment: CGFloat = 0,
        displaySize: NotchDisplaySize = .standard
    ) -> IslandLayout {
        let inferredWidth = inferredNotchWidth(
            leftArea: leftArea,
            rightArea: rightArea,
            fallback: IslandMetrics.notchWidth
        )
        return IslandLayout(
            shoulderWidth: IslandMetrics.shoulderWidth(for: displaySize),
            notchWidth: adjustedNotchWidth(base: inferredWidth, adjustment: adjustment),
            collapsedHeight: max(IslandMetrics.collapsedHeight, safeAreaTop.rounded())
        )
    }

    static func layout(
        for screen: NSScreen?,
        adjustment: CGFloat = 0,
        displaySize: NotchDisplaySize = .standard
    ) -> IslandLayout {
        guard let screen else {
            return layout(
                leftArea: .zero,
                rightArea: .zero,
                safeAreaTop: 0,
                adjustment: adjustment,
                displaySize: displaySize
            )
        }
        return layout(
            leftArea: screen.auxiliaryTopLeftArea ?? .zero,
            rightArea: screen.auxiliaryTopRightArea ?? .zero,
            safeAreaTop: topSafeInset(for: screen),
            adjustment: adjustment,
            displaySize: displaySize
        )
    }

    static func topSafeInset(for screen: NSScreen?) -> CGFloat {
        guard let screen else {
            return 0
        }
        return topSafeInset(
            screen.safeAreaInsets.top,
            leftAreaHeight: screen.auxiliaryTopLeftArea?.height ?? 0,
            rightAreaHeight: screen.auxiliaryTopRightArea?.height ?? 0
        )
    }

    static func topSafeInset(
        _ safeAreaTop: CGFloat,
        leftAreaHeight: CGFloat,
        rightAreaHeight: CGFloat
    ) -> CGFloat {
        max(safeAreaTop, leftAreaHeight, rightAreaHeight)
    }
}
