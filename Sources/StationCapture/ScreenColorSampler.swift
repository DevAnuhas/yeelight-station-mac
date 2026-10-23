import CoreVideo
import StationCore

internal enum ScreenColorSampler {
    private static let hueBinCount = 12
    // Original appsettings.yee specifies 25 for both cutoffs. Interpret these
    // on the 0...255 HSV scale, with red's configured weight of three below.
    private static let minimumSaturation = 25.0 / 255.0
    private static let minimumValue = 25

    static func colors(in pixelBuffer: CVPixelBuffer, zones: [SampleRect]) -> [RGBColor]? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixelBuffer),
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0,
              width <= Int.max / 4,
              bytesPerRow >= width * 4,
              height <= Int.max / bytesPerRow,
              CVPixelBufferGetDataSize(pixelBuffer) >= bytesPerRow * height,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        return zones.map { zone in
            guard let bounds = pixelBounds(for: zone, width: width, height: height) else {
                return .black
            }

            var overall = ColorAverage()
            var bins = Array(repeating: ColorAverage(), count: hueBinCount)
            for y in bounds.y {
                let row = pixels.advanced(by: y * bytesPerRow)
                for x in bounds.x {
                    let offset = x * 4
                    let blue = Int(row[offset])
                    let green = Int(row[offset + 1])
                    let red = Int(row[offset + 2])
                    overall.add(red: red, green: green, blue: blue)

                    if let bin = hueBin(red: red, green: green, blue: blue) {
                        bins[bin].add(red: red, green: green, blue: blue)
                    }
                }
            }

            var dominantBin: Int?
            var dominantWeight = 0.0
            for index in bins.indices {
                // Red wraps around hue zero, so both end bins receive its bias.
                let weight = Double(bins[index].count) * (index == 0 || index == 11 ? 3 : 1)
                if weight > dominantWeight {
                    dominantWeight = weight
                    dominantBin = index
                }
            }
            return dominantBin.map { bins[$0].color } ?? overall.color
        }
    }

    private static func pixelBounds(for zone: SampleRect, width: Int, height: Int) -> (x: Range<Int>, y: Range<Int>)? {
        guard zone.x.isFinite, zone.y.isFinite,
              zone.width.isFinite, zone.height.isFinite,
              zone.width > 0, zone.height > 0 else {
            return nil
        }

        // Intersect the rectangle with the screen before converting to integers.
        // A positive overflowing endpoint is safely clipped to the far edge.
        let left = max(0, zone.x)
        let top = max(0, zone.y)
        let right = min(1, zone.x + zone.width)
        let bottom = min(1, zone.y + zone.height)
        guard left < right, top < bottom else { return nil }

        let xStart = min(width, Int((left * Double(width)).rounded(.down)))
        let yStart = min(height, Int((top * Double(height)).rounded(.down)))
        let xEnd = min(width, Int((right * Double(width)).rounded(.up)))
        let yEnd = min(height, Int((bottom * Double(height)).rounded(.up)))
        guard xStart < xEnd, yStart < yEnd else { return nil }
        return (xStart..<xEnd, yStart..<yEnd)
    }

    private static func hueBin(red: Int, green: Int, blue: Int) -> Int? {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 0,
              maximum >= minimumValue,
              Double(delta) / Double(maximum) >= minimumSaturation else {
            return nil
        }

        // Hue in six sectors; each sector occupies two histogram bins.
        let sector: Double
        if maximum == red {
            let redSector = Double(green - blue) / Double(delta)
            sector = redSector < 0 ? redSector + 6 : redSector
        } else if maximum == green {
            sector = Double(blue - red) / Double(delta) + 2
        } else {
            sector = Double(red - green) / Double(delta) + 4
        }
        return min(hueBinCount - 1, Int(sector * 2))
    }

    private struct ColorAverage {
        var count = 0
        private var red = 0.0
        private var green = 0.0
        private var blue = 0.0

        mutating func add(red: Int, green: Int, blue: Int) {
            count += 1
            self.red += Double(red)
            self.green += Double(green)
            self.blue += Double(blue)
        }

        var color: RGBColor {
            guard count > 0 else { return .black }
            let divisor = Double(count)
            return RGBColor(
                red: UInt8(clamping: Int((red / divisor).rounded())),
                green: UInt8(clamping: Int((green / divisor).rounded())),
                blue: UInt8(clamping: Int((blue / divisor).rounded()))
            )
        }
    }
}
