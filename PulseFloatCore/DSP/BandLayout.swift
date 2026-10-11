import Foundation

/// 對數等距的頻帶配置（Hz）；不可變的值型別，可跨執行緒傳遞。
public struct BandLayout: Sendable {
    /// 各頻帶下緣（Hz），由低到高排列，以 Double 計算及儲存。
    public let lo: [Double]
    /// 各頻帶上緣（Hz）；相鄰頻帶共用同一個邊界。
    public let hi: [Double]
    /// 各頻帶的幾何中心（Hz），等於 sqrt(lo × hi)。
    public let center: [Double]

    /// 頻帶數量；無效輸入所建立的配置為 0。
    public var count: Int { center.count }

    /// 建立 count 個頻帶；可於任意執行緒呼叫。
    /// count 須為正數，頻率須為有限正值且 fMaxHz ≥ fMinHz；無效或計算溢位時回傳空配置。
    public init(count: Int, fMinHz: Double, fMaxHz: Double) {
        guard count > 0, fMinHz.isFinite, fMaxHz.isFinite,
              fMinHz > 0, fMaxHz >= fMinHz,
              (fMaxHz / fMinHz).isFinite else {
            lo = []
            hi = []
            center = []
            return
        }

        var lower = [Double](repeating: 0, count: count)
        var upper = [Double](repeating: 0, count: count)
        var centers = [Double](repeating: 0, count: count)
        let ratio = fMaxHz / fMinHz
        for index in 0..<count {
            let low = fMinHz * pow(ratio, Double(index) / Double(count))
            let high = fMinHz * pow(ratio, Double(index + 1) / Double(count))
            let middle = sqrt(low * high)
            guard low.isFinite, high.isFinite, middle.isFinite, middle > 0 else {
                lo = []
                hi = []
                center = []
                return
            }
            lower[index] = low
            upper[index] = high
            centers[index] = middle
        }
        lo = lower
        hi = upper
        center = centers
    }
}
