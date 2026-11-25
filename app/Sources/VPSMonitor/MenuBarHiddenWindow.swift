import AppKit
import MonitorCore
import MonitorUI
import SwiftUI

/// Says why the menu bar item is gone and how to bring it back (from Claude Usage).
@MainActor
final class MenuBarHiddenWindow: NSObject, NSWindowDelegate {
    private let strings: () -> Strings
    private let showAgain: () -> Void
    private let closed: () -> Void
    private var window: NSWindow?

    init(strings: @escaping () -> Strings, showAgain: @escaping () -> Void, closed: @escaping () -> Void) {
        self.strings = strings
        self.showAgain = showAgain
        self.closed = closed
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // The app has no Dock icon and nothing else on screen; bring it forward so the window isn't left behind.
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
        // macOS may refuse to activate an app the user didn't just open (at login, say); show the window anyway.
        window.orderFrontRegardless()
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) { closed() }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 210), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = strings().app.hiddenTitle
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Tok.bg)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MenuBarHiddenView(s: strings(), showAgain: showAgain))
        window.delegate = self
        window.center()
        return window
    }
}

private struct MenuBarHiddenView: View {
    static let menuBarSettings = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!

    let s: Strings
    let showAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 22)).foregroundStyle(Tok.claude)
                Text(s.app.hiddenBody)
                    .foregroundStyle(Tok.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Button(s.app.quit) { NSApplication.shared.terminate(nil) }
                    .buttonStyle(ClaudeButtonStyle(kind: .ghost))
                Spacer(minLength: 0)
                Button(s.app.showAgain, action: showAgain)
                    .buttonStyle(ClaudeButtonStyle(kind: .secondary))
                Button(s.app.openSystemSettings) { NSWorkspace.shared.open(Self.menuBarSettings) }
                    .buttonStyle(ClaudeButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Tok.text)
        .padding(20)
        .frame(width: 440, height: 210)
        .background(Tok.bg)
    }
}
