# Reset Credits Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display remaining Codex rate-limit reset credits and their expiry times in the local Codex detail row and each CPA Manager Plus account row.

**Architecture:** Add one shared reset-credit value model and decoder, then propagate it through the existing local `RateLimitSnapshot` and remote `RemoteCodexAccount` pipelines. Local data comes from the existing app-server response; remote data is fetched through CPA Manager Plus's `api-call` management proxy, enriched with a one-hour per-account cache, and rendered by one reusable SwiftUI indicator/popover component.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, Foundation `URLSession`, Swift Package Manager, existing executable regression suite.

---

## File Structure

- Create `Sources/CodexNotch/RateLimitResetCredits.swift`: shared models, flexible decoder, expiry filtering, display formatter.
- Create `Sources/CodexNotch/RemoteResetCreditsLoader.swift`: thread-safe one-hour cache, two-at-a-time account enrichment, stale-value fallback.
- Create `Sources/CodexNotch/ResetCreditsIndicator.swift`: shared inline label, information button, and native popover.
- Modify `Sources/CodexNotch/Models.swift`: attach reset-credit data to local usage and rate-limit snapshots.
- Modify `Sources/CodexNotch/CodexUsageStore.swift`: decode app-server `rateLimitResetCredits` and propagate it through fast snapshots.
- Modify `Sources/CodexNotch/RemoteMonitorModels.swift`: attach account-level reset-credit data and preserve it during quota merges.
- Modify `Sources/CodexNotch/CLIProxyAPIClient.swift`: call CPA Manager Plus's management proxy and decode reset-credit responses.
- Modify `Sources/CodexNotch/RemoteMonitorViewModel.swift`: enrich CPA accounts, force refresh on manual action, retain cache across automatic refreshes.
- Modify `Sources/CodexNotch/NotchIslandView.swift`: add the indicator to the local 7d line and CPA account quota line without increasing card height.
- Modify `Sources/CodexNotch/SnapshotOutputFormatter.swift`: expose local reset-credit data in diagnostic JSON.
- Modify `Tests/CodexNotchRegressionTests/main.swift`: cover decoding, filtering, propagation, cache behavior, and display formatting.
- Modify `README.md`: document local and CPA reset-credit display behavior.

### Task 1: Shared Reset-Credit Model and Decoder

**Files:**
- Create: `Sources/CodexNotch/RateLimitResetCredits.swift`
- Test: `Tests/CodexNotchRegressionTests/main.swift`

- [x] **Step 1: Write failing decoder and formatter tests**

Add tests with both app-server camelCase epoch timestamps and CPA snake_case ISO-8601 timestamps:

```swift
let resetNow = Date(timeIntervalSince1970: 1_784_500_000)
let appServerCreditsJSON = Data(#"""
{
  "availableCount": 3,
  "credits": [
    {"id":"late","resetType":"codexRateLimits","status":"available","expiresAt":1786557546},
    {"id":"early","resetType":"codexRateLimits","status":"available","expiresAt":1785110188},
    {"id":"used","resetType":"codexRateLimits","status":"consumed","expiresAt":1785525156}
  ]
}
"""#.utf8)
let decodedAppServerCredits = try RateLimitResetCreditsDecoder.decode(appServerCreditsJSON, now: resetNow)
runner.check(decodedAppServerCredits?.availableCount == 3, "reset credit count should use the service value")
runner.check(decodedAppServerCredits?.credits.map(\.id) == ["early", "late"], "available reset credits should be sorted by expiry")

let cpaCreditsJSON = Data(#"""
{
  "available_count": "1",
  "credits": [
    {"id":"cpa","reset_type":"codex_rate_limits","status":"available","expires_at":"2026-08-01T03:12:00Z"}
  ]
}
"""#.utf8)
let decodedCPACredits = try RateLimitResetCreditsDecoder.decode(cpaCreditsJSON, now: resetNow)
runner.check(decodedCPACredits?.availableCount == 1, "CPA reset credit count should decode numeric strings")
runner.check(decodedCPACredits?.credits.count == 1, "CPA reset credit expiry should decode ISO-8601")
runner.check(
    RateLimitResetCreditsFormatter.expiryText(decodedCPACredits!.credits[0].expiresAt, timeZone: TimeZone(secondsFromGMT: 0)!) == "2026/08/01 03:12",
    "reset credit expiry should use the agreed full date format"
)
```

