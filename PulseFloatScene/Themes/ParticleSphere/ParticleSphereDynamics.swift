import PulseFloatCore
import simd

/// 粒子球的音訊狀態：球諧係數、膨脹、高頻振動相位、起音脈衝與自轉。
/// 只由 `SpectrumFrame`（values 與 features）和 dt 推動；靜音後所有值收斂到精確的靜止值。
/// 初始化後不配置記憶體（陣列長度固定、就地修改）。
struct ParticleSphereDynamics {
    /// l = 1...4 的實球諧係數個數（3 + 5 + 7 + 9）。
    static let coefficientCount = 24
    /// 同時存在的起音脈衝上限。
    static let pulseCapacity = 4
    /// 脈衝壽命（秒）與波前速度（沿「核心 → 表面 → 周圍」路徑，單位／秒）。
    static let pulseLife: Float = 1.5
    static let pulseSpeed: Float = 2.1

    /// 一個起音脈衝：從球心往外、同時從 origin 方向沿球面擴散的波前。
    struct Pulse {
        var origin = SIMD3<Float>(0, 0, 1)
        var age: Float = 0
        var strength: Float = 0
        var alive = false

        /// 波前位置（與著色器的路徑長度同單位）。
        var front: Float { age * ParticleSphereDynamics.pulseSpeed }
        /// 目前振幅：隨年齡平方衰減，壽命結束時為 0。
        var amplitude: Float {
            guard alive else { return 0 }
            let k = max(0, 1 - age / ParticleSphereDynamics.pulseLife)
            return strength * k * k
        }
    }

    /// 平滑後、已乘上各階增益與正負號的係數（直接送進著色器）。
    private(set) var coefficients = [Float](repeating: 0, count: coefficientCount)
    /// 各係數這一幀的目標值（暫存，避免每幀配置）。
    private var targets = [Float](repeating: 0, count: coefficientCount)
    /// 各係數頻率窗的慢速平均（約 1 秒）：「比平常多出來的能量」才推動局部變形，持續的寬頻音量不會把形狀撐成固定的方塊。
    private var slowBands = [Float](repeating: 0, count: coefficientCount)
    /// 低頻造成的整體膨脹（半徑比例）。
    private(set) var expansion: Float = 0
    /// 高頻表面細振動的振幅（半徑比例）。
    private(set) var trebleAmplitude: Float = 0
    /// 高頻振動相位（只隨音訊前進）。
    private(set) var treblePhase: Float = 0
    /// 粒子晶格自轉角（弧度）。
    private(set) var spin: Float = 0
    /// 變形場（球諧座標系）的緩慢旋轉角（弧度）。
    private(set) var fieldSpin: Float = 0
    /// 核心亮度 0...1（低頻、響度與起音）。
    private(set) var coreGlow: Float = 0
    /// 起音脈衝（固定容量的環狀陣列）。
    private(set) var pulses = [Pulse](repeating: Pulse(), count: pulseCapacity)
    private var nextPulse = 0
    /// 累計產生的脈衝數（決定沒有明顯能量方向時的起點）。
    private(set) var pulseSerial = 0

    /// 各係數對應的頻率位置（0 低頻 ... 1 高頻）中心與半寬；低頻 → 低階大區塊，高頻 → 高階細紋。
    static let bandCenters: [Float] = {
        var centers: [Float] = []
        var i = 0
        while i < 3 { centers.append(0.05 + 0.07 * Float(i)); i += 1 }        // l = 1：低音
        i = 0
        while i < 5 { centers.append(0.25 + 0.05 * Float(i)); i += 1 }        // l = 2：中低頻
        i = 0
        while i < 7 { centers.append(0.48 + 0.04 * Float(i)); i += 1 }        // l = 3：中頻
        i = 0
        while i < 9 { centers.append(0.74 + 0.03 * Float(i)); i += 1 }        // l = 4：中高頻
        return centers
    }()
    static let bandHalfWidths: [Float] = {
        var widths: [Float] = []
        var i = 0
        while i < 24 { widths.append(i < 3 ? 0.075 : (i < 8 ? 0.06 : (i < 15 ? 0.05 : 0.04))); i += 1 }
        return widths
    }()
    /// 係數絕對值總和的軟限制起點（半徑比例）。
    static let deformationKnee: Float = 0.22
    /// 每階的變形增益（半徑比例）；低階形狀大、高階細紋小。
    static func gain(for index: Int) -> Float {
        if index < 3 { return 0.04 }
        if index < 8 { return 0.1 }
        if index < 15 { return 0.075 }
        return 0.038
    }
    /// 固定的正負號樣式（決定性；讓同一段頻率永遠推動同一塊區域，凸起與凹陷交錯）。
    static func sign(for index: Int) -> Float { signs[index] }
    private static let signs: [Float] = [1, -1, 1, 1, -1, 1, -1, 1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1, -1, 1, 1, -1, 1, -1]

    /// 已完全靜止：靜音，且所有平滑狀態都回到精確的目標值、沒有存活的脈衝。
    private(set) var isSettled = true

