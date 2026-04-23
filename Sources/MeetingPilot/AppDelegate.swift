import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let recorder = MeetingRecorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        showMainWindow()
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
        menu.addItem(withTitle: "Quit Meeting Pilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
        statusItem = item
    }

    private func showMainWindow() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ContentView(recorder: recorder)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Meeting Pilot"
        window.setContentSize(NSSize(width: 760, height: 560))
        window.styleMask.insert(.resizable)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func openMainWindow() {
        showMainWindow()
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
