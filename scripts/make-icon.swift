#!/usr/bin/env swift
// Generates Resources/Assets.xcassets/AppIcon.appiconset (key glyph on a gradient).
// Usage: swift scripts/make-icon.swift
import AppKit

let outDir = "Resources/Assets.xcassets/AppIcon.appiconset"
let sizes: [(pt: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.0977  // macOS icon grid margin
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
    NSGradient(colors: [NSColor(red: 0.29, green: 0.42, blue: 0.98, alpha: 1), NSColor(red: 0.09, green: 0.11, blue: 0.40, alpha: 1)])!
        .draw(in: shape, angle: -60)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .semibold)
    if let glyph = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: glyph.size, flipped: false) { r in
            glyph.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let g = tinted.size
        let scale = min(rect.width * 0.6 / g.width, rect.height * 0.6 / g.height)
        let w = g.width * scale, h = g.height * scale
        NSShadow().apply(blur: s * 0.02, offset: -s * 0.01)
        tinted.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSShadow {
    func apply(blur: CGFloat, offset: CGFloat) {
        shadowBlurRadius = blur
        shadowOffset = NSSize(width: 0, height: offset)
        shadowColor = NSColor.black.withAlphaComponent(0.35)
        set()
    }
}

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try render(px: pt * scale).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
print("wrote \(images.count) icons")
