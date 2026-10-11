import SceneKit

/// 可重現的亂數（LCG）：粒子與軌道的配置每次都一樣，不會每幀亂跳。
struct BlackHoleRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    /// 0..<1 的均勻亂數。
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }

    mutating func range(_ lower: Float, _ upper: Float) -> Float { lower + (upper - lower) * next() }

    /// 近似常態分佈（三個均勻亂數平均），約 −1...1。
    mutating func gauss() -> Float { (next() + next() + next()) * 2 / 3 - 1 }
}

/// 一條同心細環：半徑、傾角與節點角（弧度）。
struct BlackHoleRing: Equatable {
    var radius: Float
    var inclination: Float
    var node: Float
}

/// 一條軌道粒子流的軌道根數（同一條流共用平均角速度，所以永遠維持成一束）。
struct BlackHoleStream: Equatable {
    var semiMajor: Float
    var eccentricity: Float
    var inclination: Float
    var node: Float
    var periapsis: Float
    var head: Float
    var arc: Float
    var meanMotion: Float
}

/// 黑洞主題的網格建立（只在 apply 時執行，每幀不重建）。
enum BlackHoleMeshes {
    /// 平均角速度量化成 1/8 的整數倍：軌道相位可以在 16π 處折回而不跳動。
    static let motionQuantum: Float = 1.0 / 8
    static let orbitWrap: Double = 16 * Double.pi

