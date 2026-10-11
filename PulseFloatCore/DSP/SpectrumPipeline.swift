import Foundation

/// 將每個頻帶的 dBFS 處理成 0...1 高度；所有存取必須由同一執行緒依序進行。
/// 不綁定 actor；初始化及頻帶更新可配置記憶體，process 只配置回傳 frame 的兩個陣列。
public final class SpectrumPipeline {
    /// 目前使用的對數頻帶（Hz）；請在管線所屬執行緒讀取。
    public private(set) var bandLayout: BandLayout

    /// 目前 AGC 或固定上限（dB）；初始為 −12，AGC 運作時範圍為 −45...6。
    public private(set) var ceilingDb: Double = -12

    private var config: VisualizerConfig
    private var rawDb: [Float]
    private var values: [Float]
    private var peaks: [Float]
    private var peakTime: [Float]
    private var peakVelocity: [Float]
    private var temporary: [Float]
    private var centerHz: [Float]
    private var octaveOffsets: [Double]
    private var bass: Double = 0

    /// 以夾值後的設定建立管線；輸入初始為 −160 dBFS，其餘動態狀態為 0。
    /// 建立後須在單一執行緒使用。
    public init(config: VisualizerConfig) {
        let clamped = config.clamped()
        self.config = clamped
        bandLayout = BandLayout(
            count: clamped.bands.count,
            fMinHz: clamped.bands.fMinHz,
            fMaxHz: clamped.bands.fMaxHz
        )
        let count = bandLayout.count
        rawDb = [Float](repeating: -160, count: count)
        values = [Float](repeating: 0, count: count)
        peaks = [Float](repeating: 0, count: count)
        peakTime = [Float](repeating: 0, count: count)
        peakVelocity = [Float](repeating: 0, count: count)
        temporary = [Float](repeating: 0, count: count)
        centerHz = [Float](repeating: 0, count: count)
        octaveOffsets = [Double](repeating: 0, count: count)
        cacheBandFrequencies()
    }

    /// 在管線所屬執行緒套用夾值後的設定；count/fMinHz/fMaxHz 改變時重設全部狀態。
    /// 其他設定保留既有狀態；本方法允許配置記憶體。
    public func setConfig(_ config: VisualizerConfig) {
        let clamped = config.clamped()
        let rebuild = clamped.bands.count != self.config.bands.count
            || clamped.bands.fMinHz != self.config.bands.fMinHz
            || clamped.bands.fMaxHz != self.config.bands.fMaxHz
        self.config = clamped
        guard rebuild else { return }

        bandLayout = BandLayout(
            count: clamped.bands.count,
            fMinHz: clamped.bands.fMinHz,
            fMaxHz: clamped.bands.fMaxHz
        )
        let count = bandLayout.count
        rawDb = [Float](repeating: -160, count: count)
        values = [Float](repeating: 0, count: count)
        peaks = [Float](repeating: 0, count: count)
        peakTime = [Float](repeating: 0, count: count)
        peakVelocity = [Float](repeating: 0, count: count)
        temporary = [Float](repeating: 0, count: count)
        centerHz = [Float](repeating: 0, count: count)
        octaveOffsets = [Double](repeating: 0, count: count)
        ceilingDb = -12
        bass = 0
        cacheBandFrequencies()
    }

    /// 在管線所屬執行緒直接存取各頻帶原始 dBFS；非有限輸入在 process 時視為 −160。
    /// 指標僅在 body 執行期間有效；body 不得重入此管線或將指標保存到外部。
    public func withRawDb<R>(_ body: (UnsafeMutableBufferPointer<Float>) throws -> R) rethrows -> R {
        try rawDb.withUnsafeMutableBufferPointer { buffer in
            try body(buffer)
        }
    }

