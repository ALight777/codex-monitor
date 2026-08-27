# codex监测 / Codex Monitor

<p>
  <a href="#中文">中文</a> |
  <a href="#english">English</a>
</p>

<a id="中文"></a>

## 中文

codex监测是一款原生 macOS 刘海屏监测工具。它会贴合 MacBook 刘海区域，在左右两侧显示 Codex 本地运行状态、剩余额度或远程面板状态，并可以展开成类似灵动岛的详情面板。

项目当前支持本机 Codex、远程账号（CLIProxyAPI、CPA Manager Plus、Sub2API）、NewAPI 和 Sub2API 余额等多类数据源，适合需要长期观察 Codex 使用量、账号额度和远程代理面板状态的用户。

### 功能概览

- 刘海区域常驻显示：左侧状态灯，右侧关键指标。
- 支持标准与窄刘海两种收起尺寸；窄刘海只保留状态灯和额度数字，展开详情仍保持标准宽度。
- 点击刘海区域展开详情面板，再次点击外部区域可收起。
- 详情页使用多 tab 模式：`Codex`、可选 `Radar`、`远程账号`、`NewAPI`、`Sub2API`。
- 支持手动选择刘海区域显示来源，也支持自动模式优先展示有提醒的外部监控。
- 支持根据 macOS 顶部安全区和辅助菜单区自动识别物理刘海尺寸，并提供物理刘海宽度微调。
- 支持设置页独立开关每一种监控源。
- 支持刷新按钮、设置按钮、右键菜单、开机自启和运行指示灯动画。

### 本机 Codex 监测

本机 Codex 页面用于监测当前 Mac 上安装并运行的 Codex。

可显示：

- Codex 是否正在执行任务。
- Codex 当前可用额度窗口的剩余百分比；Plus 套餐显示 5h / 7d，Pro 套餐只显示 7d。
- 对应额度窗口的刷新时间。
- 周额度行显示剩余重置次数；点击旁边的信息图标，可以查看每次重置次数的到期时间。
- 正在运行和最近活动的对话列表。
- 当前活跃任务的活跃子代理数量。
- 每个对话的 token 用量和 API 等价花费估算，包含该对话下的子代理用量。
- 今日、7 天、30 天 token 用量与花费估算；“今日”按电脑当前时区的自然日计算，归档会话仍计入已消耗 token。
- Token 数字支持整块悬停和点击：悬停短暂查看、点击固定弹窗，显示未缓存输入、缓存输入和含推理输出的构成。
- 可选显示 GPT-5.3-Codex-Spark 专属额度窗口。

本机数据主要来自当前用户目录下的 Codex 数据文件，例如：

- `~/.codex/state_5.sqlite`
- `~/.codex/logs_2.sqlite`
- `~/.codex/sessions`
- 最近的 rollout JSONL 文件

应用只读取这些文件，不会修改 Codex 的本地数据。

花费按记录中的实际模型逐次套用 OpenAI 官方 API 单价，并分别计算未缓存输入、缓存输入和输出；长上下文模型按单次请求规则处理。该数字只是 API 等价估算，不是 Codex 订阅账单。若本地记录缺少构成、缓存写入 Token 或模型没有可匹配的公开价格，界面会显示不可估算或部分缺失，不会猜测单价。价格表版本会显示在用量卡片下方。

### CodexRadar

可在设置中启用独立的 `Radar` 页，展示 Codex 雷达提供的模型评分、通过数、成本、耗时、套餐额度预测与状态摘要。有 API Token 时使用授权接口，留空则使用公开摘要；数据每天北京时间 08:20 和 14:20 自动更新。

