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
    var subAPIMonitorEnabled = false
    var subAPIPanelURL = ""
    var subAPIUsername = ""
    var subAPIManagementKey = ""
    var subAPIRefreshInterval: TimeInterval = 300
    var subAPIRequestTimeout: TimeInterval = 6
    var subAPIAllowInsecureTLS = false
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
        subAPIMonitorEnabled = settings.subAPIMonitorEnabled
        subAPIPanelURL = settings.subAPIPanelURL
        subAPIUsername = settings.subAPIUsername
        subAPIManagementKey = settings.subAPIManagementKey
        subAPIRefreshInterval = settings.subAPIRefreshInterval
        subAPIRequestTimeout = settings.subAPIRequestTimeout
        subAPIAllowInsecureTLS = settings.subAPIAllowInsecureTLS
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Form {
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

                Section("CLIProxyAPI 设置") {
                    Toggle(isOn: $draft.remoteMonitorEnabled) {
                        HelpLabel(title: "启用 CLIProxyAPI", help: "启用后详情页会出现 CLIProxyAPI tab，用于查看 CLIProxyAPI 或 CPA Manager Plus 中的 Codex 账号状态。")
                    }

                    Picker(selection: $draft.remoteCodexDataSource) {
                        ForEach(RemoteCodexDataSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    } label: {
                        HelpLabel(title: "数据源", help: "CLIProxyAPI 适合只读取账号状态；CPA Manager Plus 会使用服务端巡检和持久用量统计。")
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

                    intervalStepper("账号刷新", value: $draft.cliproxyRefreshInterval, range: 60...3_600, help: "CLIProxyAPI 账号状态的刷新间隔。CPA Manager Plus 的巡检结果由服务端产生，这里只是读取频率。")
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

                balanceMonitorSection(
                    title: "NewAPI",
                    source: .newAPI,
                    enabled: $draft.newAPIMonitorEnabled,
                    panelURL: $draft.newAPIPanelURL,
                    managementKey: $draft.newAPIManagementKey,
                    loginUsername: $draft.newAPIUsername,
                    refreshInterval: $draft.newAPIRefreshInterval,
                    requestTimeout: $draft.newAPIRequestTimeout,
                    allowInsecureTLS: $draft.newAPIAllowInsecureTLS,
                    viewModel: newAPIViewModel,
                    keychainError: settings.newAPIKeychainError
                )

                balanceMonitorSection(
                    title: "Sub2API",
                    source: .subAPI,
                    enabled: $draft.subAPIMonitorEnabled,
                    panelURL: $draft.subAPIPanelURL,
                    managementKey: $draft.subAPIManagementKey,
                    loginUsername: $draft.subAPIUsername,
                    refreshInterval: $draft.subAPIRefreshInterval,
                    requestTimeout: $draft.subAPIRequestTimeout,
                    allowInsecureTLS: $draft.subAPIAllowInsecureTLS,
                    viewModel: subAPIViewModel,
                    keychainError: settings.subAPIKeychainError
                )

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
            .formStyle(.grouped)

            footer
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            reloadDraft()
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

    private func balanceMonitorSection(
        title: String,
        source: BalanceMonitorSource,
        enabled: Binding<Bool>,
        panelURL: Binding<String>,
        managementKey: Binding<String>,
        loginUsername: Binding<String>? = nil,
        refreshInterval: Binding<TimeInterval>,
        requestTimeout: Binding<TimeInterval>,
        allowInsecureTLS: Binding<Bool>,
        viewModel: BalanceMonitorViewModel,
        keychainError: String?
    ) -> some View {
        Section(title) {
            Toggle(isOn: enabled) {
                HelpLabel(title: "启用 \(title)", help: balanceMonitorEnableHelp(title: title, source: source))
            }

            labeledTextField(
                "面板地址",
                text: panelURL,
                placeholder: "\(title) 面板地址",
                help: "填写 \(title) 的面板地址。会自动归一化到协议、域名和端口。"
            )
            .disabled(!enabled.wrappedValue)

            if let loginUsername {
                labeledTextField(
                    balanceUsernameTitle(source: source),
                    text: loginUsername,
                    placeholder: balanceUsernamePlaceholder(source: source),
                    help: balanceUsernameHelp(source: source)
                )
                .disabled(!enabled.wrappedValue)
            }

            labeledSecureField(
                balanceCredentialTitle(source: source),
                text: managementKey,
                placeholder: balanceCredentialPlaceholder(source: source),
                help: balanceCredentialHelp(source: source)
            )
            .disabled(!enabled.wrappedValue)

            Text("地址、认证信息和刷新配置仅在点击保存后生效。")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            intervalStepper("余额刷新", value: refreshInterval, range: 60...3_600, help: "\(title) 余额和渠道列表的刷新间隔。")
                .disabled(!enabled.wrappedValue)
            intervalStepper("请求超时", value: requestTimeout, range: 3...30, help: "\(title) 单个接口请求等待的最长秒数。")
                .disabled(!enabled.wrappedValue)

            Toggle(isOn: allowInsecureTLS) {
                HelpLabel(title: "允许不安全 TLS", help: "允许连接自签名或证书不完整的测试面板。请只在你控制的面板上使用。")
            }
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
    }

    private func balanceMonitorEnableHelp(title: String, source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            "启用后详情页会出现 \(title) tab，通过登录接口读取 NewAPI 当前用户额度和渠道余额。"
        case .subAPI:
            "启用后详情页会出现 \(title) tab，通过登录接口读取 Sub2API 当前用户余额和平台配额。"
        }
    }

    private func balanceUsernameTitle(source: BalanceMonitorSource) -> String {
        switch source {
        case .newAPI:
            "用户名"
        case .subAPI:
            "用户名/邮箱"
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
            "用于调用 Sub2API POST /api/v1/auth/login 登录接口。Sub2API 当前登录字段名是 email。"
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
                onRefresh()
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
                || draft.newAPIPanelURL != current.newAPIPanelURL
                || draft.newAPIManagementKey != current.newAPIManagementKey
                || draft.newAPIUsername != current.newAPIUsername
                || draft.newAPIRefreshInterval != current.newAPIRefreshInterval
                || draft.newAPIRequestTimeout != current.newAPIRequestTimeout
                || draft.newAPIAllowInsecureTLS != current.newAPIAllowInsecureTLS
        case .subAPI:
            return draft.subAPIMonitorEnabled != current.subAPIMonitorEnabled
                || draft.subAPIPanelURL != current.subAPIPanelURL
                || draft.subAPIManagementKey != current.subAPIManagementKey
                || draft.subAPIUsername != current.subAPIUsername
                || draft.subAPIRefreshInterval != current.subAPIRefreshInterval
                || draft.subAPIRequestTimeout != current.subAPIRequestTimeout
                || draft.subAPIAllowInsecureTLS != current.subAPIAllowInsecureTLS
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
        let newAPIKeyForSave = CodexNotchSettings.apiKeyForSave(
            draftKey: next.newAPIManagementKey,
            oldPanelURL: current.newAPIPanelURL,
            newPanelURL: next.newAPIPanelURL,
            oldAllowsInsecureTLS: current.newAPIAllowInsecureTLS,
            newAllowsInsecureTLS: next.newAPIAllowInsecureTLS,
            enabled: next.newAPIMonitorEnabled,
            oldSavedKey: current.newAPIManagementKey
        )
        let subAPIKeyForSave = CodexNotchSettings.apiKeyForSave(
            draftKey: next.subAPIManagementKey,
            oldPanelURL: current.subAPIPanelURL,
            newPanelURL: next.subAPIPanelURL,
            oldAllowsInsecureTLS: current.subAPIAllowInsecureTLS,
            newAllowsInsecureTLS: next.subAPIAllowInsecureTLS,
            enabled: next.subAPIMonitorEnabled,
            oldSavedKey: current.subAPIManagementKey
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

        settings.newAPIPanelURL = next.newAPIPanelURL
        settings.newAPIUsername = next.newAPIMonitorEnabled ? next.newAPIUsername : ""
        settings.newAPIRefreshInterval = next.newAPIRefreshInterval
        settings.newAPIRequestTimeout = next.newAPIRequestTimeout
        settings.newAPIAllowInsecureTLS = next.newAPIAllowInsecureTLS
        settings.newAPIManagementKey = newAPIKeyForSave
        if next.newAPIMonitorEnabled {
            settings.newAPIMonitorEnabled = true
        }

        settings.subAPIPanelURL = next.subAPIPanelURL
        settings.subAPIUsername = next.subAPIMonitorEnabled ? next.subAPIUsername : ""
        settings.subAPIRefreshInterval = next.subAPIRefreshInterval
        settings.subAPIRequestTimeout = next.subAPIRequestTimeout
        settings.subAPIAllowInsecureTLS = next.subAPIAllowInsecureTLS
        settings.subAPIManagementKey = subAPIKeyForSave
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