    /// 有任何存活的脈衝。
    var hasLivePulse: Bool {
        var i = 0
        while i < Self.pulseCapacity {
            if pulses[i].alive { return true }
            i += 1
        }
        return false
    }

    /// 前進一幀。dt 已由呼叫端夾在 0...0.05。
    mutating func update(frame: SpectrumFrame, dt: Double) {
        let f = frame.features
        let step = Float(dt.isFinite ? min(0.05, max(0, dt)) : 0)
        let activity = Self.unit(f.activity)
        let gate: Float = f.isSilent ? 0 : 1

        // 頻段 → 24 個係數目標（各係數取頻率窗內的加權平均，扣掉一部分整體平均，保留頻譜形狀）
        let values = frame.values
        let n = values.count
        var mean: Float = 0
        var i = 0
        while i < n { mean += Self.unit(values[i]); i += 1 }
        mean = n > 0 ? mean / Float(n) : 0
        var j = 0
        while j < Self.coefficientCount {
            let center = Self.bandCenters[j], half = Self.bandHalfWidths[j]
            var sum: Float = 0, weight: Float = 0
            i = 0
            while i < n {
                let p = (Float(i) + 0.5) / Float(n)
                let w = max(0, 1 - abs(p - center) / half)
                if w > 0 {
                    sum += w * Self.unit(values[i])
                    weight += w
                }
                i += 1
            }
            let local = weight > 0 ? sum / weight : 0
            if gate > 0 {
                slowBands[j] = Self.follow(slowBands[j], local, step, attack: 0.9, release: 1.2)
            } else {
                slowBands[j] = 0   // 只影響有聲音時的目標；靜音時直接歸零，不拖慢靜止
            }
            let contrast = max(0, local - 0.6 * mean)       // 頻譜形狀：這一段比整體突出多少
            let novelty = max(0, local - slowBands[j])      // 新出現的能量（音符、旋律變化）
            let shaped = 0.9 * contrast + 1.1 * novelty + 0.12 * local
            targets[j] = gate * activity * Self.sign(for: j) * Self.gain(for: j) * shaped
            j += 1
        }

        // 軟限制：所有係數的絕對值總和（≈ 最大變形）超過 knee 之後只保留 30%，再大聲也不會變成刺球
        var total: Float = 0
        j = 0
        while j < Self.coefficientCount { total += abs(targets[j]); j += 1 }
        if total > Self.deformationKnee {
            let scale = (Self.deformationKnee + (total - Self.deformationKnee) * 0.3) / total
            j = 0
            while j < Self.coefficientCount { targets[j] *= scale; j += 1 }
        }

        var settled = f.isSilent
        j = 0
        while j < Self.coefficientCount {
            let next = Self.follow(coefficients[j], targets[j], step, attack: 0.06, release: 0.32)
            coefficients[j] = next
            if next != targets[j] { settled = false }
            j += 1
        }

        // 低頻 → 整體膨脹；高頻 → 表面細振動
        let expansionTarget = gate * (0.13 * Self.unit(f.bass) + 0.035 * Self.unit(f.level))
        expansion = Self.follow(expansion, expansionTarget, step, attack: 0.035, release: 0.22)
        if expansion != expansionTarget { settled = false }
        let trebleTarget = gate * 0.022 * Self.unit(f.treble)
        trebleAmplitude = Self.follow(trebleAmplitude, trebleTarget, step, attack: 0.02, release: 0.15)
        if trebleAmplitude != trebleTarget { settled = false }
        let glowTarget = gate * min(1, 0.45 * Self.unit(f.onsetEnvelope) + 0.35 * Self.unit(f.bass) + 0.3 * Self.unit(f.level))
        coreGlow = Self.follow(coreGlow, glowTarget, step, attack: 0.02, release: 0.25)
        if coreGlow != glowTarget { settled = false }

        // 相位與自轉只隨「dt × activity」前進：靜音時停止
        let moving = step * activity
        treblePhase = Self.wrap(treblePhase + moving * (2.4 + 5.5 * Self.unit(f.treble)), period: 20 * .pi)
        spin = Self.wrap(spin + moving * (0.05 + 0.11 * Self.unit(f.energy)), period: 2 * .pi)
        fieldSpin = Self.wrap(fieldSpin + moving * (0.025 + 0.07 * Self.unit(f.mid)), period: 2 * .pi)

        // 起音 → 新的脈衝（從目前能量最大的區域出發）
        i = 0
        while i < Self.pulseCapacity {
            if pulses[i].alive {
                pulses[i].age += step
                if pulses[i].age >= Self.pulseLife { pulses[i] = Pulse() }
            }
            i += 1
        }
        if f.onset && gate > 0 {
            var pulse = Pulse()
            pulse.origin = strongestDirection()
            pulse.strength = max(0.35, min(1, Self.unit(f.onsetEnvelope)))
            pulse.alive = true
            pulses[nextPulse] = pulse
            nextPulse = (nextPulse + 1) % Self.pulseCapacity
            pulseSerial &+= 1
        }
        if hasLivePulse { settled = false }
        isSettled = settled
    }

