import Accelerate
import Foundation

/// 真正的頻譜來源：從 `SampleRingBuffer` 取最新 4096 個樣本 → `SpectrumAnalyzer` → `SpectrumPipeline`。
/// 沒有聲音時就是沒有聲音：柱子自然落回最低點，不顯示任何模擬動畫。
/// 0.25 秒沒有任何新樣本（tap 停止、裝置切換中）時改餵 −160 dB，避免畫面停在舊的有聲緩衝上。
/// 權限被拒時 tap 只會送全 0 的 buffer，表現也是靜音；`mode` 只用來在選單上提示使用者。
/// 只在主執行緒使用；`nextFrame` 每次只配置回傳 frame 的兩個陣列。
@MainActor
public final class LiveSpectrumSource: SpectrumSource {
    /// 目前輸入狀態（給選單顯示用，不影響畫面）。
    public enum Mode: Sendable, Equatable {
        /// 正在收到有聲音的系統音訊。
        case live
        /// 連續 2 秒沒有聲音（沒有播放、或沒有錄音權限）。
        case silent
    }

    /// 低於此值（dBFS，以窗內峰值計）視為靜音。
    public static let silenceThresholdDb: Float = -90
    /// 連續靜音多久（秒）後 `mode` 變成 `.silent`。
    public static let silenceHoldSeconds: Double = 2
    /// 多久（秒）沒有新樣本就視為音訊中斷。
    public static let staleInputSeconds: Double = 0.25

    /// 目前輸入狀態；啟動時是 `.silent`，收到有聲音的樣本後變成 `.live`。
    public private(set) var mode: Mode = .silent
    /// 分析用的取樣率（Hz）。
    public private(set) var sampleRate: Double

    private let ring: SampleRingBuffer
    private let pipeline: SpectrumPipeline
    private let analyzer: SpectrumAnalyzer
    private var scratch: [Float]
    private var sideScratch: [Float]
    private let features = AudioFeatureExtractor()
    private let fftSize = 4096
    private var silentSeconds: Double
    private var staleSeconds: Double = 0
    private var lastTotalWritten = 0

    /// 建立來源；config 會先 `clamped()`，sampleRate 預設 48 kHz（tap 啟動後以 `setSampleRate` 更新）。
    public init(config: VisualizerConfig = .default, ring: SampleRingBuffer, sampleRate: Double = 48_000) {
        self.ring = ring
        self.sampleRate = sampleRate
        pipeline = SpectrumPipeline(config: config)
        analyzer = SpectrumAnalyzer(fftSize: fftSize, sampleRate: sampleRate, layout: pipeline.bandLayout)
        scratch = [Float](repeating: 0, count: fftSize)
        sideScratch = [Float](repeating: 0, count: fftSize)
        silentSeconds = Self.silenceHoldSeconds
    }

    /// 音訊格式改變時更新取樣率（Hz）；非正或非有限值忽略。可能配置記憶體。
    public func setSampleRate(_ rate: Double) {
        guard rate.isFinite, rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        analyzer.update(sampleRate: rate, layout: pipeline.bandLayout)
    }

    /// 套用新設定；頻帶改變時同步重建分析對應表。可能配置記憶體。
    public func setConfig(_ config: VisualizerConfig) {
        let previousCount = pipeline.bandLayout.count
        let previousLow = pipeline.bandLayout.lo.first
        let previousHigh = pipeline.bandLayout.hi.last
        pipeline.setConfig(config)
        let layout = pipeline.bandLayout
        if layout.count != previousCount || layout.lo.first != previousLow || layout.hi.last != previousHigh {
            analyzer.update(sampleRate: sampleRate, layout: layout)
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
        let stale = staleSeconds >= Self.staleInputSeconds

        var peak: Float = 0
        let sampleCount = fftSize
        let ring = ring
        scratch.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            sideScratch.withUnsafeMutableBufferPointer { sideBuffer in
                _ = ring.copyLatest(into: base, side: sideBuffer.baseAddress, count: sampleCount)
            }
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(sampleCount))
        }
        let levelDb = peak > 0 ? 20 * log10f(peak) : -160
        let audible = !stale && levelDb >= Self.silenceThresholdDb
        silentSeconds = audible ? 0 : min(Self.silenceHoldSeconds, silentSeconds + step)
        mode = silentSeconds >= Self.silenceHoldSeconds ? .silent : .live

        if stale {
            pipeline.withRawDb { raw in
                var index = 0
                while index < raw.count {
                    raw[index] = -160
                    index += 1
                }
            }
        } else {
            let analyzer = analyzer
            scratch.withUnsafeBufferPointer { samples in
                pipeline.withRawDb { raw in analyzer.analyze(samples: samples, into: raw) }
            }
        }
        var frame = pipeline.process(dt: step)
        let analyzer = analyzer
        let features = features
        let centers = pipeline.bandLayout.center
        frame.features = scratch.withUnsafeBufferPointer { mid in
            sideScratch.withUnsafeBufferPointer { side in
                analyzer.withBinLevels { bins in
                    features.update(dt: step, audible: audible, binDb: stale ? nil : bins, binHz: analyzer.binHz,
                                    mid: mid, side: side, bands: frame.values, bandCenters: centers)
                }
            }
        }
        return frame
    }
}
