# Notch Detail Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the detail panel extend smoothly from the fixed notch and retract through the same unified close path without leaving stale windows or animation callbacks.

**Architecture:** Add a pure transition-state value that owns generation tokens and presentation phases, then let `NotchOverlayController` translate those phases into top-anchored AppKit window-frame animations. `OverlayState` publishes only the content phase needed by SwiftUI, so the shell can extend before the controls fade in and closing can reverse that order.

**Tech Stack:** Swift 6, AppKit `NSPanel` and `NSAnimationContext`, SwiftUI, Combine, the repository's standalone regression test runner.

---

## File Structure

- Create `Sources/CodexNotch/DetailPresentation.swift`: pure transition phases, generation-token validation, and animation timing constants.
- Modify `Sources/CodexNotch/UsageViewModel.swift`: expose a read-only detail presentation phase through `OverlayState`.
- Modify `Sources/CodexNotch/AppDelegate.swift`: animate only `detailWindow`, preserve its top anchor, cancel stale completions, and centralize immediate/reduced-motion behavior.
- Modify `Sources/CodexNotch/NotchIslandView.swift`: receive `OverlayState` in `DetailPanelView` and animate only the foreground content.
- Modify `scripts/run-regression-tests.sh`: compile the new pure transition-state source into the standalone test binary.
- Modify `Tests/CodexNotchRegressionTests/main.swift`: verify transition generations and phase completion behavior.

### Task 1: Pure Detail Transition State

**Files:**
- Create: `Sources/CodexNotch/DetailPresentation.swift`
- Modify: `scripts/run-regression-tests.sh`
- Test: `Tests/CodexNotchRegressionTests/main.swift`

- [ ] **Step 1: Write failing transition-state tests**

Add these assertions near the start of `Tests/CodexNotchRegressionTests/main.swift`:

```swift
var detailTransition = DetailTransitionState()
runner.check(detailTransition.phase == .hidden, "detail transition should start hidden")

let firstShow = detailTransition.begin(expanded: true)
runner.check(detailTransition.phase == .revealing, "show should enter revealing phase")

let interruptedHide = detailTransition.begin(expanded: false)
runner.check(interruptedHide != firstShow, "every transition should receive a new generation")
runner.check(detailTransition.phase == .hiding, "reverse transition should enter hiding phase")
runner.check(!detailTransition.completeShow(generation: firstShow), "stale show completion should be ignored")
runner.check(detailTransition.phase == .hiding, "stale show completion should not replace hiding phase")
runner.check(detailTransition.completeHide(generation: interruptedHide), "current hide completion should succeed")
runner.check(detailTransition.phase == .hidden, "hide completion should end hidden")

let finalShow = detailTransition.begin(expanded: true)
runner.check(detailTransition.completeShow(generation: finalShow), "current show completion should succeed")
runner.check(detailTransition.phase == .visible, "show completion should end visible")
```

- [ ] **Step 2: Add the future source file to the regression compiler and verify failure**

Insert the source path before `Models.swift` in `scripts/run-regression-tests.sh`:

```bash
  "${ROOT_DIR}/Sources/CodexNotch/DetailPresentation.swift" \
```

Run:

```bash
./scripts/run-regression-tests.sh
```

Expected: compilation fails because `DetailTransitionState` and `DetailPresentationPhase` do not exist yet.

- [ ] **Step 3: Implement the pure transition state**

Create `Sources/CodexNotch/DetailPresentation.swift`:

