import AppKit
import SwiftUI

private enum DetailPage: String, CaseIterable, Identifiable {
    case codex
    case codexRadar
    case remoteCodex
    case newAPI
    case subAPI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            "Codex"
        case .codexRadar:
            "Codex Radar"
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

private enum MonitorTheme {
    static let pillTint = Color.black.opacity(0.48)
    static let detailTint = Color.black.opacity(0.52)
    static let panelStroke = Color.white.opacity(0.16)
    static let hairline = Color.white.opacity(0.075)
    static let sectionFill = Color.white.opacity(0.055)
    static let rowFill = Color.white.opacity(0.038)
    static let rowSelectedFill = Color.white.opacity(0.092)
    static let controlFill = Color.white.opacity(0.052)
    static let controlSelectedFill = Color.white.opacity(0.115)
    static let separator = Color.white.opacity(0.070)
    static let progressTrack = Color.white.opacity(0.115)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.44)
    static let healthy = Color(red: 0.45, green: 0.78, blue: 0.53)
    static let running = Color(red: 0.47, green: 0.72, blue: 0.82)
    static let warning = Color(red: 0.92, green: 0.68, blue: 0.42)
    static let critical = Color(red: 0.88, green: 0.45, blue: 0.45)
    static let neutral = Color.white.opacity(0.34)
}