- [x] **Step 2: Run the regression suite and confirm the tests fail**

Run: `./scripts/run-regression-tests.sh`

Expected: compilation fails because `RateLimitResetCreditsDecoder` and the shared models do not exist.

- [x] **Step 3: Implement the shared model and flexible decoder**

Create these public-to-module contracts:

```swift
struct RateLimitResetCredit: Equatable, Identifiable, Sendable {
    let id: String
    let expiresAt: Date
}

struct RateLimitResetCredits: Equatable, Sendable {
    let availableCount: Int
    let credits: [RateLimitResetCredit]
    let fetchedAt: Date

    var hasExpiryDetails: Bool { !credits.isEmpty }
}

enum RateLimitResetCreditsDecoder {
    static func decode(_ data: Data, now: Date = Date()) throws -> RateLimitResetCredits?
}

enum RateLimitResetCreditsFormatter {
    static func expiryText(_ date: Date, timeZone: TimeZone = .current) -> String
}
```

The decoder must:

- accept `availableCount` and `available_count` as numbers or strings;
- accept `resetType` and `reset_type`;
- treat `codexRateLimits` and `codex_rate_limits` as the same normalized type;
- accept `expiresAt` and `expires_at` as epoch seconds or ISO-8601 strings;
- retain only `status == available`, matching type, and `expiresAt > now`;
- sort retained rows by `expiresAt`, then `id`;
- use the valid row count only when the payload omits `availableCount`;
- clamp a returned count below zero to zero;
- return `nil` when neither a count nor a `credits` field is present.

- [x] **Step 4: Run the regression suite and confirm the decoder tests pass**

Run: `./scripts/run-regression-tests.sh`

Expected: all reset-credit decoder and formatter checks pass.

- [x] **Step 5: Commit the shared model**

```bash
git add Sources/CodexNotch/RateLimitResetCredits.swift Tests/CodexNotchRegressionTests/main.swift
git commit -m "feat: add reset credit model"
```

### Task 2: Local Codex App-Server Propagation

**Files:**
- Modify: `Sources/CodexNotch/Models.swift`
- Modify: `Sources/CodexNotch/CodexUsageStore.swift`
- Modify: `Sources/CodexNotch/SnapshotOutputFormatter.swift`
- Test: `Tests/CodexNotchRegressionTests/main.swift`

- [x] **Step 1: Write failing local propagation tests**

Add a weekly-only snapshot with reset credits and verify stabilization never discards them:

```swift
let localResetCredits = RateLimitResetCredits(
    availableCount: 3,
    credits: [RateLimitResetCredit(id: "credit", expiresAt: Date(timeIntervalSince1970: 1_786_557_546))],
    fetchedAt: resetNow
)
var snapshotWithCredits = weeklyOnlyRateLimitSnapshot
snapshotWithCredits.resetCredits = localResetCredits
let missingCreditsSnapshot = UsageSnapshot(
    primaryPercent: nil,
    secondaryPercent: 92,
    rateLimitWindows: weeklyOnlyRateLimitSnapshot.rateLimitWindows,
    usage24h: 0,
    usage7d: 0,
    usage30d: 0,
    tasks: [],
    isRunning: false,
    lastUpdated: resetNow,
    errorMessage: nil
)
runner.check(
    missingCreditsSnapshot.stabilizedRateLimits(against: snapshotWithCredits).resetCredits == localResetCredits,
    "transient app-server omissions should preserve known reset credits"
)
```

Also assert diagnostic JSON contains:

```swift
"reset_credits": {
  "available_count": 3,
  "expires_at": [1786557546]
}
```

- [x] **Step 2: Run tests and confirm the new checks fail**

Run: `./scripts/run-regression-tests.sh`

Expected: compilation fails because `UsageSnapshot` and `RateLimitSnapshot` do not carry reset credits.

- [x] **Step 3: Extend local snapshot models**

Add optional values with defaults to reduce initializer churn:

