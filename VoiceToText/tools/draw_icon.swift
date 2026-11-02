#!/usr/bin/env swift
// Draws the app icon into an .iconset folder: a rounded square in a coral
// gradient with a white waveform. tools/make_icon.sh turns it into
// Resources/AppIcon.icns with iconutil. No Xcode needed (actool is Xcode-only).
// Usage: swift tools/draw_icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    // Apple's grid: the shape fills 824 of 1024, centered, corner radius 185.
    let inset = size * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: size * 185 / 1024, yRadius: size * 185 / 1024)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.shadowBlurRadius = size * 0.02
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.45, blue: 0.38, alpha: 1),
               ending: NSColor(srgbRed: 0.84, green: 0.18, blue: 0.27, alpha: 1))!.draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try draw(pixels: points).write(to: out.appending(path: "icon_\(points)x\(points).png"))
    try draw(pixels: points * 2).write(to: out.appending(path: "icon_\(points)x\(points)@2x.png"))
}
print("wrote \(out.path)")
