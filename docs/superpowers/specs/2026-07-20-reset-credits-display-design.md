# Codex 额度重置次数显示设计

## 目标

在 Codex 本机详情页和 CPA Manager Plus 账号详情中显示可用的额度重置次数，并通过信息气泡展示每次重置资格的到期时间。主界面使用明确文案“剩余重置次数：N”，避免“重置 N 次”被误解为已经执行过的重置次数。

## 范围

- 本机 Codex 额度数据读取与展示。
- CPA Manager Plus 模式下各 Codex 账号的重置次数读取与展示。
- 重置次数的缓存、手动刷新、失败保留和过期过滤。
- Codex 与 CPA 详情页中的信息气泡交互。

以下内容不在本次范围内：

- 执行额度重置操作。
- 修改 CPA Manager Plus 服务端或巡检数据库结构。
- 在纯 CLIProxyAPI 数据源模式中读取重置次数。
- 为重置次数增加独立设置项。

## 数据来源

### 本机 Codex

继续通过 Codex app-server 的 `account/rateLimits/read` 方法读取额度。响应中的 `rateLimitResetCredits` 提供：

- `availableCount`：当前剩余可用次数。
- `credits`：每个重置资格的 `id`、`status`、`resetType` 和 `expiresAt`。

只接收 `status = available` 且 `resetType` 表示 Codex rate limit 的记录。已经过期、已消费或类型不匹配的记录不参与展示。

### CPA Manager Plus

CPA Manager Plus 的服务端巡检结果目前只持久化额度窗口，不包含重置次数。本应用不直接访问 OpenAI，而是复用 CPA Manager Plus 自身的管理代理：

1. 从已有账号列表取得 `authIndex` 和可选的 ChatGPT account ID。
2. 调用 CPA Manager Plus 的管理 API 代理请求。
3. 由 CPA Manager Plus 使用账号认证请求 Codex reset credits 接口。
4. 本应用解析 CPA Manager Plus 返回的 `body` 或 `bodyText`。

请求头与 CPA Manager Plus 网页保持一致，包括账号 ID、`OpenAI-Beta: codex-1` 和 `Originator: Codex Desktop`。

## 数据模型

新增统一的重置资格模型：

- `RateLimitResetCredit`
  - `id: String`
  - `expiresAt: Date`
- `RateLimitResetCredits`
  - `availableCount: Int`
  - `credits: [RateLimitResetCredit]`
  - `fetchedAt: Date`

本机 `UsageSnapshot` 保存一份 `RateLimitResetCredits?`。远程 `RemoteCodexAccount` 保存账号级 `RateLimitResetCredits?`。到期时间列表按时间升序排列。

`availableCount` 以接口返回值为准；若接口未返回次数但返回了有效的可用记录，则使用有效记录数。次数不得小于零。

## 刷新与缓存

### 本机

本机重置次数随现有 app-server 额度读取一起更新，不增加额外请求。

### CPA Manager Plus

- 每个账号单独缓存，缓存键优先使用稳定账号索引。
- 缓存有效期为 60 分钟。
- 自动状态刷新在缓存有效期内不重复请求。
- CPA 页面手动刷新会绕过缓存，重新读取全部可查询账号。
- 同时最多查询 2 个账号，避免大量账号造成瞬时网络和 CPU 峰值。
- 账号缺少 `authIndex` 时跳过重置次数查询，不影响原有额度和状态。

## 界面设计

### Codex 详情页

在 `7d` 额度刷新行的现有额度和刷新时间之后追加：

`剩余重置次数：3  ⓘ`

次数使用等宽数字。只有存在可用到期明细时才显示信息图标。

### CPA Manager Plus 详情页

在账号卡片的 `7d` 额度后追加同样内容：

`5h 98%  7d 85%  剩余重置次数：3  ⓘ`

该信息属于账号级数据，不绑定到某个额度窗口，但视觉上紧随 `7d` 展示。

### 信息气泡

点击信息图标后使用原生 SwiftUI popover 展示：

- 标题：`重置次数到期时间`
- 明细：`第 1 次  2026/07/27 07:56`
- 按到期时间从近到远排列。
- 使用系统时区和 `yyyy/MM/dd HH:mm` 格式。
- 点击气泡外部自动关闭。

次数为 `0` 时显示 `剩余重置次数：0`，不显示信息图标。次数存在但没有可用明细时仍显示次数，不显示信息图标。

## 错误处理

- 本机响应缺少 `rateLimitResetCredits`：隐藏重置次数区域，不影响额度窗口。
- CPA 查询失败但有旧缓存：保留上次有效结果，不改变账号健康状态。
- CPA 查询失败且没有旧缓存：隐藏重置次数区域，不将账号判为异常。
- 单个账号查询失败：其他账号继续刷新。
- 返回格式无效：按查询失败处理。
- 到期记录已过期：过滤，不进入气泡。
- 接口次数与有效明细数量不同：主界面显示接口次数，气泡只显示可验证的有效到期记录。

## 组件边界

- `CodexUsageStore`：解析本机 app-server 重置次数。
- `CLIProxyAPIClient`：通过 CPA Manager Plus 管理代理读取账号重置次数。
- `RemoteMonitorViewModel`：控制 CPA 缓存、并发、手动刷新和旧值保留。
- `Models` / `RemoteMonitorModels`：承载统一数据模型。
- `NotchIslandView`：渲染行内文案、信息图标和 popover。

数据解析与 UI 格式化保持分离，popover 不负责过滤或推导数据。

## 验证

- 解码 app-server 的 camelCase 和可能出现的 snake_case 字段。
- 验证只保留 available、Codex 类型且未过期的记录。
- 验证接口次数缺失时回退到有效记录数。
- 验证 CPA 管理代理的 `body`、`bodyText` 两种响应。
- 验证 CPA 单账号失败不影响其他账号。
- 验证自动刷新命中缓存，手动刷新绕过缓存。
- 验证失败时保留旧数据，首次失败时隐藏重置次数。
- 验证次数为 0、无明细、有多条明细时的显示规则。
- 运行回归测试、Release 构建和本地安装版验收。

## 成功标准

- 本机 Codex 详情页显示真实剩余重置次数和到期时间。
- CPA Manager Plus 账号行显示各账号真实剩余重置次数和到期时间。
- 自动刷新不会每分钟为所有 CPA 账号重复查询重置次数。
- 重置次数查询失败不会导致账号状态误报或清空已知数据。
- 新内容不造成 Codex 顶部额度行或 CPA 账号卡片溢出。
