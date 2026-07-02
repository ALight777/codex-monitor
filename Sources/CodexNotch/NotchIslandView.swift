import AppKit
import SwiftUI

private enum DetailPage: String, CaseIterable, Identifiable {
    case codex
    case remoteCodex
    case newAPI
    case subAPI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            "Codex"
        case .remoteCodex:
            "CLIProxyAPI"
        case .newAPI:
            "NewAPI"
        case .subAPI:
            "Sub2API"
        }
    }
}

private struct CollapsedMetric: Identifiable {
    let id: String
    let label: String
    let value: String
    let color: Color
}

struct NotchIslandView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var remoteViewModel: RemoteMonitorViewModel
    @ObservedObject var newAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var subAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var overlayState: OverlayState
    @ObservedObject var settings: CodexNotchSettings
    let onSettings: () -> Void
    @State private var pulse = false

    private var snapshot: UsageSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        ZStack(alignment: .top) {
            islandBackground
            collapsedContent
        }
        .frame(
            width: IslandMetrics.width,
            height: IslandMetrics.collapsedHeight,
            alignment: .top
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                overlayState.isExpanded.toggle()
            }
        }
        .contextMenu {
            Button("设置") {
                onSettings()
            }
            Button("刷新") {
                viewModel.refreshAll()
            }
            Divider()
            Button("退出 codex监测") {
                NSApp.terminate(nil)
            }
        }
        .onAppear {
            pulse = true
        }
    }

    private var islandBackground: some View {
        BottomRoundedRectangle(radius: 21)
            .fill(Color.black.opacity(0.985))
            .frame(
                width: IslandMetrics.width,
                height: IslandMetrics.collapsedHeight,
                alignment: .top
            )
            .overlay(alignment: .top) {
                centerNotchMask
            }
    }

    private var centerNotchMask: some View {
        BottomRoundedRectangle(radius: 20)
            .fill(Color.black)
            .frame(width: IslandMetrics.notchWidth, height: IslandMetrics.collapsedHeight)
            .offset(x: 0, y: 0)
    }

    private var collapsedContent: some View {
        HStack(spacing: 0) {
            statusBlock
                .frame(width: IslandMetrics.shoulderWidth, height: IslandMetrics.collapsedHeight - 4)

            Color.clear
                .frame(width: IslandMetrics.notchWidth, height: IslandMetrics.collapsedHeight)

            rateLimitBlock
                .frame(width: IslandMetrics.shoulderWidth, height: IslandMetrics.collapsedHeight - 4)
        }
        .frame(width: IslandMetrics.width, height: IslandMetrics.collapsedHeight, alignment: .top)
    }

    private var statusBlock: some View {
        HStack(spacing: 5) {
            if effectiveDisplaySource == .codex {
                StatusDot(isRunning: snapshot.isRunning, pulse: pulse, enablePulse: settings.enablePulse)
            } else {
                SeverityDot(severity: collapsedSeverity, pulse: pulse, enablePulse: settings.enablePulse)
            }
            Text(collapsedTitle)
                .font(.system(size: 10.2, weight: .bold))
                .foregroundStyle(collapsedTitleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
    }

    private var rateLimitBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(collapsedMetrics) { metric in
                CollapsedMetricRow(metric: metric)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
    }

    private var effectiveDisplaySource: NotchDisplaySource {
        let selected = settings.notchDisplaySource
        if selected == .automatic {
            let externalSources: [(NotchDisplaySource, RemoteAlertSeverity)] = [
                settings.remoteMonitorEnabled ? (.remoteCodex, remoteViewModel.snapshot.panelSeverity) : nil,
                settings.newAPIMonitorEnabled ? (.newAPI, newAPIViewModel.snapshot.panelSeverity) : nil,
                settings.subAPIMonitorEnabled ? (.subAPI, subAPIViewModel.snapshot.panelSeverity) : nil
            ].compactMap { $0 }
            if let alert = externalSources
                .filter({ $0.1 != .none })
                .sorted(by: { $0.1 > $1.1 })
                .first {
                return alert.0
            }
            return .codex
        }
        return isDisplaySourceEnabled(selected) ? selected : .codex
    }

    private func isDisplaySourceEnabled(_ source: NotchDisplaySource) -> Bool {
        switch source {
        case .automatic, .codex:
            true
        case .remoteCodex:
            settings.remoteMonitorEnabled
        case .newAPI:
            settings.newAPIMonitorEnabled
        case .subAPI:
            settings.subAPIMonitorEnabled
        }
    }

    private var collapsedTitle: String {
        switch effectiveDisplaySource {
        case .automatic, .codex:
            "Codex"
        case .remoteCodex:
            "CLIProxyAPI"
        case .newAPI:
            "NewAPI"
        case .subAPI:
            "Sub2API"
        }
    }

    private var collapsedTitleColor: Color {
        if effectiveDisplaySource == .codex {
            return snapshot.isRunning ? .white.opacity(0.94) : .white.opacity(0.74)
        }
        switch collapsedSeverity {
        case .none:
            return .white.opacity(0.80)
        case .warning:
            return Color(red: 1.0, green: 0.75, blue: 0.42)
        case .error:
            return Color(red: 1.0, green: 0.48, blue: 0.50)
        }
    }

    private var collapsedSeverity: RemoteAlertSeverity {
        switch effectiveDisplaySource {
        case .automatic, .codex:
            .none
        case .remoteCodex:
            remoteViewModel.snapshot.panelSeverity
        case .newAPI:
            newAPIViewModel.snapshot.panelSeverity
        case .subAPI:
            subAPIViewModel.snapshot.panelSeverity
        }
    }

    private var collapsedMetrics: [CollapsedMetric] {
        switch effectiveDisplaySource {
        case .automatic, .codex:
            return [
                CollapsedMetric(
                    id: "5h",
                    label: "5h",
                    value: Formatters.percent(snapshot.primaryPercent),
                    color: Color(red: 0.61, green: 0.95, blue: 0.68)
                ),
                CollapsedMetric(
                    id: "7d",
                    label: "7d",
                    value: Formatters.percent(snapshot.secondaryPercent),
                    color: Color(red: 0.50, green: 0.78, blue: 1.00)
                )
            ]
        case .remoteCodex:
            let remote = remoteViewModel.snapshot
            return [
                CollapsedMetric(id: "ok", label: "正", value: "\(remote.healthyCount)", color: Color(red: 0.61, green: 0.95, blue: 0.68)),
                CollapsedMetric(id: "bad", label: "异", value: "\(remote.quotaCount + remote.abnormalCount)", color: collapsedSeverity == .error ? Color(red: 1.0, green: 0.28, blue: 0.30) : Color(red: 1.0, green: 0.55, blue: 0.25))
            ]
        case .newAPI:
            return balanceCollapsedMetrics(newAPIViewModel.snapshot)
        case .subAPI:
            return balanceCollapsedMetrics(subAPIViewModel.snapshot)
        }
    }

    private func balanceCollapsedMetrics(_ snapshot: BalanceMonitorSnapshot) -> [CollapsedMetric] {
        [
            CollapsedMetric(id: "\(snapshot.source.rawValue)-accounts", label: "账", value: "\(snapshot.accounts.count)", color: Color(red: 0.61, green: 0.95, blue: 0.68)),
            CollapsedMetric(id: "\(snapshot.source.rawValue)-amount", label: "余", value: snapshot.totalAmountText, color: Color(red: 0.50, green: 0.78, blue: 1.00))
        ]
    }
}

private struct CollapsedMetricRow: View {
    let metric: CollapsedMetric

    var body: some View {
        HStack(spacing: 0) {
            Text(metric.label)
                .frame(width: 16, alignment: .leading)
                .foregroundStyle(.white.opacity(0.60))

            Color.clear
                .frame(width: 3)

            Text(metric.value)
                .frame(width: 35, alignment: .trailing)
                .foregroundStyle(metric.color)
                .lineLimit(1)
                .minimumScaleFactor(0.66)
        }
        .font(.system(size: 9.0, weight: .bold, design: .rounded))
        .monospacedDigit()
        .frame(width: 54, alignment: .leading)
    }
}

struct DetailPanelView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var remoteViewModel: RemoteMonitorViewModel
    @ObservedObject var newAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var subAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var settings: CodexNotchSettings
    let onSettings: () -> Void
    let onLocalRefresh: () -> Void
    let onRemoteRefresh: () -> Void
    let onNewAPIRefresh: () -> Void
    let onSubAPIRefresh: () -> Void
    @State private var detailPage: DetailPage = .codex

    private var snapshot: UsageSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        ZStack(alignment: .top) {
            BottomRoundedRectangle(radius: 24)
                .fill(Color.black.opacity(0.985))

            VStack(spacing: 10) {
                header
                pageSwitcher

                Group {
                    switch selectedPage {
                    case .codex:
                        localContent
                    case .remoteCodex:
                        remoteContent
                    case .newAPI:
                        balanceContent(newAPIViewModel)
                    case .subAPI:
                        balanceContent(subAPIViewModel)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 14)
            .padding(.top, IslandMetrics.detailTopPadding)
            .padding(.bottom, IslandMetrics.detailBottomPadding)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: IslandMetrics.width, height: detailHeight)
        .clipShape(BottomRoundedRectangle(radius: 24))
    }

    private var displayedTasks: [CodexTask] {
        snapshot.tasks
    }

    private var detailHeight: CGFloat {
        let localHeight = IslandMetrics.detailHeight(
            taskRows: IslandMetrics.visibleTaskRows,
            showsPeriodUsage: settings.showPeriodUsage
        )
        guard settings.remoteMonitorEnabled else {
            let balanceRows = [
                settings.newAPIMonitorEnabled ? newAPIViewModel.snapshot.accounts.count : nil,
                settings.subAPIMonitorEnabled ? subAPIViewModel.snapshot.accounts.count : nil
            ].compactMap { $0 }
            guard !balanceRows.isEmpty else {
                return localHeight
            }
            return max(localHeight, IslandMetrics.remoteDetailHeight(accountRows: max(1, balanceRows.max() ?? 1)))
        }
        let rows = [
            remoteViewModel.snapshot.accounts.count,
            settings.newAPIMonitorEnabled ? newAPIViewModel.snapshot.accounts.count : nil,
            settings.subAPIMonitorEnabled ? subAPIViewModel.snapshot.accounts.count : nil
        ].compactMap { $0 }
        return max(
            localHeight,
            IslandMetrics.remoteDetailHeight(
                accountRows: max(1, rows.max() ?? 1),
                usesTallRows: remoteViewModel.snapshot.accounts.contains { $0.displayQuotaWindows.count > 2 }
            )
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(headerTitle)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .frame(height: IslandMetrics.detailHeaderHeight, alignment: .center)

            Spacer()

            Text(headerStatus)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(headerStatusColor)
                .lineLimit(1)
                .frame(height: IslandMetrics.detailHeaderHeight, alignment: .center)

            Button(action: refreshCurrentPage) {
                RefreshIcon(isRefreshing: isCurrentPageRefreshing)
            }
            .buttonStyle(IconButtonStyle())
            .disabled(isCurrentPageRefreshing)
            .help(refreshHelp)

            Button(action: onSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(IconButtonStyle())
            .help("设置")
        }
        .frame(height: IslandMetrics.detailHeaderHeight, alignment: .center)
    }

    private var headerTitle: String {
        switch selectedPage {
        case .codex:
            snapshot.isRunning ? "正在运行" : "最近活动"
        case .remoteCodex:
            "CLIProxyAPI 账号"
        case .newAPI:
            "NewAPI 余额"
        case .subAPI:
            "Sub2API 余额"
        }
    }

    private var headerStatus: String {
        switch selectedPage {
        case .codex:
            return snapshot.isRunning ? "\(snapshot.tasks.filter { $0.status == .running }.count) 个任务" : "空闲"
        case .remoteCodex:
            if remoteViewModel.snapshot.usageUnavailableForSource {
                return "仅账号"
            }
            if remoteViewModel.snapshot.usageMessage != nil {
                return "用量旧"
            }
            return remoteHeaderStatus
        case .newAPI:
            return balanceHeaderStatus(newAPIViewModel.snapshot)
        case .subAPI:
            return balanceHeaderStatus(subAPIViewModel.snapshot)
        }
    }

    private var headerStatusColor: Color {
        switch selectedPage {
        case .codex:
            snapshot.isRunning ? Color(red: 0.61, green: 0.95, blue: 0.68) : .white.opacity(0.48)
        case .remoteCodex:
            remoteStatusColor
        case .newAPI:
            balanceStatusColor(newAPIViewModel.snapshot)
        case .subAPI:
            balanceStatusColor(subAPIViewModel.snapshot)
        }
    }

    private var remoteHeaderStatus: String {
        switch remoteViewModel.snapshot.panelState {
        case .disabled:
            "未启用"
        case .notConfigured:
            "待配置"
        case .loading:
            "读取中"
        case .healthy:
            "正常"
        case .warning:
            "提醒"
        case .error:
            "异常"
        }
    }

    private var remoteStatusColor: Color {
        switch remoteViewModel.snapshot.panelSeverity {
        case .none:
            return remoteViewModel.snapshot.usageMessage == nil
                ? Color(red: 0.61, green: 0.95, blue: 0.68)
                : Color(red: 1.0, green: 0.55, blue: 0.25)
        case .warning:
            return Color(red: 1.0, green: 0.55, blue: 0.25)
        case .error:
            return Color(red: 1.0, green: 0.28, blue: 0.30)
        }
    }

    private var isCurrentPageRefreshing: Bool {
        switch selectedPage {
        case .codex:
            viewModel.isRefreshing
        case .remoteCodex:
            remoteViewModel.isRefreshing
        case .newAPI:
            newAPIViewModel.isRefreshing
        case .subAPI:
            subAPIViewModel.isRefreshing
        }
    }

    private var refreshHelp: String {
        switch selectedPage {
        case .codex:
            "刷新 Codex"
        case .remoteCodex:
            "刷新 CLIProxyAPI"
        case .newAPI:
            "刷新 NewAPI"
        case .subAPI:
            "刷新 Sub2API"
        }
    }

    private var pageSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(availablePages) { page in
                Button {
                    detailPage = page
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selectedPage == page ? Color.white.opacity(0.12) : Color.white.opacity(0.035))

                        Text(page.title)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: IslandMetrics.detailPageSwitcherHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .foregroundStyle(selectedPage == page ? .white.opacity(0.92) : .white.opacity(0.48))
            }
        }
        .frame(height: IslandMetrics.detailPageSwitcherHeight)
    }

    private var availablePages: [DetailPage] {
        var pages: [DetailPage] = [.codex]
        if settings.remoteMonitorEnabled {
            pages.append(.remoteCodex)
        }
        if settings.newAPIMonitorEnabled {
            pages.append(.newAPI)
        }
        if settings.subAPIMonitorEnabled {
            pages.append(.subAPI)
        }
        return pages
    }

    private var selectedPage: DetailPage {
        availablePages.contains(detailPage) ? detailPage : .codex
    }

    private func refreshCurrentPage() {
        switch selectedPage {
        case .codex:
            onLocalRefresh()
        case .remoteCodex:
            onRemoteRefresh()
        case .newAPI:
            onNewAPIRefresh()
        case .subAPI:
            onSubAPIRefresh()
        }
    }

    private var localContent: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(displayedTasks) { task in
                        TaskRow(task: task)
                    }

                    if displayedTasks.isEmpty {
                        emptyState
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            if settings.showPeriodUsage {
                periodUsage
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var remoteContent: some View {
        VStack(spacing: 8) {
            remoteSummary

            Group {
                if remoteViewModel.snapshot.accounts.isEmpty {
                    remoteMessage
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 7) {
                            ForEach(remoteViewModel.snapshot.accounts) { account in
                                RemoteAccountRow(account: account)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            cpaUsageSummary
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func balanceContent(_ balanceViewModel: BalanceMonitorViewModel) -> some View {
        VStack(spacing: 8) {
            balanceSummary(balanceViewModel.snapshot)

            Group {
                if balanceViewModel.snapshot.accounts.isEmpty {
                    balanceMessage(balanceViewModel.snapshot)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 7) {
                            if let message = balanceViewModel.snapshot.message {
                                inlineWarningMessage(message)
                            }
                            ForEach(balanceViewModel.snapshot.accounts) { account in
                                BalanceAccountRow(account: account)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            balanceTotals(balanceViewModel.snapshot)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var remoteSummary: some View {
        HStack(spacing: 8) {
            RemoteSummaryCell(label: "正常", value: "\(remoteViewModel.snapshot.healthyCount)")
            RemoteSummaryCell(label: "配额", value: "\(remoteViewModel.snapshot.quotaCount)")
            RemoteSummaryCell(label: "异常", value: "\(remoteViewModel.snapshot.abnormalCount)")
        }
    }

    private var remoteMessage: some View {
        HStack {
            Text(remoteViewModel.snapshot.message ?? "暂无远程账号")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var cpaUsageSummary: some View {
        if remoteViewModel.snapshot.usageUnavailableForSource {
            HStack(spacing: 8) {
                PeriodUsageCell(label: "来源", value: "CLIProxyAPI")
                PeriodUsageCell(label: "账号", value: "\(remoteViewModel.snapshot.accounts.count)")
                PeriodUsageCell(label: "用量", value: "未提供")
            }
        } else {
            HStack(spacing: 8) {
                PeriodUsageCell(label: "24小时", value: Formatters.compactTokens(remoteViewModel.snapshot.usage24h))
                PeriodUsageCell(label: "7天", value: Formatters.compactTokens(remoteViewModel.snapshot.usage7d))
                PeriodUsageCell(label: "30天", value: Formatters.compactTokens(remoteViewModel.snapshot.usage30d))
            }
        }
    }

    private func balanceSummary(_ snapshot: BalanceMonitorSnapshot) -> some View {
        HStack(spacing: 8) {
            RemoteSummaryCell(label: "正常", value: "\(snapshot.healthyCount)")
            RemoteSummaryCell(label: "提醒", value: "\(snapshot.warningCount)")
            RemoteSummaryCell(label: "异常", value: "\(snapshot.errorCount)")
        }
    }

    private func balanceTotals(_ snapshot: BalanceMonitorSnapshot) -> some View {
        HStack(spacing: 8) {
            PeriodUsageCell(label: "账户", value: "\(snapshot.accounts.count)")
            PeriodUsageCell(label: "余额", value: snapshot.totalAmountText)
            PeriodUsageCell(label: "提醒", value: "\(snapshot.warningCount + snapshot.errorCount)")
        }
    }

    private func balanceMessage(_ snapshot: BalanceMonitorSnapshot) -> some View {
        HStack {
            Text(snapshot.message ?? "暂无账户")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func inlineWarningMessage(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.system(size: 9.6, weight: .semibold))
                .foregroundStyle(Color(red: 1.0, green: 0.70, blue: 0.38))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(red: 1.0, green: 0.55, blue: 0.25).opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(red: 1.0, green: 0.55, blue: 0.25).opacity(0.16), lineWidth: 1)
        )
    }

    private func balanceHeaderStatus(_ snapshot: BalanceMonitorSnapshot) -> String {
        switch snapshot.panelState {
        case .disabled:
            "未启用"
        case .notConfigured:
            "待配置"
        case .loading:
            "读取中"
        case .healthy:
            "正常"
        case .warning:
            "提醒"
        case .error:
            "异常"
        }
    }

    private func balanceStatusColor(_ snapshot: BalanceMonitorSnapshot) -> Color {
        switch snapshot.panelSeverity {
        case .none:
            Color(red: 0.61, green: 0.95, blue: 0.68)
        case .warning:
            Color(red: 1.0, green: 0.55, blue: 0.25)
        case .error:
            Color(red: 1.0, green: 0.28, blue: 0.30)
        }
    }

    private var emptyState: some View {
        HStack {
            Text(snapshot.errorMessage ?? "暂无 Codex 活动")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var periodUsage: some View {
        HStack(spacing: 8) {
            PeriodUsageCell(label: "24小时", value: Formatters.compactTokens(snapshot.usage24h))
            PeriodUsageCell(label: "7天", value: Formatters.compactTokens(snapshot.usage7d))
            PeriodUsageCell(label: "30天", value: Formatters.compactTokens(snapshot.usage30d))
        }
        .padding(.top, 1)
    }
}

private struct StatusDot: View {
    let isRunning: Bool
    let pulse: Bool
    let enablePulse: Bool

    var body: some View {
        ZStack {
            if isRunning && enablePulse {
                Circle()
                    .stroke(Color(red: 0.20, green: 0.94, blue: 0.43).opacity(0.28), lineWidth: 4)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.45 : 0.95)
                    .opacity(pulse ? 0.16 : 0.44)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            }

            Circle()
                .fill(isRunning ? Color(red: 0.20, green: 0.94, blue: 0.43) : Color(red: 0.31, green: 0.33, blue: 0.37))
                .frame(width: 8, height: 8)
                .shadow(
                    color: isRunning ? Color(red: 0.20, green: 0.94, blue: 0.43).opacity(0.9) : .white.opacity(0.08),
                    radius: isRunning ? 8 : 1,
                    x: 0,
                    y: 0
                )
        }
        .frame(width: 12, height: 12)
    }
}

private struct SeverityDot: View {
    let severity: RemoteAlertSeverity
    let pulse: Bool
    let enablePulse: Bool

    var body: some View {
        ZStack {
            if severity != .none && enablePulse {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 4)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.45 : 0.95)
                    .opacity(pulse ? 0.18 : 0.42)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            }

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(severity == .none ? 0.10 : 0.80), radius: severity == .none ? 1 : 7, x: 0, y: 0)
        }
        .frame(width: 12, height: 12)
    }

    private var color: Color {
        switch severity {
        case .none:
            Color(red: 0.31, green: 0.33, blue: 0.37)
        case .warning:
            Color(red: 1.0, green: 0.55, blue: 0.25)
        case .error:
            Color(red: 1.0, green: 0.28, blue: 0.30)
        }
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.68 : 0.58))
            .frame(width: 18, height: 18)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.035), in: Circle())
    }
}

private struct RefreshIcon: View {
    let isRefreshing: Bool

    var body: some View {
        Group {
            if isRefreshing {
                TimelineView(.periodic(from: Date(), by: 0.25)) { context in
                    icon
                        .rotationEffect(.degrees(rotationAngle(at: context.date)))
                        .foregroundStyle(Color(red: 0.61, green: 0.95, blue: 0.68))
                }
            } else {
                icon
            }
        }
    }

    private var icon: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 10, weight: .bold))
    }

    private func rotationAngle(at date: Date) -> Double {
        let cycle = 0.85
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
        return progress * 360
    }
}

private struct TaskRow: View {
    let task: CodexTask

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(task.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Text(task.status.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 6) {
                Text(task.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let badgeText = TaskBadgeFormatter.subagentBadgeText(for: task.activeSubagentCount) {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.61, green: 0.95, blue: 0.68))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Color(red: 0.61, green: 0.95, blue: 0.68).opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }

                Text(Formatters.compactTokens(task.tokenCount))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch task.status {
        case .running:
            Color(red: 0.61, green: 0.95, blue: 0.68)
        case .recent:
            Color(red: 0.50, green: 0.78, blue: 1.00)
        case .idle:
            .white.opacity(0.48)
        }
    }
}

private struct RemoteAccountRow: View {
    let account: RemoteCodexAccount

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.state.color)
                .frame(width: 8, height: 8)
                .shadow(color: account.state.color.opacity(0.45), radius: 4, x: 0, y: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    if let planLabel = account.planLabel {
                        Text(planLabel)
                            .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                            .foregroundStyle(.black.opacity(0.84))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.98, green: 0.86, blue: 0.36), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    Text(account.detailText)
                        .font(.system(size: 9.3, weight: .medium))
                        .foregroundStyle(.white.opacity(0.50))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(account.stateReasonText)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(account.state.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                quotaGrid
            }
            .frame(width: 148, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: quotaWindows.count > 2 ? 74 : 62)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var quotaWindows: [RemoteQuotaWindow] {
        account.displayQuotaWindows
    }

    @ViewBuilder
    private var quotaGrid: some View {
        if quotaWindows.isEmpty {
            Text(account.quotaSummaryText)
                .font(.system(size: 9.3, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(quotaColor)
                .lineLimit(1)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 58), spacing: 4, alignment: .trailing),
                    GridItem(.flexible(minimum: 58), spacing: 4, alignment: .trailing)
                ],
                alignment: .trailing,
                spacing: 3
            ) {
                ForEach(quotaWindows) { window in
                    Text("\(window.shortLabel) \(window.remainingText)")
                        .font(.system(size: 8.4, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(window.reachesThreshold ? Color(red: 1.0, green: 0.55, blue: 0.25) : .white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.64)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var quotaColor: Color {
        if account.quotaError != nil {
            return Color(red: 1.0, green: 0.55, blue: 0.25)
        }
        if account.displayQuotaWindows.contains(where: \.reachesThreshold) {
            return Color(red: 1.0, green: 0.55, blue: 0.25)
        }
        return .white.opacity(0.62)
    }
}

private struct BalanceAccountRow: View {
    let account: BalanceAccount

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(account.state.color)
                .frame(width: 8, height: 8)
                .shadow(color: account.state.color.opacity(0.45), radius: 4, x: 0, y: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(account.detailText)
                    .font(.system(size: 9.3, weight: .medium))
                    .foregroundStyle(.white.opacity(0.50))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(account.stateText)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(account.state.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(account.amountText)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 62)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct RemoteSummaryCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.50))
            Text(value)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.90))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.026), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PeriodUsageCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.52))
            Text(value)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.026), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
