import Foundation
import PulseFloatCore

/// 合成的示範音樂，經過真正的 `SampleRingBuffer` → `LiveSpectrumSource`（同一次 FFT、同一個特徵引擎）。
/// 120 BPM：大鼓、小鼓、hi-hat、貝斯、立體聲和弦；每 8 秒在主歌（較安靜、沒有 hi-hat）與副歌之間切換。
/// 給截圖工具、測試與主題預覽使用；同一個 seed 每次產生一模一樣的序列。只在主執行緒使用。
@MainActor
public final class DemoAudio {
    public enum Program: Sendable { case music, silence }

    public var program: Program = .music
    private let ring = SampleRingBuffer()
    private let source: LiveSpectrumSource
    private let sampleRate = 48_000.0
    private var clock = 0
    private var seed: UInt32
    private var previousNoise: Float = 0
    private var chunk: [Float] = []

    public init(bandCount: Int = 64, seed: UInt32 = 1) {
        var config = VisualizerConfig()
        config.bands.count = bandCount
        source = LiveSpectrumSource(config: config.clamped(), ring: ring, sampleRate: sampleRate)
        self.seed = seed == 0 ? 1 : seed
    }

    /// 已經播放的秒數（音樂與靜音都算）。
    public var seconds: Double { Double(clock) / sampleRate }

    /// 產生 dt 秒的音訊並回傳這一幀。
    public func next(dt: Double) -> SpectrumFrame {
        let step = dt.isFinite ? min(0.05, max(0, dt)) : 0
        let count = Int((step * sampleRate).rounded())
        if count > 0 {
            if chunk.count < count * 2 { chunk = [Float](repeating: 0, count: count * 2) }
            var i = 0
            while i < count {
                let (l, r) = program == .music ? sample(Double(clock + i) / sampleRate) : (0, 0)
                chunk[2 * i] = l
                chunk[2 * i + 1] = r
                i += 1
            }
            clock += count
            let ring = ring
            chunk.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress { ring.writeInterleaved(base, frameCount: count, channelCount: 2) }
            }
        }
        return source.nextFrame(dt: step)
    }

    /// 前進 seconds 秒（每幀 1/60 秒），回傳最後一幀。
    public func run(seconds: Double, program: Program, dt: Double = 1.0 / 60) -> SpectrumFrame {
        self.program = program
        var frame = SpectrumFrame.silent(bandCount: 64)
        var elapsed = 0.0
        while elapsed < seconds {
            frame = next(dt: dt)
            elapsed += dt
        }
        return frame
    }

    private func noise() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: seed)) / Float(Int32.max)
    }

    private func sample(_ t: Double) -> (Float, Float) {
        let beat = 0.5
        let bt = t.truncatingRemainder(dividingBy: beat)
        let beatIndex = Int(t / beat) % 4
        let chorus = Int(t / 8) % 2 == 1
        let tau = 2 * Double.pi

        // 大鼓：120 → 45 Hz 的下滑正弦
        let kickPhase = tau * (45 * bt + 75.0 / 30 * (1 - exp(-30 * bt)))
        let kick = Float(sin(kickPhase) * exp(-9 * bt)) * 0.85
        // 小鼓：第 2、4 拍
        let n = noise()
        var snare: Float = 0
        if beatIndex == 1 || beatIndex == 3 {
            snare = n * Float(exp(-18 * bt)) * 0.32 + Float(sin(tau * 190 * bt) * exp(-25 * bt)) * 0.18
        }
        // hi-hat：八分音符、高通噪音、左右交替（只在副歌）
        let ht = t.truncatingRemainder(dividingBy: 0.25)
        let hiss = (n - previousNoise) * 0.5
        previousNoise = n
        let hat = chorus ? hiss * Float(exp(-60 * ht)) * 0.22 : 0
        let hatPan: Float = Int(t / 0.25) % 2 == 0 ? 0.8 : 0.2
        // 貝斯：每拍一個音，三個泛音的鋸齒近似
        let notes: [Double] = [55, 55, 65.41, 49]
        let f = notes[beatIndex]
        let bassEnv = Float(0.55 + 0.45 * exp(-4 * bt))
        let bass = Float(sin(tau * f * t) + 0.45 * sin(tau * 2 * f * t) + 0.2 * sin(tau * 3 * f * t)) * bassEnv * 0.2
        // 和弦墊音：左右微微走音 → 立體聲寬度
        let chordGain = chorus ? 0.07 : 0.045
        let padL = (sin(tau * 220 * t) + sin(tau * 277.18 * t) + sin(tau * 329.63 * t)) * chordGain
        let padR = (sin(tau * 220.7 * t) + sin(tau * 277.9 * t) + sin(tau * 330.4 * t)) * chordGain
        // 副歌加一條明亮的旋律
        let lead = chorus ? Float(sin(tau * [880, 987.77, 1174.66, 987.77][beatIndex] * t) * exp(-3 * bt)) * 0.08 : 0

        let center = kick + snare + bass + lead
        let l = center + Float(padL) + hat * (1 - hatPan)
        let r = center + Float(padR) + hat * hatPan
        return (max(-1, min(1, l)), max(-1, min(1, r)))
    }
}
