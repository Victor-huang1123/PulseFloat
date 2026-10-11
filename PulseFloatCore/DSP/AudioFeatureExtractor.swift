import Accelerate
import Foundation

/// 由「同一次 FFT」的每個 bin 的 dBFS、mid/side 時域窗與顯示頻段計算 `AudioFeatures`。
/// 不做第二次 FFT；初始化後不配置記憶體。序列使用（主執行緒），不可並行。
public final class AudioFeatureExtractor {
    /// 目前的特徵。
    public private(set) var features = AudioFeatures()

    private static let floorDb: Float = -80
    private static let historyLength = 24
    private let maxBins: Int
    private let previousDb: UnsafeMutablePointer<Float>
    private let history: UnsafeMutablePointer<Float>
    private var historyIndex = 0
    private var historyFilled = 0
    private var fluxScale: Float = 0.5
    private var previousFlux: Float = 0
    private var previousThreshold: Float = 0
    private var cooldown: Double = 0

    /// maxBins：最多處理的 FFT bin 數（4096 點 FFT 為 2048）。
    public init(maxBins: Int = 2048) {
        self.maxBins = max(1, maxBins)
        previousDb = .allocate(capacity: self.maxBins)
        previousDb.initialize(repeating: Self.floorDb, count: self.maxBins)
        history = .allocate(capacity: Self.historyLength)
        history.initialize(repeating: 0, count: Self.historyLength)
    }

    deinit {
        previousDb.deinitialize(count: maxBins)
        previousDb.deallocate()
        history.deinitialize(count: Self.historyLength)
        history.deallocate()
    }

    /// 回到初始的靜音狀態（time 歸零）。
    public func reset() {
        features = AudioFeatures()
        var index = 0
        while index < maxBins { previousDb[index] = Self.floorDb; index += 1 }
        index = 0
        while index < Self.historyLength { history[index] = 0; index += 1 }
        historyIndex = 0
        historyFilled = 0
        fluxScale = 0.5
        previousFlux = 0
        previousThreshold = 0
        cooldown = 0
    }

