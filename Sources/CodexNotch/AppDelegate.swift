import AppKit
import Combine
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

@MainActor
final class NotchOverlayController {
    private let settings = CodexNotchSettings()
    private lazy var viewModel = UsageViewModel(settings: settings)
    private lazy var remoteViewModel = RemoteMonitorViewModel(settings: settings)
    private lazy var newAPIViewModel = BalanceMonitorViewModel(source: .newAPI, settings: settings)
    private lazy var subAPIViewModel = BalanceMonitorViewModel(source: .subAPI, settings: settings)
    private lazy var codexRadarViewModel = CodexRadarViewModel(settings: settings)
    private let overlayState = OverlayState()
    private let window: NSPanel
    private var detailWindow: NSPanel?
    private lazy var settingsController = SettingsWindowController(
        settings: settings,
        remoteViewModel: remoteViewModel,
        newAPIViewModel: newAPIViewModel,
        subAPIViewModel: subAPIViewModel,
        codexRadarViewModel: codexRadarViewModel,
        onRefresh: { [weak self] in
            self?.viewModel.refreshAll()
        }
    )
    private var cancellables: Set<AnyCancellable> = []
    private var eventMonitors: [Any] = []

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: IslandMetrics.width, height: IslandMetrics.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configureWindow()
        configureContent()
        observeState()
        observeScreenChanges()
        installEventMonitors()
        _ = codexRadarViewModel
        updateFrames()
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
    }

    private func ensureDetailWindow() -> NSPanel {
        if let detailWindow {
            return detailWindow
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: IslandMetrics.width, height: currentDetailHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let detailView = DetailPanelView(
            viewModel: viewModel,
            remoteViewModel: remoteViewModel,
            newAPIViewModel: newAPIViewModel,
            subAPIViewModel: subAPIViewModel,
            codexRadarViewModel: codexRadarViewModel,
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
            },
            onCodexRadarRefresh: { [weak self] in
                self?.codexRadarViewModel.refreshNow()
            }
        )
        let detailHostingView = NSHostingView(rootView: detailView)
        detailHostingView.frame = NSRect(x: 0, y: 0, width: IslandMetrics.width, height: currentDetailHeight)
        detailHostingView.wantsLayer = true
        detailHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = detailHostingView
        detailWindow = panel
        return panel
    }

    private func observeState() {
        overlayState.$isExpanded
            .removeDuplicates()
            .sink { [weak self] isExpanded in
                self?.setDetailVisible(isExpanded)
            }
            .store(in: &cancellables)

        settings.$taskHistoryRange
            .combineLatest(settings.$showPeriodUsage)
            .combineLatest(settings.$showSparkQuota)
            .sink { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.updateFrames()
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
                self.updateFrames()
            }
            .store(in: &cancellables)
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
        if window.frame.contains(location) || detailWindow?.frame.contains(location) == true {
            return
        }
        overlayState.isExpanded = false
    }

    private func setDetailVisible(_ visible: Bool) {
        viewModel.setDetailVisible(visible)
        updateFrames()
        if visible {
            let detailWindow = ensureDetailWindow()
            updateFrames()
            refreshDetailData()
            if window.childWindows?.contains(detailWindow) != true {
                window.addChildWindow(detailWindow, ordered: .below)
            }
            detailWindow.order(.below, relativeTo: window.windowNumber)
            window.orderFrontRegardless()
        } else {
            if let detailWindow {
                window.removeChildWindow(detailWindow)
                detailWindow.orderOut(nil)
            }
        }
    }

    private func refreshDetailData() {
        viewModel.refreshAll()

        if settings.remoteMonitorEnabled {
            remoteViewModel.refreshNow()
        }
        if settings.newAPIMonitorEnabled {
            newAPIViewModel.refreshNow()
        }
        if settings.subAPIMonitorEnabled {
            subAPIViewModel.refreshNow()
        }
        if settings.codexRadarEnabled {
            codexRadarViewModel.refreshIfNeeded()
        }
    }

    private func restorePanelOrdering() {
        guard overlayState.isExpanded else {
            return
        }

        let detailWindow = ensureDetailWindow()
        if window.childWindows?.contains(detailWindow) != true {
            window.addChildWindow(detailWindow, ordered: .below)
        }
        detailWindow.order(.below, relativeTo: window.windowNumber)
        window.orderFrontRegardless()
    }

    private func updateFrames() {
        guard let screen = primaryDisplayScreen() ?? NSScreen.screens.first else {
            return
        }

        let detailHeight = detailWindow == nil && !overlayState.isExpanded ? localDetailHeight : currentDetailHeight
        let x = screen.frame.midX - IslandMetrics.width / 2
        let islandY = screen.frame.maxY - IslandMetrics.collapsedHeight
        let islandFrame = NSRect(x: x, y: islandY, width: IslandMetrics.width, height: IslandMetrics.collapsedHeight)
        let detailFrame = NSRect(
            x: x,
            y: islandY - detailHeight + IslandMetrics.detailOverlap,
            width: IslandMetrics.width,
            height: detailHeight
        )

        window.setFrame(islandFrame, display: true, animate: false)
        window.contentView?.frame = NSRect(x: 0, y: 0, width: IslandMetrics.width, height: IslandMetrics.collapsedHeight)
        detailWindow?.setFrame(detailFrame, display: true, animate: false)
        detailWindow?.contentView?.frame = NSRect(x: 0, y: 0, width: IslandMetrics.width, height: detailHeight)
    }

    private func primaryDisplayScreen() -> NSScreen? {
        let primaryDisplayID = CGMainDisplayID()
        return NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return screenNumber.uint32Value == primaryDisplayID
        }
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

    private var currentDetailHeight: CGFloat {
        let localHeight = localDetailHeight
        let enabledExternalRows = [
            settings.remoteMonitorEnabled ? remoteViewModel.snapshot.accounts.count : nil,
            settings.newAPIMonitorEnabled ? newAPIViewModel.snapshot.accounts.count : nil,
            settings.subAPIMonitorEnabled ? subAPIViewModel.snapshot.accounts.count : nil
        ].compactMap { $0 }

        guard !enabledExternalRows.isEmpty else {
            return localHeight
        }
        let remoteRows = max(1, enabledExternalRows.max() ?? 1)
        return max(localHeight, IslandMetrics.remoteDetailHeight(accountRows: remoteRows))
    }

    private var localDetailHeight: CGFloat {
        IslandMetrics.detailHeight(
            taskRows: IslandMetrics.visibleTaskRows,
            showsPeriodUsage: settings.showPeriodUsage,
            showsSparkQuota: settings.showSparkQuota
        )
    }
}

@MainActor
final class SettingsWindowController {
    private let settings: CodexNotchSettings
    private let remoteViewModel: RemoteMonitorViewModel
    private let newAPIViewModel: BalanceMonitorViewModel
    private let subAPIViewModel: BalanceMonitorViewModel
    private let codexRadarViewModel: CodexRadarViewModel
    private let onRefresh: () -> Void
    private var window: NSWindow?

    init(
        settings: CodexNotchSettings,
        remoteViewModel: RemoteMonitorViewModel,
        newAPIViewModel: BalanceMonitorViewModel,
        subAPIViewModel: BalanceMonitorViewModel,
        codexRadarViewModel: CodexRadarViewModel,
        onRefresh: @escaping () -> Void
    ) {
        self.settings = settings
        self.remoteViewModel = remoteViewModel
        self.newAPIViewModel = newAPIViewModel
        self.subAPIViewModel = subAPIViewModel
        self.codexRadarViewModel = codexRadarViewModel
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
            codexRadarViewModel: codexRadarViewModel,
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