private struct HUDVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
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

    private var collapsedContent: some View {
        HStack(spacing: 6) {
            statusBlock

            rateLimitBlock
        }
        .padding(.horizontal, IslandMetrics.collapsedPillHorizontalPadding)
        .padding(.top, 4)
        .frame(height: IslandMetrics.collapsedHeight - 8, alignment: .center)
        .fixedSize(horizontal: true, vertical: false)
        .background(collapsedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 9, x: 0, y: 4)
        .frame(width: IslandMetrics.width, height: IslandMetrics.collapsedHeight, alignment: .top)
    }

    private var collapsedBackground: some View {
        ZStack {
            HUDVisualEffectView(material: .hudWindow)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(MonitorTheme.pillTint)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(MonitorTheme.panelStroke, lineWidth: 0.7)
        }
    }

    private var statusBlock: some View {
        HStack(spacing: 5) {
            if effectiveDisplaySource == .codex {
                StatusDot(isRunning: snapshot.isRunning, pulse: pulse, enablePulse: settings.enablePulse)
            } else {
                SeverityDot(severity: collapsedSeverity, pulse: pulse, enablePulse: settings.enablePulse)
            }
            Text(collapsedStateLabel)
                .font(.system(size: 10.6, weight: .semibold))
                .foregroundStyle(collapsedTitleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .layoutPriority(1)
    }

    private var rateLimitBlock: some View {
        HStack(spacing: 5) {
            ForEach(collapsedMetrics) { metric in
                CollapsedMetricRow(metric: metric)
            }
        }
        .layoutPriority(2)
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

    private var collapsedStateLabel: String {
        guard effectiveDisplaySource == .codex else {
            return collapsedTitle
        }
        return snapshot.isRunning ? "RUN" : "IDLE"
    }

    private var collapsedTitleColor: Color {
        if effectiveDisplaySource == .codex {
            return snapshot.isRunning ? .white.opacity(0.94) : .white.opacity(0.74)
        }
        switch collapsedSeverity {
        case .none:
            return .white.opacity(0.80)
        case .warning:
            return MonitorTheme.warning
        case .error:
            return MonitorTheme.critical
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
            let todayTokens = snapshot.usage24h
            var metrics = [
                CollapsedMetric(
                    id: "5h",
                    label: "5h",
                    value: Formatters.percent(snapshot.primaryPercent),
                    color: MonitorTheme.healthy
                ),
                CollapsedMetric(
                    id: "7d",
                    label: "7d",
                    value: Formatters.percent(snapshot.secondaryPercent),
                    color: MonitorTheme.running
                ),
                CollapsedMetric(
                    id: "tok",
                    label: "Today",
                    value: todayTokens > 0 ? Formatters.compactTokensEnglish(todayTokens) : "--",
                    color: MonitorTheme.textPrimary
                )
            ]
            let usage1h = snapshot.usage1h
            metrics.append(
                CollapsedMetric(
                    id: "usage1h",
                    label: "1h",
                    value: Formatters.signedCompactTokensEnglish(usage1h),
                    color: (usage1h ?? 0) > 0 ? MonitorTheme.running : MonitorTheme.textSecondary
                )
            )
            return metrics
        case .remoteCodex:
            let remote = remoteViewModel.snapshot
            return [
                CollapsedMetric(id: "ok", label: "正", value: "\(remote.healthyCount)", color: MonitorTheme.healthy),
                CollapsedMetric(id: "bad", label: "异", value: "\(remote.quotaCount + remote.abnormalCount)", color: collapsedSeverity == .error ? MonitorTheme.critical : MonitorTheme.warning)
            ]
        case .newAPI:
            return balanceCollapsedMetrics(newAPIViewModel.snapshot)
        case .subAPI:
            return balanceCollapsedMetrics(subAPIViewModel.snapshot)
        }
    }

    private func balanceCollapsedMetrics(_ snapshot: BalanceMonitorSnapshot) -> [CollapsedMetric] {
        [
            CollapsedMetric(id: "\(snapshot.source.rawValue)-accounts", label: "账", value: "\(snapshot.accounts.count)", color: MonitorTheme.healthy),
            CollapsedMetric(id: "\(snapshot.source.rawValue)-amount", label: "余", value: snapshot.totalAmountText, color: MonitorTheme.running)
        ]
    }

}

private struct CollapsedMetricRow: View {
    let metric: CollapsedMetric

    var body: some View {
        HStack(spacing: 3) {
            Text(metric.label)
                .font(.system(size: 8.4, weight: .medium))
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.70)

            Text(metric.value)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(metric.color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .monospacedDigit()
        }
    }
}

struct DetailPanelView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var remoteViewModel: RemoteMonitorViewModel
    @ObservedObject var newAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var subAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var codexRadarViewModel: CodexRadarViewModel
    @ObservedObject var settings: CodexNotchSettings
    let onSettings: () -> Void
    let onLocalRefresh: () -> Void
    let onRemoteRefresh: () -> Void
    let onNewAPIRefresh: () -> Void
    let onSubAPIRefresh: () -> Void
    let onCodexRadarRefresh: () -> Void
    @State private var detailPage: DetailPage = .codex

    private var snapshot: UsageSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        ZStack(alignment: .top) {
            HUDVisualEffectView(material: .hudWindow)
                .clipShape(BottomRoundedRectangle(radius: 22))

            BottomRoundedRectangle(radius: 22)
                .fill(MonitorTheme.detailTint)

            BottomRoundedRectangle(radius: 22)
                .stroke(MonitorTheme.panelStroke, lineWidth: 0.8)
                .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 10)

            VStack(spacing: 10) {
                header
                pageSwitcher

                Group {
                    switch selectedPage {
                    case .codex:
                        localContent
                    case .codexRadar:
                        codexRadarContent
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
        .clipShape(BottomRoundedRectangle(radius: 22))
    }

    private var displayedTasks: [CodexTask] {
        snapshot.tasks
    }

    private var detailHeight: CGFloat {
        let localHeight = IslandMetrics.detailHeight(
            taskRows: IslandMetrics.visibleTaskRows,
            showsPeriodUsage: settings.showPeriodUsage,
            showsSparkQuota: settings.showSparkQuota
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)
                .lineLimit(1)
                .frame(height: IslandMetrics.detailHeaderHeight, alignment: .center)

            Spacer()

            Text(headerStatus)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(headerStatusColor)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(headerStatusColor.opacity(0.13), in: Capsule())
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
            "Codex Monitor"
        case .codexRadar:
            "Codex Radar"
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
            return snapshot.isRunning ? "Running" : "Idle"
        case .codexRadar:
            return codexRadarHeaderStatus
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
            snapshot.isRunning ? MonitorTheme.healthy : MonitorTheme.textTertiary
        case .codexRadar:
            codexRadarHeaderStatusColor
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
                ? MonitorTheme.healthy
                : MonitorTheme.warning
        case .warning:
            return MonitorTheme.warning
        case .error:
            return MonitorTheme.critical
        }
    }

    private var isCurrentPageRefreshing: Bool {
        switch selectedPage {
        case .codex:
            viewModel.isRefreshing
        case .codexRadar:
            codexRadarViewModel.isRefreshing
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
        case .codexRadar:
            "刷新 Codex Radar"
        case .remoteCodex:
            "刷新 CLIProxyAPI"
        case .newAPI:
            "刷新 NewAPI"
        case .subAPI:
            "刷新 Sub2API"
        }
    }

    private var pageSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(availablePages) { page in
                PageSwitcherButton(
                    title: page.title,
                    isSelected: selectedPage == page
                ) {
                    detailPage = page
                }
            }
        }
        .padding(3)
        .frame(height: IslandMetrics.detailPageSwitcherHeight)
        .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }

    private var availablePages: [DetailPage] {
        var pages: [DetailPage] = [.codex]
        if settings.codexRadarEnabled {
            pages.append(.codexRadar)
        }
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
        case .codexRadar:
            onCodexRadarRefresh()
        case .remoteCodex:
            onRemoteRefresh()
        case .newAPI:
            onNewAPIRefresh()
        case .subAPI:
            onSubAPIRefresh()
        }
    }

    private var localContent: some View {
        VStack(spacing: 8) {
            localQuotaStrip
            if settings.showSparkQuota {
                sparkQuotaStrip
            }
            localMetricStrip
            localTaskTable
                .frame(maxHeight: .infinity, alignment: .top)

            if settings.showPeriodUsage {
                periodUsage
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var localQuotaStrip: some View {
        HStack(spacing: 14) {
            QuotaBarCell(
                label: "5h Quota",
                value: Formatters.percent(snapshot.primaryPercent),
                percent: snapshot.primaryPercent,
                resetText: quotaResetText(
                    for: snapshot.primaryResetsAt,
                    percent: snapshot.primaryPercent,
                    style: .time
                ),
                color: quotaColor(for: snapshot.primaryPercent)
            )
            QuotaBarCell(
                label: "7d Quota",
                value: Formatters.percent(snapshot.secondaryPercent),
                percent: snapshot.secondaryPercent,
                resetText: quotaResetText(
                    for: snapshot.secondaryResetsAt,
                    percent: snapshot.secondaryPercent,
                    style: .date
                ),
                color: quotaColor(for: snapshot.secondaryPercent)
            )
            CompactStatusCell(
                label: "Running",
                value: "\(runningTaskCount)",
                detail: "\(displayedTasks.count) sessions"
            )
            .frame(width: 96)
            CompactStatusCell(
                label: "Ctx",
                value: currentContextPercentText,
                detail: currentContextTokenRatioText
            )
            .frame(width: 116)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(MonitorTheme.sectionFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }

    private var sparkQuotaStrip: some View {
        HStack(spacing: 8) {
            Text("Spark")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)
                .lineLimit(1)

            if snapshot.sparkQuotaWindows.isEmpty {
                Text("--")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorTheme.textTertiary)
            } else {
                ForEach(snapshot.sparkQuotaWindows) { window in
                    SparkQuotaChip(window: window)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }

    private var localMetricStrip: some View {
        HStack(spacing: 0) {
            MetricReadout(label: "Active Sessions", value: "\(displayedTasks.count)")
            verticalSeparator
            MetricReadout(label: "Subagents", value: "\(activeSubagentTotal)")
            verticalSeparator
            MetricReadout(label: "Usage 24h", value: Formatters.compactTokens(snapshot.usage24h))
            verticalSeparator
            MetricReadout(label: "Current", value: Formatters.compactTokens(currentTaskTokens))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }

    private var localTaskTable: some View {
        VStack(spacing: 0) {
            TaskTableHeader()
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: 0.6)

            if displayedTasks.isEmpty {
                emptyState
                    .padding(.top, 8)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(displayedTasks.enumerated()), id: \.element.id) { index, task in
                            TaskTableRow(task: task, isSelected: index == 0)
                        }
                    }
                }
            }
        }
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }

    private var runningTaskCount: Int {
        displayedTasks.filter { $0.status == .running }.count
    }

    private var activeSubagentTotal: Int {
        displayedTasks.reduce(0) { $0 + $1.activeSubagentCount }
    }

    private var currentTaskTokens: Int {
        displayedTasks.first?.tokenCount ?? 0
    }

    private var currentContextTask: CodexTask? {
        displayedTasks.first { $0.contextInputTokens != nil && $0.contextWindowTokens != nil }
    }

    private var currentContextPercentText: String {
        Formatters.percent(currentContextTask?.contextPercent)
    }

    private var currentContextTokenRatioText: String {
        Formatters.compactTokenRatio(
            currentContextTask?.contextInputTokens,
            currentContextTask?.contextWindowTokens
        )
    }

    private var verticalSeparator: some View {
        Rectangle()
            .fill(MonitorTheme.separator)
            .frame(width: 0.6, height: 32)
    }

    private func quotaColor(for percent: Int?) -> Color {
        guard let percent else {
            return MonitorTheme.textTertiary
        }
        if percent <= 5 {
            return MonitorTheme.critical
        }
        if percent <= 20 {
            return MonitorTheme.warning
        }
        return MonitorTheme.healthy
    }

    private func quotaResetText(
        for resetAt: Int?,
        percent: Int?,
        style: Formatters.QuotaResetDisplayStyle
    ) -> String? {
        guard percent != nil else {
            return nil
        }
        return Formatters.quotaResetText(resetAt, style: style)
    }

    private var codexRadarHeaderStatus: String {
        switch codexRadarViewModel.snapshot.panelState {
        case .disabled:
            "Off"
        case .loading:
            "Loading"
        case .ready:
            "Updated"
        case .stale:
            "Stale"
        case .error:
            "Error"
        }
    }

    private var codexRadarHeaderStatusColor: Color {
        switch codexRadarViewModel.snapshot.panelState {
        case .disabled, .loading:
            MonitorTheme.textTertiary
        case .ready:
            MonitorTheme.healthy
        case .stale:
            MonitorTheme.warning
        case .error:
            MonitorTheme.critical
        }
    }

    private var codexRadarContent: some View {
        let radar = codexRadarViewModel.snapshot
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                codexRadarSummary(radar)

                if let message = radar.message, radar.panelState != .ready {
                    inlineWarningMessage(message)
                }

                if radar.models.isEmpty {
                    codexRadarEmptyMessage(radar)
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 128), spacing: 7),
                            GridItem(.flexible(minimum: 128), spacing: 7),
                            GridItem(.flexible(minimum: 128), spacing: 7)
                        ],
                        spacing: 7
                    ) {
                        ForEach(radar.models) { model in
                            CodexRadarModelCard(model: model)
                        }
                    }
                }

                codexRadarQuotaTable(radar)
                codexRadarFooter(radar)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func codexRadarSummary(_ radar: CodexRadarSnapshot) -> some View {
        HStack(spacing: 8) {
            RadarSummaryCell(
                label: "Updated",
                value: radarUpdatedText(radar),
                color: MonitorTheme.textPrimary
            )
            RadarSummaryCell(
                label: "Status",
                value: radar.status?.replacingOccurrences(of: "_", with: " ") ?? "--",
                color: codexRadarStatusColor(radar.status)
            )
            RadarSummaryCell(
                label: "Cost",
                value: radar.costUSD.map { String(format: "$%.2f", $0) } ?? "--",
                color: MonitorTheme.running
            )
        }
    }

    private func codexRadarEmptyMessage(_ radar: CodexRadarSnapshot) -> some View {
        HStack {
            Text(radar.message ?? "暂无 Codex Radar 模型数据")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }

    private func codexRadarQuotaTable(_ radar: CodexRadarSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                radarTableHeader("Plan")
                    .frame(maxWidth: .infinity, alignment: .leading)
                radarTableHeader("5h")
                    .frame(width: 86, alignment: .trailing)
                radarTableHeader("7d")
                    .frame(width: 86, alignment: .trailing)
                radarTableHeader("Basis")
                    .frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 25)

            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: 0.6)

            if radar.quotaRows.isEmpty {
                HStack {
                    Text("暂无 quota radar 摘要")
                        .font(.system(size: 10.4, weight: .semibold))
                        .foregroundStyle(MonitorTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
            } else {
                ForEach(radar.quotaRows) { row in
                    CodexRadarQuotaRowView(row: row)
                }
            }
        }
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }

    private func codexRadarFooter(_ radar: CodexRadarSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("\(radar.attributionText) · \(radar.dataSource.displayLabel)")
                .font(.system(size: 9.4, weight: .medium))
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer()
            Button {
                NSWorkspace.shared.open(radar.siteURL)
            } label: {
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle())
            .help("打开 codexradar.com")
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }

    private func radarUpdatedText(_ radar: CodexRadarSnapshot) -> String {
        let date = radar.displayUpdatedAt
        guard let date else {
            return "--"
        }
        return Self.radarDateFormatter.string(from: date)
    }

    private func codexRadarStatusColor(_ status: String?) -> Color {
        switch status?.lowercased() {
        case "green", "open", "normal":
            MonitorTheme.healthy
        case "yellow", "warning", "community_confirmed":
            MonitorTheme.warning
        case "red", "error", "closed":
            MonitorTheme.critical
        default:
            MonitorTheme.textPrimary
        }
    }

    private func radarTableHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.6, weight: .semibold))
            .foregroundStyle(MonitorTheme.textSecondary)
    }

    private static let radarDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

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
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
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
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }

    private func inlineWarningMessage(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.system(size: 9.6, weight: .semibold))
                .foregroundStyle(MonitorTheme.warning)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(MonitorTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.warning.opacity(0.16), lineWidth: 0.6)
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
            MonitorTheme.healthy
        case .warning:
            MonitorTheme.warning
        case .error:
            MonitorTheme.critical
        }
    }

    private var emptyState: some View {
        HStack {
            Text(snapshot.errorMessage ?? "暂无 Codex 活动")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }

    private var periodUsage: some View {
        HStack(spacing: 8) {
            PeriodUsageCell(label: "24小时", value: Formatters.compactTokens(snapshot.usage24h))
            PeriodUsageCell(label: "7天", value: Formatters.compactTokens(snapshot.usage7d))
            PeriodUsageCell(label: "30天", value: Formatters.compactTokens(snapshot.usage30d))
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }
}

private struct PageSwitcherButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? MonitorTheme.controlSelectedFill : Color.clear)

                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
            .frame(height: IslandMetrics.detailPageSwitcherHeight - 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .foregroundStyle(isSelected ? MonitorTheme.textPrimary : MonitorTheme.textSecondary)
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
                    .stroke(MonitorTheme.healthy.opacity(0.18), lineWidth: 3)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.34 : 0.95)
                    .opacity(pulse ? 0.12 : 0.34)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            }

            Circle()
                .fill(isRunning ? MonitorTheme.healthy : MonitorTheme.neutral)
                .frame(width: 8, height: 8)
                .shadow(
                    color: isRunning ? MonitorTheme.healthy.opacity(0.34) : .white.opacity(0.06),
                    radius: isRunning ? 4 : 1,
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
                    .stroke(color.opacity(0.20), lineWidth: 3)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.34 : 0.95)
                    .opacity(pulse ? 0.14 : 0.34)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            }

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(severity == .none ? 0.08 : 0.42), radius: severity == .none ? 1 : 4, x: 0, y: 0)
        }
        .frame(width: 12, height: 12)
    }

    private var color: Color {
        switch severity {
        case .none:
            MonitorTheme.neutral
        case .warning:
            MonitorTheme.warning
        case .error:
            MonitorTheme.critical
        }
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.76 : 0.60))
            .frame(width: 20, height: 20)
            .background(Color.white.opacity(configuration.isPressed ? 0.095 : 0.045), in: Circle())
            .overlay(
                Circle()
                    .stroke(MonitorTheme.hairline, lineWidth: 0.5)
            )
    }
}

