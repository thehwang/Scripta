import AppKit
import MeetingPilotCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let recorder = MeetingRecorder()
    private let summaryModelManager = SummaryModelManager()
    private let translationService = TranslationService()
    private var savedFullFrame: NSRect?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(DisplayMode.full.rawValue, forKey: "MeetingPilot.displayMode")
        setupMenuBar()
        showPermissionsWindow()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDisplayModeChanged(_:)),
            name: .displayModeChanged, object: nil
        )
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
            win.minSize = NSSize(width: 320, height: 80)
            win.maxSize = NSSize(width: 1200, height: 400)
            let size = NSSize(width: 560, height: 120)
            let screen = win.screen ?? NSScreen.main ?? NSScreen.screens[0]
            let origin = NSPoint(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.minY + 24
            )
            win.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
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

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "person.2.wave.2", accessibilityDescription: "Meeting Pilot")
            button.toolTip = "Meeting Pilot"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Open Meeting Pilot", action: #selector(openMainWindow), keyEquivalent: "o")
        menu.addItem(withTitle: "Start/Stop Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Toggle Minimal/Full View", action: #selector(toggleDisplayMode), keyEquivalent: "m")
        menu.addItem(withTitle: "AI Model Settings...", action: #selector(showSetup), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Meeting Pilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    private func showPermissionsWindow() {
        let permView = PermissionsView { [weak self] in
            self?.showMainWindow()
        }
        let hosting = NSHostingController(rootView: permView)
        let win = window ?? NSWindow(contentViewController: hosting)
        win.contentViewController = hosting
        win.title = "Meeting Pilot"
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
        let win = window ?? NSWindow(contentViewController: hosting)
        win.contentViewController = hosting
        win.title = "Meeting Pilot — AI Model Setup"
        win.setContentSize(NSSize(width: 560, height: 520))
        win.styleMask = [.titled, .closable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func showMainWindow() {
        let rootView = ContentView(
            recorder: recorder,
            summaryModelManager: summaryModelManager,
            translationService: translationService,
            onOpenModelSettings: { [weak self] in
                self?.showSetupWindow()
            }
        )
        let hosting = NSHostingController(rootView: rootView)

        if let win = window {
            win.contentViewController = hosting
            win.title = "Meeting Pilot"
            win.setContentSize(NSSize(width: 760, height: 680))
            win.styleMask.insert(.resizable)
            win.makeKeyAndOrderFront(nil)
        } else {
            let win = NSWindow(contentViewController: hosting)
            win.title = "Meeting Pilot"
            win.setContentSize(NSSize(width: 760, height: 680))
            win.styleMask.insert(.resizable)
            win.center()
            win.makeKeyAndOrderFront(nil)
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openMainWindow() {
        showMainWindow()
    }

    @objc private func showSetup() {
        showSetupWindow()
    }

    @objc private func toggleDisplayMode() {
        let current = UserDefaults.standard.string(forKey: "MeetingPilot.displayMode") ?? DisplayMode.full.rawValue
        let next: DisplayMode = (current == DisplayMode.minimal.rawValue) ? .full : .minimal
        UserDefaults.standard.set(next.rawValue, forKey: "MeetingPilot.displayMode")
        NotificationCenter.default.post(name: .displayModeChanged, object: next)
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
