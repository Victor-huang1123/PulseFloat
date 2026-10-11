import Accelerate
import Foundation

/// 真正的頻譜來源：從 `SampleRingBuffer` 取最新 4096 個樣本 → `SpectrumAnalyzer` → `SpectrumPipeline`。
/// 輸入連續 2 秒低於 −90 dBFS（或 0.25 秒沒有任何新樣本）時改用 `SimulatedSpectrum`，
/// 有聲音後立即切回。權限被拒時 tap 只會送全 0 的 buffer，所以「沒權限」與「靜音」走同一條規則。
/// 只在主執行緒使用；`nextFrame` 每次只配置回傳 frame 的兩個陣列。
@MainActor
public final class LiveSpectrumSource: SpectrumSource {
    /// 目前畫面資料的來源。
    public enum Mode: Sendable, Equatable {
        /// 系統音訊。
        case live
        /// 模擬訊號（靜音、沒有權限或尚未收到音訊）。
        case simulated
    }

    /// 低於此值（dBFS，以窗內峰值計）視為靜音。
    public static let silenceThresholdDb: Float = -90
    /// 連續靜音多久（秒）後切到模擬訊號。
    public static let silenceHoldSeconds: Double = 2
    /// 多久（秒）沒有新樣本就視為音訊中斷。
    public static let staleInputSeconds: Double = 0.25

    /// 目前模式；啟動時是模擬訊號，收到有聲音的樣本後切到 live。
    public private(set) var mode: Mode = .simulated
    /// 分析用的取樣率（Hz）。
    public private(set) var sampleRate: Double

    private let ring: SampleRingBuffer
    private let pipeline: SpectrumPipeline
    private let analyzer: SpectrumAnalyzer
    private var simulated: SimulatedSpectrum
    private var scratch: [Float]
    private let fftSize = 4096
    private var silentSeconds: Double
    private var staleSeconds: Double = 0
    private var lastTotalWritten = 0
    private var simulatedTime: Double = 0

    /// 建立來源；config 會先 `clamped()`，sampleRate 預設 48 kHz（tap 啟動後以 `setSampleRate` 更新）。
    public init(config: VisualizerConfig = .default, ring: SampleRingBuffer, sampleRate: Double = 48_000) {
        self.ring = ring
        self.sampleRate = sampleRate
        pipeline = SpectrumPipeline(config: config)
        analyzer = SpectrumAnalyzer(fftSize: fftSize, sampleRate: sampleRate, layout: pipeline.bandLayout)
        simulated = SimulatedSpectrum(layout: pipeline.bandLayout)
        scratch = [Float](repeating: 0, count: fftSize)
        silentSeconds = Self.silenceHoldSeconds
    }

    /// 音訊格式改變時更新取樣率（Hz）；非正或非有限值忽略。可能配置記憶體。
    public func setSampleRate(_ rate: Double) {
        guard rate.isFinite, rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        analyzer.update(sampleRate: rate, layout: pipeline.bandLayout)
    }

    /// 套用新設定；頻帶改變時同步重建分析對應表與模擬訊號。可能配置記憶體。
    public func setConfig(_ config: VisualizerConfig) {
        let previousCount = pipeline.bandLayout.count
        let previousLow = pipeline.bandLayout.lo.first
        let previousHigh = pipeline.bandLayout.hi.last
        pipeline.setConfig(config)
        let layout = pipeline.bandLayout
        if layout.count != previousCount || layout.lo.first != previousLow || layout.hi.last != previousHigh {
            analyzer.update(sampleRate: sampleRate, layout: layout)
            simulated = SimulatedSpectrum(layout: layout)
        }
    }

    /// 前進 dt 秒並回傳這一幀；dt 夾在 0…0.05 秒。
    public func nextFrame(dt: TimeInterval) -> SpectrumFrame {
        let step = dt.isFinite ? min(0.05, max(0, dt)) : 0

        let total = ring.totalWritten
        if total != lastTotalWritten {
            lastTotalWritten = total
            staleSeconds = 0
        } else {
            staleSeconds += step
        }

        var peak: Float = 0
        let sampleCount = fftSize
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            ring.copyLatest(into: base, count: sampleCount)
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(sampleCount))
        }
        let levelDb = peak > 0 ? 20 * log10f(peak) : -160
        let audible = levelDb >= Self.silenceThresholdDb && staleSeconds < Self.staleInputSeconds
        silentSeconds = audible ? 0 : min(Self.silenceHoldSeconds, silentSeconds + step)
        mode = silentSeconds >= Self.silenceHoldSeconds ? .simulated : .live

        switch mode {
        case .live:
            let analyzer = analyzer
            scratch.withUnsafeBufferPointer { samples in
                pipeline.withRawDb { raw in analyzer.analyze(samples: samples, into: raw) }
            }
        case .simulated:
            simulatedTime += step
            let simulated = simulated
            let time = simulatedTime
            pipeline.withRawDb { raw in simulated.fill(raw, time: time) }
        }
        return pipeline.process(dt: step)
    }
}
