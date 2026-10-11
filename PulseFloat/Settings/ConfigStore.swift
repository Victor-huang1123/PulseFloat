import Foundation
import PulseFloatCore

/// 把 `VisualizerConfig` 以原型相容的 JSON 存在 UserDefaults（SPEC §5 的 key `pulsefloat.params.v1`）。
/// 讀取時用寬鬆解碼並 `clamped()`；壞掉的資料直接忽略、回到預設值。只在主執行緒使用。
enum ConfigStore {
    static let key = "pulsefloat.params.v1"

    static func load(defaults: UserDefaults = .standard) -> VisualizerConfig? {
        guard let text = defaults.string(forKey: key), let data = text.data(using: .utf8),
              let config = try? JSONDecoder().decode(VisualizerConfig.self, from: data) else { return nil }
        return config.clamped()
    }

    static func save(_ config: VisualizerConfig, defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(config), let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: key)
    }

    /// 浮動視窗上次的位置與大小（螢幕座標，pt）；沒有存過或資料壞掉時回傳 nil。
    static let windowFrameKey = "pulsefloat.window.v1"

    static func loadWindowFrame(defaults: UserDefaults = .standard) -> NSRect? {
        guard let text = defaults.string(forKey: windowFrameKey) else { return nil }
        let frame = NSRectFromString(text)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    static func saveWindowFrame(_ frame: NSRect, defaults: UserDefaults = .standard) {
        defaults.set(NSStringFromRect(frame), forKey: windowFrameKey)
    }
}