Token 使用应用现有的密钥保存方式（默认 macOS 钥匙串），不写入 UserDefaults 或 CodexRadar 响应缓存。缓存文件仅当前用户可读写。数据来自 [Codex 雷达](https://codexradar.com)。

### 远程账号监测

远程 Codex / OpenAI 账号监测支持同时配置多个数据源：

- `CLIProxyAPI`：直接读取 CLIProxyAPI 管理接口中的 Codex auth 文件和账号状态。
- `CPA Manager Plus`：读取 CPA Manager Plus 的服务端巡检结果和用量统计。
- `Sub2API`：通过管理员接口读取 Sub2API 中的 OpenAI OAuth 账号、配额状态和用量趋势。

如果你的服务端已经部署 CPA Manager Plus，建议优先使用它读取巡检结果，避免客户端重复触发账号检查。多个数据源可以并存，远程账号页会合并展示已启用来源中的账号。

远程页面可显示：

- 已启用 Codex 账号列表。
- 账号正常、配额耗尽、异常数量。
- 每个账号的套餐、索引、成功/失败次数。
- Codex 账号剩余额度；Plus 显示 5h / 7d，Pro 只显示 7d。
- CPA Manager Plus 和 Sub2API 在接口提供数据时，会在账号周额度后显示剩余重置次数，并可通过信息图标查看每次到期时间。
- 账号异常原因，例如登录过期、账号不可用、请求失败、5 小时额度已满、周额度已满等。
- CPA Manager Plus 和 Sub2API 的 24 小时、7 天、30 天总 token 用量；Sub2API 只统计当前监测到的 OpenAI OAuth 账号。
- 每个来源的用量覆盖状态、整轮最近更新时间和刷新失败说明；重复配置同一面板时，用量只计入一次。
- 单个来源失败时保留其他来源的新账号结果，并沿用失败来源的上次账号快照；总用量只有在所有应提供用量的来源都成功时才会替换。

CPA Manager Plus 的重置次数通过 `/v0/management/api-call` 管理代理读取，并按账号缓存；手动刷新会绕过该缓存，单个账号刷新失败时会沿用已有旧值。Sub2API 每轮直接读取管理员账号配额接口返回的重置次数。两种来源都不会仅因用量接口不可用而改变账号健康状态。`CLIProxyAPI` 直连模式不提供重置次数数据。

### NewAPI 和 Sub2API 余额监测

NewAPI 和 Sub2API 用于监测普通用户账号余额，而不是管理员侧的全局面板状态。

支持：

- 多账号管理。
- 每个账号单独配置面板地址、用户名、密码、请求超时和 TLS 行为。
- 默认余额阈值，也可为单个账号配置自定义阈值。
- 提醒阈值和告警阈值两级状态。
- 余额低于提醒阈值时显示黄色提醒。
- 余额低于告警阈值时显示红色告警。
- 展示账户余额、已用余额、已用 token、请求次数等面板返回的数据。
- 多币种或不同计价单位会分组汇总，无法安全相加时会显示为多币种摘要。

认证方式：

- NewAPI 使用 `POST /api/user/login` 登录，再读取用户信息。
- Sub2API 使用 `POST /api/v1/auth/login` 登录，再读取当前用户资料与余额。平台配额不会显示在余额页；管理员侧 OpenAI 账号配额归入“远程账号”监测。

### 设置

设置窗口分为以下页面：

- `Codex`：本机 Codex 刷新频率、额度来源、任务范围和历史用量显示。
- `CodexRadar`：开关、可选 API Token、数据状态和手动刷新。
- `远程账号`：管理 CLIProxyAPI、CPA Manager Plus、Sub2API 数据源及其地址、认证信息、刷新频率、请求超时和 TLS 设置。
- `NewAPI`：NewAPI 监测开关、刷新频率、默认阈值和账号列表。
- `Sub2API`：Sub2API 监测开关、刷新频率、默认阈值和账号列表。
- `启动与外观`：刘海显示大小与来源、物理刘海微调、密钥存储方式、开机自启和指示灯动画。
- `关于`：软件简介、当前版本号和监测能力说明。

设置页中的问号按钮会解释每个配置项的作用。大部分远程配置只有在点击“保存”后才会生效，避免输入密码或密钥时立即触发请求。

### 密钥存储

应用支持两种密钥存储方式：

- `钥匙串`：默认方式，安全性更高。由于当前应用是本地 ad-hoc 签名，更新应用后 macOS 可能会重新请求访问授权。
- `本机数据库`：保存在 `~/Library/Application Support/codex监测/secrets.sqlite3`，文件权限限制为当前用户可读写。它可以减少钥匙串授权弹窗，但安全性低于钥匙串。

切换存储方式时，应用会把当前已保存的密钥迁移到新的存储位置。请不要把本机数据库文件提交到 GitHub 或分享给他人。

### 构建和运行

要求：

- macOS 14 或更高版本。
- Swift 6 toolchain / Xcode Command Line Tools。

直接运行：

```bash
swift run CodexNotch
```

构建 release：

```bash
swift build -c release
```

构建可双击运行的 `.app` 和 `.dmg`：

```bash
./scripts/build-app.sh
```

DMG 会输出到 `dist/`，文件名包含软件名、版本号和支持架构，例如：

```text
dist/codex-monitor-0.1.12-arm64.dmg
dist/codex-monitor-0.1.12-amd64.dmg
```

安装到当前用户的 Applications 目录：

```bash
./scripts/install-user-app.sh
```

安装脚本会复制到：

```text
~/Applications/codex监测.app
```

因此本机更新通常不需要管理员密码。

### 调试命令

打印完整本机快照：

```bash
.build/release/CodexNotch --print-snapshot
```

该输出是人类可读格式，`task=` 行保持兼容：最后一列仍为 token 数。

打印快速快照：

```bash
.build/release/CodexNotch --print-fast-snapshot
```

打印稳定 JSON 快照，包含 `usage_today`、`spark_quota_windows` 以及每个任务的 `subagents` 活跃子代理数量：

```bash
.build/release/CodexNotch --print-snapshot-json
```

快速 JSON 快照：

```bash
.build/release/CodexNotch --print-fast-snapshot-json
```

运行回归测试：

```bash
./scripts/run-regression-tests.sh
```

### 注意事项

- 本项目当前面向 MacBook 刘海屏设计。在无刘海屏或外接显示器上也可以运行，但视觉位置可能需要按实际设备调整。
- 刘海尺寸会优先根据 macOS 暴露的顶部安全区和辅助菜单区自动推断。如果系统、缩放模式或机型导致识别偏宽或偏窄，可以在设置页使用“物理刘海微调”校准。
- 本机 Codex 的额度和任务状态依赖 Codex 本地数据文件。如果 Codex 改变文件结构，可能需要同步适配。
- CPA Manager Plus 模式读取的是服务端巡检结果。服务端巡检频率由 CPA Manager Plus 自身配置决定，客户端刷新只是读取最新结果。
- 账号重置次数由 CPA Manager Plus 或 Sub2API 在接口提供时显示；CLIProxyAPI 直连模式不会查询或展示该数据。
- `允许不安全 TLS` 会信任自签名或证书不完整的面板证书。请只在你控制的测试环境中启用。
- 当前构建脚本使用 ad-hoc 签名，适合本机使用。如果要公开发布给其他用户，建议使用 Apple Developer ID 签名并进行 notarization。
- 请不要把任何真实面板地址、管理密钥、账号密码或本机密钥数据库提交到公开仓库。

### 项目结构

```text
Sources/CodexNotch/              应用源码
Tests/CodexNotchRegressionTests/ 回归测试
scripts/build-app.sh             构建 .app 和 .dmg
scripts/install-user-app.sh      安装到 ~/Applications
scripts/run-regression-tests.sh  运行回归测试
```

<a id="english"></a>

## English

Codex Monitor is a native macOS notch overlay for monitoring Codex activity, local usage, and several remote account panels. It sits around the MacBook notch like a compact dynamic island, showing a small status indicator on the left and key metrics on the right.

The app currently supports local Codex telemetry, remote accounts through CLIProxyAPI, CPA Manager Plus, and Sub2API, plus NewAPI and Sub2API balance monitoring. It is designed for users who want a persistent, low-friction view of Codex activity, quota status, and remote account balances.

### Features

- Persistent notch overlay with left-side status and right-side metrics.
- Standard and narrow collapsed sizes; narrow mode keeps only the status light and quota values while the expanded detail panel remains full width.
- Click to expand a dynamic-island-style detail panel.
- Multi-tab detail panel: `Codex`, optional `Radar`, `Remote Accounts`, `NewAPI`, and `Sub2API`.
- Per-source enable/disable switches.
- Manual or automatic notch display source selection.
- Automatic physical notch size inference from macOS safe-area and auxiliary menu-bar geometry, with a manual notch-width adjustment when needed.
- Manual refresh buttons, settings button, context menu, launch at login, and optional pulse animation.

### Local Codex Monitoring

The Codex tab monitors the Codex installation on the current Mac.

It can show:

- Whether Codex is currently running a task.
- Remaining percentages for currently available Codex quota windows: Plus shows 5h / 7d, while Pro shows 7d only.
- Refresh times for the displayed quota windows.
- Remaining reset-credit count on the weekly quota row; click the adjacent information icon to view each credit's expiry time.
- Running and recent conversations.
- Active subagent count for currently running tasks.
- Token usage and API-equivalent cost per conversation, including subagent usage under the same conversation.
- Today, 7-day, and 30-day token totals with estimated API-equivalent cost.
- Hover or click the enlarged token target to inspect uncached input, cached input, and output including reasoning; clicking pins the popover.
- Today, 7-day, and 30-day token usage totals. Today starts at midnight in the Mac's current time zone, and archived conversations remain part of consumed-token totals.
- Optional GPT-5.3-Codex-Spark quota windows.

Local data is read from Codex files under the current user account, including:

- `~/.codex/state_5.sqlite`
- `~/.codex/logs_2.sqlite`
- `~/.codex/sessions`
- recent rollout JSONL files

The app reads these files only. It does not modify local Codex data.

Costs are estimated per recorded request using the matching official OpenAI API model price, with uncached input, cached input, output, and supported long-context rules calculated separately. This is an API-equivalent estimate, not Codex subscription billing. Missing component data, cache-write tokens, or an unknown public model price remains explicitly unavailable rather than being guessed. The pricing snapshot date appears below the local usage cells.

### CodexRadar

The optional `Radar` tab shows model scores, pass counts, cost, duration, plan-quota estimates, and status summaries from Codex Radar. It uses the authorized endpoint when an API token is configured and the public summary otherwise. Refreshes are scheduled for 08:20 and 14:20 Beijing time each day.

The API token uses the app's existing secret-storage mode (macOS Keychain by default) and is not written to UserDefaults or the CodexRadar response cache. Cache files are restricted to the current user. Data comes from [Codex Radar](https://codexradar.com).

### Remote Account Monitoring

Remote Codex / OpenAI account monitoring supports multiple data sources at the same time:

- `CLIProxyAPI`: reads Codex auth files and account status directly from the CLIProxyAPI management API.
- `CPA Manager Plus`: reads server-side inspection results and usage analytics from CPA Manager Plus.
- `Sub2API`: reads OpenAI OAuth accounts, quota status, and usage trends through Sub2API administrator APIs.

If CPA Manager Plus is available, it is recommended for account inspections because the app can reuse server-side results instead of repeatedly checking every account from the client. Multiple enabled sources are merged into one remote-account view.

The remote tab can show:

- Enabled Codex accounts.
- Healthy, quota-exhausted, and abnormal account counts.
- Plan, account index, success count, and failure count.
- Remaining quota per Codex account: Plus shows 5h / 7d, while Pro shows 7d only.
- Remaining reset credits after each account's weekly quota when CPA Manager Plus or Sub2API provides them, with an information popover listing their expiry times.
- Clear status reasons such as expired login, unavailable account, request failures, 5-hour quota exhausted, and weekly quota exhausted.
- CPA Manager Plus and Sub2API total token usage for 24 hours, 7 days, and 30 days. Sub2API totals include only the monitored OpenAI OAuth accounts.
- Per-source usage coverage, the latest whole-refresh timestamp, and refresh-failure details. Duplicate configurations for the same panel contribute usage only once.
- If one source fails, successful sources still update while the failed source keeps its previous account snapshot. Aggregate usage is replaced only after every usage-capable source succeeds.

CPA Manager Plus reset-credit data is retrieved through its `/v0/management/api-call` management proxy and cached per account. Manual refresh bypasses that cache, while a single-account refresh failure retains the last known value. Sub2API reads reset-credit fields directly from its administrator quota endpoint on every refresh. For either source, a usage-endpoint failure alone does not change account health. Direct `CLIProxyAPI` mode does not provide reset-credit data.

### NewAPI and Sub2API Balance Monitoring

NewAPI and Sub2API monitoring is intended for normal user accounts, not global administrator dashboards.

Supported capabilities:

- Multiple accounts per source.
- Per-account panel URL, username, password, timeout, and TLS behavior.
- Default balance thresholds with optional per-account custom thresholds.
- Two-level threshold status: warning and alert.
- Yellow warning when the balance falls below the warning threshold.
- Red alert when the balance falls below the alert threshold.
- Balance, used amount, used tokens, request count, and other supported panel fields.
- Multi-currency or mixed-unit summaries are grouped instead of being incorrectly added together.

Authentication:

- NewAPI uses `POST /api/user/login`, then reads user information.
- Sub2API uses `POST /api/v1/auth/login`, then reads the current user's profile and balance. Platform quota entries are excluded from the balance tab; administrator-side OpenAI account quota belongs to Remote Account Monitoring.

### Settings

The settings window is split into these tabs:

- `Codex`: local refresh intervals, quota source, task range, and period usage display.
- `CodexRadar`: enablement, optional API token, data status, and manual refresh.
- `Remote Accounts`: manages CLIProxyAPI, CPA Manager Plus, and Sub2API sources, including URLs, credentials, refresh interval, timeout, and TLS settings.
- `NewAPI`: NewAPI monitoring, refresh interval, default thresholds, and account list.
- `Sub2API`: Sub2API monitoring, refresh interval, default thresholds, and account list.
- `Launch & Appearance`: notch display size and source, physical notch adjustment, secret storage mode, launch at login, and pulse animation.
- `About`: app summary, current version, and supported monitoring sources.

Question-mark buttons next to setting labels explain what each option does. Most remote settings take effect only after clicking Save, so typing passwords or keys does not immediately trigger network requests.

### Secret Storage

The app supports two secret storage modes:

- `Keychain`: the default and more secure option. Because the app is currently ad-hoc signed, macOS may ask for Keychain access again after app updates.
- `Local database`: stores secrets in `~/Library/Application Support/codex监测/secrets.sqlite3` with current-user-only file permissions. This reduces Keychain prompts, but is less secure than Keychain.

When switching storage modes, the app migrates currently saved secrets into the selected store. Do not commit or share the local secret database.

### Build and Run

Requirements:

- macOS 14 or later.
- Swift 6 toolchain / Xcode Command Line Tools.

Run directly:

```bash
swift run CodexNotch
```

Build release binary:

```bash
swift build -c release
```

Build a double-clickable `.app` and `.dmg`:

```bash
./scripts/build-app.sh
```

The DMG is written to `dist/` with the app name, version, and supported architecture in the filename, for example:

```text
dist/codex-monitor-0.1.12-arm64.dmg
dist/codex-monitor-0.1.12-amd64.dmg
```

Install into the current user's Applications folder:

```bash
./scripts/install-user-app.sh
```

The install script copies the app to:

```text
~/Applications/codex监测.app
```

Local updates usually do not require an administrator password.

### Debug Commands

Print a full local snapshot:

```bash
.build/release/CodexNotch --print-snapshot
```

This is human-readable output. For compatibility, `task=` lines still end with the token count.

Print a fast local snapshot:

```bash
.build/release/CodexNotch --print-fast-snapshot
```

Print a stable JSON snapshot, including `usage_today`, `spark_quota_windows`, and each task's `subagents` active subagent count:

```bash
.build/release/CodexNotch --print-snapshot-json
```

Print a fast JSON snapshot:

```bash
.build/release/CodexNotch --print-fast-snapshot-json
```

Run regression tests:

```bash
./scripts/run-regression-tests.sh
```

### Notes

- The UI is designed for MacBook displays with a physical notch. It can run on external or non-notched displays, but visual positioning may need adjustment.
- Notch dimensions are inferred from macOS safe-area and auxiliary menu-bar geometry. If a macOS version, display scaling mode, or MacBook model reports imperfect geometry, use the physical notch adjustment setting to fine-tune the center mask.
- Local Codex monitoring depends on Codex's local data files. If Codex changes its file format, the app may need an update.
- CPA Manager Plus mode reads server-side inspection results. The inspection frequency is controlled by CPA Manager Plus, while this app only controls how often it reads the latest result.
- Account reset credits are shown when CPA Manager Plus or Sub2API provides them; direct CLIProxyAPI mode does not query or display them.
- `Allow insecure TLS` trusts self-signed or incomplete certificates for the configured panel request. Use it only for testing environments you control.
- The current build script uses ad-hoc signing, which is suitable for local use. For public distribution, use Apple Developer ID signing and notarization.
- Never commit real panel URLs, management keys, account passwords, or local secret database files to a public repository.

### Repository Layout

```text
Sources/CodexNotch/              App source
Tests/CodexNotchRegressionTests/ Regression tests
scripts/build-app.sh             Build .app and .dmg
scripts/install-user-app.sh      Install to ~/Applications
scripts/run-regression-tests.sh  Run regression tests
```
