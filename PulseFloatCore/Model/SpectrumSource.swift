import Foundation

/// 主執行緒使用的頻譜來源；由 App 層唯一的畫面時鐘驅動。
@MainActor
public protocol SpectrumSource: AnyObject {
    /// 前進 dt 秒並回傳這一幀要畫的資料。每次螢幕刷新在主執行緒呼叫一次。
    func nextFrame(dt: TimeInterval) -> SpectrumFrame
}