private struct RefreshIcon: View {
    let isRefreshing: Bool

    var body: some View {
        Group {
            if isRefreshing {
                TimelineView(.animation) { context in
                    icon
                        .rotationEffect(.degrees(rotationAngle(at: context.date)))
                        .foregroundStyle(MonitorTheme.healthy)
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

private struct QuotaBarCell: View {
    let label: String
    let value: String
    let percent: Int?
    let resetText: String?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 10.4, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 10.4, weight: .semibold))
                    .foregroundStyle(color)
                    .monospacedDigit()
                if let resetText {
                    Text(resetText)
                        .font(.system(size: 9.2, weight: .medium))
                        .foregroundStyle(MonitorTheme.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }

            CapsuleQuotaBar(value: percent, color: color)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SparkQuotaChip: View {
    let window: SparkQuotaWindow

    var body: some View {
        HStack(spacing: 4) {
            Text(window.label)
                .font(.system(size: 9.2, weight: .medium))
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)

            Text(window.remainingText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(MonitorTheme.running)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(MonitorTheme.controlFill, in: Capsule())
        .overlay(
            Capsule()
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
        .help(helpText)
    }

    private var helpText: String {
        var parts = ["GPT-5.3-Codex-Spark \(window.label)"]
        if let resetText = window.resetText {
            parts.append(resetText)
        } else if let resetText = Formatters.quotaResetText(window.resetAt) {
            parts.append(resetText)
        }
        return parts.joined(separator: " · ")
    }
}

private struct CapsuleQuotaBar: View {
    let value: Int?
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(MonitorTheme.progressTrack)
                Capsule(style: .continuous)
                    .fill(color.opacity(0.92))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 5)
    }

    private var progress: CGFloat {
        guard let value else {
            return 0
        }
        return CGFloat(max(0, min(100, value))) / 100
    }
}

private struct CompactStatusCell: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10.4, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)
            Text(value)
                .font(.system(size: 17.2, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.textPrimary)
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 9.2, weight: .semibold))
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
    }
}

private struct MetricReadout: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9.7, weight: .medium))
                .foregroundStyle(MonitorTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 15.6, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

private struct TaskTableHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            tableHeaderText("Session")
                .frame(maxWidth: .infinity, alignment: .leading)
            tableHeaderText("Status")
                .frame(width: 58, alignment: .leading)
            tableHeaderText("+10m")
                .frame(width: 56, alignment: .trailing)
            tableHeaderText("Today")
                .frame(width: 78, alignment: .trailing)
            tableHeaderText("Ctx")
                .frame(width: 66, alignment: .trailing)
            tableHeaderText("Total")
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    private func tableHeaderText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.8, weight: .semibold))
            .foregroundStyle(MonitorTheme.textSecondary)
    }
}