```swift
import Foundation

enum DetailPresentationPhase: Equatable {
    case hidden
    case revealing
    case visible
    case hiding

    var showsContent: Bool {
        self == .visible
    }
}

struct DetailTransitionState {
    private(set) var phase: DetailPresentationPhase = .hidden
    private(set) var generation: UInt = 0

    mutating func begin(expanded: Bool) -> UInt {
        generation &+= 1
        phase = expanded ? .revealing : .hiding
        return generation
    }

    func isCurrent(_ candidate: UInt) -> Bool {
        generation == candidate
    }

    mutating func completeShow(generation candidate: UInt) -> Bool {
        guard isCurrent(candidate), phase == .revealing else {
            return false
        }
        phase = .visible
        return true
    }

    mutating func completeHide(generation candidate: UInt) -> Bool {
        guard isCurrent(candidate), phase == .hiding else {
            return false
        }
        phase = .hidden
        return true
    }
}

enum DetailAnimationTiming {
    static let revealDuration: TimeInterval = 0.26
    static let contentDelay: TimeInterval = 0.06
    static let contentDuration: TimeInterval = 0.14
    static let hideContentDuration: TimeInterval = 0.10
    static let hideShellDelay: TimeInterval = 0.04
    static let hideDuration: TimeInterval = 0.20
}
```

- [ ] **Step 4: Run regression tests**

Run:

```bash
./scripts/run-regression-tests.sh
```

Expected: `All regression tests passed`.

- [ ] **Step 5: Commit the transition state**

```bash
git add Sources/CodexNotch/DetailPresentation.swift scripts/run-regression-tests.sh Tests/CodexNotchRegressionTests/main.swift
git commit -m "test: cover detail animation transitions"
```

### Task 2: Animate the Detail Shell and Content

**Files:**
- Modify: `Sources/CodexNotch/UsageViewModel.swift`
- Modify: `Sources/CodexNotch/AppDelegate.swift`
- Modify: `Sources/CodexNotch/NotchIslandView.swift`

- [ ] **Step 1: Publish the presentation phase from `OverlayState`**

Replace the current `OverlayState` with:

```swift
@MainActor
final class OverlayState: ObservableObject {
    @Published var isExpanded = false
    @Published private(set) var detailPresentationPhase: DetailPresentationPhase = .hidden

    func setDetailPresentationPhase(_ phase: DetailPresentationPhase) {
        detailPresentationPhase = phase
    }
}
```

- [ ] **Step 2: Pass `OverlayState` into the detail view and animate foreground content**

Add `overlayState: overlayState` when constructing `DetailPanelView` in `AppDelegate.configureContent()`. Add this observed property to `DetailPanelView`:

```swift
@ObservedObject var overlayState: OverlayState
```

Move `header`, `pageSwitcher`, the selected page content, and `quotaResetStrip` into a foreground container while keeping `BottomRoundedRectangle` outside it. Apply:

```swift
.opacity(overlayState.detailPresentationPhase.showsContent ? 1 : 0)
.offset(y: overlayState.detailPresentationPhase.showsContent ? 0 : -6)
.animation(
    .easeOut(duration: DetailAnimationTiming.contentDuration),
    value: overlayState.detailPresentationPhase
)
```

The background remains visible for the full shell animation, and hidden content uses `.allowsHitTesting(false)` until the phase becomes `.visible`.

- [ ] **Step 3: Add top-anchored frame helpers to `NotchOverlayController`**

Add helpers that derive both frames from the same final frame:

```swift
private func detailFrames(for screen: NSScreen) -> (collapsed: NSRect, expanded: NSRect) {
    let layout = currentIslandLayout(for: screen)
    let detailHeight = currentDetailHeight(for: screen, layout: layout)
    let x = screen.frame.midX - layout.width / 2
    let islandY = screen.frame.maxY - layout.collapsedHeight
    let expanded = NSRect(
        x: x,
        y: islandY - detailHeight + IslandMetrics.detailOverlap,
        width: layout.width,
        height: detailHeight
    )
    let collapsedHeight = IslandMetrics.detailOverlap
    let collapsed = NSRect(
        x: expanded.minX,
        y: expanded.maxY - collapsedHeight,
        width: expanded.width,
        height: collapsedHeight
    )
    return (collapsed, expanded)
}
```

Add controller state:

```swift
private var detailTransition = DetailTransitionState()
private var pendingDetailWorkItems: [DispatchWorkItem] = []
```

- [ ] **Step 4: Replace immediate visibility changes with generation-safe animation methods**

