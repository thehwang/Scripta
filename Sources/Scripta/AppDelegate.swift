import AppKit
import ScriptaCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let recorder = MeetingRecorder()
    private let summaryModelManager = SummaryModelManager()
    private let translationService = TranslationService()
    private let meetingStore = MeetingStore()
    private var savedFullFrame: NSRect?
    private var isShowingSetup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(DisplayMode.full.rawValue, forKey: "Scripta.displayMode")
        loadAppIcon()
        setupMainMenu()
        setupMenuBar()
        showPermissionsWindow()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDisplayModeChanged(_:)),
            name: .displayModeChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMinimalWindowLayoutNeeded),
            name: .minimalWindowLayoutNeeded, object: nil
        )
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

        let fitting = win.contentView?.fittingSize ?? NSSize(width: 560, height: 96)
        let contentWidth = min(900, max(480, fitting.width))
        let contentHeight = min(280, max(72, fitting.height))
        let contentSize = NSSize(width: contentWidth, height: contentHeight)

        var frame = win.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        frame.origin.x = screen.visibleFrame.midX - frame.width / 2

        let bottomMargin = max(48, screen.visibleFrame.height * 0.06)
        frame.origin.y = screen.visibleFrame.minY + bottomMargin

        // Keep the entire window inside the visible area.
        let topLimit = screen.visibleFrame.maxY - 24
        if frame.maxY > topLimit {
            frame.origin.y = topLimit - frame.height
        }
        if frame.minY < screen.visibleFrame.minY + 16 {
            frame.origin.y = screen.visibleFrame.minY + 16
        }

        win.setFrame(frame, display: true, animate: animated)
    }

    private func configureHostingController(_ hosting: NSHostingController<some View>) {
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = .intrinsicContentSize
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Scripta")

        appMenu.addItem(withTitle: "About Scripta", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(showSetup), keyEquivalent: ",")
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
            savedFullFrame = win.frame
            win.styleMask = [.titled, .resizable, .fullSizeContentView]
            win.standardWindowButton(.closeButton)?.isHidden = true
            win.standardWindowButton(.miniaturizeButton)?.isHidden = true
            win.standardWindowButton(.zoomButton)?.isHidden = true
            win.level = .floating
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.backgroundColor = .clear
            win.isOpaque = false
            win.minSize = NSSize(width: 320, height: 72)
            win.maxSize = NSSize(width: 900, height: 280)
            win.setContentSize(NSSize(width: 560, height: 96))
            DispatchQueue.main.async { [weak self] in
                self?.applyMinimalWindowFrame(win, animated: true)
                DispatchQueue.main.async {
                    self?.applyMinimalWindowFrame(win, animated: false)
                }
            }
        case .full:
            win.standardWindowButton(.closeButton)?.isHidden = false
            win.standardWindowButton(.miniaturizeButton)?.isHidden = false
            win.standardWindowButton(.zoomButton)?.isHidden = false
            win.level = .normal
            win.isMovableByWindowBackground = false
            win.titlebarAppearsTransparent = false
            win.titleVisibility = .visible
            win.backgroundColor = nil
            win.isOpaque = true
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.minSize = NSSize(width: 760, height: 680)
            win.maxSize = NSSize(width: .max, height: .max)
            if let saved = savedFullFrame {
                win.setFrame(saved, display: true, animate: true)
            } else {
                win.setContentSize(NSSize(width: 760, height: 680))
                win.center()
            }
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
        menu.addItem(withTitle: "AI Model Settings...", action: #selector(showSetup), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Scripta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    private func showPermissionsWindow() {
        let permView = PermissionsView { [weak self] in
            self?.showMainWindow()
        }
        let hosting = NSHostingController(rootView: permView)
        configureHostingController(hosting)
        let win = window ?? NSWindow(contentViewController: hosting)
        win.contentViewController = hosting
        win.title = "Scripta"
        win.setContentSize(NSSize(width: 740, height: 480))
        win.styleMask = [.titled, .closable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func showSetupWindow() {
        let setupView = SetupView(modelManager: summaryModelManager) { [weak self] in
            self?.showMainWindow()
        }
        let hosting = NSHostingController(rootView: setupView)
        configureHostingController(hosting)
        let win = window ?? NSWindow(contentViewController: hosting)
        win.contentViewController = hosting
        win.title = "Scripta — AI Model Setup"
        win.setContentSize(NSSize(width: 560, height: 520))
        win.styleMask = [.titled, .closable, .resizable]
        win.minSize = NSSize(width: 540, height: 400)
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        isShowingSetup = true
    }

    private func showMainWindow() {
        let rootView = ContentView(
            recorder: recorder,
            summaryModelManager: summaryModelManager,
            translationService: translationService,
            meetingStore: meetingStore,
            onOpenModelSettings: { [weak self] in
                self?.showSetupWindow()
            }
        )
        let hosting = NSHostingController(rootView: rootView)
        configureHostingController(hosting)

        if let win = window {
            win.contentViewController = hosting
            win.title = "Scripta"
            win.setContentSize(NSSize(width: 760, height: 680))
            win.styleMask.insert(.resizable)
            win.makeKeyAndOrderFront(nil)
        } else {
            let win = NSWindow(contentViewController: hosting)
            win.title = "Scripta"
            win.setContentSize(NSSize(width: 760, height: 680))
            win.styleMask.insert(.resizable)
            win.delegate = self
            win.center()
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
        return true
    }
}
