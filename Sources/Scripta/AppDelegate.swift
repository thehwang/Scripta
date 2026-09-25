import AppKit
import Darwin
import ScriptaCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let recorder = MeetingRecorder()
    private let summaryModelManager = SummaryModelManager()
    private let translationService = TranslationService()
    private let meetingStore = MeetingStore()
    private lazy var scheduleStore = ScheduleStore()
    private lazy var scheduleCoordinator = ScheduleCoordinator(recorder: recorder, store: scheduleStore)
    private var savedFullContentSize: NSSize?
    private var isShowingSetup = false
    private var windowObservers: [NSObjectProtocol] = []

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await recorder.prepareForTermination()
            // whisper.cpp's ggml Metal backend can abort during C++ static teardown on
            // normal exit(); skip atexit handlers after explicit cleanup.
            _exit(0)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(DisplayMode.full.rawValue, forKey: "Scripta.displayMode")
        loadAppIcon()
        setupMainMenu()
        setupMenuBar()
        scheduleCoordinator.start()
        if UserDefaults.standard.bool(forKey: "Scripta.permissionsOnboardingComplete") {
            showMainWindow()
        } else {
            showPermissionsWindow()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDisplayModeChanged(_:)),
            name: .displayModeChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMinimalWindowLayoutNeeded),
            name: .minimalWindowLayoutNeeded, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFullWindowLayoutNeeded(_:)),
            name: .fullWindowLayoutNeeded, object: nil
        )
    }

    @objc private func handleFullWindowLayoutNeeded(_ note: Notification) {
        guard let win = window,
              UserDefaults.standard.string(forKey: "Scripta.displayMode") != DisplayMode.minimal.rawValue else { return }
        let showChat = note.userInfo?[WindowLayoutUserInfoKey.showChatPanel] as? Bool ?? false
        let fontScale = note.userInfo?[WindowLayoutUserInfoKey.fontScale] as? Double
            ?? UserDefaults.standard.double(forKey: "Scripta.fontScale")
        let animated = note.userInfo?[WindowLayoutUserInfoKey.animated] as? Bool ?? false
        let widthOnly = note.userInfo?[WindowLayoutUserInfoKey.widthOnly] as? Bool ?? false
        DispatchQueue.main.async { [weak self] in
            self?.applyFullWindowFrame(
                win,
                showChatPanel: showChat,
                fontScale: fontScale,
                animated: animated,
                widthOnly: widthOnly
            )
        }
    }

    @objc private func handleMinimalWindowLayoutNeeded() {
        guard let win = window,
              UserDefaults.standard.string(forKey: "Scripta.displayMode") == DisplayMode.minimal.rawValue else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyMinimalWindowFrame(win, animated: false)
        }
    }

    private func applyMinimalWindowFrame(_ win: NSWindow, animated: Bool) {
        guard let screen = win.screen ?? NSScreen.main else { return }

        win.contentView?.layoutSubtreeIfNeeded()

        let fontScale = UserDefaults.standard.double(forKey: "Scripta.fontScale")
        let minWidth = WindowLayout.minimalContentWidth(fontScale: fontScale)
        let fitting = win.contentView?.fittingSize ?? NSSize(width: minWidth, height: 96)
        let contentWidth = min(WindowLayout.minimalMaxSize(fontScale: fontScale).width, max(minWidth, fitting.width))
        let minHeight = WindowLayout.minimalMinContentHeight(fontScale: fontScale)
        let contentHeight = min(320, max(minHeight, fitting.height))
        let contentSize = NSSize(width: contentWidth, height: contentHeight)

        var frame = win.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        // Resize around the current center so the user can place the window anywhere.
        frame.origin.x = win.frame.midX - frame.width / 2
        frame.origin.y = win.frame.midY - frame.height / 2
        clampWindowFrame(&frame, to: screen.visibleFrame)

        win.setFrame(frame, display: true, animate: animated)
    }

    private func applyMinimalWindowChrome(_ win: NSWindow) {
        win.styleMask = [.titled, .resizable, .fullSizeContentView]
        win.title = ""
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.level = .floating
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        if #available(macOS 11.0, *) {
            win.titlebarSeparatorStyle = .none
        }
        win.isMovableByWindowBackground = true
        win.backgroundColor = .clear
        win.isOpaque = false
        let fontScale = UserDefaults.standard.double(forKey: "Scripta.fontScale")
        win.minSize = WindowLayout.minimalMinSize(fontScale: fontScale)
        win.maxSize = WindowLayout.minimalMaxSize(fontScale: fontScale)
    }

    private func configureWindowPersistence(_ win: NSWindow) {
        win.isReleasedWhenClosed = false
        win.delegate = self
        attachWindowObservers(win)
    }

    private func attachWindowObservers(_ win: NSWindow) {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()

        let screenChange = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.handleMinimalWindowLayoutNeeded()
        }
        windowObservers.append(screenChange)
    }

    private func resetWindowForFullMode(_ win: NSWindow) {
        win.standardWindowButton(.closeButton)?.isHidden = false
        win.standardWindowButton(.miniaturizeButton)?.isHidden = false
        win.standardWindowButton(.zoomButton)?.isHidden = false
        win.level = .normal
        win.isMovableByWindowBackground = false
        win.titlebarAppearsTransparent = false
        win.titleVisibility = .visible
        win.backgroundColor = nil
        win.isOpaque = true
        var mask = win.styleMask
        mask.insert([.titled, .closable, .miniaturizable, .resizable])
        mask.remove(.fullSizeContentView)
        win.styleMask = mask
        win.contentResizeIncrements = NSSize(width: 1, height: 1)
    }

    private func applyFullWindowFrame(
        _ win: NSWindow,
        showChatPanel: Bool,
        fontScale: Double,
        animated: Bool,
        force: Bool = false,
        preferredContentSize: NSSize? = nil,
        recenter: Bool = false,
        widthOnly: Bool = false
    ) {
        resetWindowForFullMode(win)
        setHostingSizingOptions(win, sizing: .standardBounds)

        let screen = win.screen ?? NSScreen.main
        let screenVisible = screen?.visibleFrame ?? .zero
        let minSize = WindowLayout.fullMinSize(showChatPanel: showChatPanel, fontScale: fontScale)
        let defaultTarget = WindowLayout.fullContentSize(showChatPanel: showChatPanel, fontScale: fontScale)
        let current = win.contentRect(forFrameRect: win.frame).size

        let target: NSSize
        if widthOnly {
            let scale = WindowLayout.normalizedFontScale(fontScale)
            let targetWidth = (showChatPanel ? WindowLayout.fullChatWidth : WindowLayout.fullBaseWidth) * scale
            let maxWidth = max(minSize.width, screenVisible.width - 32)
            let clampedWidth = min(max(targetWidth, minSize.width), maxWidth)
            target = NSSize(width: clampedWidth, height: max(current.height, minSize.height))
        } else {
            target = preferredContentSize.map {
                WindowLayout.clampedFullContentSize(
                    $0, showChatPanel: showChatPanel, fontScale: fontScale, screenVisible: screenVisible
                )
            } ?? defaultTarget
        }

        win.minSize = minSize
        win.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let needsResize = widthOnly
            ? abs(current.width - target.width) > 4
            : abs(current.width - target.width) > 4 || abs(current.height - target.height) > 4
        guard force || needsResize else {
            ensureWindowOnScreen(win)
            return
        }

        win.setContentSize(target)
        var frame = win.frameRect(forContentRect: NSRect(origin: .zero, size: target))
        if recenter {
            frame.origin.x = screenVisible.midX - frame.width / 2
            frame.origin.y = screenVisible.midY - frame.height / 2
        } else {
            frame.origin.x = win.frame.midX - frame.width / 2
            frame.origin.y = win.frame.midY - frame.height / 2
        }
        clampWindowFrame(&frame, to: screenVisible)
        win.setFrame(frame, display: true, animate: animated)
        ensureWindowOnScreen(win)

        // SwiftUI may settle one layout pass later; re-sync once content size is stable.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ensureWindowOnScreen(win)
            let settled = win.contentRect(forFrameRect: win.frame).size
            if widthOnly {
                if abs(settled.width - target.width) > 6 {
                    win.setContentSize(NSSize(width: target.width, height: settled.height))
                    self.ensureWindowOnScreen(win)
                }
            } else if abs(settled.height - target.height) > 6 || abs(settled.width - target.width) > 6 {
                win.setContentSize(target)
                self.ensureWindowOnScreen(win)
            }
        }
    }

    private func ensureWindowOnScreen(_ win: NSWindow) {
        guard let screen = win.screen ?? NSScreen.main else { return }
        var frame = win.frame
        clampWindowFrame(&frame, to: screen.visibleFrame)
        if frame != win.frame {
            win.setFrame(frame, display: true)
        }
    }

    private func clampWindowFrame(_ frame: inout NSRect, to screenVisible: NSRect) {
        guard screenVisible.width > 0, screenVisible.height > 0 else { return }
        if frame.maxY > screenVisible.maxY - 8 {
            frame.origin.y = screenVisible.maxY - frame.height - 8
        }
        if frame.minY < screenVisible.minY + 8 {
            frame.origin.y = screenVisible.minY + 8
        }
        if frame.maxX > screenVisible.maxX - 8 {
            frame.origin.x = screenVisible.maxX - frame.width - 8
        }
        if frame.minX < screenVisible.minX + 8 {
            frame.origin.x = screenVisible.minX + 8
        }
    }

    private func setHostingSizingOptions(_ win: NSWindow, sizing: NSHostingSizingOptions) {
        guard #available(macOS 13.0, *), let controller = win.contentViewController else { return }
        func apply<V: View>(_ hosting: NSHostingController<V>) {
            hosting.sizingOptions = sizing
        }
        switch controller {
        case let hosting as NSHostingController<ContentView>: apply(hosting)
        case let hosting as NSHostingController<PermissionsView>: apply(hosting)
        case let hosting as NSHostingController<SetupView>: apply(hosting)
        default: break
        }
    }

    private func applyPermissionsWindowFrame(_ win: NSWindow) {
        win.styleMask = [.titled, .closable]
        win.minSize = WindowLayout.permissionsMinSize
        win.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        win.setContentSize(WindowLayout.permissionsContentSize)
        win.center()
    }

    private func configureHostingController(
        _ hosting: NSHostingController<some View>,
        sizing: NSHostingSizingOptions = []
    ) {
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = sizing
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Scripta")

        appMenu.addItem(withTitle: "About Scripta", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSetup), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Permissions Setup...", action: #selector(reopenPermissionsOnboarding), keyEquivalent: "")
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(title: "Hide Scripta", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApp
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Scripta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Standard Edit menu so common shortcuts (⌘C/⌘V/⌘X/⌘A/⌘Z) work in
        // text fields and the chat panel without us wiring them individually.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func handleDisplayModeChanged(_ note: Notification) {
        guard let mode = note.object as? DisplayMode, let win = window else { return }
        switch mode {
        case .minimal:
            let contentSize = win.contentRect(forFrameRect: win.frame).size
            if WindowLayout.isReasonableFullContentSize(contentSize) {
                savedFullContentSize = contentSize
            }
            setHostingSizingOptions(win, sizing: .intrinsicContentSize)
            applyMinimalWindowChrome(win)
            DispatchQueue.main.async { [weak self] in
                self?.applyMinimalWindowFrame(win, animated: true)
            }
        case .full:
            let fontScale = UserDefaults.standard.double(forKey: "Scripta.fontScale")
            applyFullWindowFrame(
                win,
                showChatPanel: false,
                fontScale: fontScale,
                animated: true,
                force: true,
                preferredContentSize: savedFullContentSize,
                recenter: false
            )
        }
    }

    private func loadAppIcon() {
        let execURL = Bundle.main.executableURL ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let resourcesURL = execURL
            .deletingLastPathComponent() // MacOS/
            .deletingLastPathComponent() // Contents/
            .appendingPathComponent("Contents/Resources/AppIcon.icns")
        if let icon = NSImage(contentsOf: resourcesURL) {
            NSApplication.shared.applicationIconImage = icon
            return
        }
        if let bundleIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: bundleIcon) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "person.2.wave.2", accessibilityDescription: "Scripta")
            button.toolTip = "Scripta"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "About Scripta", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Scripta", action: #selector(openMainWindow), keyEquivalent: "o")
        menu.addItem(withTitle: "Start/Stop Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Toggle Minimal/Full View", action: #selector(toggleDisplayMode), keyEquivalent: "m")
        menu.addItem(withTitle: "Meeting History", action: #selector(openHistory), keyEquivalent: "h")
        menu.addItem(withTitle: "Scheduled Recordings…", action: #selector(openSchedules), keyEquivalent: "")
        menu.addItem(withTitle: "AI Model Settings...", action: #selector(showSetup), keyEquivalent: ",")
        menu.addItem(withTitle: "Permissions Setup...", action: #selector(reopenPermissionsOnboarding), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Scripta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    private func showPermissionsWindow() {
        let permView = PermissionsView { [weak self] in
            UserDefaults.standard.set(true, forKey: "Scripta.permissionsOnboardingComplete")
            self?.showMainWindow()
        }
        let hosting = NSHostingController(rootView: permView)
        configureHostingController(hosting, sizing: .intrinsicContentSize)
        let win = window ?? NSWindow(contentViewController: hosting)
        win.contentViewController = hosting
        win.title = "Scripta"
        applyPermissionsWindowFrame(win)
        configureWindowPersistence(win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func showSetupWindow() {
        let setupView = SetupView(modelManager: summaryModelManager) { [weak self] in
            self?.showMainWindow()
        }
        let hosting = NSHostingController(rootView: setupView)
        configureHostingController(hosting, sizing: .intrinsicContentSize)
        let win = window ?? NSWindow(contentViewController: hosting)
        win.contentViewController = hosting
        win.title = "Scripta — AI Model Setup"
        win.setContentSize(WindowLayout.setupContentSize)
        win.styleMask = [.titled, .closable, .resizable]
        win.minSize = WindowLayout.setupMinSize
        configureWindowPersistence(win)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        isShowingSetup = true
    }

    private func showMainWindow() {
        UserDefaults.standard.set(DisplayMode.full.rawValue, forKey: "Scripta.displayMode")

        let rootView = ContentView(
            recorder: recorder,
            summaryModelManager: summaryModelManager,
            translationService: translationService,
            meetingStore: meetingStore,
            scheduleCoordinator: scheduleCoordinator,
            onOpenModelSettings: { [weak self] in
                self?.showSetupWindow()
            }
        )
        let hosting = NSHostingController(rootView: rootView)
        configureHostingController(hosting, sizing: .standardBounds)

        let fontScale = UserDefaults.standard.double(forKey: "Scripta.fontScale")

        if let win = window {
            win.contentViewController = hosting
            win.title = "Scripta"
            configureWindowPersistence(win)
            applyFullWindowFrame(
                win,
                showChatPanel: false,
                fontScale: fontScale,
                animated: false,
                force: true,
                recenter: !win.isVisible
            )
            win.makeKeyAndOrderFront(nil)
        } else {
            let win = NSWindow(contentViewController: hosting)
            win.title = "Scripta"
            configureWindowPersistence(win)
            applyFullWindowFrame(
                win,
                showChatPanel: false,
                fontScale: fontScale,
                animated: false,
                force: true,
                recenter: true
            )
            win.makeKeyAndOrderFront(nil)
            window = win
        }
        isShowingSetup = false
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Scripta",
            .applicationVersion: version,
            .version: build,
            .credits: NSAttributedString(
                string: "Privacy-first meeting transcription & AI summary.\n100% local. No cloud. No subscriptions.\n\ngithub.com/thehwang/Scripta",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: {
                        let p = NSMutableParagraphStyle()
                        p.alignment = .center
                        return p
                    }()
                ]
            ),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 thehwang. MIT License."
        ])
    }

    @objc private func openMainWindow() {
        showMainWindow()
    }

    @objc private func showSetup() {
        showSetupWindow()
    }

    @objc private func reopenPermissionsOnboarding() {
        isShowingSetup = false
        UserDefaults.standard.set(false, forKey: "Scripta.permissionsOnboardingComplete")
        window?.orderOut(nil)
        showPermissionsWindow()
    }

    @objc private func toggleDisplayMode() {
        let current = UserDefaults.standard.string(forKey: "Scripta.displayMode") ?? DisplayMode.full.rawValue
        let next: DisplayMode = (current == DisplayMode.minimal.rawValue) ? .full : .minimal
        UserDefaults.standard.set(next.rawValue, forKey: "Scripta.displayMode")
        NotificationCenter.default.post(name: .displayModeChanged, object: next)
    }

    @objc private func openHistory() {
        showMainWindow()
        NotificationCenter.default.post(name: .showMeetingHistory, object: nil)
    }

    @objc private func openSchedules() {
        showMainWindow()
        NotificationCenter.default.post(name: .showScheduledRecordings, object: nil)
    }

    @objc private func toggleRecording() {
        Task { @MainActor in
            if recorder.isRecording {
                recorder.stopRecording()
            } else {
                await recorder.startRecording()
            }
            showMainWindow()
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isShowingSetup {
            showMainWindow()
            return false
        }
        sender.orderOut(nil)
        return false
    }
}
