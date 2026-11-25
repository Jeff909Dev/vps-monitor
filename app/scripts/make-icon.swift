#!/usr/bin/env swift
// Draws the app icon at every iconset size and builds Resources/AppIcon.icns with iconutil: a server rack in Claude
// orange on the same dark tile as Claude Usage's icon. Run from app/: swift scripts/make-icon.swift
//
// The tile fills the whole canvas: macOS 26 rounds it with its own mask.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    context.setFillColor(color(0x262624))
    context.fill(rect)

    // A faint light from above.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xffffff, 0.07), color(0xffffff, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.midY),
                               options: [])

    // Three rack units, the top one lit: a server with one agent working.
    let width = s * 0.56
    let height = s * 0.15
    let gap = s * 0.05
    let x = (s - width) / 2
    let top = s / 2 + height * 1.5 + gap
    for unit in 0..<3 {
        let y = top - CGFloat(unit + 1) * height - CGFloat(unit) * gap
        let box = CGRect(x: x, y: y, width: width, height: height)
        let path = CGPath(roundedRect: box, cornerWidth: s * 0.035, cornerHeight: s * 0.035, transform: nil)
        context.addPath(path)
        context.setFillColor(color(0xd97757, unit == 0 ? 1 : 0.22))
        context.fillPath()
        // Two status lights on the right.
        let dot = s * 0.03
        for i in 0..<2 {
            let cx = box.maxX - s * 0.06 - CGFloat(i) * dot * 2.4
            context.setFillColor(unit == 0 ? color(0x262624, 0.85) : color(0xd97757, 0.8))
            context.fillEllipse(in: CGRect(x: cx - dot / 2, y: box.midY - dot / 2, width: dot, height: dot))
        }
        // A slot on the left.
        let slot = CGRect(x: box.minX + s * 0.05, y: box.midY - s * 0.009, width: width * 0.32, height: s * 0.018)
        context.setFillColor(unit == 0 ? color(0x262624, 0.6) : color(0xd97757, 0.45))
        context.fill(slot)
    }
    return context.makeImage()!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let url = iconset.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, draw(size: points * scale), nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(name)") }
    }
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
