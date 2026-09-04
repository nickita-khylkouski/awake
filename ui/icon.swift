import AppKit

// Vector artwork rasterized at each macOS icon size; no downloaded assets.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(srgbRed: 1, green: 0.62, blue: 0.18, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205).fill()
        NSColor(srgbRed: 0.15, green: 0.13, blue: 0.10, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 349, y: 349, width: 326, height: 326)).fill()
        NSColor(srgbRed: 0.15, green: 0.13, blue: 0.10, alpha: 1).setStroke()
        for ray in 0..<8 {
            let angle = Double(ray) * .pi / 4
            let path = NSBezierPath()
            path.lineWidth = 49
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: 512 + cos(angle) * 230, y: 512 + sin(angle) * 230))
            path.line(to: NSPoint(x: 512 + cos(angle) * 300, y: 512 + sin(angle) * 300))
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
