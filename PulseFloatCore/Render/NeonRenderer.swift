import CoreGraphics
import Dispatch
import Foundation

/// 原型 drawNeon 的半浮點殘影與加亮光暈；同一實例須序列使用，不綁定 actor。
public final class NeonRenderer: SpectrumRenderer {
    /// 目前殘影 bitmap 的像素尺寸；尚未成功建立時為 zero，須與 draw 序列存取。
    public private(set) var bitmapPixelSize: CGSize = .zero

    private var bitmap: CGContext?
    private var trailBuffer: NeonTrailBuffer?
    private var bitmapPointSize: CGSize = .zero
    private var bitmapScale: CGFloat = 0
    private var glowBuffers: NeonGlowBuffers?
    private let paletteCache = RenderPaletteCache()
    private var strokeColors: [CGColor] = []
    private var strokePalette: PaletteID?
    private var strokeAlpha: CGFloat = 0
    private let maximumWorkers: Int

    /// 建立不含殘影的繪圖器；更換主題時建立新實例即可重置。
    public init() { maximumWorkers = 8 }

    // 測試可限制為序列合成，逐像素驗證分區插值與多幀殘影的一致性。
    init(maximumWorkers: Int) { self.maximumWorkers = min(8, max(1, maximumWorkers)) }

    /// 以 pt 與 y 向下的 context 繪圖；options.scale 明確指定 bitmap 倍率，不由 CTM 推測。
    /// look 須先 clamped；空或不等長 frame 清空目標與殘影，尺寸或倍率變更亦重置殘影。
    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame, look: VisualizerConfig.Look, options: RenderOptions) {
        context.saveGState()
        defer { context.restoreGState() }
        let bounds = CGRect(origin: .zero, size: size)
        context.clear(bounds)
        guard RenderMath.isDrawable(size: size, frame: frame), options.scale.isFinite, options.scale > 0 else {
            bitmap = nil
            trailBuffer = nil
            bitmapPointSize = .zero
            bitmapPixelSize = .zero
            bitmapScale = 0
            glowBuffers = nil
            return
        }
        guard let bitmap = prepareBitmap(size: size, scale: options.scale) else { return }
        let fade = options.fade.isNaN ? 0 : min(1, max(0, options.fade))

        let count = frame.bandCount
        let padX = size.width * 0.06
        let middle = size.height * 0.5
        let maxHeight = size.height * 0.4
        let pitch = (size.width - padX * 2) / CGFloat(count)
        let lineWidth = max(1, pitch * (1 - look.barGap) * 0.7)
        let bass = RenderMath.unit(frame.bass)
        let alpha: CGFloat = options.isThumbnail ? 0.55 : 0.9
        updateStrokeColors(palette: look.palette, count: count, alpha: alpha)
        let blur: CGFloat = options.isThumbnail ? 3 : 14 + 10 * bass
        let downsample = options.isThumbnail ? 1 : 4
        if glowBuffers?.downsample != downsample {
            glowBuffers = NeonGlowBuffers(pixelSize: bitmapPixelSize, scale: options.scale, downsample: downsample)
        }
        var compositedGlow = false
        if let glowBuffers {
            glowBuffers.sourceContext.clear(glowBuffers.bounds)
            drawLines(in: glowBuffers.sourceContext, frame: frame, colors: strokeColors,
                      padX: padX, middle: middle, maxHeight: maxHeight, pitch: pitch, lineWidth: lineWidth)
            if let glow = glowBuffers.blurredImage(blur: blur) {
                trailBuffer?.drawGlow(glow, size: size, fade: fade)
                compositedGlow = true
            }
        }
        if !compositedGlow {
            bitmap.saveGState()
            bitmap.setBlendMode(.destinationOut)
            bitmap.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: fade))
            bitmap.fill(bounds)
            bitmap.restoreGState()
        }
        drawLines(in: bitmap, frame: frame, colors: strokeColors,
                  padX: padX, middle: middle, maxHeight: maxHeight, pitch: pitch, lineWidth: lineWidth)
        let palette = Palette(look.palette)
        if let gradient = RenderMath.gradient([
            palette.color(at: 0).cgColor(alpha: 0),
            palette.color(at: 0.5).cgColor(alpha: 0.5 + 0.4 * bass),
            palette.color(at: 1).cgColor(alpha: 0)
        ], locations: [0, 0.5, 1]) {
            let horizon = CGPath(rect: CGRect(x: padX, y: middle - 0.5, width: size.width - padX * 2, height: 1), transform: nil)
            RenderMath.fillGradient(gradient, in: bitmap, path: horizon,
                                    start: CGPoint(x: padX, y: 0), end: CGPoint(x: size.width - padX, y: 0))
        }
        guard let image = trailBuffer?.snapshotImage() else { return }
        // CGImage 的原生座標 y 向上；在 y 向下的目標 context 局部翻回，避免殘影上下顛倒。
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
    }

    private func drawLines(
        in context: CGContext,
        frame: SpectrumFrame,
        colors: [CGColor],
        padX: CGFloat,
        middle: CGFloat,
        maxHeight: CGFloat,
        pitch: CGFloat,
        lineWidth: CGFloat
    ) {
        context.saveGState()
        context.setBlendMode(.plusLighter)
        context.setLineCap(.round)
        context.setLineWidth(lineWidth)
        var index = 0
        while index < frame.bandCount {
            let x = padX + (CGFloat(index) + 0.5) * pitch
            let length = max(1, RenderMath.unit(frame.values[index]) * maxHeight)
            context.setStrokeColor(colors[index])
            context.beginPath()
            context.move(to: CGPoint(x: x, y: middle - length))
            context.addLine(to: CGPoint(x: x, y: middle + length * 0.55))
            context.strokePath()
            index += 1
        }
        context.restoreGState()
    }

    private func updateStrokeColors(palette: PaletteID, count: Int, alpha: CGFloat) {
        guard strokePalette != palette || strokeColors.count != count || strokeAlpha != alpha else { return }
        let colors = paletteCache.colors(for: palette, count: count)
        strokeColors.removeAll(keepingCapacity: true)
        strokeColors.reserveCapacity(count)
        var index = 0
        while index < count {
            strokeColors.append(colors[index].cgColor(alpha: alpha))
            index += 1
        }
        strokePalette = palette
        strokeAlpha = alpha
    }

    private func prepareBitmap(size: CGSize, scale: CGFloat) -> CGContext? {
        if let bitmap, bitmapPointSize == size, bitmapScale == scale { return bitmap }
        bitmap = nil
        trailBuffer = nil
        bitmapPixelSize = .zero
        glowBuffers = nil
        let pixelWidth = ceil(size.width * scale)
        let pixelHeight = ceil(size.height * scale)
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0,
              pixelWidth < CGFloat(Int.max), pixelHeight < CGFloat(Int.max),
              let storage = NeonTrailBuffer(width: Int(pixelWidth), height: Int(pixelHeight), scale: scale,
                                            maximumWorkers: maximumWorkers) else { return nil }
        let created = storage.context
        trailBuffer = storage
        bitmap = created
        bitmapPointSize = size
        bitmapScale = scale
        bitmapPixelSize = CGSize(width: pixelWidth, height: pixelHeight)
        return created
    }
}

