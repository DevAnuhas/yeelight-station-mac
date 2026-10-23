import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Run from the project root:
// swift scripts/make-icon.swift <output.iconset> [master.png]
// The master defaults to assets/app-icon.png: square PNG, at least 1024 pixels.
// Every representation is rendered directly from the unchanged source master.
// iconutil -c icns <output.iconset> -o assets/Station.icns
let usage = """
Usage: swift scripts/make-icon.swift <output.iconset> [master.png]
  master.png   Square PNG, at least 1024 x 1024; default: assets/app-icon.png
  All relative paths resolve from the current working directory.
  Writes the standard 16/32/128/256/512-point icons at 1x and 2x.

Then run: iconutil -c icns <output.iconset> -o assets/Station.icns
"""

struct IconError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func pngData(from image: CGImage, pixels: Int) throws -> Data {
    let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: pixels * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
        throw IconError(message: "Could not create the \(pixels)-pixel bitmap.")
    }
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    graphics.imageInterpolation = .high
    NSGraphicsContext.current = graphics
    let source = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    source.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: NSRect(x: 0, y: 0, width: image.width, height: image.height),
        operation: .copy,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high.rawValue]
    )
    guard let resized = context.makeImage() else {
        throw IconError(message: "Could not downsample to \(pixels) pixels.")
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw IconError(message: "Could not create the PNG encoder.")
    }
    CGImageDestinationAddImage(destination, resized, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError(message: "Could not encode the \(pixels)-pixel PNG.")
    }
    return data as Data
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print(usage)
    exit(EXIT_SUCCESS)
}

do {
    guard (1...2).contains(arguments.count) else {
        throw IconError(message: usage)
    }
    let directory = URL(fileURLWithPath: arguments[0], isDirectory: true).standardizedFileURL
    guard directory.pathExtension == "iconset" else {
        throw IconError(message: "The output directory must end in .iconset.\n\(usage)")
    }
    let input = URL(fileURLWithPath: arguments.count == 2 ? arguments[1] : "assets/app-icon.png")
    guard let masterData = try? Data(contentsOf: input),
          let source = CGImageSourceCreateWithData(masterData as CFData, nil),
          CGImageSourceGetType(source) as String? == UTType.png.identifier,
          CGImageSourceGetCount(source) == 1,
          let master = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw IconError(message: "Could not read a single PNG image at \(input.path).")
    }
    guard master.width == master.height && master.width >= 1024 else {
        throw IconError(message: "The master must be square and at least 1024 x 1024 pixels; got \(master.width) x \(master.height).")
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    let orientation = properties?[kCGImagePropertyOrientation as String] as? Int ?? 1
    guard orientation == 1 else {
        throw IconError(message: "The master must have upright pixels without an orientation transform.")
    }

    // Encode before touching the output, and reuse identical pixel dimensions.
    let sizes = [16, 32, 128, 256, 512]
    var images = [Int: Data]()
    for pixels in Set(sizes.flatMap { [$0, $0 * 2] }).sorted() {
        images[pixels] = try pngData(from: master, pixels: pixels)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in sizes {
        for scale in [1, 2] {
            let suffix = scale == 1 ? "" : "@2x"
            let output = directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
            try images[size * scale]!.write(to: output, options: .atomic)
        }
    }
    print("Wrote 10 icon representations from \(input.path) to \(directory.path)")
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
