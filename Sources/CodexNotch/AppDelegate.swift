import AppKit
import Combine
import SwiftUI

@main
struct CodexNotchApp {
    static func main() {
        if CommandLine.arguments.contains("--print-snapshot") || CommandLine.arguments.contains("--print-fast-snapshot") {
            let includePeriodUsage = !CommandLine.arguments.contains("--print-fast-snapshot")
            let snapshot = CodexUsageStore().loadSnapshot(includePeriodUsage: includePeriodUsage)
            print("primary=\(Formatters.percent(snapshot.primaryPercent)) secondary=\(Formatters.percent(snapshot.secondaryPercent)) running=\(snapshot.isRunning)")
            print("usage24h=\(snapshot.usage24h) usage7d=\(snapshot.usage7d) usage30d=\(snapshot.usage30d)")
            for task in snapshot.tasks.prefix(4) {
                print("task=\(task.status.label) \(task.title) \(task.tokenCount)")
            }
            if let error = snapshot.errorMessage {
                print("error=\(error)")
            }
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("Codex Notch runs as a persistent notch overlay")
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
        let appMenu = NSMenu(title: "Codex Notch")
        appMenu.addItem(withTitle: "退出 Codex 刘海", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
    private let overlayState = OverlayState()
    private let window: NSPanel
    private let detailWindow: NSPanel
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
        installEventMonitors()
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
        detailHostingView.frame = NSRect(x: 0, y: 0, width: IslandMetrics.width, height: currentDetailHeight)
        detailHostingView.wantsLayer = true
        detailHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        detailWindow.contentView = detailHostingView
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
        if window.frame.contains(location) || detailWindow.frame.contains(location) {
            return
        }
        overlayState.isExpanded = false
    }

    private func setDetailVisible(_ visible: Bool) {
        updateFrames()
        if visible {
            if window.childWindows?.contains(detailWindow) != true {
                window.addChildWindow(detailWindow, ordered: .below)
            }
            detailWindow.order(.below, relativeTo: window.windowNumber)
            window.orderFrontRegardless()
        } else {
            window.removeChildWindow(detailWindow)
            detailWindow.orderOut(nil)
        }
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

        let detailHeight = currentDetailHeight
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
        detailWindow.setFrame(detailFrame, display: true, animate: false)
        detailWindow.contentView?.frame = NSRect(x: 0, y: 0, width: IslandMetrics.width, height: detailHeight)
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
        let localHeight = IslandMetrics.detailHeight(
            taskRows: IslandMetrics.visibleTaskRows,
            showsPeriodUsage: settings.showPeriodUsage
        )
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
        window.title = "Codex 刘海设置"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        return window
    }
}
