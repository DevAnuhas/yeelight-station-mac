import AppKit
import StationCore
import SwiftUI
import XCTest
@testable import YeelightStation

final class StationColorPickerTests: XCTestCase {
    func testHexAcceptsExactRGBAndRejectsMalformedInput() {
        for text in ["#01A0ff", "01a0FF", " \n#01A0FF\t"] {
            XCTAssertEqual(StationColorComponents.parseHex(text), RGBColor(red: 1, green: 160, blue: 255))
        }
        for text in ["", "#", "#ABC", "#12345678", "##123456", "0x123456", "12345G", "１２３４５６", "123 56", "-12345"] {
            XCTAssertNil(StationColorComponents.parseHex(text), text)
        }
        XCTAssertEqual(StationColorComponents.parseHex("#000000"), .black)
        XCTAssertEqual(StationColorComponents.parseHex("#FFFFFF"), RGBColor(packed: 0xFFFFFF))
    }

    func testRGBRoundTripsWithoutLosingAByte() {
        // Includes every channel boundary and a dense sample through the RGB cube.
        for red in stride(from: 0, through: 255, by: 17) {
            for green in stride(from: 0, through: 255, by: 17) {
                for blue in stride(from: 0, through: 255, by: 17) {
                    let rgb = RGBColor(red: UInt8(red), green: UInt8(green), blue: UInt8(blue))
                    XCTAssertEqual(StationColorComponents(rgb).rgb, rgb, rgb.hex)
                }
            }
        }
        for packed in [0x010203, 0xFEFDFC, 0x807F80, 0x123456, 0xA699FF] {
            let rgb = RGBColor(packed: packed)
            XCTAssertEqual(StationColorComponents(rgb).rgb, rgb)
        }
    }

    func testAchromaticEditsRetainHueAndBlackRetainsSaturation() {
        let previous = StationColorComponents(hue: 0.72, saturation: 0.65, brightness: 0.8)
        var black = StationColorComponents(.black, preserving: previous)
        XCTAssertEqual(black.hue, previous.hue)
        XCTAssertEqual(black.saturation, previous.saturation)
        XCTAssertEqual(black.rgb, .black)
        black.brightness = 0.8
        XCTAssertEqual(black.rgb, previous.rgb)
        let gray = StationColorComponents(RGBColor(packed: 0x808080), preserving: previous)
        XCTAssertEqual(gray.hue, previous.hue)
        XCTAssertEqual(gray.saturation, 0)
        XCTAssertEqual(gray.rgb, RGBColor(packed: 0x808080))
    }

    func testEditingCoordinatesClampSafelyAndHueWrapsAtRed() {
        XCTAssertEqual(StationColorComponents(hue: 1, saturation: 1, brightness: 1).rgb, RGBColor(packed: 0xFF0000))
        XCTAssertEqual(StationColorComponents(hue: 0, saturation: 1, brightness: 1).rgb, RGBColor(packed: 0xFF0000))
        XCTAssertEqual(StationColorComponents(hue: -.infinity, saturation: .nan, brightness: .infinity).rgb, .black)
        XCTAssertEqual(StationColorComponents(hue: -1, saturation: 2, brightness: 2).rgb, RGBColor(packed: 0xFF0000))
    }
}

@MainActor
final class StationBrandResourceTests: XCTestCase {
    func testBundledLogosDecodeAndLetteringContrastsInBothAppearances() throws {
        try StationBrand.validateResources()
        for scheme: ColorScheme in [.light, .dark] {
            let image = StationBrand.image(for: scheme)
            let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            XCTAssertEqual(Double(bitmap.pixelsWide) / Double(bitmap.pixelsHigh), 327.0 / 73.0, accuracy: 0.01)

            // Check the lettering separately from the red mark. A dark logo
            // accidentally reused in dark mode still has a visible red mark.
            let firstLetterColumn = bitmap.pixelsWide / 4
            let background = scheme == .dark ? 0.0 : 1.0
            var contrastingLetterPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in firstLetterColumn..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                    let contrast = abs(luminance - background) * color.alphaComponent
                    if contrast > 0.45 { contrastingLetterPixels += 1 }
                }
            }
            let letteringArea = (bitmap.pixelsWide - firstLetterColumn) * bitmap.pixelsHigh
            XCTAssertGreaterThan(contrastingLetterPixels, letteringArea / 20, "The \(scheme) logo lettering must be visible on its sidebar.")
        }
    }
}

/// Opt-in, entirely synthetic visual fixtures. They do not start Station, polling,
/// capture, discovery, or device commands, and never present a window onscreen.
@MainActor
final class StationControlSnapshotTests: XCTestCase {
    func testOffscreenControlAndWindowFixtures() throws {
        guard let path = ProcessInfo.processInfo.environment["STATION_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set STATION_UI_SNAPSHOT_DIR to render synthetic offscreen UI fixtures.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let model = StationModel(previewMode: true)

        for scheme: ColorScheme in [.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            model.mode = .idle
            model.audioSource = .system
            model.audioInputs = []

            let picker = NSHostingView(rootView: StationColorPopover(selection: .constant(RGBColor(packed: 0xA699FF)), label: "RGB backlight").preferredColorScheme(scheme))
            picker.appearance = appearance
            picker.frame = CGRect(origin: .zero, size: picker.fittingSize)
            try render(picker, to: directory.appendingPathComponent("color-picker-\(name).png"))

            for size in [CGSize(width: 980, height: 700), CGSize(width: 1160, height: 810)] {
                for page in StationPage.allCases {
                    let filename = "\(page.id.rawValue.replacingOccurrences(of: " ", with: "-").lowercased())-\(name)-\(Int(size.width)).png"
                    try renderWindow(StationView(initialPage: page).environmentObject(model), size: size,
                                     scheme: scheme, to: directory.appendingPathComponent(filename))
                }
            }
            model.audioSource = .microphone
            model.audioInputs = [.init(id: "snapshot-microphone", name: "Studio USB Microphone", isDefault: true)]
            try renderWindow(StationView(initialPage: .music).environmentObject(model), size: CGSize(width: 980, height: 700),
                             scheme: scheme, to: directory.appendingPathComponent("music-flow-microphone-\(name)-980.png"))

            // Setting synthetic presentation state does not start a sync session.
            model.mode = .screen
            try renderWindow(StationView(initialPage: .lights).environmentObject(model), size: CGSize(width: 980, height: 700),
                             scheme: scheme, to: directory.appendingPathComponent("my-lights-active-\(name)-980.png"))
        }
    }

    private func renderWindow<Content: View>(_ content: Content, size: CGSize, scheme: ColorScheme, to url: URL) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.title = "Synthetic Station fixture"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentViewController = NSHostingController(rootView:
            content.preferredColorScheme(scheme).frame(minWidth: 980, minHeight: 700))
        // Installing a hosting controller can resize a hidden window to its
        // preferred size. Apply the fixture dimensions afterwards.
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let view = try XCTUnwrap(window.contentView)
        XCTAssertEqual(view.bounds.width, size.width, accuracy: 0.5)
        // The production minimum sits below the native toolbar safe area.
        let minimumHeight = 700 + view.safeAreaInsets.top + view.safeAreaInsets.bottom
        XCTAssertEqual(view.bounds.height, max(size.height, minimumHeight), accuracy: 0.5)
        try render(view, to: url)
    }

    private func render(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1_000)
        try png.write(to: url)
    }
}