    /// 在管線所屬執行緒前進 dt 秒，回傳獨立擁有 values/peaks 的 0...1 頻譜。
    /// 有限 dt ≤ 0 時保留動態狀態，但 AGC 關閉時仍套用固定 ceiling。
    /// 非有限 dt（包含 +∞）完全不改變狀態；每次只配置回傳的兩個陣列。
    public func process(dt: Double) -> SpectrumFrame {
        guard dt.isFinite else { return makeFrame() }
        let level = config.level
        if !level.agc { ceilingDb = level.ceilingDb }
        guard dt > 0 else { return makeFrame() }

        let count = bandLayout.count
        let motion = config.motion
        var frameMaximum: Double = -160
        var index = 0
        while index < count {
            if !rawDb[index].isFinite { rawDb[index] = -160 }
            let compensated = Double(rawDb[index]) + config.bands.tiltDbPerOct * octaveOffsets[index]
            temporary[index] = Float(compensated)
            if compensated > frameMaximum { frameMaximum = compensated }
            index += 1
        }

        if level.agc {
            if frameMaximum > ceilingDb {
                ceilingDb += (frameMaximum - ceilingDb) * (1 - exp(-dt / 0.05))
            } else {
                ceilingDb -= level.agcReleaseDbPerSec * dt
            }
            ceilingDb = min(6, max(-45, ceilingDb))
        }

        let floorDb = ceilingDb - level.rangeDb
        index = 0
        while index < count {
            let normalized = Double(rawDb[index]) < level.gateDb
                ? 0 : (Double(temporary[index]) - floorDb) / level.rangeDb
            temporary[index] = Float(pow(min(1, max(0, normalized)), level.gamma))
            index += 1
        }

        // 與原型 Float32Array 相同：每次寫回為 Float，讀取後以 Double 計算。
        var previous = Double(temporary[0])
        index = 0
        while index < count {
            let current = Double(temporary[index])
            let next = Double(temporary[min(count - 1, index + 1)])
            let smoothed = (1 - motion.spatial) * current + motion.spatial * 0.5 * (previous + next)
            previous = current
            temporary[index] = Float(smoothed)
            index += 1
        }

        let attack = 1 - exp(-dt / (motion.attackMs / 1000))
        let release = 1 - exp(-dt / (motion.releaseMs / 1000))
        var bassTotal: Double = 0
        var bassCount = 0
        index = 0
        while index < count {
            let target = Double(temporary[index])
            let current = Double(values[index])
            let value = current + (target - current) * (target > current ? attack : release)
            values[index] = Float(value)
            if value >= Double(peaks[index]) {
                peaks[index] = Float(value)
                peakTime[index] = 0
                peakVelocity[index] = 0
            } else {
                // 極大但有限 dt 不讓 Float 時間或速度溢位；正常 dt 保留原型的儲存精度。
                peakTime[index] = Float(min(Double(Float.greatestFiniteMagnitude), Double(peakTime[index]) + dt))
                if Double(peakTime[index]) * 1000 > motion.peakHoldMs {
                    peakVelocity[index] = Float(min(
                        Double(Float.greatestFiniteMagnitude),
                        Double(peakVelocity[index]) + motion.peakGravity * dt
                    ))
                    let fallingPeak = Double(peaks[index]) - Double(peakVelocity[index]) * dt
                    // 保留先寫回 Float 再比較的順序；極大 dt 的負溢位夾到有限端點。
                    peaks[index] = Float(max(-Double(Float.greatestFiniteMagnitude), fallingPeak))
                    if Double(peaks[index]) < value {
                        peaks[index] = Float(value)
                        peakVelocity[index] = 0
                    }
                }
            }
            if centerHz[index] < 150 {
                bassTotal += value
                bassCount += 1
            }
            index += 1
        }

        let bassTarget = bassCount > 0 ? bassTotal / Double(bassCount) : 0
        bass += (bassTarget - bass) * (1 - exp(-dt / (bassTarget > bass ? 0.03 : 0.18)))
        return makeFrame()
    }

    private func cacheBandFrequencies() {
        for index in 0..<bandLayout.count {
            centerHz[index] = Float(bandLayout.center[index])
            octaveOffsets[index] = log2(Double(centerHz[index]) / 1000)
        }
    }

    private func makeFrame() -> SpectrumFrame {
        // 不把 state 陣列交給 frame：即使呼叫端保存舊幀，下次 process 也不會因 COW 配置。
        var frameValues = [Float](repeating: 0, count: bandLayout.count)
        var framePeaks = [Float](repeating: 0, count: bandLayout.count)
        var index = 0
        while index < bandLayout.count {
            frameValues[index] = values[index]
            framePeaks[index] = peaks[index]
            index += 1
        }
        return SpectrumFrame(values: frameValues, peaks: framePeaks, bass: Float(bass))
    }
}
