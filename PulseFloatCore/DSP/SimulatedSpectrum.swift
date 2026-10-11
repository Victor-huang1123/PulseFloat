import Foundation

/// 原型的 128 BPM kick、和弦、掃頻與 hi-hat 頻譜；不依賴 actor。
/// 同一實例及其 noise closure 應由單一執行緒依序使用。
public struct SimulatedSpectrum {
    private let centers: [Float]
    private let noise: @Sendable () -> Double

    /// 建立固定頻帶的模擬器；noise 預期回傳 −0.5...0.5，測試可注入 { 0 }。
    /// 頻帶改變時建立新實例；中心頻率轉為 Float，以重現原型的 Float32 儲存點。
    public init(
        layout: BandLayout,
        noise: @escaping @Sendable () -> Double = { Double.random(in: -0.5...0.5) }
    ) {
        var centers = [Float](repeating: 0, count: layout.count)
        for index in 0..<layout.count {
            centers[index] = Float(layout.center[index])
        }
        self.centers = centers
        self.noise = noise
    }

    /// 將 time 秒時的補償前 dB 寫入前 min(rawDb.count, 頻帶數) 個元素，其餘保持不變。
    /// 非有限的時間或計算結果視為 −160 dB；本方法不配置工作記憶體，noise 的配置行為由呼叫端負責。
    public func fill(_ rawDb: UnsafeMutableBufferPointer<Float>, time: Double) {
        let count = min(rawDb.count, centers.count)
        guard time.isFinite else {
            var index = 0
            while index < count {
                rawDb[index] = -160
                index += 1
            }
            return
        }
        let secondsPerBeat = 60.0 / 128
        let phase = (time / secondsPerBeat).truncatingRemainder(dividingBy: 1)
        let kick = exp(-phase * 7)
        let hat = exp(-(phase + 0.5).truncatingRemainder(dividingBy: 1) * 16)
        let bar = (floor(time / (secondsPerBeat * 4)).truncatingRemainder(dividingBy: 4) + 4)
            .truncatingRemainder(dividingBy: 4)
        let chordHz: Double
        switch bar {
        case 0: chordHz = 220
        case 1: chordHz = 174.6
        case 2: chordHz = 261.6
        default: chordHz = 196
        }
        let sweep = 900 * pow(2, sin(time * 0.45) * 2)
        let chordEnvelope = 0.7 + 0.3 * sin(time * 3)
        // Range iteration allocates in Debug; keep the per-frame loop index-based.
        var index = 0
        while index < count {
            let frequency = Double(centers[index])
            var db = -20 - 4.2 * log2(frequency / 60)
            db += 16 * kick * Self.gaussian(log2(frequency / 55), width: 0.7)
            db += 9 * Self.gaussian(log2(frequency / chordHz), width: 0.35) * chordEnvelope
            db += 7 * Self.gaussian(log2(frequency / sweep), width: 0.5)
            db += 11 * hat * Self.gaussian(log2(frequency / 9500), width: 0.9)
            db += noise() * 7
            let result = Float(db)
            rawDb[index] = result.isFinite ? result : -160
            index += 1
        }
    }

    private static func gaussian(_ value: Double, width: Double) -> Double {
        exp(-(value * value) / (2 * width * width))
    }
}