private struct TaskTableRow: View {
    let task: CodexTask
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(task.status == .running ? 0.55 : 0.18), radius: 4, x: 0, y: 0)

                Text(task.title)
                    .font(.system(size: 11.2, weight: .medium))
                    .foregroundStyle(MonitorTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let badgeText = TaskBadgeFormatter.subagentBadgeText(for: task.activeSubagentCount) {
                    Text(badgeText)
                        .font(.system(size: 8.4, weight: .semibold))
                        .foregroundStyle(MonitorTheme.running)
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(MonitorTheme.running.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusPill(status: task.status)
                .frame(width: 58, alignment: .leading)

            Text(Formatters.signedCompactTokens(task.delta10mTokens))
                .font(.system(size: 10.2, weight: .semibold))
                .foregroundStyle(deltaColor(task.delta10mTokens))
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .monospacedDigit()

            Text(Formatters.compactTokensWithShare(tokens: task.todayTokens, sharePercent: task.todaySharePercent))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(todayColor)
                .frame(width: 78, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.56)
                .monospacedDigit()

            Text(Formatters.percent(task.contextPercent))
                .font(.system(size: 10.2, weight: .semibold))
                .foregroundStyle(task.contextPercent == nil ? MonitorTheme.textTertiary : MonitorTheme.running)
                .frame(width: 66, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .monospacedDigit()

            Text(Formatters.compactTokens(task.tokenCount))
                .font(.system(size: 10.3, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)
                .frame(width: 72, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(isSelected ? MonitorTheme.rowSelectedFill : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: 0.6)
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .running:
            MonitorTheme.healthy
        case .recent, .idle:
            MonitorTheme.neutral
        }
    }

    private var todayColor: Color {
        guard let tokens = task.todayTokens else {
            return MonitorTheme.textTertiary
        }
        return tokens > 0 ? MonitorTheme.running : MonitorTheme.textSecondary
    }

    private func deltaColor(_ value: Int?) -> Color {
        guard let value else {
            return MonitorTheme.textTertiary
        }
        return value > 0 ? MonitorTheme.running : MonitorTheme.textSecondary
    }
}

private struct StatusPill: View {
    let status: TaskStatus

    var body: some View {
        Text(status.hudLabel)
            .font(.system(size: 9.2, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.13), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .running:
            MonitorTheme.healthy
        case .recent, .idle:
            MonitorTheme.textTertiary
        }
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

                Text(task.status.hudLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 6) {
                Text(task.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let badgeText = TaskBadgeFormatter.subagentBadgeText(for: task.activeSubagentCount) {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(MonitorTheme.healthy)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            MonitorTheme.healthy.opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }

                Text(Formatters.compactTokens(task.tokenCount))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }

    private var statusColor: Color {
        switch task.status {
        case .running:
            MonitorTheme.healthy
        case .recent, .idle:
            MonitorTheme.textTertiary
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
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    if let planLabel = account.planLabel {
                        Text(planLabel)
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.black.opacity(0.84))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.98, green: 0.86, blue: 0.36), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    Text(account.detailText)
                        .font(.system(size: 9.3, weight: .medium))
                        .foregroundStyle(MonitorTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(account.stateReasonText)
                    .font(.system(size: 10, weight: .semibold))
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
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
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
                        .foregroundStyle(window.reachesThreshold ? MonitorTheme.warning : MonitorTheme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.64)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private var quotaColor: Color {
        if account.quotaError != nil {
            return MonitorTheme.warning
        }
        if account.displayQuotaWindows.contains(where: \.reachesThreshold) {
            return MonitorTheme.warning
        }
        return MonitorTheme.textSecondary
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
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(account.detailText)
                    .font(.system(size: 9.3, weight: .medium))
                    .foregroundStyle(MonitorTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(account.stateText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(account.state.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(account.amountText)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 62)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }
}

private struct RemoteSummaryCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(MonitorTheme.textPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }
}

private struct PeriodUsageCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9.6, weight: .semibold))
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }
}

private struct RadarSummaryCell: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9.4, weight: .medium))
                .foregroundStyle(MonitorTheme.textSecondary)
            Text(value)
                .font(.system(size: 10.8, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(MonitorTheme.rowFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(MonitorTheme.hairline, lineWidth: 0.6)
        )
    }
}

private struct CodexRadarModelCard: View {
    let model: CodexRadarModelScore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.38), radius: 3, x: 0, y: 0)

                Text(model.label)
                    .font(.system(size: 10.3, weight: .semibold))
                    .foregroundStyle(MonitorTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text(scoreText)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()

            HStack(spacing: 5) {
                Text(passText)
                if let wallTimeHuman = model.wallTimeHuman {
                    Text(wallTimeHuman)
                }
            }
            .font(.system(size: 8.7, weight: .medium))
            .foregroundStyle(MonitorTheme.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.70)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(statusColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(statusColor.opacity(0.18), lineWidth: 0.7)
        )
    }

    private var scoreText: String {
        guard let score = model.score else {
            return "--"
        }
        return String(format: "%.1f", score)
    }

    private var passText: String {
        guard let passed = model.passed,
              let tasks = model.tasks else {
            return "--/--"
        }
        return "\(passed)/\(tasks)"
    }

    private var statusColor: Color {
        switch model.status?.lowercased() {
        case "green":
            MonitorTheme.healthy
        case "yellow":
            MonitorTheme.warning
        case "red":
            MonitorTheme.critical
        default:
            MonitorTheme.running
        }
    }
}

private struct CodexRadarQuotaRowView: View {
    let row: CodexRadarQuotaRow

    var body: some View {
        HStack(spacing: 0) {
            Text(row.tier)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(MonitorTheme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(quotaText(row.fiveH))
                .font(.system(size: 10.4, weight: .semibold))
                .foregroundStyle(MonitorTheme.running)
                .lineLimit(1)
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)

            Text(quotaText(row.sevenD))
                .font(.system(size: 10.4, weight: .semibold))
                .foregroundStyle(MonitorTheme.healthy)
                .lineLimit(1)
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)

            Text(row.basis ?? "--")
                .font(.system(size: 9.2, weight: .medium))
                .foregroundStyle(MonitorTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 31)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: 0.6)
        }
    }

    private func quotaText(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }
        return String(format: "%.1f", value)
    }
}
