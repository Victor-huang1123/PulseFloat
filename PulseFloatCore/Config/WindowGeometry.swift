import CoreGraphics

/// 浮動視窗的尺寸規則（pt，AppKit 左下原點的螢幕座標）：固定 2.6:1、最小 182 寬、
/// 最大不超過螢幕可用寬度的 60%（且不超過 1040），並且整個視窗一定落在可用範圍內。
public enum WindowGeometry {
    public static let aspect: CGFloat = 2.6
    public static let minWidth: CGFloat = 182
    public static let maxWidthCap: CGFloat = 1040
    public static let defaultWidth: CGFloat = 390

    /// 這個可用範圍允許的最大寬度（至少等於 minWidth）。
    public static func maxWidth(in visible: CGRect) -> CGFloat {
        let byWidth = visible.width * 0.6
        let byHeight = visible.height * 0.6 * aspect
        return max(minWidth, min(maxWidthCap, byWidth, byHeight))
    }

    /// 第一次啟動的位置：可用範圍左側 8%、自上方 40% 處。
    public static func defaultFrame(in visible: CGRect) -> CGRect {
        let width = min(defaultWidth, maxWidth(in: visible))
        let height = width / aspect
        return fit(CGRect(x: visible.minX + 0.08 * visible.width,
                          y: visible.maxY - 0.40 * visible.height - height,
                          width: width, height: height), in: visible)
    }

    /// 修正比例、夾住寬度並把視窗整個移進可用範圍；尺寸改變時固定左上角。非有限值回到預設位置。
    public static func fit(_ frame: CGRect, in visible: CGRect) -> CGRect {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, visible.width > 0, visible.height > 0 else {
            return defaultFrame(in: visible.width > 0 && visible.height > 0 ? visible : CGRect(x: 0, y: 0, width: 1440, height: 900))
        }
        let width = min(maxWidth(in: visible), max(minWidth, frame.width))
        let height = width / aspect
        var x = frame.minX
        var y = frame.maxY - height
        x = min(max(x, visible.minX), visible.maxX - width)
        y = min(max(y, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 從一組螢幕的可用範圍中挑出與 frame 重疊最多的一個；完全沒有重疊時回傳 nil。
    public static func bestVisibleFrame(for frame: CGRect, among visibles: [CGRect]) -> CGRect? {
        var best: CGRect?
        var bestArea: CGFloat = 0
        var index = 0
        while index < visibles.count {
            let overlap = visibles[index].intersection(frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea { bestArea = area; best = visibles[index] }
            index += 1
        }
        return best
    }
}
