// Offscreen, deterministic on a given macOS/font version; no app or Finder UI.
// swift scripts/make-dmg-background.swift packaging/dmg
import AppKit
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift scripts/make-dmg-background.swift OUTPUT_DIRECTORY")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for scale in [1, 2] {
    let context = CGContext(data: nil, width: 600 * scale, height: 400 * scale,
        bitsPerComponent: 8, bytesPerRow: 600 * scale * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.setFillColor(NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat,
              weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor) {
        (value as NSString).draw(at: NSPoint(x: x, y: 400 - top - size * 1.25),
            withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                             .foregroundColor: color])
    }
    text("Yeelight Station", x: 36, top: 30, size: 26, weight: .semibold,
         color: NSColor(srgbRed: 0.13, green: 0.15, blue: 0.19, alpha: 1))
    text("Drag Station into Applications to install.", x: 36, top: 70, size: 14,
         color: NSColor(srgbRed: 0.36, green: 0.39, blue: 0.43, alpha: 1))
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 274, y: 220))
    arrow.line(to: NSPoint(x: 326, y: 220))
    arrow.move(to: NSPoint(x: 316, y: 230))
    arrow.line(to: NSPoint(x: 326, y: 220))
    arrow.line(to: NSPoint(x: 316, y: 210))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(srgbRed: 0.54, green: 0.57, blue: 0.63, alpha: 1).setStroke()
    arrow.stroke()
    let muted = NSColor(srgbRed: 0.40, green: 0.43, blue: 0.48, alpha: 1)
    text("Updating? Quit Station before replacing it.", x: 36, top: 292, size: 12, color: muted)
    text("Then open it from Applications and eject this disk.", x: 36, top: 314, size: 12, color: muted)
    text("Made for your light. MIT licensed.", x: 36, top: 364, size: 11, color: muted)
    NSGraphicsContext.restoreGraphicsState()
    let output = directory.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png")
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG encoding failed") }
    try (data as Data).write(to: output, options: .atomic)
    print(output.path)
}