    /// 前進 dt 秒（夾在 0...0.05；0 只清除 onset 旗標）並回傳新的特徵。
    /// - Parameters:
    ///   - audible: 這一幀是否有聲音（未靜音且輸入沒有中斷）；false 時所有值釋放到 0、時鐘停止。
    ///   - binDb: 這一幀 FFT 每個 bin 的 dBFS；沒有新音訊時傳 nil。
    ///   - binHz: 每個 bin 的寬度（Hz）。
    ///   - mid: 單聲道（(L+R)/2）時域窗；nil 時響度為 0。
    ///   - side: 側聲道（(L−R)/2）時域窗，長度同 mid；nil 時沒有立體聲資訊。
    ///   - bands: 顯示用頻段高度 0...1。
    ///   - bandCenters: 各頻段中心頻率（Hz），長度不足的部分忽略。
    @discardableResult
    public func update(dt: Double, audible: Bool, binDb: UnsafeBufferPointer<Float>?, binHz: Double,
                       mid: UnsafeBufferPointer<Float>?, side: UnsafeBufferPointer<Float>?,
                       bands: [Float], bandCenters: [Double]) -> AudioFeatures {
        var f = features
        f.onset = false
        let step = dt.isFinite ? min(0.05, max(0, dt)) : 0
        guard step > 0 else {
            features = f
            return f
        }

        // 活動量與音訊時鐘
        f.activity = Self.follow(f.activity, audible ? 1 : 0, step, attack: 0.08, release: 0.22, snap: 1e-3)
        f.time += step * Double(f.activity)

        // 顯示頻段 → 低／中／高與平均能量（沿用管線的 AGC 與閘門）
        // 每段取「平均與最大值的中間」：寬頻音樂接近平均，單一音高也不會被大量安靜的頻段稀釋。
        var bassSum: Float = 0, midSum: Float = 0, trebleSum: Float = 0, total: Float = 0
        var bassMax: Float = 0, midMax: Float = 0, trebleMax: Float = 0
        var bassCount = 0, midCount = 0, trebleCount = 0
        let count = min(bands.count, bandCenters.count)
        var index = 0
        while index < count {
            let value = Self.unit(bands[index])
            let hz = bandCenters[index]
            total += value
            if hz < 150 {
                bassSum += value; bassCount += 1; bassMax = max(bassMax, value)
            } else if hz < 2000 {
                midSum += value; midCount += 1; midMax = max(midMax, value)
            } else if hz <= 16000 {
                trebleSum += value; trebleCount += 1; trebleMax = max(trebleMax, value)
            }
            index += 1
        }
        let gate: Float = audible ? 1 : 0
        func blend(_ sum: Float, _ n: Int, _ peak: Float) -> Float { n > 0 ? 0.5 * (sum / Float(n) + peak) : 0 }
        f.bass = Self.follow(f.bass, gate * blend(bassSum, bassCount, bassMax), step, attack: 0.03, release: 0.2)
        f.mid = Self.follow(f.mid, gate * blend(midSum, midCount, midMax), step, attack: 0.03, release: 0.16)
        f.treble = Self.follow(f.treble, gate * blend(trebleSum, trebleCount, trebleMax), step, attack: 0.02, release: 0.12)
        f.energy = Self.follow(f.energy, gate * (count > 0 ? total / Float(count) : 0), step, attack: 0.04, release: 0.25)

        // 響度與峰值（時域）
        var levelTarget: Float = 0, peakTarget: Float = 0
        var widthTarget: Float = 0, balanceTarget: Float = 0
        if audible, let mid, let base = mid.baseAddress, mid.count > 0 {
            let n = min(mid.count, 2048)
            let start = base + (mid.count - n)
            var rms: Float = 0, maxMag: Float = 0
            vDSP_rmsqv(start, 1, &rms, vDSP_Length(n))
            vDSP_maxmgv(start, 1, &maxMag, vDSP_Length(n))
            levelTarget = Self.dbUnit(rms)
            peakTarget = Self.dbUnit(maxMag)
            if let side, let sideBase = side.baseAddress, side.count >= mid.count {
                let sideStart = sideBase + (side.count - n)
                var pm: Float = 0, ps: Float = 0, cross: Float = 0
                vDSP_svesq(start, 1, &pm, vDSP_Length(n))
                vDSP_svesq(sideStart, 1, &ps, vDSP_Length(n))
                vDSP_dotpr(start, 1, sideStart, 1, &cross, vDSP_Length(n))
                let sum = pm + ps
                if sum > 1e-9, sum.isFinite {
                    widthTarget = min(1, 2 * ps / sum)
                    // L = M+S、R = M−S：(R²−L²)/(R²+L²) = −2·ΣMS / (ΣM²+ΣS²)
                    balanceTarget = max(-1, min(1, -2 * cross / sum))
                }
            }
        }
        f.level = Self.follow(f.level, levelTarget, step, attack: 0.03, release: 0.25)
        f.peak = Self.follow(f.peak, peakTarget, step, attack: 0, release: 0.15)
        f.stereoWidth = Self.follow(f.stereoWidth, widthTarget, step, attack: 0.3, release: 0.3)
        f.balance = Self.follow(f.balance, balanceTarget, step, attack: 0.3, release: 0.3)

        // 頻譜重心、變化量與起音（每個 bin）
        var fluxRate: Float = 0
        if audible, let binDb, binHz.isFinite, binHz > 0 {
            let n = min(binDb.count, maxBins, Int(16_000 / binHz) + 1)
            var power: Float = 0, weighted: Float = 0, rise: Float = 0
            var bin = 1
            while bin < n {
                let db = binDb[bin].isFinite ? max(Self.floorDb, binDb[bin]) : Self.floorDb
                let p = expf(db * 0.230_258_51) // 10^(dB/10)
                power += p
                weighted += p * Float(Double(bin) * binHz)
                let delta = db - previousDb[bin]
                if delta > 0 { rise += delta }
                previousDb[bin] = db
                bin += 1
            }
            if power > 1e-12 {
                let hz = max(30, weighted / power)
                let target = max(0, min(1, log2f(hz / 30) / log2f(16_000 / 30)))
                f.centroid += (target - f.centroid) * Float(1 - exp(-step / 0.12))
            }
            // 每 bin 平均上升的 dB，換算成 60 fps 的量，讓不同刷新率的結果一致。
            fluxRate = n > 1 ? rise / Float(n - 1) / Float(step * 60) : 0
        } else if !audible {
            var bin = 0
            while bin < maxBins { previousDb[bin] = Self.floorDb; bin += 1 }
        }

        cooldown = max(0, cooldown - step)
        var mean: Float = 0
        index = 0
        while index < historyFilled { mean += history[index]; index += 1 }
        mean = historyFilled > 0 ? mean / Float(historyFilled) : 0
        let threshold = mean * 1.5 + 0.35
        if audible && fluxRate > threshold && previousFlux <= previousThreshold && cooldown == 0 {
            f.onset = true
            f.onsetCount &+= 1
            let strength = max(0.2, min(1, (fluxRate - mean) / (2 * mean + 1.5)))
            f.onsetEnvelope = max(f.onsetEnvelope, strength)
            cooldown = 0.1
        }
        previousFlux = fluxRate
        previousThreshold = threshold
        if audible {
            history[historyIndex] = fluxRate
            historyIndex = (historyIndex + 1) % Self.historyLength
            historyFilled = min(Self.historyLength, historyFilled + 1)
        } else {
            historyFilled = 0
            historyIndex = 0
        }
        if !f.onset { f.onsetEnvelope = Self.follow(f.onsetEnvelope, 0, step, attack: 0, release: 0.25) }
        fluxScale = max(0.5, max(fluxRate, fluxScale * Float(exp(-step / 3))))
        f.flux = Self.follow(f.flux, audible ? min(1, fluxRate / fluxScale) : 0, step, attack: 0.02, release: 0.12)

        features = f
        return f
    }

    /// attack/release 指數平滑（時間常數，秒；0 表示立即）；目標為 0 且值小於 snap 時歸零。
    static func follow(_ value: Float, _ target: Float, _ dt: Double, attack: Double, release: Double, snap: Float = 1e-4) -> Float {
        let tau = target > value ? attack : release
        let next = tau <= 0 ? target : value + (target - value) * Float(1 - exp(-dt / tau))
        if target == 0 && abs(next) < snap { return 0 }
        return next.isFinite ? next : target
    }

    private static func unit(_ value: Float) -> Float { value.isFinite ? max(0, min(1, value)) : 0 }

    private static func dbUnit(_ amplitude: Float) -> Float {
        guard amplitude > 0, amplitude.isFinite else { return 0 }
        return max(0, min(1, (20 * log10f(amplitude) + 60) / 60))
    }
}
