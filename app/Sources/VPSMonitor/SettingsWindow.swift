import AppKit
import MonitorCore
import MonitorUI
import SwiftUI

/// The Settings window. Its view lives in MonitorUI, so `vpsmon-mac render --settings` draws the same one.
@MainActor
final class SettingsWindow: NSObject {
    private let monitor: Monitor
    private var window: NSWindow?

    init(monitor: Monitor) {
        self.monitor = monitor
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.title = monitor.strings.settings.windowTitle
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView(monitor: monitor, loginItem: .mainApp))
        // The window follows the view's height, which grows when setup shows an install command.
        controller.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Tok.bg)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
