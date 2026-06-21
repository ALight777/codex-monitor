# Settings Sidebar Account Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the settings window into a wider sidebar layout with clear balance threshold rows and table-style account management using add/edit/delete dialogs.

**Architecture:** Keep the existing `SettingsDraft` save-on-click model. Move visual complexity out of inline account forms by editing a temporary account copy in a SwiftUI sheet, then applying it to the draft list only when the user confirms. Add small model-level summary helpers so account rows and regression tests share the same threshold display logic.

**Tech Stack:** SwiftUI, native macOS sheet presentation, existing Swift Package app, existing shell regression harness.

---

### Task 1: Add Testable Summary Helpers

**Files:**
- Modify: `Sources/CodexNotch/BalanceMonitorModels.swift`
- Modify: `Tests/CodexNotchRegressionTests/main.swift`

- [ ] Add `BalanceThresholdConfiguration.summaryText`.
- [ ] Add `BalanceAccountConfiguration.thresholdSummary(defaults:)`.
- [ ] Add regression checks for empty/default/custom threshold summaries.
- [ ] Run `./scripts/run-regression-tests.sh` and verify the new assertions fail before implementation, then pass after implementation.

### Task 2: Rework Settings Window Layout

**Files:**
- Modify: `Sources/CodexNotch/SettingsView.swift`

- [ ] Replace the top segmented tab picker with a left sidebar.
- [ ] Widen the settings window to roughly `900px` and keep the content column stable.
- [ ] Keep the existing footer actions and save-on-click behavior.

### Task 3: Clarify Threshold Editing

**Files:**
- Modify: `Sources/CodexNotch/SettingsView.swift`

- [ ] Replace the current horizontal optional-field layout with two row-style fields.
- [ ] Show `提醒阈值` and `告警阈值` as explicit rows with the input aligned on the right.
- [ ] Keep empty input meaning “不设置”.

### Task 4: Move Account Editing Into a Sheet

**Files:**
- Modify: `Sources/CodexNotch/SettingsView.swift`

- [ ] Add a draft account state and sheet presentation state.
- [ ] Replace inline expanded account forms with a list/table card.
- [ ] Provide `添加账号`, `修改`, `删除`, `启用/停用` actions.
- [ ] Use a confirmation dialog before deleting an account.
- [ ] Edit full account details inside a modal sheet and apply only on confirm.

### Task 5: Verify and Ship

**Files:**
- Modify: `scripts/run-regression-tests.sh` only if new test-visible source files are introduced.

- [ ] Run `./scripts/run-regression-tests.sh`.
- [ ] Run `git diff --check`.
- [ ] Run `./scripts/build-app.sh`.
- [ ] Verify `dist/Codex Notch.app` signature and `dist/Codex Notch.dmg`.
- [ ] Replace `/Applications/Codex Notch.app`, launch it, and commit the work.
