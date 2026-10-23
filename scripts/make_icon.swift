// Generates Resources/AppIcon.icns: a glass tile of warm orange liquid on a cream squircle.
// Usage: swift scripts/make_icon.swift <output.icns>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Workday-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let outer = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: outer, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 1.0, green: 0.97, blue: 0.92, alpha: 1), NSColor(red: 0.98, green: 0.90, blue: 0.80, alpha: 1)])!
        .draw(in: squircle, angle: -90)

    let tile = NSRect(x: 250 * s, y: 215 * s, width: 524 * s, height: 594 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 96 * s, yRadius: 96 * s)
    NSColor.white.setFill()
    tilePath.fill()
    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    func wave(level: CGFloat, amp: CGFloat, phase: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: tile.minX, y: tile.minY))
        for i in 0...60 {
            let u = CGFloat(i) / 60
            p.line(to: NSPoint(x: tile.minX + tile.width * u, y: level + amp * sin(u * 2 * .pi + phase)))
        }
        p.line(to: NSPoint(x: tile.maxX, y: tile.minY))
        p.close()
        return p
    }
    let level = tile.minY + tile.height * 0.62
    NSColor(red: 1.0, green: 0.62, blue: 0.18, alpha: 0.45).setFill()
    wave(level: level + 14 * s, amp: 18 * s, phase: 2.2).fill()
    let front = wave(level: level, amp: 20 * s, phase: 0)
    NSGradient(colors: [NSColor(red: 1.0, green: 0.74, blue: 0.33, alpha: 1), NSColor(red: 0.95, green: 0.42, blue: 0.03, alpha: 1)])!
        .draw(in: front, angle: -90)
    for (x, y, r) in [(0.3, 0.25, 18.0), (0.62, 0.4, 13.0), (0.45, 0.12, 10.0), (0.75, 0.2, 15.0)] {
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: tile.minX + tile.width * x, y: tile.minY + tile.height * y, width: r * s * 2, height: r * s * 2)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSColor(red: 0.93, green: 0.45, blue: 0.05, alpha: 0.35).setStroke()
    tilePath.lineWidth = 8 * s
    tilePath.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(size: px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote \(output)")
