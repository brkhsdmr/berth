// Uygulama simgesini çizer: Resources/AppIcon.icns. Windows'taki simgeyle aynı çizim (üst üste üç
// pencere, öndeki dolu), macOS simge ızgarasında.
//   swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS ızgarası: 1024'te 824'lük gövde, 100 kenar boşluğu.
    let body = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.52, blue: 0.98, alpha: 1),
                        NSColor(srgbRed: 0.04, green: 0.33, blue: 0.80, alpha: 1)])!.draw(in: shape, angle: -90)
    let span = body.width * 0.62
    let w = span * 0.62, h = span * 0.5, step = span * 0.19
    let origin = CGPoint(x: body.midX - span / 2, y: body.midY - span / 2)
    let line = max(1, s * 22 / 1024)
    for i in 0..<3 {
        // Arkadaki sağ üstte; AppKit'te y yukarı.
        let x = origin.x + step * CGFloat(2 - i), y = origin.y + span - h - step * CGFloat(i)
        let rect = NSRect(x: x, y: y, width: w, height: h).insetBy(dx: line / 2, dy: line / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: w * 0.12, yRadius: w * 0.12)
        NSColor.white.setFill(); NSColor.white.setStroke()
        if i == 2 { path.fill() } else { path.lineWidth = line; path.stroke() }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Yazıldı: \(output.path)" : "iconutil başarısız")
