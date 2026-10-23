import AppKit
import SwiftUI
import XCTest
@testable import YeelightStation

final class StationAppearanceTests: XCTestCase {
    func testPrimaryAndAccentTextRemainReadableInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var contrasts: [Double] = []
            appearance.performAsCurrentDrawingAppearance {
                let background = rgba(NSColor(StationAppearance.windowBackground))
                let card = composite(rgba(NSColor(StationAppearance.cardBackground)), over: background)
                for foreground in [NSColor.labelColor, NSColor(StationAppearance.accent)] {
                    let text = rgba(foreground)
                    contrasts.append(contrast(composite(text, over: background), background))
                    contrasts.append(contrast(composite(text, over: card), card))
                }
            }
            for value in contrasts { XCTAssertGreaterThanOrEqual(value, 4.5, "\(name.rawValue) text contrast") }
        }
    }

    private func rgba(_ color: NSColor) -> (Double, Double, Double, Double) {
        guard let rgb = color.usingColorSpace(.sRGB) else { XCTFail("Color must resolve to sRGB"); return (0, 0, 0, 1) }
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
    }
    private func composite(_ a: (Double, Double, Double, Double), over b: (Double, Double, Double, Double)) -> (Double, Double, Double, Double) {
        (a.0 * a.3 + b.0 * (1 - a.3), a.1 * a.3 + b.1 * (1 - a.3), a.2 * a.3 + b.2 * (1 - a.3), 1)
    }
    private func contrast(_ a: (Double, Double, Double, Double), _ b: (Double, Double, Double, Double)) -> Double {
        func luminance(_ color: (Double, Double, Double, Double)) -> Double {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(color.0) + 0.7152 * linear(color.1) + 0.0722 * linear(color.2)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
