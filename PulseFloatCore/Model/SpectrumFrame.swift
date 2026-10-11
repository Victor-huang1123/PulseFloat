/// 可跨執行緒傳遞的單幀頻譜值；有效資料應維持 values.count == peaks.count == bandCount，且數值在 0...1。
/// 原樣保存輸入，renderer 須容忍不等長陣列。
public struct SpectrumFrame: Sendable, Equatable {
    /// 各頻帶的正規化高度（0...1），依低頻到高頻排列。
    public var values: [Float]
    /// 各頻帶的峰值帽位置（0...1），長度須與 values 相同。
    public var peaks: [Float]
    /// 平滑後的低頻能量（0...1），供脈動效果使用。
    public var bass: Float

    /// 原樣建立頻譜，不檢查或修正輸入；有效資料應為等長陣列且數值在 0...1，可於任意執行緒呼叫。
    public init(values: [Float], peaks: [Float], bass: Float) {
        self.values = values
        self.peaks = peaks
        self.bass = bass
    }

    /// 頻帶數量（可為 0），以 values 的長度為準；有效資料的 peaks 應具有相同長度。
    public var bandCount: Int { values.count }

    /// 建立指定頻帶數的全零頻譜，負數視為 0；可於任意執行緒呼叫。
    public static func silent(bandCount: Int) -> SpectrumFrame {
        let count = max(0, bandCount)
        return SpectrumFrame(
            values: [Float](repeating: 0, count: count),
            peaks: [Float](repeating: 0, count: count),
            bass: 0
        )
    }
}
