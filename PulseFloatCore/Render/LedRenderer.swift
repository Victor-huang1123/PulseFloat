import CoreGraphics
import Foundation

/// 原型 drawLed 的頻帶重採樣點陣與峰值點；同一實例須序列使用。
public final class LedRenderer: SpectrumRenderer {
    private var litRows: [Int] = []
    private var peakRows: [Int] = []
    private var geometrySize = CGSize.zero
    private var geometryColumns = 0
    private var geometryRows = 0
    private var cellPaths: [CGPath] = []
    private var litPaths: [CGPath] = []
    private var peakPaths: [CGPath] = []
    private var dirtyRows: [Bool] = []
    private var unlitPath: CGPath?
    private var paletteID: PaletteID?
    private var litColors: [CGColor] = []
    private var peakColors: [CGColor] = []
    private let unlitColor = RGB(red: 255, green: 255, blue: 255).cgColor(alpha: 0.055)
    private var bitmapContext: CGContext?
    private var bitmapSize = CGSize.zero
    private var bitmapScale: CGFloat = 0
    private var cachedImage: CGImage?

    /// 建立獨立繪圖器，不綁定 actor。
    public init() {}

    /// 以 pt 與 y 向下的 context 繪圖；look 須先 clamped，空或不等長 frame 只清空。
    public func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame, look: VisualizerConfig.Look, options: RenderOptions) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clear(CGRect(origin: .zero, size: size))
        guard RenderMath.isDrawable(size: size, frame: frame),
              options.scale.isFinite, options.scale > 0 else { return }
        let columns = max(8, Int((Double(frame.bandCount) / (options.isThumbnail ? 2 : 1.5)).rounded()))
        let padX = size.width * 0.05
        let padY = size.height * 0.1
        let pitch = (size.width - padX * 2) / CGFloat(columns)
        let cell = pitch * 0.72
        let rows = max(4, Int(floor((size.height - padY * 2) / pitch)))
        let top = padY + ((size.height - padY * 2) - CGFloat(rows) * pitch) / 2
        let geometryChanged = updateGeometry(size: size, columns: columns, rows: rows,
                                             pitch: pitch, cell: cell, padX: padX, top: top)
        let colorsChanged = updateColors(palette: look.palette, rows: rows)
        if dirtyRows.count != rows {
            dirtyRows = [Bool](repeating: true, count: rows)
            litPaths = [CGPath](repeating: CGMutablePath(), count: rows)
            peakPaths = [CGPath](repeating: CGMutablePath(), count: rows)
        }
        if litRows.count != columns {
            litRows = [Int](repeating: 0, count: columns)
            peakRows = [Int](repeating: 0, count: columns)
        }
        var hasDirtyRows = false
        var column = 0
        while column < columns {
            let first = column * frame.bandCount / columns
            let end = min(frame.bandCount, max(first + 1, (column + 1) * frame.bandCount / columns))
            var value: CGFloat = 0
            var peak: CGFloat = 0
            var index = first
            while index < end {
                value = max(value, RenderMath.unit(frame.values[index]))
                peak = max(peak, RenderMath.unit(frame.peaks[index]))
                index += 1
            }
            let lit = Int((value * CGFloat(rows)).rounded())
            let peakRow = min(rows - 1, Int((peak * CGFloat(rows)).rounded()))
            if litRows[column] != lit || peakRows[column] != peakRow {
                var row = 0
                while row < rows {
                    let wasOn = row < litRows[column]
                    let wasPeak = row == peakRows[column] && row > 0 && !wasOn
                    let isOn = row < lit
                    let isPeak = row == peakRow && row > 0 && !isOn
                    if wasOn != isOn || wasPeak != isPeak {
                        dirtyRows[row] = true
                        hasDirtyRows = true
                    }
                    row += 1
                }
                litRows[column] = lit
                peakRows[column] = peakRow
            }
            column += 1
        }
        let bitmapChanged = updateBitmap(size: size, scale: options.scale)
        guard let bitmapContext else { return }
        // 列界線位於空隙中央；空隙不足 2 px 時改成全畫，保護鄰列的反鋸齒像素。
        let redrawAll = geometryChanged || colorsChanged || bitmapChanged || cachedImage == nil
            || (hasDirtyRows && pitch * options.scale * 0.14 < 1)
        if redrawAll {
            var row = 0
            while row < rows {
                dirtyRows[row] = true
                row += 1
            }
            hasDirtyRows = true
        }
        if hasDirtyRows {
            cachedImage = nil
            rebuildPaths(columns: columns, rows: rows)
            if redrawAll {
                bitmapContext.clear(CGRect(origin: .zero, size: size))
            } else {
                var row = 0
                while row < rows {
                    if dirtyRows[row] {
                        let start = top + CGFloat(rows - 1 - row) * pitch
                        let y0 = (start * options.scale).rounded() / options.scale
                        let y1 = ((start + pitch) * options.scale).rounded() / options.scale
                        bitmapContext.clear(CGRect(x: 0, y: y0, width: size.width, height: y1 - y0))
                    }
                    row += 1
                }
            }
            fillPaths(in: bitmapContext, rows: rows)
            cachedImage = bitmapContext.makeImage()
            var row = 0
            while row < rows {
                dirtyRows[row] = false
                row += 1
            }
        }
        guard let cachedImage else { return }
        // bitmap 已是 y 向下；CGImage 合成時局部翻回，避免上下顛倒。
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(cachedImage, in: CGRect(origin: .zero, size: size))
    }

    private func fillPaths(in context: CGContext, rows: Int) {
        if let unlitPath, !unlitPath.isEmpty {
            RenderMath.fill(unlitPath, in: context, color: unlitColor)
        }
        var row = 0
        while row < rows {
            if dirtyRows[row] {
                if !litPaths[row].isEmpty {
                    RenderMath.fill(litPaths[row], in: context, color: litColors[row])
                }
                if !peakPaths[row].isEmpty {
                    RenderMath.fill(peakPaths[row], in: context, color: peakColors[row])
                }
            }
            row += 1
        }
    }

    private func updateGeometry(size: CGSize, columns: Int, rows: Int,
                                pitch: CGFloat, cell: CGFloat, padX: CGFloat, top: CGFloat) -> Bool {
        guard geometrySize != size || geometryColumns != columns || geometryRows != rows else { return false }
        geometrySize = size
        geometryColumns = columns
        geometryRows = rows
        cellPaths.removeAll(keepingCapacity: true)
        cellPaths.reserveCapacity(columns * rows)
        let radius = min(2, cell * 0.25)
        var row = 0
        while row < rows {
            let y = top + CGFloat(rows - 1 - row) * pitch + (pitch - cell) / 2
            var column = 0
            while column < columns {
                let x = padX + CGFloat(column) * pitch + (pitch - cell) / 2
                cellPaths.append(RenderMath.roundedRect(
                    CGRect(x: x, y: y, width: cell, height: cell), radius: radius
                ))
                column += 1
            }
            row += 1
        }
        return true
    }

    private func updateColors(palette: PaletteID, rows: Int) -> Bool {
        guard paletteID != palette || litColors.count != rows else { return false }
        paletteID = palette
        litColors.removeAll(keepingCapacity: true)
        peakColors.removeAll(keepingCapacity: true)
        litColors.reserveCapacity(rows)
        peakColors.reserveCapacity(rows)
        let colors = Palette(palette)
        var row = 0
        while row < rows {
            let color = colors.color(at: Double(row) / Double(rows - 1))
            litColors.append(color.cgColor(alpha: 0.95))
            peakColors.append(color.cgColor(alpha: 0.7))
            row += 1
        }
        return true
    }

    private func updateBitmap(size: CGSize, scale: CGFloat) -> Bool {
        guard bitmapContext == nil || bitmapSize != size || bitmapScale != scale else { return false }
        bitmapContext = nil
        cachedImage = nil
        bitmapSize = size
        bitmapScale = scale
        let width = ceil(size.width * scale)
        let height = ceil(size.height * scale)
        guard width.isFinite, height.isFinite, width < CGFloat(Int.max), height < CGFloat(Int.max),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(
                data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return true }
        bitmap.translateBy(x: 0, y: height)
        bitmap.scaleBy(x: scale, y: -scale)
        bitmapContext = bitmap
        return true
    }

    private func rebuildPaths(columns: Int, rows: Int) {
        // 只重建有格子變化的列；其他列的 path 與 bitmap 像素皆可沿用。
        let unlitPath = CGMutablePath()
        var row = 0
        while row < rows {
            if !dirtyRows[row] {
                row += 1
                continue
            }
            let litPath = CGMutablePath()
            let peakPath = CGMutablePath()
            var column = 0
            while column < columns {
                let path: CGMutablePath
                if row < litRows[column] {
                    path = litPath
                } else if row == peakRows[column] && row > 0 {
                    path = peakPath
                } else {
                    path = unlitPath
                }
                path.addPath(cellPaths[row * columns + column])
                column += 1
            }
            litPaths[row] = litPath
            peakPaths[row] = peakPath
            row += 1
        }
        self.unlitPath = unlitPath
    }
}
