import AppKit
import MonitorCore
import MonitorUI
import Observation
import SwiftUI

/// The menu bar item: `server.rack` tinted by the worst alert, the alert's label or busy/total Claude Code sessions,
/// and a click opens the popover. AppKit rather than MenuBarExtra, which names its item "Item-0" like every other app's and quits
/// the app when Control Center hides it (learned in Claude Usage).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let monitor: Monitor
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var presence = MenuBarPresence()
    private var visibility: NSKeyValueObservation?
    private lazy var settingsWindow = SettingsWindow(monitor: monitor)
    private lazy var helpWindow = MenuBarHiddenWindow(
        strings: { [monitor] in monitor.strings },
        showAgain: { [weak self] in self?.showAgain() },
        closed: { [weak self] in self?.change { $0.helpClosed() } })

    init(monitor: Monitor) {
        self.monitor = monitor
        super.init()
        // Control Center keeps the item's visibility under this name.
        statusItem.autosaveName = "com.jeff909dev.VPSMonitor.status"
        // Command-drag can't remove it, and being hidden never quits the app.
        statusItem.behavior = []
        // Ask for it on every launch: if the user turned it off in System Settings, Control Center keeps it hidden
        // and the help window says so.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: Popover.width, height: Popover.height)
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            monitor: monitor,
            openSettings: { [weak self] in self?.openSettings() },
            quit: { NSApplication.shared.terminate(nil) }))
        showStatus()
        visibility = statusItem.observe(\.isVisible) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let visible = self.statusItem.isVisible
                self.change { $0.visibilityChanged(visible: visible) }
            }
        }
        checkSoon()
    }

    /// The app was opened again while it runs: show the item, and its popover if the item is in the menu bar.
    func reopen() {
        showAgain()
        if isShowing { showPopover() }
    }

    /// Whether the item is in the menu bar. Control Center can keep an item out of it (System Settings › Menu Bar,
    /// or no room beside the notch) without telling the app; the item's window is then off screen.
    private var isShowing: Bool {
        guard statusItem.isVisible, let window = statusItem.button?.window else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// Looks a moment later, once Control Center has placed the item or not. Only then: the menu bar also hides every
    /// item while an app is full screen.
    private func checkSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            let showing = isShowing
            change { $0.visibilityChanged(visible: showing) }
        }
    }

    private func showAgain() {
        statusItem.isVisible = true
        change { $0.showAgain() }
        checkSoon()
    }

    /// Draws the item, then again each time the monitor changes what it says.
    private func showStatus() {
        withObservationTracking {
            draw(monitor.menuBar)
        } onChange: { [weak self] in
            Task { @MainActor in self?.showStatus() }
        }
    }

    private func draw(_ state: MenuBarState) {
        guard let button = statusItem.button else { return }
        let symbol = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "VPS Monitor")!
        let image: NSImage
        switch state.tint {
        case .normal, .offline, .neutral:
            // A template follows the menu bar's own color; offline dims it with the title.
            image = symbol
            image.isTemplate = true
        case .warning:
            image = symbol.withSymbolConfiguration(.init(paletteColors: [.systemOrange])) ?? symbol
        case .critical:
            image = symbol.withSymbolConfiguration(.init(paletteColors: [.systemRed])) ?? symbol
        }
        button.image = image
        button.appearsDisabled = state.tint == .offline
        button.title = state.title.isEmpty ? "" : " " + state.title
        button.toolTip = state.tooltip
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        // The app has no Dock icon and isn't active; keyboard shortcuts in the popover need it to be.
        NSApplication.shared.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        monitor.popoverOpened()
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.popoverClosed()
    }

    private func openSettings() {
        popover.performClose(nil)
        settingsWindow.show()
    }

    private func change(_ update: (inout MenuBarPresence) -> Void) {
        var next = presence
        update(&next)
        guard next != presence else { return }
        presence = next
        if presence.showsHelp { helpWindow.show() } else { helpWindow.close() }
    }
}