```swift
struct UsageSnapshot: Equatable {
    // existing properties
    var resetCredits: RateLimitResetCredits? = nil
}

struct RateLimitSnapshot: Equatable {
    // existing properties
    var windows: [UsageQuotaWindow] = []
    var resetCredits: RateLimitResetCredits? = nil
}
```

Update `stabilizedRateLimits(against:)` so a missing new value preserves the previous valid value, while an explicit count of zero remains authoritative.

- [x] **Step 4: Decode `rateLimitResetCredits` from app-server**

Extend `AppServerRateLimitResult`:

```swift
private struct AppServerRateLimitResult: Decodable {
    let rateLimits: AppServerRateLimitSnapshot
    let rateLimitsByLimitId: [String: AppServerRateLimitSnapshot]?
    let rateLimitResetCredits: AppServerResetCreditsPayload?
}
```

Use the shared decoder to normalize the nested payload and assign it to the returned `RateLimitSnapshot`. Propagate the value through full snapshots, fast snapshots, and error-free cached paths.

- [x] **Step 5: Add reset credits to diagnostic JSON**

Keep existing compatibility fields and add one optional `reset_credits` object containing `available_count` and epoch `expires_at` values.

- [x] **Step 6: Run local tests and a real app-server probe**

Run:

```bash
./scripts/run-regression-tests.sh
swift build -c release
.build/release/CodexNotch --print-fast-snapshot-json
```

Expected: tests and build pass; JSON includes the current local reset-credit count when Codex returns it.

- [x] **Step 7: Commit local propagation**

```bash
git add Sources/CodexNotch/Models.swift Sources/CodexNotch/CodexUsageStore.swift Sources/CodexNotch/SnapshotOutputFormatter.swift Tests/CodexNotchRegressionTests/main.swift
git commit -m "feat: read local reset credits"
```

### Task 3: CPA Manager Plus Proxy Client

**Files:**
- Modify: `Sources/CodexNotch/CLIProxyAPIClient.swift`
- Test: `Tests/CodexNotchRegressionTests/main.swift`

- [x] **Step 1: Write failing proxy envelope tests**

Cover object `body`, JSON-string `body`, and `bodyText` fallback:

```swift
let proxyEnvelope = Data(#"""
{
  "status_code": 200,
  "body": {
    "available_count": 2,
    "credits": [
      {"id":"one","reset_type":"codex_rate_limits","status":"available","expires_at":"2026-08-01T03:12:00Z"}
    ]
  }
}
"""#.utf8)
let proxyCredits = try CLIProxyAPIClient.decodeResetCreditsProxyResponse(proxyEnvelope, now: resetNow)
runner.check(proxyCredits?.availableCount == 2, "CPA proxy envelope should expose reset credit count")
runner.check(proxyCredits?.credits.count == 1, "CPA proxy envelope should expose expiry rows")
```

Add a non-2xx envelope and assert it throws an upstream error rather than returning zero.

- [x] **Step 2: Run tests and confirm failure**

Run: `./scripts/run-regression-tests.sh`

Expected: compilation fails because the reset-credit proxy decoder does not exist.

- [x] **Step 3: Add the CPA management proxy request**

Add:

```swift
func fetchResetCredits(
    authIndex: String,
    accountID: String?,
    now: Date = Date()
) async throws -> RateLimitResetCredits?

static func decodeResetCreditsProxyResponse(
    _ data: Data,
    now: Date = Date()
) throws -> RateLimitResetCredits?
```

POST to `<managementBaseURL>/api-call` with this encoded body:

```json
{
  "authIndex": "account-index",
  "method": "GET",
  "url": "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
  "header": {
    "Authorization": "Bearer $TOKEN$",
    "Content-Type": "application/json",
    "Accept": "application/json",
    "OpenAI-Beta": "codex-1",
    "Originator": "Codex Desktop",
    "Chatgpt-Account-Id": "optional-account-id"
  }
}
```

Use the existing management bearer key and insecure-TLS session behavior. Decode `status_code`/`statusCode`, `body`, `body_text`, and `bodyText` without treating a missing payload as zero credits.

- [x] **Step 4: Run the regression suite**

Run: `./scripts/run-regression-tests.sh`

Expected: all proxy envelope tests pass.

- [x] **Step 5: Commit the CPA client**

