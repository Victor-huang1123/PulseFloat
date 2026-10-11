import Accelerate
import CoreGraphics
import Foundation

/// Neon 專用的可重用低解析度光暈工作區；與擁有它的 renderer 一同序列使用。
final class NeonGlowBuffers {
    let sourceContext: CGContext
    let downsample: Int
    let bounds: CGRect

    private let destinationData: UnsafeMutableRawPointer
    private let destinationByteCount: Int
    private let colorSpace: CGColorSpace
    private var sourceBuffer: vImage_Buffer
    private var destinationBuffer: vImage_Buffer
    private let temporaryBuffer: UnsafeMutableRawPointer
    private let transparent: [UInt8] = [0, 0, 0, 0]
    private let convolutionFlags = vImage_Flags(kvImageBackgroundColorFill | kvImageDoNotTile)

    init?(pixelSize: CGSize, scale: CGFloat, downsample: Int) {
        let width = Int(ceil(pixelSize.width / CGFloat(downsample)))
        let height = Int(ceil(pixelSize.height / CGFloat(downsample)))
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let source = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: colorSpace,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let sourceData = source.data,
              let destinationData = calloc(height, source.bytesPerRow) else { return nil }
        var initialized = false
        defer { if !initialized { free(destinationData) } }
        var sourceBuffer = vImage_Buffer(data: sourceData, height: vImagePixelCount(height),
                                         width: vImagePixelCount(width), rowBytes: source.bytesPerRow)
        var destinationBuffer = vImage_Buffer(data: destinationData, height: vImagePixelCount(height),
                                              width: vImagePixelCount(width), rowBytes: source.bytesPerRow)

        // bass 只改變 kernel；初始化時涵蓋所有可能的奇數寬度，避免每幀配置 temp。
        let maximumWidth = Self.kernelWidth(blur: downsample == 1 ? 3 : 24, downsample: downsample)
        let flags = vImage_Flags(kvImageBackgroundColorFill | kvImageDoNotTile | kvImageGetTempBufferSize)
        let background: [UInt8] = [0, 0, 0, 0]
        var temporarySize = 0
        var kernel: UInt32 = 3
        while kernel <= maximumWidth {
            let requiredSize = vImageTentConvolve_ARGB8888(
                &sourceBuffer, &destinationBuffer, nil, 0, 0, kernel, kernel, background, flags
            )
            guard requiredSize >= 0 else { return nil }
            temporarySize = max(temporarySize, requiredSize)
            kernel += 2
        }
        guard let temporary = malloc(max(1, temporarySize)) else { return nil }

        let glowScale = scale / CGFloat(downsample)
        source.translateBy(x: 0, y: CGFloat(height))
        source.scaleBy(x: glowScale, y: -glowScale)
        self.sourceContext = source
        self.destinationData = destinationData
        self.destinationByteCount = source.bytesPerRow * height
        self.colorSpace = colorSpace
        self.sourceBuffer = sourceBuffer
        self.destinationBuffer = destinationBuffer
        self.temporaryBuffer = temporary
        self.downsample = downsample
        self.bounds = CGRect(x: 0, y: 0, width: CGFloat(width) / glowScale, height: CGFloat(height) / glowScale)
        initialized = true
    }

    deinit {
        free(temporaryBuffer)
        free(destinationData)
    }

    func blurredImage(blur: CGFloat) -> CGImage? {
        let width = Self.kernelWidth(blur: blur, downsample: downsample)
        // 四個通道使用相同 kernel，因此此 API 亦可直接處理 RGBA；透明背景避免邊緣複製。
        let error = vImageTentConvolve_ARGB8888(
            &sourceBuffer, &destinationBuffer, temporaryBuffer, 0, 0, width, width,
            transparent, convolutionFlags
        )
        guard error == kvImageNoError else { return nil }
        // vImage 直接寫入 owned buffer；明確複製快照，避免繞過 CGContext.makeImage 的 COW。
        guard let snapshot = CFDataCreate(nil, destinationData.assumingMemoryBound(to: UInt8.self), destinationByteCount),
              let provider = CGDataProvider(data: snapshot) else { return nil }
        return CGImage(width: Int(destinationBuffer.width), height: Int(destinationBuffer.height),
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: destinationBuffer.rowBytes,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func kernelWidth(blur: CGFloat, downsample: Int) -> UInt32 {
        let sigma = blur / (2 * CGFloat(downsample))
        let base = max(2, (sqrt(6 * sigma * sigma + 1)).rounded())
        return UInt32(2 * base - 1)
    }
}
