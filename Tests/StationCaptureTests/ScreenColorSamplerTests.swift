import CoreVideo
import XCTest
import StationCore
@testable import StationCapture

private typealias RGBColor = StationCore.RGBColor

final class ScreenColorSamplerTests: XCTestCase {
    private let fullScreen = SampleRect(x: 0, y: 0, width: 1, height: 1)
    private let red = RGBColor(red: 255, green: 0, blue: 0)
    private let green = RGBColor(red: 0, green: 255, blue: 0)
    private let blue = RGBColor(red: 0, green: 0, blue: 255)

    func testReadsBGRAWithPaddedRowsAndTopLeftCoordinates() throws {
        let buffer = try makeBuffer(width: 2, height: 2, bytesPerRow: 64, pixels: [red, green, blue, .black])
        let zones = [
            SampleRect(x: 0, y: 0, width: 0.5, height: 0.5),
            SampleRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            SampleRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
            SampleRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        ]
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: zones), [red, green, blue, .black])
    }

    func testClipsZonesToTheirScreenIntersection() throws {
        let buffer = try makeBuffer(width: 2, height: 2, pixels: [red, green, blue, .black])
        let zones = [
            SampleRect(x: -0.5, y: -0.5, width: 1, height: 1),
            SampleRect(x: 0.5, y: 0, width: 2, height: 0.5),
            SampleRect(x: 0, y: 0.5, width: 0.5, height: 2)
        ]
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: zones), [red, green, blue])
    }

    func testFractionalZonesIncludeIntersectingPixels() throws {
        let buffer = try makeBuffer(width: 2, height: 2, pixels: [red, green, blue, .black])
        let zone = SampleRect(x: 0.01, y: 0.51, width: 0.01, height: 0.01)
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: [zone]), [blue])
    }

    func testInvalidOrEmptyZonesAreBlackAndPreserveOutputOrder() throws {
        let buffer = try makeBuffer(width: 1, height: 1, pixels: [green])
        let invalidZones = [
            SampleRect(x: 0, y: 0, width: 0, height: 1),
            SampleRect(x: 0, y: 0, width: -1, height: 1),
            SampleRect(x: 0, y: 0, width: 1, height: -1),
            SampleRect(x: 1, y: 0, width: 1, height: 1),
            SampleRect(x: 0, y: -2, width: 1, height: 1),
            SampleRect(x: .nan, y: 0, width: 1, height: 1),
            SampleRect(x: 0, y: .infinity, width: 1, height: 1),
            SampleRect(x: 0, y: 0, width: .infinity, height: 1),
            SampleRect(x: 0, y: 0, width: 1, height: .nan)
        ]
        XCTAssertEqual(
            ScreenColorSampler.colors(in: buffer, zones: invalidZones + [fullScreen]),
            Array(repeating: .black, count: invalidZones.count) + [green]
        )
    }

    func testExtremeFiniteCoordinatesCannotOverflowIndices() throws {
        let buffer = try makeBuffer(width: 1, height: 1, pixels: [blue])
        let zones = [
            SampleRect(x: Double.greatestFiniteMagnitude, y: 0, width: Double.greatestFiniteMagnitude, height: 1),
            SampleRect(x: -Double.greatestFiniteMagnitude, y: 0, width: 1, height: 1),
            SampleRect(x: 0, y: 0, width: Double.greatestFiniteMagnitude, height: Double.greatestFiniteMagnitude)
        ]
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: zones), [.black, .black, blue])
    }

    func testRedWeightCanOutvoteMoreGreenPixels() throws {
        let buffer = try makeBuffer(width: 7, height: 1, pixels: [red, red] + Array(repeating: green, count: 5))
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: [fullScreen]), [red])
    }

    func testHigherWeightedCountStillWinsAgainstRed() throws {
        let buffer = try makeBuffer(width: 5, height: 1, pixels: [red] + Array(repeating: green, count: 4))
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: [fullScreen]), [green])
    }

    func testRedWeightAlsoAppliesBelowHueWraparound() throws {
        let warmRed = RGBColor(red: 255, green: 0, blue: 32)
        let buffer = try makeBuffer(width: 7, height: 1, pixels: [warmRed, warmRed] + Array(repeating: green, count: 5))
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: [fullScreen]), [warmRed])
    }

    func testAveragesOnlyPixelsInDominantBin() throws {
        let darkerRed = RGBColor(red: 129, green: 0, blue: 0)
        let buffer = try makeBuffer(width: 3, height: 1, pixels: [red, darkerRed, blue])
        XCTAssertEqual(
            ScreenColorSampler.colors(in: buffer, zones: [fullScreen]),
            [RGBColor(red: 192, green: 0, blue: 0)]
        )
    }

    func testLowSaturationAndDarkPixelsDoNotWinHistogram() throws {
        let gray = RGBColor(red: 240, green: 230, blue: 230)
        let darkRed = RGBColor(red: 24, green: 0, blue: 0)
        let pixels = Array(repeating: gray, count: 12) + Array(repeating: darkRed, count: 12) + [green]
        let buffer = try makeBuffer(width: pixels.count, height: 1, pixels: pixels)
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: [fullScreen]), [green])
    }

    func testByteScaleThresholdsIncludeTheCutoff() throws {
        for color in [RGBColor(red: 25, green: 0, blue: 0), RGBColor(red: 255, green: 230, blue: 230)] {
            let buffer = try makeBuffer(width: 3, height: 1, pixels: [color, green, green])
            XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: [fullScreen]), [color])
        }
        for color in [RGBColor(red: 24, green: 0, blue: 0), RGBColor(red: 255, green: 231, blue: 231)] {
            let buffer = try makeBuffer(width: 3, height: 1, pixels: [color, green, green])
            XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: [fullScreen]), [green])
        }
    }

    func testFallsBackToOverallAverageWithoutColorfulPixels() throws {
        let pixels = [RGBColor(packed: 0xFFFFFF), RGBColor(packed: 0x818181), .black]
        let buffer = try makeBuffer(width: 3, height: 1, pixels: pixels)
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: [fullScreen]), [RGBColor(packed: 0x808080)])
    }

    func testAllBlackAndNoZones() throws {
        let buffer = try makeBuffer(width: 1, height: 1, pixels: [.black])
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: [fullScreen]), [.black])
        XCTAssertEqual(ScreenColorSampler.colors(in: buffer, zones: []), [])
    }

    func testUnsupportedPixelFormatReturnsNil() throws {
        let buffer = try makeBuffer(width: 1, height: 1, pixelFormat: kCVPixelFormatType_32ARGB, pixels: [red])
        XCTAssertNil(ScreenColorSampler.colors(in: buffer, zones: [fullScreen]))
    }

    private func makeBuffer(
        width: Int,
        height: Int,
        bytesPerRow: Int? = nil,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA,
        pixels: [RGBColor]
    ) throws -> CVPixelBuffer {
        let rowBytes = bytesPerRow ?? width * 4
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 64)
        let bytes = allocation.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        bytes.initialize(repeating: 0xE7, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixels[y * width + x]
                let offset = y * rowBytes + x * 4
                bytes[offset] = color.blue
                bytes[offset + 1] = color.green
                bytes[offset + 2] = color.red
                bytes[offset + 3] = 0 // Alpha is irrelevant to captured screen RGB.
            }
        }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            kCFAllocatorDefault, width, height, pixelFormat, allocation, rowBytes,
            { _, base in UnsafeMutableRawPointer(mutating: base)?.deallocate() },
            nil, nil, &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            allocation.deallocate()
            throw NSError(domain: "ScreenColorSamplerTests", code: Int(status))
        }
        return buffer
    }
}