    /// 變形場座標系中，目前凸出最多（並偏向鏡頭 +z）的方向；全為 0 時依序號走黃金角。
    func strongestDirection() -> SIMD3<Float> {
        var best = SIMD3<Float>(0, 0, 1)
        var bestScore: Float = -.infinity
        var any = false
        var k = 0
        while k < Self.probeDirections.count {
            let d = Self.probeDirections[k]
            let value = Self.evaluate(coefficients, d)
            if value != 0 { any = true }
            // 偏向鏡頭那一側，讓波前在畫面上看得到
            let score = value + 0.02 * worldFacing(d)
            if score > bestScore {
                bestScore = score
                best = d
            }
            k += 1
        }
        if any { return best }
        let angle = Float(pulseSerial) * 2.399_963
        return simd_normalize(SIMD3<Float>(cos(angle) * 0.6, 0.35 * sin(angle * 0.7), 0.75 + 0.2 * sin(angle)))
    }

    /// 場座標方向 d 轉回世界後朝向鏡頭（+z）的程度。
    private func worldFacing(_ d: SIMD3<Float>) -> Float {
        let world = Self.fieldRotation(fieldSpin).transpose * d
        return world.z
    }

    /// 世界 → 變形場座標的旋轉（繞傾斜 25° 的軸）。著色器用同一個矩陣。
    static func fieldRotation(_ angle: Float) -> simd_float3x3 {
        let axis = simd_normalize(SIMD3<Float>(0.42, 1, 0.0))
        return simd_float3x3(simd_quatf(angle: angle, axis: axis))
    }

    /// 世界 → 晶格座標的旋轉（繞 y 軸自轉，加一點固定傾角讓兩極不正對鏡頭）。
    static func latticeRotation(_ angle: Float) -> simd_float3x3 {
        let tilt = simd_quatf(angle: 0.38, axis: SIMD3<Float>(1, 0, 0.3))
        let turn = simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        return simd_float3x3(tilt * turn)
    }

    /// 32 個探測方向（費氏球面）。
    static let probeDirections: [SIMD3<Float>] = {
        var dirs: [SIMD3<Float>] = []
        let count = 32
        var i = 0
        while i < count {
            let y = 1 - 2 * (Float(i) + 0.5) / Float(count)
            let r = (1 - y * y).squareRoot()
            let a = 2.399_963 * Float(i)
            dirs.append(SIMD3(cos(a) * r, y, sin(a) * r))
            i += 1
        }
        return dirs
    }()

    /// 在方向 d（單位向量）上計算 l = 1...4 的球諧場（與著色器同一組多項式與尺度）。
    static func evaluate(_ c: [Float], _ d: SIMD3<Float>) -> Float {
        guard c.count >= coefficientCount else { return 0 }
        let x = d.x, y = d.y, z = d.z
        let x2 = x * x, y2 = y * y, z2 = z * z
        var s = c[0] * x + c[1] * y + c[2] * z
        s += c[3] * (2 * x * y) + c[4] * (2 * y * z) + c[5] * (1.5 * z2 - 0.5) + c[6] * (2 * x * z) + c[7] * (x2 - y2)
        s += c[8] * (y * (3 * x2 - y2)) + c[9] * (5.2 * x * y * z) + c[10] * (0.726 * y * (5 * z2 - 1))
        s += c[11] * (0.5 * z * (5 * z2 - 3)) + c[12] * (0.726 * x * (5 * z2 - 1)) + c[13] * (2.6 * z * (x2 - y2))
        s += c[14] * (x * (x2 - 3 * y2))
        s += c[15] * (4 * x * y * (x2 - y2)) + c[16] * (3.08 * y * z * (3 * x2 - y2)) + c[17] * (1.555 * x * y * (7 * z2 - 1))
        s += c[18] * (0.947 * y * z * (7 * z2 - 3)) + c[19] * (0.125 * (35 * z2 * z2 - 30 * z2 + 3))
        s += c[20] * (0.947 * x * z * (7 * z2 - 3)) + c[21] * (0.778 * (x2 - y2) * (7 * z2 - 1))
        s += c[22] * (3.08 * x * z * (x2 - 3 * y2)) + c[23] * (x2 * (x2 - 3 * y2) - y2 * (3 * x2 - y2))
        return s
    }

    /// 收斂門檻：半徑的 4e-4（約 0.05 px）以下直接等於目標，讓靜音後能精確、快速地靜止。
    static let settleEpsilon: Float = 4e-4

    /// attack/release 指數平滑（秒）；與目標差距小於 settleEpsilon 時直接等於目標。
    static func follow(_ value: Float, _ target: Float, _ dt: Float, attack: Float, release: Float) -> Float {
        guard dt > 0 else { return value }
        let tau = abs(target) > abs(value) ? attack : release
        var next = tau <= 0 ? target : value + (target - value) * (1 - expf(-dt / tau))
        if !next.isFinite { next = target }
        if abs(next - target) < settleEpsilon { next = target }
        return next
    }

    static func unit(_ v: Float) -> Float { v.isFinite ? min(1, max(0, v)) : 0 }

    static func wrap(_ v: Float, period: Float) -> Float {
        guard v.isFinite else { return 0 }
        let r = v.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }
}
