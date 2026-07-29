import AppKit
import Combine
import QuartzCore
import SwiftUI

@main
struct CodexNotchApp {
    static func main() {
        let arguments = CommandLine.arguments
        let shouldPrintHumanSnapshot = arguments.contains("--print-snapshot") || arguments.contains("--print-fast-snapshot")
        let shouldPrintJSONSnapshot = arguments.contains("--print-snapshot-json") || arguments.contains("--print-fast-snapshot-json")
        if shouldPrintHumanSnapshot || shouldPrintJSONSnapshot {
            let includePeriodUsage = !(arguments.contains("--print-fast-snapshot") || arguments.contains("--print-fast-snapshot-json"))
            let snapshot = CodexUsageStore().loadSnapshot(includePeriodUsage: includePeriodUsage)
            if shouldPrintJSONSnapshot {
                FileHandle.standardOutput.write(SnapshotOutputFormatter.jsonData(for: snapshot))
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                for line in SnapshotOutputFormatter.humanLines(for: snapshot) {
                    print(line)
                }
            }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("codex监测 runs as a persistent notch overlay")
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: NotchOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        overlayController = NotchOverlayController()
        overlayController?.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "codex监测")
        appMenu.addItem(withTitle: "退出 codex监测", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(editMenuItem("撤销", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(editMenuItem("重做", action: Selector(("redo:")), key: "Z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(editMenuItem("剪切", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(editMenuItem("拷贝", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(editMenuItem("粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(editMenuItem("全选", action: #selector(NSText.selectAll(_:)), key: "a"))
        editItem.submenu = editMenu

        return mainMenu
    }

    private static func editMenuItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }
}

private final class TopAnchoredClippingView: NSView {
    private let hostedView: NSView
    private var targetContentSize: NSSize

    init(hostedView: NSView, contentSize: NSSize) {
        self.hostedView = hostedView
        targetContentSize = contentSize
        super.init(frame: NSRect(origin: .zero, size: contentSize))

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostedView.autoresizingMask = []
        addSubview(hostedView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func updateContentSize(_ size: NSSize) {
        targetContentSize = size
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        hostedView.frame = NSRect(
            x: bounds.minX,
            y: bounds.maxY - targetContentSize.height,
            width: targetContentSize.width,
            height: targetContentSize.height
        )
    }
}

@MainActor
final class NotchOverlayController {
    private let settings = CodexNotchSettings(loadSecretsSynchronously: false)
    private lazy var viewModel = UsageViewModel(settings: settings)
    private lazy var remoteViewModel = RemoteMonitorViewModel(settings: settings)
    private lazy var newAPIViewModel = BalanceMonitorViewModel(source: .newAPI, settings: settings)
    private lazy var subAPIViewModel = BalanceMonitorViewModel(source: .subAPI, settings: settings)
    private let overlayState = OverlayState()
    private let window: NSPanel
    private let detailWindow: NSPanel
    private var detailContentContainer: TopAnchoredClippingView?
    private lazy var settingsController = SettingsWindowController(
        settings: settings,
        remoteViewModel: remoteViewModel,
        newAPIViewModel: newAPIViewModel,
        subAPIViewModel: subAPIViewModel,
        onRefresh: { [weak self] in
            self?.viewModel.refreshAll()
        }
    )
    private var cancellables: Set<AnyCancellable> = []
    private var eventMonitors: [Any] = []
    private var detailTransition = DetailTransitionState()
    private var pendingDetailWorkItems: [DispatchWorkItem] = []
    private var latestDetailExpandedFrame: NSRect?
    private var systemActivityResumeTimer: Timer?

    private static let detailSettleDuration: TimeInterval = 0.12

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: IslandMetrics.width, height: IslandMetrics.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        detailWindow = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: IslandMetrics.width, height: IslandMetrics.detailHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureWindow()
        configureContent()
        observeState()
        observeScreenChanges()
        observeSystemActivity()
        installEventMonitors()
        synchronizeFramesForGeometryChange()
    }

    func show() {
        window.orderFrontRegardless()
    }

    private func configureWindow() {
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        detailWindow.backgroundColor = .clear
        detailWindow.isOpaque = false
        detailWindow.hasShadow = false
        detailWindow.level = .statusBar
        detailWindow.ignoresMouseEvents = false
        detailWindow.isMovableByWindowBackground = false
        detailWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    private func configureContent() {
        let view = NotchIslandView(
            viewModel: viewModel,
            remoteViewModel: remoteViewModel,
            newAPIViewModel: newAPIViewModel,
            subAPIViewModel: subAPIViewModel,
            overlayState: overlayState,
            settings: settings,
            onSettings: { [weak self] in
                self?.showSettings()
            }
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: IslandMetrics.width, height: IslandMetrics.collapsedHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView

        let detailView = DetailPanelView(
            viewModel: viewModel,
            remoteViewModel: remoteViewModel,
            newAPIViewModel: newAPIViewModel,
            subAPIViewModel: subAPIViewModel,
            overlayState: overlayState,
            settings: settings,
            onSettings: { [weak self] in
                self?.showSettings()
            },
            onLocalRefresh: { [weak self] in
                self?.viewModel.refreshAll()
            },
            onRemoteRefresh: { [weak self] in
                self?.remoteViewModel.refreshNow()
            },
            onNewAPIRefresh: { [weak self] in
                self?.newAPIViewModel.refreshNow()
            },
            onSubAPIRefresh: { [weak self] in
                self?.subAPIViewModel.refreshNow()
            }
        )
        let detailHostingView = NSHostingView(rootView: detailView)
        let detailContentSize = NSSize(width: IslandMetrics.width, height: currentDetailHeight())
        detailHostingView.frame = NSRect(origin: .zero, size: detailContentSize)
        detailHostingView.wantsLayer = true
        detailHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        let detailContentContainer = TopAnchoredClippingView(
            hostedView: detailHostingView,
            contentSize: detailContentSize
        )
        self.detailContentContainer = detailContentContainer
        detailWindow.contentView = detailContentContainer
    }

    private func observeState() {
        overlayState.$isExpanded
            .removeDuplicates()
            .sink { [weak self] isExpanded in
                guard let self else {
                    return
                }
                self.setDetailVisible(isExpanded)
                if isExpanded, self.settings.showPeriodUsage {
                    self.viewModel.refreshUsageTotalsIfStale()
                } else if self.settings.showPeriodUsage {
                    self.viewModel.pausePeriodicUsageRefresh()
                } else {
                    self.viewModel.disableUsageTotals()
                }
            }
            .store(in: &cancellables)

        settings.$taskHistoryRange
            .combineLatest(settings.$showPeriodUsage)
            .sink { [weak self] _, showPeriodUsage in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    if self.overlayState.isExpanded {
                        if showPeriodUsage {
                            self.viewModel.refreshUsageTotalsIfStale()
                        } else {
                            self.viewModel.disableUsageTotals()
                        }
                    } else if showPeriodUsage {
                        self.viewModel.pausePeriodicUsageRefresh()
                    } else {
                        self.viewModel.disableUsageTotals()
                    }
                    self.updateFrames()
                }
            }
            .store(in: &cancellables)

        settings.$notchWidthAdjustment
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.synchronizeFramesForGeometryChange()
                }
            }
            .store(in: &cancellables)

        viewModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateFrames()
                }
            }
            .store(in: &cancellables)

        remoteViewModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateFrames()
                }
            }
            .store(in: &cancellables)

        newAPIViewModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateFrames()
                }
            }
            .store(in: &cancellables)

        subAPIViewModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateFrames()
                }
            }
            .store(in: &cancellables)
    }

    private func observeScreenChanges() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                self.synchronizeFramesForGeometryChange()
            }
            .store(in: &cancellables)
    }

    private func observeSystemActivity() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ] {
            notificationCenter.publisher(for: name)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleSystemActivityResume()
                    }
                }
                .store(in: &cancellables)
        }
    }

    private func scheduleSystemActivityResume() {
        systemActivityResumeTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: SystemActivityRefreshCadence.debounceDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.systemActivityResumeTimer = nil
                self?.viewModel.resumeAfterSystemActivity()
            }
        }
        timer.tolerance = 0.25
        systemActivityResumeTimer = timer
    }

    private func installEventMonitors() {
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            Task { @MainActor in
                self?.closeIfClickIsOutside()
            }
        }) {
            eventMonitors.append(globalMonitor)
        }

        if let localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.overlayState.isExpanded = false
                }
                return nil
            }
            if self?.shouldSuppressTextInputShortcut(event) == true {
                return nil
            }
            return event
        }) {
            eventMonitors.append(localKeyMonitor)
        }

        if let localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            Task { @MainActor in
                self?.closeIfClickIsOutside()
                self?.restorePanelOrdering()
            }
            return event
        }) {
            eventMonitors.append(localMouseMonitor)
        }
    }

    private func closeIfClickIsOutside() {
        guard overlayState.isExpanded else {
            return
        }

        let location = NSEvent.mouseLocation
        if window.frame.contains(location) || detailWindow.frame.contains(location) {
            return
        }
        overlayState.isExpanded = false
    }

    private func setDetailVisible(_ visible: Bool) {
        cancelPendingDetailWorkItems()

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let previousPhase = detailTransition.phase
        let generation = detailTransition.begin(expanded: visible)
        if visible {
            showDetail(on: screen, previousPhase: previousPhase, generation: generation)
        } else {
            hideDetail(on: screen, generation: generation)
        }
    }

    private func showDetail(
        on screen: NSScreen,
        previousPhase: DetailPresentationPhase,
        generation: UInt
    ) {
        let frames = detailFrames(for: screen)
        latestDetailExpandedFrame = frames.expanded
        if previousPhase == .hidden || !detailWindow.isVisible {
            updateDetailContentSize(for: frames.expanded)
        }
        overlayState.setDetailPresentationPhase(.revealing)

        if window.childWindows?.contains(detailWindow) != true {
            window.addChildWindow(detailWindow, ordered: .below)
        }
        if previousPhase == .hidden || !detailWindow.isVisible {
            detailWindow.setFrame(frames.collapsed, display: false)
        }
        detailWindow.order(.below, relativeTo: window.windowNumber)
        window.orderFrontRegardless()

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            detailWindow.setFrame(frames.expanded, display: true)
            guard detailTransition.completeShow(generation: generation) else {
                return
            }
            overlayState.setDetailPresentationPhase(.visible)
            updateFrames()
            return
        }

        scheduleDetailWork(after: DetailAnimationTiming.contentDelay, generation: generation) { [weak self] in
            self?.overlayState.setDetailPresentationPhase(.visible)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = DetailAnimationTiming.revealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            detailWindow.animator().setFrame(frames.expanded, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.detailTransition.isCurrent(generation) else {
                    return
                }
                self.settleDetailAfterReveal(
                    generation: generation,
                    currentTarget: frames.expanded
                )
            }
        }
    }

    private func hideDetail(on screen: NSScreen, generation: UInt) {
        overlayState.setDetailPresentationPhase(.hiding)
        let frames = detailFrames(for: screen)
        latestDetailExpandedFrame = frames.expanded

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            detailWindow.setFrame(frames.collapsed, display: false)
            guard detailTransition.completeHide(generation: generation) else {
                return
            }
            finishHidingDetail()
            return
        }

        scheduleDetailWork(after: DetailAnimationTiming.hideShellDelay, generation: generation) { [weak self] in
            guard let self else {
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DetailAnimationTiming.hideDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.detailWindow.animator().setFrame(frames.collapsed, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.detailTransition.completeHide(generation: generation) else {
                        return
                    }
                    self.finishHidingDetail()
                }
            }
        }
    }

    private func settleDetailAfterReveal(generation: UInt, currentTarget: NSRect) {
        guard detailTransition.isCurrent(generation), detailTransition.phase == .revealing else {
            return
        }

        let latestTarget = latestDetailExpandedFrame ?? currentTarget
        guard latestTarget != currentTarget else {
            updateDetailContentSize(for: latestTarget)
            guard detailTransition.completeShow(generation: generation) else {
                return
            }
            overlayState.setDetailPresentationPhase(.visible)
            return
        }

        updateDetailContentSize(for: latestTarget)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.detailSettleDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            detailWindow.animator().setFrame(latestTarget, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.detailTransition.isCurrent(generation) else {
                    return
                }
                self.settleDetailAfterReveal(
                    generation: generation,
                    currentTarget: latestTarget
                )
            }
        }
    }

    private func finishHidingDetail() {
        overlayState.setDetailPresentationPhase(.hidden)
        window.removeChildWindow(detailWindow)
        detailWindow.orderOut(nil)
        updateFrames()
    }

    private func scheduleDetailWork(
        after delay: TimeInterval,
        generation: UInt,
        action: @escaping @MainActor () -> Void
    ) {
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.detailTransition.isCurrent(generation) else {
                    return
                }
                action()
            }
        }
        pendingDetailWorkItems.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelPendingDetailWorkItems() {
        pendingDetailWorkItems.forEach { $0.cancel() }
        pendingDetailWorkItems.removeAll()
    }

    private func restorePanelOrdering() {
        guard overlayState.isExpanded else {
            return
        }

        if window.childWindows?.contains(detailWindow) != true {
            window.addChildWindow(detailWindow, ordered: .below)
        }
        detailWindow.order(.below, relativeTo: window.windowNumber)
        window.orderFrontRegardless()
    }

    private func updateFrames() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        let layout = currentIslandLayout(for: screen)
        let x = screen.frame.midX - layout.width / 2
        let islandY = screen.frame.maxY - layout.collapsedHeight
        let islandFrame = NSRect(x: x, y: islandY, width: layout.width, height: layout.collapsedHeight)
        let detailFrames = detailFrames(for: screen, layout: layout)

        window.setFrame(islandFrame, display: true, animate: false)
        window.contentView?.frame = NSRect(x: 0, y: 0, width: layout.width, height: layout.collapsedHeight)
        latestDetailExpandedFrame = detailFrames.expanded
        switch detailTransition.phase {
        case .hidden:
            updateDetailContentSize(for: detailFrames.expanded)
            detailWindow.setFrame(detailFrames.collapsed, display: false)
        case .visible:
            updateDetailContentSize(for: detailFrames.expanded)
            detailWindow.setFrame(detailFrames.expanded, display: true)
        case .revealing, .hiding:
            break
        }
    }

    private func synchronizeFramesForGeometryChange() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }

        cancelPendingDetailWorkItems()
        let layout = currentIslandLayout(for: screen)
        let frames = detailFrames(for: screen, layout: layout)
        let islandFrame = NSRect(
            x: screen.frame.midX - layout.width / 2,
            y: screen.frame.maxY - layout.collapsedHeight,
            width: layout.width,
            height: layout.collapsedHeight
        )

        window.setFrame(islandFrame, display: true, animate: false)
        window.contentView?.frame = NSRect(origin: .zero, size: islandFrame.size)
        latestDetailExpandedFrame = frames.expanded
        updateDetailContentSize(for: frames.expanded)

        let generation = detailTransition.begin(expanded: overlayState.isExpanded)
        if overlayState.isExpanded {
            if window.childWindows?.contains(detailWindow) != true {
                window.addChildWindow(detailWindow, ordered: .below)
            }
            detailWindow.setFrame(frames.expanded, display: true)
            detailWindow.order(.below, relativeTo: window.windowNumber)
            window.orderFrontRegardless()
            guard detailTransition.completeShow(generation: generation) else {
                return
            }
            overlayState.setDetailPresentationPhase(.visible)
        } else {
            detailWindow.setFrame(frames.collapsed, display: false)
            guard detailTransition.completeHide(generation: generation) else {
                return
            }
            overlayState.setDetailPresentationPhase(.hidden)
            window.removeChildWindow(detailWindow)
            detailWindow.orderOut(nil)
        }
    }

    private func detailFrames(
        for screen: NSScreen,
        layout: IslandLayout? = nil
    ) -> DetailWindowFrames {
        let layout = layout ?? currentIslandLayout(for: screen)
        let detailHeight = currentDetailHeight(for: screen, layout: layout)
        return DetailWindowFrameCalculator.calculate(
            screenFrame: screen.frame,
            layoutWidth: layout.width,
            collapsedHeight: layout.collapsedHeight,
            detailHeight: detailHeight,
            overlap: IslandMetrics.detailOverlap
        )
    }

    private func updateDetailContentSize(for expandedFrame: NSRect) {
        detailContentContainer?.updateContentSize(expandedFrame.size)
    }

    private func currentIslandLayout(for screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first) -> IslandLayout {
        ScreenNotchGeometry.layout(for: screen, adjustment: CGFloat(settings.notchWidthAdjustment))
    }

    private func showSettings() {
        overlayState.isExpanded = false
        settingsController.show()
    }

    private func shouldSuppressTextInputShortcut(_ event: NSEvent) -> Bool {
        guard NSApp.keyWindow?.firstResponder is NSTextView else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return SettingsShortcutFilter.shouldSuppressTextInputKey(
            characters: event.characters,
            hasCommand: flags.contains(.command),
            hasControl: flags.contains(.control),
            hasOption: flags.contains(.option),
            hasShift: flags.contains(.shift)
        )
    }

    private func currentDetailHeight(
        for screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first,
        layout: IslandLayout? = nil
    ) -> CGFloat {
        let layout = layout ?? currentIslandLayout(for: screen)
        let safeAreaTop = ScreenNotchGeometry.topSafeInset(for: screen)
        let topPadding = IslandMetrics.detailContentTopPadding(
            safeAreaTop: safeAreaTop,
            collapsedHeight: layout.collapsedHeight
        )
        let enabledExternalRows = [
            settings.remoteMonitorEnabled ? remoteViewModel.snapshot.accounts.count : nil,
            settings.newAPIMonitorEnabled ? newAPIViewModel.snapshot.accounts.count : nil,
            settings.subAPIMonitorEnabled ? subAPIViewModel.snapshot.accounts.count : nil
        ].compactMap { $0 }

        let accountRows = enabledExternalRows.isEmpty ? nil : max(1, enabledExternalRows.max() ?? 1)
        let usesTallRemoteRows = remoteViewModel.snapshot.accounts.contains { $0.displayQuotaWindows.count > 2 }
        return IslandMetrics.combinedDetailHeight(
            accountRows: accountRows,
            showsPeriodUsage: settings.showPeriodUsage,
            usesTallRemoteRows: usesTallRemoteRows,
            topPadding: topPadding
        )
    }
}

@MainActor
final class SettingsWindowController {
    private let settings: CodexNotchSettings
    private let remoteViewModel: RemoteMonitorViewModel
    private let newAPIViewModel: BalanceMonitorViewModel
    private let subAPIViewModel: BalanceMonitorViewModel
    private let onRefresh: () -> Void
    private var window: NSWindow?

    init(
        settings: CodexNotchSettings,
        remoteViewModel: RemoteMonitorViewModel,
        newAPIViewModel: BalanceMonitorViewModel,
        subAPIViewModel: BalanceMonitorViewModel,
        onRefresh: @escaping () -> Void
    ) {
        self.settings = settings
        self.remoteViewModel = remoteViewModel
        self.newAPIViewModel = newAPIViewModel
        self.subAPIViewModel = subAPIViewModel
        self.onRefresh = onRefresh
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(
            settings: settings,
            remoteViewModel: remoteViewModel,
            newAPIViewModel: newAPIViewModel,
            subAPIViewModel: subAPIViewModel,
            onRefresh: onRefresh
        )
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "codex监测设置"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        return window
    }
}
