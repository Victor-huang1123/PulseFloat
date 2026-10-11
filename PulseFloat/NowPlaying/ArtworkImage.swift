import AppKit
import ImageIO
import PulseFloatCore

/// 封面與 App 圖示的影像處理：統一轉成最多 256×256 的 sRGB 點陣圖，繪圖時不必再縮放大圖。
enum ArtworkImage {
    /// 輸出圖片的最大邊長（像素）。
    static let maxPixels = 256

    /// 用 ImageIO 解碼圖片資料，置中裁成正方形並縮到最多 256×256。耗時，請在背景執行緒呼叫；失敗回傳 nil。
    nonisolated static func cover(from data: Data) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        // 讓短邊約 256 px 再裁切，避免把 3000 px 的封面整張解碼。
        let longSide = max(width, height)
        let shortSide = min(width, height)
        let maxPixelSize = min(longSide, Int((Double(maxPixels) * Double(longSide) / Double(shortSide)).rounded(.up)))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        let crop = NowPlayingParsing.centerSquareCrop(width: decoded.width, height: decoded.height)
        guard crop.width > 0, let square = decoded.cropping(to: crop) else { return nil }
        return render(square, side: min(maxPixels, square.width))
    }

    /// 把 App 圖示畫成 256×256 的點陣圖（不裁切，保留透明邊）；NSWorkspace 與 NSImage 繪圖在主執行緒進行。
    @MainActor
    static func appIcon(atPath path: String) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        guard let context = makeContext(side: maxPixels) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: maxPixels, height: maxPixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private nonisolated static func render(_ image: CGImage, side: Int) -> CGImage? {
        guard let context = makeContext(side: side) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    private nonisolated static func makeContext(side: Int) -> CGContext? {
        guard side > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
