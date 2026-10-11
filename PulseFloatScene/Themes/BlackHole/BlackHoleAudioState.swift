import Foundation
import PulseFloatCore

/// 黑洞主題的音訊狀態：把 `AudioFeatures` 與頻段轉成 shader 參數。純值型別，不配置記憶體，可單獨測試。
///
/// 規則：所有相位只以 `dt × features.activity` 前進（靜音時停止）；平滑值收斂到目標時直接吸附，
/// 起音脈衝以 dt 老化並在壽命結束時歸零，所以靜音後狀態會在有限時間內完全固定。
struct BlackHoleAudioState: Equatable {
    /// 盤面紊流的流動相位（每 6 單位一個 flow-map 週期，64 個週期後折回）。
    static let flowWrap: Double = 6 * 64
    /// 脈衝壽命（秒）與傳播距離（盤內緣 → 外緣）。
    static let pulseLife: Float = 1.1

    var flowPhase: Double = 0
    var spiralPhase: Double = 0
    var orbitPhase: Double = 0
    var midPhase: Double = 0
    /// 低頻 → 盤面厚度。
    var thickness: Float = 0
    /// 響度 → 整體亮度（靜音時回到 1 以外的基準，畫面保留）。
    var loudness: Float = 0
    /// 高頻 → 細塵亮度。
    var trebleGlow: Float = 0
    /// 高頻瞬變 → 火花包絡。
    var spark: Float = 0
    var trebleSlow: Float = 0
    /// 中頻 → 粒子流變形、細環變形。
    var mid: Float = 0
    /// 低頻瞬變 → 黑色核心微微脈動。
    var core: Float = 0
    var bassSlow: Float = 0
    var balance: Float = 0
    var width: Float = 0
    /// 中頻三段（低中、中、高中）→ 細環的 2、3、5 次諧波。
    var harmonics = SIMD3<Float>(repeating: 0)
    /// 軌道相位目前的前進速率（0...1）→ 粒子拖尾長度；靜音時收斂到 0。
    var orbitRate: Float = 0
    var sparkSeed: Float = 0
    /// 四個起音脈衝（由盤面內緣往外傳的亮環）：年齡（秒）與強度；強度 0 表示沒有在跑。用 SIMD 而不是陣列，每幀不配置記憶體。
    var pulseAge = SIMD4<Float>(repeating: 0)
    var pulseStrength = SIMD4<Float>(repeating: 0)
    private var nextPulse = 0

    /// 盤面亮度倍率（靜音時保留 1.0，畫面停在最後的樣子而不是變暗消失）。
    var gain: Float { 1.0 + 0.4 * loudness }
    /// 核心縮放（1 = 靜止）。
    var coreScale: Float { 1 + 0.045 * core }

    /// 脈衝 k 目前的半徑（盤座標）與強度。
    func pulse(_ k: Int, inner: Float, outer: Float) -> (radius: Float, amplitude: Float) {
        guard k >= 0, k < 4, pulseStrength[k] > 0 else { return (inner - 1, 0) }
        let age = pulseAge[k]
        let t = min(1, max(0, age / Self.pulseLife))
        let radius = inner + (outer - inner) * 1.05 * powf(t, 0.75)
        let fadeIn = min(1, age / 0.05)
        let amplitude = pulseStrength[k] * powf(1 - t, 1.15) * fadeIn
        return (radius, amplitude)
    }

    /// 是否有脈衝還在傳播。
    var hasActivePulse: Bool { pulseStrength.max() > 0 }

