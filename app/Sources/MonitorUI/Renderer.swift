import AppKit
import MonitorCore
import SwiftUI

/// Draws the popover and Settings into PNGs, the way `vpsmon-mac render` proves the UI without opening the app.
@MainActor
public enum Renderer {
    public static func popover(monitor: Monitor, now: Date, dark: Bool,
                               expansion: PopoverView.Expansion = PopoverView.Expansion(), scale: CGFloat = 2) -> Data? {
        let view = PopoverView(monitor: monitor, clock: .fixed(now), expansion: expansion)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        // The tokens are NSColors that resolve against the drawing appearance, not SwiftUI's color scheme.
        var image: NSImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            image = renderer.nsImage
        }
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Settings has text fields, switches and a menu, which are AppKit controls that ImageRenderer leaves blank, so
    /// it is drawn the way its window draws it: a hosting view in an offscreen window.
    public static func settings(monitor: Monitor, form: ServerForm?, state: SetupState, dark: Bool,
                                configHosts: [SSHConfigHost] = []) -> Data? {
        let root = SettingsView(monitor: monitor, loginItem: .off, configHosts: configHosts, form: form, state: state)
            .fixedSize(horizontal: false, vertical: true)
        let host = NSHostingView(rootView: root)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        host.appearance = appearance
        let first = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: first), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: first)
        host.layoutSubtreeIfNeeded()
        // SwiftUI fills an AppKit-hosted tree over a few runloop turns, and the controls change its height.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let settled = host.fittingSize
        window.setContentSize(settled)
        host.frame = NSRect(origin: .zero, size: settled)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let size = host.bounds.size
        let scale = window.backingScaleFactor
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
