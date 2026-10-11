import CoreGraphics
import Foundation
import PulseFloatCore
import XCTest

enum RenderTestSupport {
    /// 原本四個 2D 主題；新主題各自有測試檔，不放進共用的通用測試。
    static let legacyThemes: [ThemeID] = [.bars, .radial, .neon, .led]

    static let size = CGSize(width: 320, height: 120)
    static let fade = 1 - exp(-(1.0 / 60.0) / 0.07)

    static func frame(level: Float = 1, bandCount: Int = 64) -> SpectrumFrame {
        SpectrumFrame(
            values: [Float](repeating: level, count: bandCount),
            peaks: [Float](repeating: level, count: bandCount),
            bass: level
        )
    }

    struct Bitmap {
        let context: CGContext
        let width: Int
        let height: Int

        init(size: CGSize = RenderTestSupport.size, scale: CGFloat = 1,
             colorSpaceName: CFString = CGColorSpace.sRGB) throws {
            width = Int(ceil(size.width * scale))
            height = Int(ceil(size.height * scale))
            let colorSpace = try XCTUnwrap(CGColorSpace(name: colorSpaceName))
            context = try XCTUnwrap(CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
        }

        func component(x: Int, y: Int, channel: Int) -> UInt8 {
            guard x >= 0, x < width, y >= 0, y < height, let data = context.data else { return 0 }
            return data.load(fromByteOffset: y * context.bytesPerRow + x * 4 + channel, as: UInt8.self)
        }

        func alpha(x: Int, y: Int) -> UInt8 {
            component(x: x, y: y, channel: 3)
        }

        var alphaSum: Int {
            var sum = 0
            for y in 0..<height {
                for x in 0..<width {
                    sum += Int(alpha(x: x, y: y))
                }
            }
            return sum
        }

        func visibleCount(rows: Range<Int>? = nil) -> Int {
            var count = 0
            for y in rows ?? 0..<height {
                for x in 0..<width where alpha(x: x, y: y) > 0 {
                    count += 1
                }
            }
            return count
        }

        var visibleRatio: Double {
            Double(visibleCount()) / Double(width * height)
        }

        func borderMaximum(includeHorizontal: Bool = true) -> UInt8 {
            var maximum: UInt8 = 0
            for y in 0..<height {
                for x in 0..<width {
                    if x < 2 || x >= width - 2 || (includeHorizontal && (y < 2 || y >= height - 2)) {
                        maximum = max(maximum, alpha(x: x, y: y))
                    }
                }
            }
            return maximum
        }
    }
}