    private static func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data, semantic: semantic, vectorCount: values.count / components,
                                 usesFloatComponents: true, componentsPerVector: components,
                                 bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                 dataStride: MemoryLayout<Float>.size * components)
    }

    /// 吸積盤：極座標網格，內圈較密（透鏡把遠側內緣拉成拱形時才夠平滑）。texcoord = (角度 0...1, 徑向 0...1)。
    static func disk(radial: Int, angular: Int, inner: Float, outer: Float) -> SCNGeometry {
        let rows = max(2, radial), cols = max(8, angular)
        var positions: [Float] = []
        var uvs: [Float] = []
        positions.reserveCapacity((rows + 1) * (cols + 1) * 3)
        uvs.reserveCapacity((rows + 1) * (cols + 1) * 2)
        var j = 0
        while j <= rows {
            let s = powf(Float(j) / Float(rows), 1.4)
            let r = inner + (outer - inner) * s
            var i = 0
            while i <= cols {
                let u = Float(i) / Float(cols)
                let a = u * 2 * .pi
                positions.append(r * cosf(a)); positions.append(0); positions.append(r * sinf(a))
                uvs.append(u); uvs.append(s)
                i += 1
            }
            j += 1
        }
        // 先畫遠側半圈（z < 0，精簡模式鏡頭在 +z），再畫近側：半透明的近側盤面會正確地疊在遠側上
        var indices: [UInt32] = []
        indices.reserveCapacity(rows * cols * 6)
        var half = 0
        while half < 2 {
            j = 0
            while j < rows {
                var i = half == 0 ? cols / 2 : 0
                let end = half == 0 ? cols : cols / 2
                while i < end {
                    let a = UInt32(j * (cols + 1) + i), b = a + 1
                    let c = UInt32((j + 1) * (cols + 1) + i), d = c + 1
                    indices.append(contentsOf: [a, c, b, b, c, d])
                    i += 1
                }
                j += 1
            }
            half += 1
        }
        let geometry = SCNGeometry(sources: [source(positions, .vertex, components: 3), source(uvs, .texcoord, components: 2)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        // 厚度與透鏡會把頂點推離平面：包圍盒放大，避免被視錐裁掉
        geometry.boundingBox = (SCNVector3(-CGFloat(outer), -0.6, -CGFloat(outer)), SCNVector3(CGFloat(outer), 0.6, CGFloat(outer)))
        return geometry
    }

    /// 帶狀細環：每條環 segments 段、兩側頂點。position 存 (半徑, 傾角, 節點)，texcoord = (u, 側 −1/+1)。
    static func ribbons(_ rings: [BlackHoleRing], segments: Int, extent: Float) -> SCNGeometry {
        let segs = max(16, segments)
        var positions: [Float] = []
        var uvs: [Float] = []
        var indices: [UInt32] = []
        var ringIndex = 0
        while ringIndex < rings.count {
            let ring = rings[ringIndex]
            let base = UInt32(positions.count / 3)
            var i = 0
            while i <= segs {
                let u = Float(i) / Float(segs)
                var side: Float = -1
                while side <= 1 {
                    positions.append(ring.radius); positions.append(ring.inclination); positions.append(ring.node)
                    uvs.append(u); uvs.append(side)
                    side += 2
                }
                i += 1
            }
            i = 0
            while i < segs {
                let a = base + UInt32(i * 2)
                indices.append(contentsOf: [a, a + 1, a + 2, a + 2, a + 1, a + 3])
                i += 1
            }
            ringIndex += 1
        }
        let geometry = SCNGeometry(sources: [source(positions, .vertex, components: 3), source(uvs, .texcoord, components: 2)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let e = CGFloat(extent)
        geometry.boundingBox = (SCNVector3(-e, -e, -e), SCNVector3(e, e, e))
        return geometry
    }

    /// 螢幕對齊的單一細環（光子環）。
    static func screenRing(segments: Int) -> SCNGeometry {
        ribbons([BlackHoleRing(radius: 0.3, inclination: 0, node: 0)], segments: segments, extent: 1)
    }

    /// 粒子的打包資料（每個粒子 12 個 float）。
    struct Particles {
        var elements: [Float] = []   // a, e, M0
        var orient: [Float] = []     // 傾角, 節點, 近點角
        var motion: [Float] = []     // 平均角速度, 雜湊
        var attributes: [Float] = [] // 徑向偏移+0.5, 法向偏移+0.5, 亮度, 種類
        var count: Int { elements.count / 3 }

        mutating func append(a: Float, e: Float, m0: Float, inc: Float, node: Float, peri: Float, n: Float, hash: Float,
                             offR: Float, offN: Float, brightness: Float, kind: Float) {
            elements.append(a); elements.append(e); elements.append(m0)
            orient.append(inc); orient.append(node); orient.append(peri)
            motion.append(n); motion.append(hash)
            attributes.append(0.5 + offR); attributes.append(0.5 + offN); attributes.append(brightness); attributes.append(kind)
        }
    }

    /// 平均角速度：克卜勒 n ∝ a^-1.5，量化到 1/8。
    static func meanMotion(semiMajor: Float, inner: Float) -> Float {
        let raw = 0.95 * powf(max(semiMajor, 0.05) / inner, -1.5)
        return max(motionQuantum, (raw / motionQuantum).rounded() * motionQuantum)
    }

    /// 由種子產生 count 條粒子流的軌道根數（傾角正負交錯，給畫面上下的層次）。
    static func streams(count: Int, inner: Float, seed: UInt64) -> [BlackHoleStream] {
        var rng = BlackHoleRandom(seed: seed)
        var result: [BlackHoleStream] = []
        var k = 0
        while k < count {
            let t = count > 1 ? Float(k) / Float(count - 1) : 0.5
            let a = 0.66 + 0.78 * t + rng.range(-0.06, 0.06)
            let sign: Float = k % 2 == 0 ? 1 : -1
            let inc = sign * rng.range(0.24, 0.6)
            result.append(BlackHoleStream(semiMajor: a, eccentricity: rng.range(0.04, 0.24), inclination: inc,
                                          node: rng.range(0, 2 * .pi), periapsis: rng.range(0, 2 * .pi),
                                          head: rng.range(0, 2 * .pi), arc: rng.range(2.6, 5.4),
                                          meanMotion: meanMotion(semiMajor: a, inner: inner)))
            k += 1
        }
        return result
    }

    /// 粒子流：沿軌道弧分佈，頭亮尾暗、尾巴截面較寬。
    static func streamParticles(_ streams: [BlackHoleStream], perStream: Int, seed: UInt64) -> Particles {
        var rng = BlackHoleRandom(seed: seed)
        var particles = Particles()
        var k = 0
        while k < streams.count {
            let stream = streams[k]
            var i = 0
            while i < perStream {
                let t = powf(rng.next(), 0.85)
                let spread = 0.3 + 1.0 * t
                particles.append(a: stream.semiMajor, e: stream.eccentricity, m0: stream.head - t * stream.arc,
                                 inc: stream.inclination, node: stream.node, peri: stream.periapsis,
                                 n: stream.meanMotion, hash: rng.next(),
                                 offR: rng.gauss() * 0.014 * spread, offN: rng.gauss() * 0.009 * spread,
                                 brightness: powf(1 - t, 1.3) * rng.range(0.55, 1.0) + 0.08,
                                 kind: 0)
                i += 1
            }
            k += 1
        }
        return particles
    }

    /// 細塵：環繞盤面的薄環狀雲，每顆有自己的軌道（量化的角速度）。
    static func dustParticles(count: Int, inner: Float, outer: Float, seed: UInt64) -> Particles {
        var rng = BlackHoleRandom(seed: seed)
        var particles = Particles()
        var i = 0
        while i < count {
            let a = inner * 1.15 + (outer * 1.12 - inner * 1.15) * powf(rng.next(), 0.8)
            let wide = rng.next() < 0.25
            particles.append(a: a, e: rng.range(0, 0.1), m0: rng.range(0, 2 * .pi),
                             inc: rng.gauss() * (wide ? 0.22 : 0.06), node: rng.range(0, 2 * .pi), peri: rng.range(0, 2 * .pi),
                             n: meanMotion(semiMajor: a, inner: inner), hash: rng.next(),
                             offR: 0, offN: rng.gauss() * 0.01, brightness: rng.range(0.25, 0.7), kind: 0.5)
            i += 1
        }
        return particles
    }

    /// 從粒子流裡每 every 顆挑一顆當高頻火花（同一條軌道、種類改成 1）。
    static func sparks(from streams: Particles, every: Int) -> Particles {
        var result = Particles()
        let step = max(1, every)
        var i = 0
        while i < streams.count {
            result.elements.append(contentsOf: streams.elements[(i * 3)..<(i * 3 + 3)])
            result.orient.append(contentsOf: streams.orient[(i * 3)..<(i * 3 + 3)])
            result.motion.append(contentsOf: streams.motion[(i * 2)..<(i * 2 + 2)])
            result.attributes.append(contentsOf: streams.attributes[(i * 4)..<(i * 4 + 3)])
            result.attributes.append(1)
            i += step
        }
        return result
    }

    /// 由打包資料建立粒子幾何：每顆粒子 4 個頂點（角落編號存在 color.w 的十位數），形狀在 shader 裡展開成拖尾四邊形。
    static func quads(_ particles: Particles, extent: Float) -> SCNGeometry {
        let count = particles.count
        var elements: [Float] = [], orient: [Float] = [], motion: [Float] = [], attributes: [Float] = []
        elements.reserveCapacity(count * 12); orient.reserveCapacity(count * 12)
        motion.reserveCapacity(count * 8); attributes.reserveCapacity(count * 16)
        var indices: [UInt32] = []
        indices.reserveCapacity(count * 6)
        var i = 0
        while i < count {
            var corner = 0
            while corner < 4 {
                elements.append(contentsOf: particles.elements[(i * 3)..<(i * 3 + 3)])
                orient.append(contentsOf: particles.orient[(i * 3)..<(i * 3 + 3)])
                motion.append(contentsOf: particles.motion[(i * 2)..<(i * 2 + 2)])
                attributes.append(contentsOf: particles.attributes[(i * 4)..<(i * 4 + 3)])
                attributes.append(particles.attributes[i * 4 + 3] + Float(corner) * 10)
                corner += 1
            }
            let base = UInt32(i * 4)
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            i += 1
        }
        let geometry = SCNGeometry(sources: [source(elements, .vertex, components: 3),
                                             source(orient, .normal, components: 3),
                                             source(motion, .texcoord, components: 2),
                                             source(attributes, .color, components: 4)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let e = CGFloat(extent)
        geometry.boundingBox = (SCNVector3(-e, -e, -e), SCNVector3(e, e, e))
        return geometry
    }
}
