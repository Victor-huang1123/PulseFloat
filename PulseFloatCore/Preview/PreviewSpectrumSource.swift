// 開發用預覽訊號源；T04 將由真正音訊與 DSP 的 VisualizerEngine 取代。
import Foundation

/// 主執行緒使用的決定性音樂預覽；以 128 BPM 低頻脈衝與三個移動高斯峰產生 0...1 頻譜。
@MainActor
public final class PreviewSpectrumSource: SpectrumSource {
    private let bandCount: Int
    private var elapsed: TimeInterval = 0
    private var values: [Float]
    private var peaks: [Float]
    private var peakHold: [Double]
    private var peakVelocity: [Double]
    private var bass: Float = 0

    /// 建立指定頻帶數的預覽；負數視為 0，預設 64，僅於主執行緒呼叫。
    public init(bandCount: Int = 64) {
        self.bandCount = max(0, bandCount)
        values = [Float](repeating: 0, count: self.bandCount)
        peaks = [Float](repeating: 0, count: self.bandCount)
        peakHold = [Double](repeating: 0, count: self.bandCount)
        peakVelocity = [Double](repeating: 0, count: self.bandCount)
    }

    /// 主執行緒前進 dt 秒；非有限值或負值視為 0，最大 0.05 秒，與 FrameClock 的時步限制一致。
    /// 相同 dt 序列產生完全相同的 values、peaks 與 bass；峰值不低於目前高度。
    public func nextFrame(dt: TimeInterval) -> SpectrumFrame {
        let step = dt.isFinite ? min(0.05, max(0, dt)) : 0
        guard step > 0, bandCount > 0 else {
            return SpectrumFrame(values: values, peaks: peaks, bass: bass)
        }
        elapsed += step
        let beatPhase = (elapsed / (60.0 / 128.0)).truncatingRemainder(dividingBy: 1)
        let pulse = exp(-beatPhase * 7)
        let lowCenter = 0.24 + 0.055 * sin(elapsed * 0.61)
        let middleCenter = 0.51 + 0.10 * sin(elapsed * 0.43 + 1.2)
        let highCenter = 0.79 + 0.075 * sin(elapsed * 0.31 + 2.4)

        var index = 0
        while index < bandCount {
            let position = bandCount > 1 ? Double(index) / Double(bandCount - 1) : 0
            let floor = 0.075 + 0.16 * exp(-position * 2.4)
            let kick = 0.68 * pulse * gaussian(position - 0.07, width: 0.12)
            let low = 0.32 * gaussian(position - lowCenter, width: 0.065)
            let middle = (0.25 + 0.055 * sin(elapsed * 1.9))
                * gaussian(position - middleCenter, width: 0.085)
            let high = 0.22 * gaussian(position - highCenter, width: 0.05)
            let target = min(1, max(0, floor + kick + low + middle + high))
            let previous = Double(values[index])
            let tau = target > previous ? 0.012 : 0.14
            values[index] = Float(previous + (target - previous) * (1 - exp(-step / tau)))

            if values[index] >= peaks[index] {
                peaks[index] = values[index]
                peakHold[index] = 0.16
                peakVelocity[index] = 0
            } else if peakHold[index] > 0 {
                peakHold[index] = max(0, peakHold[index] - step)
            } else {
                peakVelocity[index] += 3.2 * step
                peaks[index] = max(values[index], peaks[index] - Float(peakVelocity[index] * step))
            }
            index += 1
        }
        let bassTarget = 0.08 + pulse * 0.92
        let bassTau = bassTarget > Double(bass) ? 0.03 : 0.18
        bass += Float((bassTarget - Double(bass)) * (1 - exp(-step / bassTau)))
        return SpectrumFrame(values: values, peaks: peaks, bass: bass)
    }

    private func gaussian(_ distance: Double, width: Double) -> Double {
        exp(-(distance * distance) / (2 * width * width))
    }
}