/// 安全性：renderer 序列呼叫；worker 只讀 trail，且各自寫獨立 scratch context。
/// concurrentPerform 同步結束後，呼叫執行緒才回寫互不重疊的中心列、存取 context 或建立快照。
private final class NeonTrailBuffer: @unchecked Sendable {
    let context: CGContext

    private struct Tile {
        let context: CGContext
        let data: UnsafeMutableRawPointer
        let firstRow: Int
        let endRow: Int
        let paddedFirstRow: Int
        let paddedEndRow: Int
    }

    private let data: UnsafeMutableRawPointer
    private let width: Int
    private let height: Int
    private let rowBytes: Int
    private let colorSpace: CGColorSpace
    private let bitmapInfo: CGBitmapInfo
    private let tiles: [Tile]

    init?(width: Int, height: Int, scale: CGFloat, maximumWorkers: Int) {
        let rowSize = width.multipliedReportingOverflow(by: 8)
        guard !rowSize.overflow,
              !rowSize.partialValue.multipliedReportingOverflow(by: height).overflow,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let data = calloc(height, rowSize.partialValue) else { return nil }
        var ownershipTransferred = false
        defer { if !ownershipTransferred { free(data) } }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let context = CGContext(data: data, width: width, height: height, bitsPerComponent: 16,
                                      bytesPerRow: rowSize.partialValue, space: colorSpace,
                                      bitmapInfo: bitmapInfo.rawValue,
                                      releaseCallback: { _, data in free(data) }, releaseInfo: nil) else { return nil }
        // 由 context 的 release callback 釋放；renderer 另持有 context 時亦不會提前 free。
        ownershipTransferred = true
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        var tiles: [Tile] = []
        let workerCount = min(maximumWorkers, ProcessInfo.processInfo.activeProcessorCount, height / 48)
        if width * height >= 200_000 && workerCount > 1 {
            var index = 0
            while index < workerCount {
                let first = height * index / workerCount
                let end = height * (index + 1) / workerCount
                // medium 插值在 context 邊緣會裁掉取樣；放大倍率至多 4，保留 8 px 邊帶。
                let paddedFirst = max(0, first - 8)
                let paddedEnd = min(height, end + 8)
                guard let scratch = CGContext(data: nil, width: width, height: paddedEnd - paddedFirst,
                                              bitsPerComponent: 16, bytesPerRow: rowSize.partialValue,
                                              space: colorSpace, bitmapInfo: bitmapInfo.rawValue),
                      let scratchData = scratch.data else { return nil }
                scratch.translateBy(x: 0, y: CGFloat(paddedEnd))
                scratch.scaleBy(x: scale, y: -scale)
                tiles.append(Tile(context: scratch, data: scratchData, firstRow: first, endRow: end,
                                  paddedFirstRow: paddedFirst, paddedEndRow: paddedEnd))
                index += 1
            }
        }
        self.context = context
        self.data = data
        self.width = width
        self.height = height
        self.rowBytes = rowSize.partialValue
        self.colorSpace = colorSpace
        self.bitmapInfo = bitmapInfo
        self.tiles = tiles
    }

