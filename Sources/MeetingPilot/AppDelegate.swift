import AppKit
import MeetingPilotCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let recorder = MeetingRecorder()
    private let modelManager = ModelManager()
    private let translationService = TranslationService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        showPermissionsWindow()
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
        menu.addItem(withTitle: "Model Settings...", action: #selector(showSetup), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Meeting Pilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    private func showPermissionsWindow() {
        let permView = PermissionsView { [weak self] in
            if self?.modelManager.isReady == true {
                self?.loadModelAndShowMain()
            } else {
                self?.showSetupWindow()
            }
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
        let setupView = SetupView(modelManager: modelManager) { [weak self] in
            self?.loadModelAndShowMain()
        }
        let hosting = NSHostingController(rootView: setupView)
        let win = window ?? NSWindow(contentViewController: hosting)
        win.contentViewController = hosting
        win.title = "Meeting Pilot — Setup"
        win.setContentSize(NSSize(width: 540, height: 500))
        win.styleMask = [.titled, .closable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func loadModelAndShowMain() {
        guard let path = modelManager.localModelPath else {
            showSetupWindow()
            return
        }

        Task { @MainActor in
            do {
                try await recorder.loadWhisperModel(path: path)
            } catch {
                mplog("Failed to load Whisper model: \(error.localizedDescription)")
                recorder.transcriptionEngine = .apple
            }

            showMainWindow()
        }
    }

    private func showMainWindow() {
        let rootView = ContentView(recorder: recorder, translationService: translationService)
        let hosting = NSHostingController(rootView: rootView)

        if let win = window {
            win.contentViewController = hosting
            win.title = "Meeting Pilot"
            win.setContentSize(NSSize(width: 760, height: 620))
            win.styleMask.insert(.resizable)
            win.makeKeyAndOrderFront(nil)
        } else {
            let win = NSWindow(contentViewController: hosting)
            win.title = "Meeting Pilot"
            win.setContentSize(NSSize(width: 760, height: 620))
            win.styleMask.insert(.resizable)
            win.center()
            win.makeKeyAndOrderFront(nil)
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openMainWindow() {
        if modelManager.isReady {
            showMainWindow()
        } else {
            showSetupWindow()
        }
    }

    @objc private func showSetup() {
        showSetupWindow()
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
