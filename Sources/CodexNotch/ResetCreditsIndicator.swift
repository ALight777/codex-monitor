import Foundation
import SwiftUI

struct ResetCreditsDisplay: Equatable {
    let availableCount: Int
    let expiryDates: [Date]

    init?(resetCredits: RateLimitResetCredits?) {
        guard let resetCredits else {
            return nil
        }
        let normalizedCount = max(0, resetCredits.availableCount)
        availableCount = normalizedCount
        expiryDates = Array(
            resetCredits.credits
                .map(\.expiresAt)
                .sorted()
                .prefix(normalizedCount)
        )
    }

    var countText: String {
        "剩余重置次数：\(availableCount)"
    }

    var showsInfoButton: Bool {
        availableCount > 0 && !expiryDates.isEmpty
    }

    func expiryRows(timeZone: TimeZone = .current) -> [ResetCreditExpiryRow] {
        expiryDates.enumerated().map { index, expiryDate in
            ResetCreditExpiryRow(
                ordinalText: "第 \(index + 1) 次",
                expiryText: RateLimitResetCreditsFormatter.expiryText(
                    expiryDate,
                    timeZone: timeZone
                )
            )
        }
    }
}

enum ResetCreditsPlacement {
    static func showsInLocalQuotaRow(label: String) -> Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "7d"
    }
}

enum ResetCreditsLayoutMode: Equatable {
    case full
    case compact

    var trailingWidth: CGFloat {
        switch self {
        case .full: 190
        case .compact: 148
        }
    }

    var quotaSpacing: CGFloat {
        switch self {
        case .full: 5
        case .compact: 2
        }
    }

    var quotaFontSize: CGFloat {
        switch self {
        case .full: 8.4
        case .compact: 7.6
        }
    }

    var resetCreditFontSize: CGFloat {
        switch self {
        case .full: 7.7
        case .compact: 6.8
        }
    }
}

enum ResetCreditsLayout {
    static let rowFixedChromeWidth: CGFloat = 46
    static let fullMinimumLeadingWidth: CGFloat = 100
    static let minimumReadableLeadingWidth: CGFloat = 80
    static let fullMinimumAvailableWidth: CGFloat = ResetCreditsLayoutMode.full.trailingWidth
        + rowFixedChromeWidth
        + fullMinimumLeadingWidth
    static let infoHitTarget: CGFloat = 20
    static let inlineLayoutHeight: CGFloat = 20
    static let remoteCardHeight: CGFloat = 62
    static let remoteVerticalPadding: CGFloat = 8
    static let remoteStateLineHeight: CGFloat = 12
    static let remoteRowSpacing: CGFloat = 4

    static var remoteRequiredContentHeight: CGFloat {
        remoteVerticalPadding * 2
            + remoteStateLineHeight
            + remoteRowSpacing
            + inlineLayoutHeight
    }

    static func mode(availableWidth: CGFloat, hasResetCredits: Bool) -> ResetCreditsLayoutMode {
        guard hasResetCredits, availableWidth >= fullMinimumAvailableWidth else {
            return .compact
        }
        return .full
    }

    static func estimatedLeadingWidth(
        availableWidth: CGFloat,
        mode: ResetCreditsLayoutMode
    ) -> CGFloat {
        max(0, availableWidth - mode.trailingWidth - rowFixedChromeWidth)
    }
}

struct ResetCreditExpiryRow: Equatable {
    let ordinalText: String
    let expiryText: String
}

struct ResetCreditsIndicator: View {
    let resetCredits: RateLimitResetCredits?
    var fontSize: CGFloat = 8.4
    var foregroundColor: Color = .white.opacity(0.58)

    @State private var isPopoverPresented = false

    private var display: ResetCreditsDisplay? {
        ResetCreditsDisplay(resetCredits: resetCredits)
    }

    var body: some View {
        if let display {
            HStack(spacing: 2) {
                Text(display.countText)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .layoutPriority(1)

                if display.showsInfoButton {
                    Button {
                        isPopoverPresented.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 10, height: 10)
                            .frame(width: ResetCreditsLayout.infoHitTarget, height: ResetCreditsLayout.infoHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.58))
                    .help("查看重置次数到期时间")
                    .accessibilityLabel("查看重置次数到期时间")
                    .accessibilityHint("显示每次可用重置次数的到期时间")
                    .accessibilityValue("共 \(display.expiryDates.count) 条到期时间")
                    .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
                        ResetCreditsExpiryPopover(display: display)
                    }
                }
            }
            .lineLimit(1)
            .frame(height: ResetCreditsLayout.inlineLayoutHeight)
        }
    }
}

private struct ResetCreditsExpiryPopover: View {
    let display: ResetCreditsDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("重置次数到期时间")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(display.expiryRows().enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        Text(row.ordinalText)
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)

                        Text(row.expiryText)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .padding(14)
        .frame(minWidth: 226, alignment: .leading)
    }
}