    func drawGlow(_ image: CGImage, size: CGSize, fade: Double) {
        let fadeColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: fade)
        guard !tiles.isEmpty else {
            Self.drawGlow(image, in: context, size: size, fadeColor: fadeColor)
            return
        }
        DispatchQueue.concurrentPerform(iterations: tiles.count) { index in
            let tile = self.tiles[index]
            memcpy(tile.data, self.data.advanced(by: tile.paddedFirstRow * self.rowBytes),
                   (tile.paddedEndRow - tile.paddedFirstRow) * self.rowBytes)
            Self.drawGlow(image, in: tile.context, size: size, fadeColor: fadeColor)
        }
        // 此處所有 worker 已完成；scratch 不產生 CGImage，因此沒有 snapshot/COW 指標失效。
        var index = 0
        while index < tiles.count {
            let tile = tiles[index]
            memcpy(data.advanced(by: tile.firstRow * rowBytes),
                   tile.data.advanced(by: (tile.firstRow - tile.paddedFirstRow) * rowBytes),
                   (tile.endRow - tile.firstRow) * rowBytes)
            index += 1
        }
    }

    func snapshotImage() -> CGImage? {
        // trail 由 caller-owned storage 支撐，快照明確複製，後續 raw 回寫不依賴 CGContext COW。
        guard let snapshot = CFDataCreate(nil, data.assumingMemoryBound(to: UInt8.self), rowBytes * height),
              let provider = CGDataProvider(data: snapshot) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                       bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func drawGlow(_ image: CGImage, in context: CGContext, size: CGSize, fadeColor: CGColor) {
        let bounds = CGRect(origin: .zero, size: size)
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.setFillColor(fadeColor)
        context.fill(bounds)
        context.setBlendMode(.plusLighter)
        context.interpolationQuality = .medium
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}
