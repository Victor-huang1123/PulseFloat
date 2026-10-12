/// 決定系統音訊擷取什麼時候接上、什麼時候釋放輸出裝置（純邏輯，可測試）。
/// 有其他程序在輸出聲音就接上；連續 `releaseDelay` 秒都沒有就釋放；啟動失敗後 `retryDelay` 秒內不重試。
/// 時間單位是秒（單調時鐘）。值型別，序列使用。
public struct CaptureGate: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case start
        case release
    }

    public let releaseDelay: Double
    public let retryDelay: Double
    private var idleSince: Double?

    public init(releaseDelay: Double = 3, retryDelay: Double = 5) {
        self.releaseDelay = releaseDelay
        self.retryDelay = retryDelay
    }

    /// 回到初始狀態（例如預設輸出裝置改變、整條重建之後）。
    public mutating func reset() { idleSince = nil }

    /// 根據目前狀況決定要做什麼。
    public mutating func evaluate(othersOutputting: Bool, isCapturing: Bool, now: Double, lastFailure: Double?) -> Action {
        if othersOutputting {
            idleSince = nil
            guard !isCapturing else { return .none }
            if let lastFailure, now - lastFailure < retryDelay { return .none }
            return .start
        }
        guard isCapturing else {
            idleSince = nil
            return .none
        }
        guard let since = idleSince else {
            idleSince = now
            return .none
        }
        guard now - since >= releaseDelay else { return .none }
        idleSince = nil
        return .release
    }
}
