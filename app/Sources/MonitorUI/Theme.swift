import AppKit
import MonitorCore
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

/// Claude Usage's tokens (light / dark), so the two menu bar apps look like siblings.
public enum Tok {
    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }

    public static let bg = dynamic(light: 0xfaf9f5, dark: 0x262624)
    static let surface = dynamic(light: 0xf5f4ed, dark: 0x1f1e1d)
    static let surface2 = dynamic(light: 0xf0eee6, dark: 0x30302e)
    static let surface3 = dynamic(light: 0xe8e6dc, dark: 0x3a3936)
    public static let text = dynamic(light: 0x141413, dark: 0xfaf9f5)
    public static let text2 = dynamic(light: 0x3d3d3a, dark: 0xc2c0b6)
    public static let muted = dynamic(light: 0x73726c, dark: 0x9c9a92)
    static let faint = dynamic(light: 0xa3a19a, dark: 0x6b6a65)
    static let border = dynamic(light: 0x1f1e1d, dark: 0xdedcd1, lightAlpha: 0.12, darkAlpha: 0.12)
    static let borderStrong = dynamic(light: 0x1f1e1d, dark: 0xdedcd1, lightAlpha: 0.22, darkAlpha: 0.22)
    static let track = dynamic(light: 0x1f1e1d, dark: 0xdedcd1, lightAlpha: 0.08, darkAlpha: 0.10)
    public static let claude = dynamic(light: 0xc96442, dark: 0xd97757)
    static let claudeStrong = Color(nsColor: NSColor(hex: 0xc96442))
    static let claudeTint = dynamic(light: 0xc96442, dark: 0xd97757, lightAlpha: 0.10, darkAlpha: 0.14)
    public static let success = dynamic(light: 0x2f8f46, dark: 0x4eba65)
    public static let warning = dynamic(light: 0xb7791f, dark: 0xe5a83b)
    public static let error = dynamic(light: 0xc4314b, dark: 0xff6b80)
    static let errorStrong = dynamic(light: 0xc4314b, dark: 0xd9475f)

    /// The dataviz reference hues minus orange and red (the accent and the alerts), most distinct first.
    static let hues: [Color] = [
        dynamic(light: 0x2a78d6, dark: 0x3987e5),  // blue
        dynamic(light: 0x1baf7a, dark: 0x199e70),  // green
        dynamic(light: 0x6250d6, dark: 0x9085e9),  // violet
        dynamic(light: 0xe87ba4, dark: 0xd55181),  // pink
        dynamic(light: 0xeda100, dark: 0xc98500),  // amber
        dynamic(light: 0x86b6ef, dark: 0x6f9fd8),  // light blue
        dynamic(light: 0x9a7b5f, dark: 0x8a6d52),  // brown
        dynamic(light: 0x6b7385, dark: 0x6f7a8c),  // slate
    ]
    /// The rest of the disk, the rest of the used RAM.
    static let neutral = dynamic(light: 0xc2c0b6, dark: 0x5c5b56)

    /// Each disk-map group's color, by id, so a group keeps its color when the sizes reorder.
    static func group(_ id: String) -> Color {
        switch id {
        case "home": return hues[0]
        case "docker": return hues[1]
        case "caches": return hues[2]
        case "claude": return hues[3]
        case "temp": return hues[4]
        case "logs": return hues[5]
        case "system": return hues[6]
        case "swap": return hues[7]
        default: return neutral
        }
    }

    /// A program's color in the RAM breakdown, by its place in the list.
    static func program(_ index: Int) -> Color { hues[index % hues.count] }

    public static func level(_ level: AlertLevel) -> Color {
        switch level {
        case .warning: return warning
        case .critical: return error
        }
    }

    static func level(_ level: AlertLevel?, otherwise: Color) -> Color {
        level.map(Self.level) ?? otherwise
    }
}

/// Monospaced, like Claude Usage's default "CLI" theme.
enum Typo {
    static func ui(size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