`setDetailVisible(_:)` should cancel pending work items, begin a new generation, and route to `showDetail` or `hideDetail`. Opening must order the child window below the fixed notch, set the collapsed frame without animation, then animate to the expanded frame. Closing must hide foreground content first, wait `hideShellDelay`, animate to the collapsed frame, and call `removeChildWindow` plus `orderOut` only if the completion generation is still current.

Use AppKit animation contexts with explicit timing:

```swift
NSAnimationContext.runAnimationGroup { context in
    context.duration = DetailAnimationTiming.revealDuration
    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
    detailWindow.animator().setFrame(frames.expanded, display: true)
} completionHandler: {
    Task { @MainActor [weak self] in
        guard let self, self.detailTransition.completeShow(generation: generation) else { return }
        self.overlayState.setDetailPresentationPhase(.visible)
    }
}
```

The delayed content reveal and delayed shell hide use cancellable `DispatchWorkItem` instances that check `detailTransition.isCurrent(generation)` before mutating UI.

- [ ] **Step 5: Add reduced-motion immediate transitions**

Before scheduling animation work, read:

```swift
let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
```

When true, set the final frame and final phase synchronously. Opening orders the detail window and sets `.visible`; closing sets `.hidden`, removes the child window, and orders it out.

- [ ] **Step 6: Keep geometry updates from replaying entrance animation**

Update `updateFrames()` so the top window always receives its current calculated frame. For the detail window:

```swift
switch detailTransition.phase {
case .hidden:
    detailWindow.setFrame(frames.collapsed, display: false)
case .revealing, .visible:
    detailWindow.setFrame(frames.expanded, display: true)
case .hiding:
    break
}
```

The `.hiding` branch preserves the in-flight presentation frame. `restorePanelOrdering()` must only repair parent/child ordering.

- [ ] **Step 7: Build and run regression tests**

Run:

```bash
./scripts/run-regression-tests.sh
swift build -c release
git diff --check
```

Expected: regression output ends in `All regression tests passed`, release build succeeds, and `git diff --check` prints nothing.

- [ ] **Step 8: Commit the animation integration**

```bash
git add Sources/CodexNotch/UsageViewModel.swift Sources/CodexNotch/AppDelegate.swift Sources/CodexNotch/NotchIslandView.swift
git commit -m "feat: animate notch detail expansion"
```

### Task 3: Package and Installed-App Verification

**Files:**
- Verify: `dist/codex监测.app`
- Verify: `/Users/alight/Applications/codex监测.app`

- [ ] **Step 1: Build both release architectures and the local app bundle**

Run:

```bash
./scripts/build-app.sh
```

Expected: arm64 and amd64 DMGs plus `dist/codex监测.app` are produced and ad-hoc signed.

- [ ] **Step 2: Install and launch the current-machine build**

Run:

```bash
./scripts/install-user-app.sh
```

Expected: `/Users/alight/Applications/codex监测.app` replaces the previous installation and `CodexNotch` is running.

- [ ] **Step 3: Verify package metadata and process state**

Run:

```bash
codesign --verify --deep --strict /Users/alight/Applications/codex监测.app
defaults read /Users/alight/Applications/codex监测.app/Contents/Info CFBundleShortVersionString
pgrep -fl CodexNotch
```

Expected: code signing verification succeeds, version is `0.1.5`, and one installed `CodexNotch` process is running.

- [ ] **Step 4: Perform interaction smoke checks**

Verify on the installed app:

1. Opening keeps the top notch fixed while the black shell extends down.
2. Content fades in after the shell starts.
3. Clicking outside and pressing `Esc` run the same reverse animation.
4. Rapid repeated clicks do not leave a partial or invisible click-blocking window.
5. With Reduce Motion enabled, both directions switch immediately.

- [ ] **Step 5: Commit any verification-driven corrections**

If smoke verification requires a correction, repeat Tasks 2 Step 7 and Task 3 Steps 1-4, then commit only the correction:

```bash
git add Sources/CodexNotch Tests/CodexNotchRegressionTests scripts/run-regression-tests.sh
git commit -m "fix: stabilize notch detail animation"
```
