import AppKit
import MonitorCore
import SwiftUI

@main
struct VPSMonitorApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    // The menu bar item, its popover and Settings are AppKit (StatusItemController). SwiftUI needs a scene; this one
    // opens no window by itself.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Monitor?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        let poster = NotificationPoster.make()
        let monitor = Monitor(
            settings: Settings.load(from: defaults),
            environment: Monitor.Environment(
                backend: { SSHBackend(server: $0, language: $1) },
                installer: { AppInfo.bundledInstaller() },
                appVersion: AppInfo.version(),
                notify: { poster.post($0) },
                copy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                save: { $0.save(to: defaults) }))
        self.monitor = monitor
        monitor.start()
        statusItem = StatusItemController(monitor: monitor)
    }

    /// Opening the app while it runs (Finder, Spotlight, `open`) shows the menu bar item and its popover.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.reopen()
        return true
    }
}