    /// 前進一幀。dt 已由 SceneRenderer 夾在 0...0.05。
    mutating func advance(features raw: AudioFeatures, values: [Float], dt: Double) {
        let f = Self.sanitized(raw)
        let step = dt.isFinite ? min(0.05, max(0, dt)) : 0
        let act = Double(f.activity)

        // 平滑值（attack / release，接近目標就吸附，保證靜音後完全固定）；activity 歸零後改用較快的釋放
        let rs = f.activity > 0 ? 1.0 : 0.3
        thickness = Self.follow(thickness, f.bass, step, attack: 0.05, release: 0.32 * rs)
        loudness = Self.follow(loudness, 0.55 * f.energy + 0.45 * f.level, step, attack: 0.06, release: 0.4 * rs)
        trebleGlow = Self.follow(trebleGlow, f.treble, step, attack: 0.02, release: 0.18 * rs)
        trebleSlow = Self.follow(trebleSlow, f.treble, step, attack: 0.35, release: 0.35 * rs)
        let sparkTarget = min(1, max(0, (f.treble - trebleSlow) * 5))
        spark = Self.follow(spark, sparkTarget, step, attack: 0.012, release: 0.14 * rs)
        mid = Self.follow(mid, f.mid, step, attack: 0.08, release: 0.35 * rs)
        bassSlow = Self.follow(bassSlow, f.bass, step, attack: 0.25, release: 0.3 * rs)
        let coreTarget = min(1, max(0, (f.bass - bassSlow) * 3.5))
        core = Self.follow(core, coreTarget, step, attack: 0.02, release: 0.2 * rs)
        balance = Self.follow(balance, f.balance, step, attack: 0.25, release: 0.3 * rs)
        width = Self.follow(width, f.stereoWidth, step, attack: 0.25, release: 0.3 * rs)
        // 頻段只在有聲音時使用（靜音時頻段可能殘留極小的值，不能讓它阻止狀態收斂）
        let bands = f.activity > 0 ? Self.midBands(values) : SIMD3<Float>(repeating: 0)
        harmonics.x = Self.follow(harmonics.x, bands.x, step, attack: 0.06, release: 0.3 * rs)
        harmonics.y = Self.follow(harmonics.y, bands.y, step, attack: 0.06, release: 0.3 * rs)
        harmonics.z = Self.follow(harmonics.z, bands.z, step, attack: 0.06, release: 0.3 * rs)
        let rateTarget = f.activity * min(1, 0.35 + 0.65 * f.energy + 0.3 * mid)
        orbitRate = Self.follow(orbitRate, rateTarget, step, attack: 0.1, release: 0.3 * rs)

        // 相位：只隨音訊前進（activity 為 0 時完全不動）
        if act > 0 {
            let d = step * act
            flowPhase = Self.wrap(flowPhase + d * Double(0.42 + 0.55 * f.energy + 0.45 * thickness), Self.flowWrap)
            spiralPhase = Self.wrap(spiralPhase + d * Double(0.25 + 2.4 * thickness), 2 * .pi)
            orbitPhase = Self.wrap(orbitPhase + d * Double(0.30 + 0.55 * f.energy + 0.25 * mid), BlackHoleMeshes.orbitWrap)
            midPhase = Self.wrap(midPhase + d * Double(0.35 + 1.8 * mid), 2 * .pi)
            sparkSeed = Float(Int((f.time * 9).truncatingRemainder(dividingBy: 997)))
        }

        // 起音脈衝：以 dt 老化，壽命結束就關閉（靜音前產生的脈衝也會在幾秒內走完）
        var k = 0
        while k < 4 {
            if pulseStrength[k] > 0 {
                pulseAge[k] += Float(step)
                if pulseAge[k] >= Self.pulseLife {
                    pulseAge[k] = 0
                    pulseStrength[k] = 0
                }
            }
            k += 1
        }
        if f.onset && f.activity > 0 {
            pulseAge[nextPulse] = 0
            pulseStrength[nextPulse] = min(1, 0.25 + 0.75 * f.onsetEnvelope) * (0.25 + 0.75 * f.bass)
            nextPulse = (nextPulse + 1) % 4
        }
    }

    /// 靜音且所有平滑值都已吸附到目標、沒有脈衝在跑。
    func isSettled(silent: Bool) -> Bool {
        silent && !hasActivePulse && thickness == 0 && loudness == 0 && trebleGlow == 0 && trebleSlow == 0
            && spark == 0 && mid == 0 && core == 0 && bassSlow == 0 && balance == 0 && width == 0
            && orbitRate == 0 && harmonics == SIMD3<Float>(repeating: 0)
    }

    /// attack/release 指數平滑；與目標差距小於 snap 時直接吸附（靜音後一定會停在精確值）。
    static func follow(_ value: Float, _ target: Float, _ dt: Double, attack: Double, release: Double, snap: Float = 2e-4) -> Float {
        guard target.isFinite else { return 0 }
        guard value.isFinite else { return target }
        let tau = target > value ? attack : release
        let next = tau <= 0 ? target : value + (target - value) * Float(1 - exp(-dt / tau))
        return abs(next - target) < snap ? target : next
    }

    static func wrap(_ value: Double, _ period: Double) -> Double {
        guard value.isFinite else { return 0 }
        let r = value.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }

    /// 顯示頻段的中頻三段（以頻段比例近似 150 Hz...2 kHz）。
    static func midBands(_ values: [Float]) -> SIMD3<Float> {
        let n = values.count
        guard n >= 6 else { return SIMD3(repeating: 0) }
        func average(_ from: Double, _ to: Double) -> Float {
            let lo = min(n - 1, Int(Double(n) * from)), hi = max(lo + 1, min(n, Int(Double(n) * to)))
            var sum: Float = 0
            var i = lo
            while i < hi {
                let v = values[i]
                sum += v.isFinite ? min(1, max(0, v)) : 0
                i += 1
            }
            return sum / Float(hi - lo)
        }
        return SIMD3(average(0.25, 0.39), average(0.39, 0.53), average(0.53, 0.67))
    }

    /// 把非有限或超出範圍的特徵夾回合理值（異常 frame 不會污染狀態）。
    static func sanitized(_ f: AudioFeatures) -> AudioFeatures {
        var s = f
        func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }
        s.level = unit(f.level)
        s.bass = unit(f.bass)
        s.mid = unit(f.mid)
        s.treble = unit(f.treble)
        s.energy = unit(f.energy)
        s.onsetEnvelope = unit(f.onsetEnvelope)
        s.stereoWidth = unit(f.stereoWidth)
        s.activity = unit(f.activity)
        s.balance = f.balance.isFinite ? min(1, max(-1, f.balance)) : 0
        s.time = f.time.isFinite ? max(0, f.time) : 0
        return s
    }
}
