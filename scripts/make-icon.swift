import AppKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        NSAffineTransform().alsoScale(factor)
        let bounds = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        NSColor(calibratedRed: 0.085, green: 0.09, blue: 0.145, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 12, dy: 12), xRadius: 225, yRadius: 225).fill()
        let glow = NSGradient(colors: [NSColor.systemPurple.withAlphaComponent(0.05), NSColor.systemPurple.withAlphaComponent(0.85), NSColor.systemCyan.withAlphaComponent(0.7)])!
        glow.draw(in: NSBezierPath(roundedRect: NSRect(x: 145, y: 230, width: 734, height: 470), xRadius: 155, yRadius: 155), angle: 25)
        NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 166, y: 248, width: 692, height: 402), xRadius: 90, yRadius: 90).fill()
        NSColor(calibratedWhite: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 171, y: 649, width: 682, height: 52), xRadius: 26, yRadius: 26).fill()
        NSColor(calibratedWhite: 0.5, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 442, y: 287, width: 140, height: 22), xRadius: 11, yRadius: 11).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 1 ? "" : "@2x"
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
extension NSAffineTransform {
    func alsoScale(_ factor: CGFloat) { scale(by: factor); concat() }
}
