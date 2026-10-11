import CoreGraphics
import Foundation

/// Render 專用幾何命名空間，避免在 T02 共用 module 注入 extension 或頂層函式。
enum RenderMath {
    static func unit(_ value: Float) -> CGFloat {
        value.isNaN ? 0 : CGFloat(min(1, max(0, value)))
    }

    static func isDrawable(size: CGSize, frame: SpectrumFrame) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && frame.bandCount > 0 && frame.values.count == frame.peaks.count
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func gradient(_ colors: [CGColor], locations: [CGFloat]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)
    }

    static func fill(_ path: CGPath, in context: CGContext, color: CGColor) {
        context.addPath(path)
        context.setFillColor(color)
        context.fillPath()
    }

    static func fillGradient(
        _ gradient: CGGradient,
        in context: CGContext,
        path: CGPath,
        start: CGPoint,
        end: CGPoint
    ) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    static func strokeGradient(
        _ gradient: CGGradient,
        in context: CGContext,
        path: CGPath,
        start: CGPoint,
        end: CGPoint
    ) {
        context.saveGState()
        context.addPath(path)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }
}