```bash
git add Sources/CodexNotch/CLIProxyAPIClient.swift Tests/CodexNotchRegressionTests/main.swift
git commit -m "feat: query CPA reset credits"
```

### Task 4: Remote Cache, Concurrency, and Failure Preservation

**Files:**
- Create: `Sources/CodexNotch/RemoteResetCreditsLoader.swift`
- Modify: `Sources/CodexNotch/RemoteMonitorModels.swift`
- Modify: `Sources/CodexNotch/RemoteMonitorViewModel.swift`
- Test: `Tests/CodexNotchRegressionTests/main.swift`

- [x] **Step 1: Write failing model and cache tests**

Add checks that:

- `RemoteCodexAccount` carries reset credits through `preservingQuota`;
- a valid cached value is returned before 60 minutes;
- a forced lookup bypasses the fresh cache;
- an expired cached value remains available only as failure fallback;
- cache keys include panel identity plus stable account identity.

Use a deterministic cache clock:

```swift
let resetCache = RemoteResetCreditsCache(ttl: 3_600)
resetCache.store(localResetCredits, for: "panel|account")
runner.check(
    resetCache.freshValue(for: "panel|account", now: localResetCredits.fetchedAt.addingTimeInterval(3_599)) == localResetCredits,
    "reset credit cache should remain fresh for one hour"
)
runner.check(
    resetCache.freshValue(for: "panel|account", now: localResetCredits.fetchedAt.addingTimeInterval(3_601)) == nil,
    "reset credit cache should expire after one hour"
)
runner.check(
    resetCache.staleValue(for: "panel|account") == localResetCredits,
    "failed refresh should be able to reuse stale reset credits"
)
```

- [x] **Step 2: Run tests and confirm failure**

Run: `./scripts/run-regression-tests.sh`

Expected: compilation fails because the cache and remote account field do not exist.

- [x] **Step 3: Add reset credits to `RemoteCodexAccount`**

Append an initializer parameter with a default:

```swift
let resetCredits: RateLimitResetCredits?

init(
    // existing parameters
    unavailable: Bool = false,
    resetCredits: RateLimitResetCredits? = nil
)
```

Add `withResetCredits(_:)` and make every quota/state preservation constructor retain the previous reset-credit value unless a fresh non-`nil` value is supplied.

- [x] **Step 4: Implement the thread-safe cache and loader**

`RemoteResetCreditsCache` uses `NSLock`, stores `RateLimitResetCredits` by `panelURL|authIndex`, and exposes synchronous `freshValue`, `staleValue`, and `store` methods.

`RemoteResetCreditsLoader` must:

- run only for `.cpaManagerPlus`;
- skip accounts with no `authIndex`;
- reuse fresh cache unless `forceRefresh == true`;
- fetch accounts in batches of at most two concurrent tasks;
- preserve original account order;
- use stale cache on individual request failure;
- leave the account unchanged when no value has ever succeeded.

- [x] **Step 5: Wire the loader into remote refresh**

Change the refresh entry points:

```swift
func refreshNow() {
    consecutiveFailures = 0
    refreshRemoteSnapshot(cancelInFlight: true, forceResetCredits: true)
}

private func refreshRemoteSnapshot(
    cancelInFlight: Bool = false,
    forceResetCredits: Bool = false
)
```

Pass the long-lived cache into `RemoteCodexProvider.fetch`. Automatic timer refreshes use the cache; manual detail-page refresh bypasses it.

- [x] **Step 6: Run regression and concurrency checks**

Run: `./scripts/run-regression-tests.sh`

Expected: cache and remote preservation checks pass; existing refresh overlap tests remain green.

- [x] **Step 7: Commit remote enrichment**

```bash
git add Sources/CodexNotch/RemoteResetCreditsLoader.swift Sources/CodexNotch/RemoteMonitorModels.swift Sources/CodexNotch/RemoteMonitorViewModel.swift Tests/CodexNotchRegressionTests/main.swift
git commit -m "feat: cache remote reset credits"
```

### Task 5: Reusable Information Popover and Detail-Row Integration

**Files:**
- Create: `Sources/CodexNotch/ResetCreditsIndicator.swift`
- Modify: `Sources/CodexNotch/NotchIslandView.swift`
- Test: `Tests/CodexNotchRegressionTests/main.swift`

