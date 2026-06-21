import SwiftUI

private enum RefreshPreset: String, CaseIterable, Identifiable {
    case realtime
    case balanced
    case economy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .realtime:
            "实时"
        case .balanced:
            "均衡"
        case .economy:
            "低功耗"
        }
    }

    var values: (active: TimeInterval, idle: TimeInterval, usage: TimeInterval, watcher: TimeInterval, gap: TimeInterval) {
        switch self {
        case .realtime:
            (active: 2, idle: 4, usage: 20, watcher: 8, gap: 1)
        case .balanced:
            (active: 3, idle: 6, usage: 30, watcher: 12, gap: 3)
        case .economy:
            (active: 8, idle: 20, usage: 90, watcher: 30, gap: 8)
        }
    }

    func matches(_ draft: SettingsDraft) -> Bool {
        let values = values
        return draft.activeRefreshInterval == values.active
            && draft.idleRefreshInterval == values.idle
            && draft.usageRefreshInterval == values.usage
            && draft.watcherRefreshInterval == values.watcher
            && draft.fileChangeRefreshMinimumGap == values.gap
    }

    static func matching(_ draft: SettingsDraft) -> RefreshPreset {
        allCases.first { $0.matches(draft) } ?? .balanced
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case codex
    case remoteCodex
    case newAPI
    case subAPI
    case launch

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
        case .launch:
            "启动与外观"
        }
    }

    var iconName: String {
        switch self {
        case .codex:
            "circle.grid.2x2.fill"
        case .remoteCodex:
            "network"
        case .newAPI:
            "creditcard.fill"
        case .subAPI:
            "person.2.fill"
        case .launch:
            "gearshape.fill"
        }
    }
}

private struct AccountDeleteCandidate {
    let source: BalanceMonitorSource
    let id: String
    let label: String
}

private struct SettingsDraft: Equatable {
    var activeRefreshInterval: TimeInterval = 3
    var idleRefreshInterval: TimeInterval = 6
    var usageRefreshInterval: TimeInterval = 30
    var watcherRefreshInterval: TimeInterval = 12
    var fileChangeRefreshMinimumGap: TimeInterval = 3
    var rateLimitSource: RateLimitSourcePreference = .appServerFirst
    var showPeriodUsage = true
    var taskHistoryRange: TaskHistoryRange = .threeDays
    var notchDisplaySource: NotchDisplaySource = .codex
    var remoteMonitorEnabled = false
    var remoteCodexDataSource: RemoteCodexDataSource = .cpaManagerPlus
    var cliproxyPanelURL = ""
    var cliproxyManagementKey = ""
    var cliproxyRefreshInterval: TimeInterval = 60
    var cliproxyRequestTimeout: TimeInterval = 6
    var cliproxyAllowInsecureTLS = false
    var newAPIMonitorEnabled = false
    var newAPIPanelURL = ""
    var newAPIManagementKey = ""
    var newAPIUsername = ""
    var newAPIRefreshInterval: TimeInterval = 300
    var newAPIRequestTimeout: TimeInterval = 6
    var newAPIAllowInsecureTLS = false
    var newAPIAccounts: [BalanceAccountConfiguration] = []
    var newAPIThresholds = BalanceThresholdConfiguration()
    var subAPIMonitorEnabled = false
    var subAPIPanelURL = ""
    var subAPIUsername = ""
    var subAPIManagementKey = ""
    var subAPIRefreshInterval: TimeInterval = 300
    var subAPIRequestTimeout: TimeInterval = 6
    var subAPIAllowInsecureTLS = false
    var subAPIAccounts: [BalanceAccountConfiguration] = []
    var subAPIThresholds = BalanceThresholdConfiguration()
    var launchAtLoginEnabled = false
    var enablePulse = true

    @MainActor
    init(settings: CodexNotchSettings) {
        activeRefreshInterval = settings.activeRefreshInterval
        idleRefreshInterval = settings.idleRefreshInterval
        usageRefreshInterval = settings.usageRefreshInterval
        watcherRefreshInterval = settings.watcherRefreshInterval
        fileChangeRefreshMinimumGap = settings.fileChangeRefreshMinimumGap
        rateLimitSource = settings.rateLimitSource
        showPeriodUsage = settings.showPeriodUsage
        taskHistoryRange = settings.taskHistoryRange
        notchDisplaySource = settings.notchDisplaySource
        remoteMonitorEnabled = settings.remoteMonitorEnabled
        remoteCodexDataSource = settings.remoteCodexDataSource
        cliproxyPanelURL = settings.cliproxyPanelURL
        cliproxyManagementKey = settings.cliproxyManagementKey
        cliproxyRefreshInterval = settings.cliproxyRefreshInterval
        cliproxyRequestTimeout = settings.cliproxyRequestTimeout
        cliproxyAllowInsecureTLS = settings.cliproxyAllowInsecureTLS
        newAPIMonitorEnabled = settings.newAPIMonitorEnabled
        newAPIPanelURL = settings.newAPIPanelURL
        newAPIManagementKey = settings.newAPIManagementKey
        newAPIUsername = settings.newAPIUsername
        newAPIRefreshInterval = settings.newAPIRefreshInterval
        newAPIRequestTimeout = settings.newAPIRequestTimeout
        newAPIAllowInsecureTLS = settings.newAPIAllowInsecureTLS
        newAPIAccounts = settings.balanceAccounts(for: .newAPI)
        newAPIThresholds = settings.balanceDefaultThresholds(for: .newAPI)
        subAPIMonitorEnabled = settings.subAPIMonitorEnabled
        subAPIPanelURL = settings.subAPIPanelURL
        subAPIUsername = settings.subAPIUsername
        subAPIManagementKey = settings.subAPIManagementKey
        subAPIRefreshInterval = settings.subAPIRefreshInterval
        subAPIRequestTimeout = settings.subAPIRequestTimeout
        subAPIAllowInsecureTLS = settings.subAPIAllowInsecureTLS
        subAPIAccounts = settings.balanceAccounts(for: .subAPI)
        subAPIThresholds = settings.balanceDefaultThresholds(for: .subAPI)
        launchAtLoginEnabled = settings.launchAtLoginEnabled
        enablePulse = settings.enablePulse
    }

