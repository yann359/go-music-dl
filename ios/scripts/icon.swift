import AppKit
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.92, alpha: 1), ending: NSColor(calibratedRed: 0.91, green: 0.87, blue: 0.81, alpha: 1))!
    .draw(in: NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)), angle: 45)
// Original waveform mark; no Apple brand assets or private symbols.
NSColor(calibratedRed: 0.78, green: 0.31, blue: 0.25, alpha: 1).setStroke()
let heights: [CGFloat] = [80, 165, 300, 430, 300, 165, 80]
for (index, height) in heights.enumerated() {
    let path = NSBezierPath(); path.lineWidth = 48; path.lineCapStyle = .round
    let x = CGFloat(302 + index * 70)
    path.move(to: NSPoint(x: x, y: 512 - height / 2)); path.line(to: NSPoint(x: x, y: 512 + height / 2)); path.stroke()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