- [x] **Step 1: Write failing display contract tests**

Keep display decisions testable outside SwiftUI:

```swift
runner.check(ResetCreditsDisplay.countText(3) == "剩余重置次数：3", "reset credit label should be unambiguous")
runner.check(ResetCreditsDisplay.showsInfoButton(localResetCredits), "expiry details should show the info button")
runner.check(
    !ResetCreditsDisplay.showsInfoButton(RateLimitResetCredits(availableCount: 0, credits: [], fetchedAt: resetNow)),
    "zero credits without expiry rows should hide the info button"
)
```

- [x] **Step 2: Run tests and confirm failure**

Run: `./scripts/run-regression-tests.sh`

Expected: compilation fails because `ResetCreditsDisplay` does not exist.

- [x] **Step 3: Build the reusable indicator**

Create `ResetCreditsIndicator` with:

- `Text("剩余重置次数：\(credits.availableCount)")` and monospaced digits;
- an `info.circle` symbol button only when `availableCount > 0` and `credits.credits` is nonempty;
- `.help("查看重置次数到期时间")`;
- a native `.popover` titled `重置次数到期时间`;
- rows rendered as `第 N 次` plus `yyyy/MM/dd HH:mm`;
- plain button style and fixed icon dimensions so the row does not shift.

- [x] **Step 4: Integrate the local Codex 7d row**

In `quotaResetItem`, append the indicator only when `label == "7d"` and `snapshot.resetCredits != nil`. Keep it in the existing top-safe-area strip so physical-notch avoidance remains unchanged.

- [x] **Step 5: Integrate the CPA account row without increasing height**

Replace the two-column quota grid with one compact horizontal quota line for the already-filtered 5h/7d windows, then append the indicator. Increase only the internal trailing-column allocation by using existing card whitespace; keep the island width and the 62-point card height unchanged.

The row must retain:

- one-line clipping protection;
- minimum scale factor for long localized values;
- a fixed info-button hit target;
- no additional row for reset credits.

- [x] **Step 6: Run tests and release build**

Run:

```bash
./scripts/run-regression-tests.sh
swift build -c release
git diff --check
```

Expected: all commands succeed.

- [x] **Step 7: Commit the UI**

```bash
git add Sources/CodexNotch/ResetCreditsIndicator.swift Sources/CodexNotch/NotchIslandView.swift Tests/CodexNotchRegressionTests/main.swift
git commit -m "feat: show reset credit details"
```

### Task 6: Documentation and Installed-App Verification

**Files:**
- Modify: `README.md`

- [x] **Step 1: Document the feature in Chinese and English**

Add these behaviors to the existing local and CPA sections:

- remaining reset-credit count appears beside the weekly quota;
- clicking the information icon shows each available credit's expiry time;
- CPA values are queried through CPA Manager Plus and cached for one hour;
- reset-credit lookup failures do not change account health state.

- [x] **Step 2: Run the complete verification set**

Run:

```bash
./scripts/run-regression-tests.sh
swift build -c release
git diff --check
./scripts/build-app.sh
./scripts/install-user-app.sh
codesign --verify --deep --strict /Users/alight/Applications/codex监测.app
```

Expected: regression, release build, DMG build, installation, and signature verification all succeed.

- [x] **Step 3: Verify live local data**

Run:

```bash
.build/release/CodexNotch --print-fast-snapshot-json
```

Expected: the current local response includes `reset_credits.available_count` and sorted future `expires_at` values.

- [ ] **Step 4: Verify the installed UI**

Open the installed app, expand Codex details, and verify:

- `剩余重置次数：N` appears on the 7d row;
- clicking `info.circle` shows ordered expiry rows;
- switching to CPA keeps account cards at the existing height;
- each account with data shows its own count and popover;
- no count is shown for accounts that have never returned reset-credit data;
- closing the popover by clicking outside works reliably.

- [x] **Step 5: Commit documentation and final verification changes**

```bash
git add README.md
git commit -m "docs: describe reset credit monitoring"
```

- [x] **Step 6: Inspect final repository state**

Run:

```bash
git status --short
git log -6 --oneline
```

Expected: the worktree is clean and the reset-credit implementation commits are visible. Do not publish a GitHub release unless the user explicitly requests one.