    init() {}

    mutating func applyPreset(_ preset: RefreshPreset) {
        let values = preset.values
        activeRefreshInterval = values.active
        idleRefreshInterval = values.idle
        usageRefreshInterval = values.usage
        watcherRefreshInterval = values.watcher
        fileChangeRefreshMinimumGap = values.gap
    }

    mutating func resetRefreshDefaults() {
        applyPreset(.balanced)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: CodexNotchSettings
    @ObservedObject var remoteViewModel: RemoteMonitorViewModel
    @ObservedObject var newAPIViewModel: BalanceMonitorViewModel
    @ObservedObject var subAPIViewModel: BalanceMonitorViewModel
    let onRefresh: () -> Void

    @State private var draft = SettingsDraft()
    @State private var selectedPreset: RefreshPreset = .balanced
    @State private var selectedTab: SettingsTab = .codex
    @State private var showsAccountEditor = false
    @State private var accountEditorSource: BalanceMonitorSource?
    @State private var accountEditorID: String?
    @State private var accountEditorDraft = BalanceAccountConfiguration(source: .newAPI)
    @State private var deleteCandidate: AccountDeleteCandidate?

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                header

                Form {
                    tabContent
                }
                .formStyle(.grouped)

                footer
            }
            .padding(20)
            .frame(width: 710)
        }
        .frame(width: 900)
        .frame(minHeight: 660)
        .onAppear {
            reloadDraft()
        }
        .sheet(isPresented: $showsAccountEditor) {
            accountEditorSheet
        }
        .alert(
            "删除账号？",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                deletePendingAccount()
            }
            Button("取消", role: .cancel) {
                deleteCandidate = nil
            }
        } message: {
            Text(deleteCandidate.map { "确定删除「\($0.label)」吗？删除后需要重新添加账号和密码。" } ?? "")
        }
    }

    private var currentDraft: SettingsDraft {
        SettingsDraft(settings: settings)
    }

    private var hasChanges: Bool {
        draft != currentDraft
    }

    private var hasRemoteChanges: Bool {
        let current = currentDraft
        return draft.remoteMonitorEnabled != current.remoteMonitorEnabled
            || draft.remoteCodexDataSource != current.remoteCodexDataSource
            || draft.cliproxyPanelURL != current.cliproxyPanelURL
            || draft.cliproxyManagementKey != current.cliproxyManagementKey
            || draft.cliproxyRefreshInterval != current.cliproxyRefreshInterval
            || draft.cliproxyRequestTimeout != current.cliproxyRequestTimeout
            || draft.cliproxyAllowInsecureTLS != current.cliproxyAllowInsecureTLS
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Codex 刘海设置")
                    .font(.system(size: 18, weight: .bold))
                Text("调整刷新、数据来源和启动行为")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("设置")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 16)
                        Text(tab.title)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        selectedTab == tab ? Color.primary.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 20)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.055))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .codex:
            codexSettingsContent
        case .remoteCodex:
            remoteCodexSettingsContent
        case .newAPI:
            balanceMonitorSection(
                title: "NewAPI",
                source: .newAPI,
                enabled: $draft.newAPIMonitorEnabled,
                accounts: $draft.newAPIAccounts,
                defaultThresholds: $draft.newAPIThresholds,
                refreshInterval: $draft.newAPIRefreshInterval,
                viewModel: newAPIViewModel,
                keychainError: settings.newAPIKeychainError
            )
        case .subAPI:
            balanceMonitorSection(
                title: "Sub2API",
                source: .subAPI,
                enabled: $draft.subAPIMonitorEnabled,
                accounts: $draft.subAPIAccounts,
                defaultThresholds: $draft.subAPIThresholds,
                refreshInterval: $draft.subAPIRefreshInterval,
                viewModel: subAPIViewModel,
                keychainError: settings.subAPIKeychainError
            )
        case .launch:
            launchAndAppearanceContent
        }
    }

    @ViewBuilder
    private var codexSettingsContent: some View {
        Section("Codex 刷新") {
            HelpLabel(
                title: "刷新模式",
                help: "快速切换 Codex 运行状态、空闲状态、历史用量和文件监听的刷新频率。自定义数值后会自动变为均衡以外的配置。"
            )
            presetControls
            intervalStepper("运行中", value: $draft.activeRefreshInterval, range: 2...30, help: "检测到 Codex 正在执行任务时的状态刷新间隔。数值越小越实时，功耗也越高。")
            intervalStepper("空闲", value: $draft.idleRefreshInterval, range: 4...120, help: "Codex 没有运行中任务时的状态刷新间隔。")
            intervalStepper("历史用量", value: $draft.usageRefreshInterval, range: 15...300, help: "统计 Codex 24小时、7天、30天 token 用量的刷新间隔。")
            intervalStepper("文件监听", value: $draft.watcherRefreshInterval, range: 8...120, help: "扫描 Codex 会话文件变化的保底间隔，用于补偿文件事件丢失。")
            intervalStepper("补刷节流", value: $draft.fileChangeRefreshMinimumGap, range: 1...30, help: "文件变化很多时，连续触发刷新之间的最小间隔。")
        }

        Section("Codex 数据") {
            Picker(selection: $draft.rateLimitSource) {
                ForEach(RateLimitSourcePreference.allCases) { source in
                    Text(source.label).tag(source)
                }
            } label: {
                HelpLabel(title: "额度来源", help: "决定 Codex 5小时和7天剩余额度优先从实时接口读取，还是只使用本地记录。")
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $draft.showPeriodUsage) {
                HelpLabel(title: "显示 24小时 / 7天 / 30天", help: "控制详情页底部是否显示 Codex 三个时间窗口的 token 用量。")
            }
            Picker(selection: $draft.taskHistoryRange) {
                ForEach(TaskHistoryRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            } label: {
                HelpLabel(title: "任务范围", help: "决定 Codex 详情页任务列表读取最近多长时间内的对话。列表会在详情页中滚动显示。")
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var remoteCodexSettingsContent: some View {
        Section("CLIProxyAPI 设置") {
            Toggle(isOn: $draft.remoteMonitorEnabled) {
                HelpLabel(title: "启用 CLIProxyAPI", help: "启用后详情页会出现 CLIProxyAPI tab，用于查看 CLIProxyAPI 或 CPA Manager Plus 中的 Codex 账号状态。")
            }

            Picker(selection: $draft.remoteCodexDataSource) {
                ForEach(RemoteCodexDataSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            } label: {
                HelpLabel(title: "数据源", help: "未安装 CPA Manager Plus 时可选择 CLIProxyAPI；安装后建议选择 CPA Manager Plus，直接读取服务端巡检和用量统计。")
            }
            .pickerStyle(.segmented)
            .disabled(!draft.remoteMonitorEnabled)

            labeledTextField(
                "面板地址",
                text: $draft.cliproxyPanelURL,
                placeholder: draft.remoteCodexDataSource == .cpaManagerPlus ? "CPA Manager Plus 地址" : "CLIProxyAPI 管理面板地址",
                help: "填写管理面板地址。支持 https；本地 localhost 可使用 http。"
            )
            .disabled(!draft.remoteMonitorEnabled)

            labeledSecureField(
                "管理密钥",
                text: $draft.cliproxyManagementKey,
                placeholder: draft.remoteCodexDataSource == .cpaManagerPlus ? "CPA Manager Plus 管理密钥" : "CLIProxyAPI 管理密钥",
                help: "用于调用远程管理接口。密钥只保存到 macOS Keychain，不写入 UserDefaults。"
            )
            .disabled(!draft.remoteMonitorEnabled)

            Text("地址、认证信息和刷新配置仅在点击保存后生效。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            intervalStepper("账号刷新", value: $draft.cliproxyRefreshInterval, range: 60...3_600, help: "远程账号状态的读取间隔。CPA Manager Plus 的巡检结果由服务端产生，这里只是读取频率。")
                .disabled(!draft.remoteMonitorEnabled)
            intervalStepper("请求超时", value: $draft.cliproxyRequestTimeout, range: 3...30, help: "单个远程管理接口请求等待的最长秒数。")
                .disabled(!draft.remoteMonitorEnabled)

            Toggle(isOn: $draft.cliproxyAllowInsecureTLS) {
                HelpLabel(title: "允许不安全 TLS", help: "允许连接自签名或证书不完整的测试面板。开启后会信任该请求中的服务器证书，请只在你控制的面板上使用。")
            }
            .disabled(!draft.remoteMonitorEnabled)

            remoteStatusRow

            if let error = settings.cliproxyKeychainError {
                Text("管理密钥保存失败：\(error)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
    }

    @ViewBuilder
    private var launchAndAppearanceContent: some View {
        Section("刘海显示") {
            Picker(selection: $draft.notchDisplaySource) {
                ForEach(NotchDisplaySource.allCases) { source in
                    Text(source.label).tag(source)
                }
            } label: {
                HelpLabel(title: "显示来源", help: "选择收起状态下刘海左右区域显示哪一种监控数据。自动模式会优先显示有提醒的外部监控，否则显示 Codex。")
            }
            .pickerStyle(.menu)
        }

        Section("启动与外观") {
            Toggle(isOn: $draft.launchAtLoginEnabled) {
                HelpLabel(title: "开机自启", help: "登录 macOS 后自动启动 Codex 刘海。保存时才会调用系统启动项接口。")
            }
            Toggle(isOn: $draft.enablePulse) {
                HelpLabel(title: "运行指示灯动画", help: "控制运行中状态点和外部提醒状态点是否带轻微呼吸动画。关闭可进一步降低功耗。")
            }

            if let error = settings.launchAtLoginError {
                Text("开机自启设置失败：\(error)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
    }

    private var presetControls: some View {
        HStack(spacing: 8) {
            ForEach(RefreshPreset.allCases) { preset in
                Button {
                    selectedPreset = preset
                    draft.applyPreset(preset)
                } label: {
                    Text(preset.title)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            (selectedPreset == preset ? Color.primary.opacity(0.14) : Color.secondary.opacity(0.10)),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func intervalStepper(
        _ title: String,
        value: Binding<TimeInterval>,
        range: ClosedRange<TimeInterval>,
        help: String
    ) -> some View {
        HStack {
            HelpLabel(title: title, help: help)
            Spacer()
            Text(intervalText(value.wrappedValue))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Stepper("", value: value, in: range, step: 1)
                .labelsHidden()
        }
    }

    private func labeledTextField(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HelpLabel(title: title, help: help)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledSecureField(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HelpLabel(title: title, help: help)
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func balanceMonitorSection(
        title: String,
        source: BalanceMonitorSource,
        enabled: Binding<Bool>,
        accounts: Binding<[BalanceAccountConfiguration]>,
        defaultThresholds: Binding<BalanceThresholdConfiguration>,
        refreshInterval: Binding<TimeInterval>,
        viewModel: BalanceMonitorViewModel,
        keychainError: String?
    ) -> some View {
        Section(title) {
            Toggle(isOn: enabled) {
                HelpLabel(title: "启用 \(title)", help: balanceMonitorEnableHelp(title: title, source: source))
            }

            Text("地址、认证信息和刷新配置仅在点击保存后生效。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            intervalStepper("余额刷新", value: refreshInterval, range: 60...3_600, help: "\(title) 所有账号余额的刷新间隔。")
                .disabled(!enabled.wrappedValue)

            thresholdsEditor(
                title: "默认阈值",
                warning: Binding(
                    get: { defaultThresholds.wrappedValue.warningThreshold },
                    set: { defaultThresholds.wrappedValue.warningThreshold = $0 }
                ),
                alert: Binding(
                    get: { defaultThresholds.wrappedValue.alertThreshold },
                    set: { defaultThresholds.wrappedValue.alertThreshold = $0 }
                ),
                help: "账号没有单独设置阈值时使用这里的值。余额低于提醒阈值显示黄灯，低于告警阈值显示红灯。"
            )
            .disabled(!enabled.wrappedValue)

            balanceStatusRow(
                source: source,
                viewModel: viewModel,
                enabled: enabled.wrappedValue
            )

            if let keychainError {
                Text("认证信息保存失败：\(keychainError)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
            }
        }

        Section("\(title) 账户") {
            accountList(
                source: source,
                accounts: accounts,
                defaultThresholds: defaultThresholds.wrappedValue,
                enabled: enabled.wrappedValue
            )
        }
    }

    private func accountList(
        source: BalanceMonitorSource,
        accounts: Binding<[BalanceAccountConfiguration]>,
        defaultThresholds: BalanceThresholdConfiguration,
        enabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("账号列表")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Button {
                    startAddingAccount(source: source)
                } label: {
                    Label("添加账号", systemImage: "plus.circle.fill")
                }
                .disabled(!enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            accountListHeader

            if accounts.wrappedValue.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("还没有配置账号")
                        .font(.system(size: 12, weight: .semibold))
                    Text("点击右上角“添加账号”配置面板地址和认证信息。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ForEach(accounts.wrappedValue) { account in
                    Divider()
                    accountListRow(
                        account: account,
                        source: source,
                        defaults: defaultThresholds,
                        enabled: enabled,
                        onToggle: {
                            toggleAccountEnabled(id: account.id, source: source)
                        },
                        onEdit: {
                            startEditingAccount(source: source, account: account)
                        },
                        onDelete: {
                            deleteCandidate = AccountDeleteCandidate(
                                source: source,
                                id: account.id,
                                label: account.displayLabel
                            )
                        }
                    )
                }
            }
        }
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .disabled(!enabled)
    }

    private var accountListHeader: some View {
        HStack(spacing: 10) {
            Text("名称")
                .frame(width: 92, alignment: .leading)
            Text("面板")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("账号")
                .frame(width: 104, alignment: .leading)
            Text("阈值")
                .frame(width: 132, alignment: .leading)
            Text("操作")
                .frame(width: 118, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func accountListRow(
        account: BalanceAccountConfiguration,
        source: BalanceMonitorSource,
        defaults: BalanceThresholdConfiguration,
        enabled: Bool,
        onToggle: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayLabel)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Text(account.enabled ? "已启用" : "已停用")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(account.enabled ? Color.green : .secondary)
            }
            .frame(width: 92, alignment: .leading)

            Text(account.panelURL.isEmpty ? "未填写" : account.panelURL)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(account.panelURL.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(account.username.isEmpty ? "未填写" : account.username)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(account.username.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 104, alignment: .leading)

            Text(account.thresholdSummary(defaults: defaults))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(width: 132, alignment: .leading)

            HStack(spacing: 5) {
                Button(account.enabled ? "停用" : "启用", action: onToggle)
                Button("修改", action: onEdit)
                Button("删除", role: .destructive, action: onDelete)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5, weight: .semibold))
            .frame(width: 118, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(enabled ? 1 : 0.55)
    }

    @ViewBuilder
    private var accountEditorSheet: some View {
        if let source = accountEditorSource {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(accountEditorID == nil ? "添加 \(source.title) 账号" : "修改 \(source.title) 账号")
                            .font(.system(size: 17, weight: .bold))
                        Text("账号配置只会在点击“保存账号”后写入当前设置草稿。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Form {
                    Section("基础信息") {
                        Toggle(isOn: $accountEditorDraft.enabled) {
                            HelpLabel(title: "启用账号", help: "关闭后这个账号不会参与刷新、详情页展示或刘海提醒。")
                        }

                        labeledTextField(
                            "显示名称",
                            text: $accountEditorDraft.label,
                            placeholder: "\(source.title) 账号",
                            help: "只用于本机显示，留空时会使用登录用户名。"
                        )

                        labeledTextField(
                            "面板地址",
                            text: $accountEditorDraft.panelURL,
                            placeholder: "\(source.title) 面板地址",
                            help: "填写这个账号所在面板的地址。会自动归一化到协议、域名和端口。"
                        )

                        labeledTextField(
                            balanceUsernameTitle(source: source),
                            text: $accountEditorDraft.username,
                            placeholder: balanceUsernamePlaceholder(source: source),
                            help: balanceUsernameHelp(source: source)
                        )

                        labeledSecureField(
                            balanceCredentialTitle(source: source),
                            text: $accountEditorDraft.secret,
                            placeholder: balanceCredentialPlaceholder(source: source),
                            help: balanceCredentialHelp(source: source)
                        )
                    }

                    Section("连接与阈值") {
                        intervalStepper(
                            "请求超时",
                            value: $accountEditorDraft.requestTimeout,
                            range: 3...30,
                            help: "\(source.title) 这个账号单个接口请求等待的最长秒数。"
                        )

                        Toggle(isOn: $accountEditorDraft.allowInsecureTLS) {
                            HelpLabel(title: "允许不安全 TLS", help: "允许连接自签名或证书不完整的测试面板。请只在你控制的面板上使用。")
                        }

                        Toggle(isOn: $accountEditorDraft.usesDefaultThresholds) {
                            HelpLabel(title: "使用默认阈值", help: "开启后使用本页上方的默认提醒/告警阈值；关闭后可按这个账号单独设置。")
                        }

                        if !accountEditorDraft.usesDefaultThresholds {
                            thresholdsEditor(
                                title: "账号阈值",
                                warning: $accountEditorDraft.warningThreshold,
                                alert: $accountEditorDraft.alertThreshold,
                                help: "用于覆盖默认阈值。适合消费量差异较大的账号单独设置。"
                            )
                        }
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Button("取消") {
                        closeAccountEditor()
                    }
                    Spacer()
                    Button("保存账号") {
                        saveAccountEditor()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 560)
            .frame(minHeight: 560)
        } else {
            EmptyView()
        }
    }

    private func thresholdsEditor(
        title: String,
        warning: Binding<Double?>,
        alert: Binding<Double?>,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HelpLabel(title: title, help: help)
            thresholdFieldRow("提醒阈值", value: warning, help: "余额低于这个值时显示黄灯提醒。")
            thresholdFieldRow("告警阈值", value: alert, help: "余额低于这个值时显示红灯告警。通常应小于提醒阈值。")
            Text("留空表示不启用对应提醒。账号自定义阈值会覆盖默认阈值。")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func thresholdFieldRow(
        _ title: String,
        value: Binding<Double?>,
        help: String
    ) -> some View {
        HStack(spacing: 12) {
            HelpLabel(title: title, help: help)
            Spacer()
            TextField(
                "不设置",
                text: Binding(
                    get: {
                        guard let number = value.wrappedValue else {
                            return ""
                        }
                        return String(format: "%.2f", number)
                    },
                    set: { text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        value.wrappedValue = trimmed.isEmpty ? nil : Double(trimmed)
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1)
            .frame(width: 170, alignment: .trailing)
        }
    }

    private func normalizedAccount(_ account: BalanceAccountConfiguration, source: BalanceMonitorSource) -> BalanceAccountConfiguration {
        var copy = account
        copy.source = source
        copy.requestTimeout = min(30, max(3, copy.requestTimeout.rounded()))
        if !copy.secret.isEmpty {
            copy.secretReadFailed = false
        }
        return copy
    }

    private func accountBinding(for source: BalanceMonitorSource) -> Binding<[BalanceAccountConfiguration]> {
        switch source {
        case .newAPI:
            return $draft.newAPIAccounts
        case .subAPI:
            return $draft.subAPIAccounts
        }
    }

    private func startAddingAccount(source: BalanceMonitorSource) {
        let count = accountBinding(for: source).wrappedValue.count
        accountEditorSource = source
        accountEditorID = nil
        accountEditorDraft = BalanceAccountConfiguration(
            source: source,
            label: "\(source.title) \(count + 1)",
            requestTimeout: 6
        )
        showsAccountEditor = true
    }

    private func startEditingAccount(source: BalanceMonitorSource, account: BalanceAccountConfiguration) {
        accountEditorSource = source
        accountEditorID = account.id
        accountEditorDraft = account
        showsAccountEditor = true
    }

    private func closeAccountEditor() {
        showsAccountEditor = false
        accountEditorSource = nil
        accountEditorID = nil
        accountEditorDraft = BalanceAccountConfiguration(source: .newAPI)
    }

    private func saveAccountEditor() {
        guard let source = accountEditorSource else {
            closeAccountEditor()
            return
        }
        let accounts = accountBinding(for: source)
        if let accountEditorID {
            updateAccount(
                id: accountEditorID,
                newValue: accountEditorDraft,
                source: source,
                accounts: accounts
            )
        } else {
            accounts.wrappedValue.append(normalizedAccount(accountEditorDraft, source: source))
        }
        closeAccountEditor()
    }

    private func toggleAccountEnabled(id: String, source: BalanceMonitorSource) {
        let accounts = accountBinding(for: source)
        guard let index = accounts.wrappedValue.firstIndex(where: { $0.id == id }) else {
            return
        }
        accounts.wrappedValue[index].enabled.toggle()
    }

    private func deletePendingAccount() {
        guard let candidate = deleteCandidate else {
            return
        }
        let accounts = accountBinding(for: candidate.source)
        accounts.wrappedValue.removeAll { $0.id == candidate.id }
        deleteCandidate = nil
    }

    private func accountBindingValue(
        id: String,
        fallback: BalanceAccountConfiguration,
        accounts: Binding<[BalanceAccountConfiguration]>
    ) -> BalanceAccountConfiguration {
        accounts.wrappedValue.first { $0.id == id } ?? fallback
    }

    private func updateAccount(
        id: String,
        newValue: BalanceAccountConfiguration,
        source: BalanceMonitorSource,
        accounts: Binding<[BalanceAccountConfiguration]>
    ) {
        guard let index = accounts.wrappedValue.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldValue = accounts.wrappedValue[index]
        var copy = normalizedAccount(newValue, source: source)
        if accountSecurityContextChanged(old: oldValue, new: copy),
           copy.secret == oldValue.secret {
            copy.secret = ""
            copy.secretReadFailed = false
        }
        accounts.wrappedValue[index] = copy
    }

    private func accountSecurityContextChanged(
        old: BalanceAccountConfiguration,
        new: BalanceAccountConfiguration
    ) -> Bool {
        old.allowInsecureTLS != new.allowInsecureTLS
            || apiOrigin(from: old.panelURL) != apiOrigin(from: new.panelURL)
    }

    private func apiOrigin(from input: String) -> String? {
        guard let url = BalanceAPIClient.apiBaseURL(from: input),
              let scheme = url.scheme,
              let host = url.host else {
            return nil
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host.lowercased())\(port)"
    }

    private func balanceMonitorEnableHelp(title: String, source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            "启用后详情页会出现 \(title) tab，通过登录接口读取 NewAPI 当前用户额度。"
        case .subAPI:
            "启用后详情页会出现 \(title) tab，通过登录接口读取 Sub2API 当前用户余额和平台配额。"
        }
    }

    private func balanceUsernameTitle(source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            "用户名"
        case .subAPI:
            "登录邮箱"
        }
    }

    private func balanceUsernamePlaceholder(source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            "NewAPI 登录用户名"
        case .subAPI:
            "Sub2API 登录邮箱"
        }
    }

    private func balanceUsernameHelp(source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            "用于调用 NewAPI POST /api/user/login 登录接口。"
        case .subAPI:
            "用于调用 Sub2API POST /api/v1/auth/login 登录接口。Sub2API 当前接口要求填写邮箱格式。"
        }
    }

    private func balanceCredentialTitle(source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            "密码"
        case .subAPI:
            "密码"
        }
    }

    private func balanceCredentialPlaceholder(source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            "NewAPI 登录密码"
        case .subAPI:
            "Sub2API 登录密码"
        }
    }

    private func balanceCredentialHelp(source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            "用于调用 NewAPI POST /api/user/login。密码只保存到 macOS Keychain。"
        case .subAPI:
            "用于调用 Sub2API POST /api/v1/auth/login。密码只保存到 macOS Keychain。"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("恢复默认刷新") {
                draft.resetRefreshDefaults()
                selectedPreset = .balanced
            }

            if hasChanges {
                Text("有未保存更改")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button("立即刷新") {
                refreshSelectedTab()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("取消更改") {
                reloadDraft()
            }
            .disabled(!hasChanges)

            Button("保存") {
                saveDraft()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges)
        }
    }

    private var remoteStatusRow: some View {
        HStack {
            HelpLabel(title: "CLIProxyAPI 状态", help: "显示当前保存配置下的 CLIProxyAPI 读取状态。修改地址、认证信息或数据源后需要先保存再刷新。")
            Spacer()
            Text(hasRemoteChanges ? "保存后生效" : remoteStatusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hasRemoteChanges ? .orange : remoteStatusColor)
                .lineLimit(1)
            Button("刷新 CLIProxyAPI") {
                remoteViewModel.refreshNow()
            }
            .disabled(!settings.remoteMonitorEnabled || hasRemoteChanges)
        }
    }

    private func balanceStatusRow(
        source: BalanceMonitorSource,
        viewModel: BalanceMonitorViewModel,
        enabled: Bool
    ) -> some View {
        let hasChanges = hasBalanceChanges(for: source)
        return HStack {
            HelpLabel(title: "\(source.title) 状态", help: "显示当前保存配置下的 \(source.title) 余额读取状态。修改地址或认证信息后需要先保存再刷新。")
            Spacer()
            Text(hasChanges ? "保存后生效" : balanceStatusText(viewModel.snapshot))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hasChanges ? .orange : balanceStatusColor(viewModel.snapshot))
                .lineLimit(1)
            Button("刷新") {
                viewModel.refreshNow()
            }
            .disabled(!settings.balanceMonitorEnabled(for: source) || hasChanges || !enabled)
        }
    }

    private func hasBalanceChanges(for source: BalanceMonitorSource) -> Bool {
        let current = currentDraft
        switch source {
        case .newAPI:
            return draft.newAPIMonitorEnabled != current.newAPIMonitorEnabled
                || draft.newAPIRefreshInterval != current.newAPIRefreshInterval
                || draft.newAPIAccounts != current.newAPIAccounts
                || draft.newAPIThresholds != current.newAPIThresholds
        case .subAPI:
            return draft.subAPIMonitorEnabled != current.subAPIMonitorEnabled
                || draft.subAPIRefreshInterval != current.subAPIRefreshInterval
                || draft.subAPIAccounts != current.subAPIAccounts
                || draft.subAPIThresholds != current.subAPIThresholds
        }
    }

    private var remoteStatusText: String {
        switch remoteViewModel.snapshot.panelState {
        case .disabled:
            "未启用"
        case .notConfigured:
            "待配置"
        case .loading:
            "读取中"
        case .healthy:
            remoteViewModel.snapshot.summaryText
        case .warning:
            remoteViewModel.snapshot.summaryText
        case .error:
            remoteViewModel.snapshot.message ?? "异常"
        }
    }

    private var remoteStatusColor: Color {
        switch remoteViewModel.snapshot.panelSeverity {
        case .none:
            .secondary
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    private func balanceStatusText(_ snapshot: BalanceMonitorSnapshot) -> String {
        switch snapshot.panelState {
        case .disabled:
            "未启用"
        case .notConfigured:
            "待配置"
        case .loading:
            "读取中"
        case .healthy:
            snapshot.summaryText
        case .warning:
            snapshot.summaryText
        case .error:
            snapshot.message ?? "异常"
        }
    }

    private func balanceStatusColor(_ snapshot: BalanceMonitorSnapshot) -> Color {
        switch snapshot.panelSeverity {
        case .none:
            .secondary
        case .warning:
            .orange
        case .error:
            .red
        }
    }

    private func reloadDraft() {
        let nextDraft = currentDraft
        draft = nextDraft
        selectedPreset = .matching(nextDraft)
    }

    private func saveDraft() {
        let next = draft
        let current = currentDraft
        let managementKeyForSave = CodexNotchSettings.managementKeyForSave(
            draftKey: next.cliproxyManagementKey,
            oldPanelURL: current.cliproxyPanelURL,
            newPanelURL: next.cliproxyPanelURL,
            oldAllowsInsecureTLS: current.cliproxyAllowInsecureTLS,
            newAllowsInsecureTLS: next.cliproxyAllowInsecureTLS,
            remoteEnabled: next.remoteMonitorEnabled,
            oldDataSource: current.remoteCodexDataSource,
            newDataSource: next.remoteCodexDataSource,
            oldSavedKey: current.cliproxyManagementKey
        )
        let newAPIAccounts = sanitizedAccountsForSave(
            next.newAPIAccounts,
            current: current.newAPIAccounts,
            source: .newAPI
        )
        let subAPIAccounts = sanitizedAccountsForSave(
            next.subAPIAccounts,
            current: current.subAPIAccounts,
            source: .subAPI
        )
        if !next.remoteMonitorEnabled {
            settings.remoteMonitorEnabled = false
        }
        if !next.newAPIMonitorEnabled {
            settings.newAPIMonitorEnabled = false
        }
        if !next.subAPIMonitorEnabled {
            settings.subAPIMonitorEnabled = false
        }

        settings.activeRefreshInterval = next.activeRefreshInterval
        settings.idleRefreshInterval = next.idleRefreshInterval
        settings.usageRefreshInterval = next.usageRefreshInterval
        settings.watcherRefreshInterval = next.watcherRefreshInterval
        settings.fileChangeRefreshMinimumGap = next.fileChangeRefreshMinimumGap
        settings.rateLimitSource = next.rateLimitSource
        settings.showPeriodUsage = next.showPeriodUsage
        settings.taskHistoryRange = next.taskHistoryRange
        settings.notchDisplaySource = next.notchDisplaySource

        settings.remoteCodexDataSource = next.remoteCodexDataSource
        settings.cliproxyPanelURL = next.cliproxyPanelURL
        settings.cliproxyRefreshInterval = next.cliproxyRefreshInterval
        settings.cliproxyRequestTimeout = next.cliproxyRequestTimeout
        settings.cliproxyAllowInsecureTLS = next.cliproxyAllowInsecureTLS
        settings.cliproxyManagementKey = managementKeyForSave
        if next.remoteMonitorEnabled {
            settings.remoteMonitorEnabled = true
        }

        settings.setBalanceDefaultThresholds(next.newAPIThresholds, for: .newAPI)
        settings.setBalanceAccounts(newAPIAccounts, for: .newAPI)
        settings.newAPIPanelURL = newAPIAccounts.first?.panelURL ?? ""
        settings.newAPIUsername = next.newAPIMonitorEnabled ? (newAPIAccounts.first?.username ?? "") : ""
        settings.newAPIRefreshInterval = next.newAPIRefreshInterval
        settings.newAPIRequestTimeout = newAPIAccounts.first?.requestTimeout ?? next.newAPIRequestTimeout
        settings.newAPIAllowInsecureTLS = newAPIAccounts.first?.allowInsecureTLS ?? next.newAPIAllowInsecureTLS
        settings.newAPIManagementKey = legacyKeyForFirstAccount(
            newAPIAccounts.first,
            currentKey: current.newAPIManagementKey
        )
        if next.newAPIMonitorEnabled {
            settings.newAPIMonitorEnabled = true
        }

        settings.setBalanceDefaultThresholds(next.subAPIThresholds, for: .subAPI)
        settings.setBalanceAccounts(subAPIAccounts, for: .subAPI)
        settings.subAPIPanelURL = subAPIAccounts.first?.panelURL ?? ""
        settings.subAPIUsername = next.subAPIMonitorEnabled ? (subAPIAccounts.first?.username ?? "") : ""
        settings.subAPIRefreshInterval = next.subAPIRefreshInterval
        settings.subAPIRequestTimeout = subAPIAccounts.first?.requestTimeout ?? next.subAPIRequestTimeout
        settings.subAPIAllowInsecureTLS = subAPIAccounts.first?.allowInsecureTLS ?? next.subAPIAllowInsecureTLS
        settings.subAPIManagementKey = legacyKeyForFirstAccount(
            subAPIAccounts.first,
            currentKey: current.subAPIManagementKey
        )
        if next.subAPIMonitorEnabled {
            settings.subAPIMonitorEnabled = true
        }

        if next.launchAtLoginEnabled != settings.launchAtLoginEnabled {
            settings.setLaunchAtLoginEnabled(next.launchAtLoginEnabled)
        }
        settings.enablePulse = next.enablePulse

        selectedPreset = .matching(next)
        reloadDraft()
    }

    private func intervalText(_ value: TimeInterval) -> String {
        "\(Int(value)) 秒"
    }

    private func refreshSelectedTab() {
        switch selectedTab {
        case .codex, .launch:
            onRefresh()
        case .remoteCodex:
            remoteViewModel.refreshNow()
        case .newAPI:
            newAPIViewModel.refreshNow()
        case .subAPI:
            subAPIViewModel.refreshNow()
        }
    }

    private func sanitizedAccountsForSave(
        _ accounts: [BalanceAccountConfiguration],
        current: [BalanceAccountConfiguration],
        source: BalanceMonitorSource
    ) -> [BalanceAccountConfiguration] {
        let currentByID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { existing, _ in existing })
        return accounts.map { account in
            var copy = normalizedAccount(account, source: source)
            guard let oldAccount = currentByID[copy.id] else {
                return copy
            }
            if accountSecurityContextChanged(old: oldAccount, new: copy),
               copy.secret == oldAccount.secret {
                copy.secret = ""
                copy.secretReadFailed = false
            }
            return copy
        }
    }

    private func legacyKeyForFirstAccount(
        _ account: BalanceAccountConfiguration?,
        currentKey: String
    ) -> String {
        guard let account else {
            return ""
        }
        if account.secretReadFailed && account.secret.isEmpty {
            return currentKey
        }
        return account.secret
    }

}

private struct HelpLabel: View {
    let title: String
    let help: String
    @State private var showsHelp = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Button {
                showsHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsHelp, arrowEdge: .trailing) {
                Text(help)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 260, alignment: .leading)
            }
        }
    }
}
