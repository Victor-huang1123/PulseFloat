import Metal
import PulseFloatCore

/// 頻段 → 地形欄的空間核：低頻寬（寬廣的山）、高頻窄（細緻的稜線）。只在欄數或頻段數改變時重建。
///
/// 核是高斯差（DoG）：(1 + k)·G(σ) − k·G(3σ)。寬的負瓣把整片高原壓低、讓頻譜上的峰（音高、共振）站出來，
/// 所以地形有山也有谷，而不是一整片毯子。
struct TerrainKernel {
    let columns: Int
    let bands: Int
    /// 每欄最多幾個權重。
    let taps: Int
    /// 每欄第一個頻段。
    let start: [Int]
    /// 每欄實際的權重數。
    let count: [Int]
    /// columns × taps 個權重（每欄總和為 1，可能有負值）。
    let weights: [Float]

    /// 峰值強調量 k。
    static let emphasis = 0.55

    /// 第 j 欄（對數頻率位置 u = j/(columns−1)）的高斯寬度（以頻段為單位，64 頻段時低頻 2.6、高頻 0.45）。
    static func sigma(u: Double, bands: Int) -> Double {
        let scale = Double(max(bands, 1)) / 64
        return max(0.35, scale * (2.6 + (0.45 - 2.6) * pow(min(1, max(0, u)), 0.75)))
    }

    init(columns: Int, bands: Int) {
        self.columns = max(1, columns)
        self.bands = max(0, bands)
        let maxSigma = Self.sigma(u: 0, bands: self.bands)
        taps = max(1, min(self.bands, 2 * Int((maxSigma * 7.5).rounded(.up)) + 1))
        var start = [Int](repeating: 0, count: self.columns)
        var count = [Int](repeating: 0, count: self.columns)
        var weights = [Float](repeating: 0, count: self.columns * taps)
        var narrow = [Double](repeating: 0, count: taps)
        var wide = [Double](repeating: 0, count: taps)
        let k = Self.emphasis
        var j = 0
        while j < self.columns, self.bands > 0 {
            let u = self.columns > 1 ? Double(j) / Double(self.columns - 1) : 0
            let center = u * Double(self.bands - 1)
            let sigma = Self.sigma(u: u, bands: self.bands)
            let reach = Int((sigma * 7.5).rounded(.up))
            let mid = Int(center.rounded())
            let first = max(0, min(self.bands - 1, mid - reach))
            let last = min(self.bands - 1, max(first, mid + reach))
            let n = min(taps, last - first + 1)
            var narrowTotal = 0.0, wideTotal = 0.0
            var t = 0
            while t < n {
                let d = Double(first + t) - center
                narrow[t] = exp(-0.5 * (d / sigma) * (d / sigma))
                wide[t] = exp(-0.5 * (d / (3 * sigma)) * (d / (3 * sigma)))
                narrowTotal += narrow[t]
                wideTotal += wide[t]
                t += 1
            }
            t = 0
            while t < n, narrowTotal > 0, wideTotal > 0 {
                weights[j * taps + t] = Float((1 + k) * narrow[t] / narrowTotal - k * wide[t] / wideTotal)
                t += 1
            }
            start[j] = first
            count[j] = n
            j += 1
        }
        self.start = start
        self.count = count
        self.weights = weights
    }
}

/// 地形的歷史緩衝：rows 個頻譜切片的環狀緩衝，存在一張 columns × (rows + 1) 的 rgba32Float 貼圖。
///
/// - 每個 texel：r = 高度 0...1（空間平滑後），g = 這個切片的起音標記 0...1，a = 1。
/// - 最後一列第 0 個 texel 是參數：(head, frac, 線條相位, 前緣起音光)。
/// - 「即時列」是下一個要寫入的槽（head + 1）：每幀覆寫；音訊時鐘每前進 1/rowsPerSecond 秒就提交一次（head + 1），
///   整片地形往後退一格，最舊的切片被即時列重用。網格用 frac 平滑地捲動，所以不會一格一格跳。
/// - 靜音（`features.isSilent`）時完全不動：不提交、不捲動、不上傳，畫面逐像素不變。
/// - 每幀只上傳一列（columns × 16 bytes）加一個參數 texel；不配置記憶體。
@MainActor
final class TerrainHistory {
    let columns: Int
    let rows: Int
    let texture: (any MTLTexture)?
    /// 音訊時鐘每秒新增幾個切片。
    var rowsPerSecond: Double
    /// 時間切片線每幾個切片畫一條（線條黏在資料上，跟著捲動）。
    var lineStep: Int {
        didSet { lineStep = max(1, lineStep) }
    }

    /// 最新已提交切片所在的槽。
    private(set) var head = 0
    /// 累計提交的切片數。
    private(set) var sliceCount = 0
    /// 下一次提交前的捲動比例 0..<1。
    private(set) var frac: Float = 0
    /// 即時列（下一個切片）目前的高度。
    private(set) var live: [Float]
    /// 即時列的起音標記。
    private(set) var liveBeat: Float = 0
    /// 快速追隨（鼓點的起伏）與慢速追隨（持續的音色＝山脈）。即時列 = 兩者混合。
    private var fast: [Float]
    private var slow: [Float]
    /// 即時列中快速成分的比例。
    static let fastWeight: Float = 0.45

    private var accumulator: Double = 0
    private var lastTime: Double?
    private var frontGlow: Float = 0
    private var target: [Float]
    private var mirror: [Float]
    private var kernel: TerrainKernel

    /// 建立歷史緩衝；from 不為 nil 時把舊的歷史重新取樣過來（切換畫質或呈現方式時保留地景）。
    init(columns: Int, rows: Int, rowsPerSecond: Double, lineStep: Int, device: (any MTLDevice)?, from old: TerrainHistory? = nil) {
        self.columns = max(4, columns)
        self.rows = max(4, rows)
        self.rowsPerSecond = rowsPerSecond
        self.lineStep = max(1, lineStep)
        live = [Float](repeating: 0, count: self.columns)
        fast = [Float](repeating: 0, count: self.columns)
        slow = [Float](repeating: 0, count: self.columns)
        target = [Float](repeating: 0, count: self.columns)
        mirror = [Float](repeating: 0, count: self.columns * (self.rows + 1) * 4)
        kernel = TerrainKernel(columns: self.columns, bands: 64)
        if let device {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: self.columns,
                                                                      height: self.rows + 1, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            texture = device.makeTexture(descriptor: descriptor)
        } else {
            texture = nil
        }
        if let old { resample(from: old) }
        uploadAll()
    }

    /// 把 old 的歷史依深度與頻率位置最近鄰取樣到這個緩衝（head 從 0 開始）。
    private func resample(from old: TerrainHistory) {
        head = 0
        sliceCount = old.sliceCount
        accumulator = old.accumulator
        frac = old.frac
        lastTime = old.lastTime
        liveBeat = old.liveBeat
        var k = 0
        while k < rows {
            let oldK = Int((Double(k) * Double(old.rows - 1) / Double(rows - 1)).rounded())
            let oldSlot = Self.slot(head: old.head, k: oldK, rows: old.rows)
            let newSlot = Self.slot(head: head, k: k, rows: rows)
            var j = 0
            while j < columns {
                let oldJ = Int((Double(j) * Double(old.columns - 1) / Double(columns - 1)).rounded())
                let src = (oldSlot * old.columns + oldJ) * 4
                let dst = (newSlot * columns + j) * 4
                mirror[dst] = old.mirror[src]
                mirror[dst + 1] = old.mirror[src + 1]
                mirror[dst + 2] = old.mirror[src + 2]
                mirror[dst + 3] = old.mirror[src + 3]
                j += 1
            }
            k += 1
        }
        var j = 0
        while j < columns {
            let oldJ = Int((Double(j) * Double(old.columns - 1) / Double(columns - 1)).rounded())
            live[j] = old.live[oldJ]
            fast[j] = old.fast[oldJ]
            slow[j] = old.slow[oldJ]
            j += 1
        }
    }

    /// 網格第 k 列（0 = 最前面的即時列）對應的槽。
    static func slot(head: Int, k: Int, rows: Int) -> Int {
        let s = (head + 1 - k) % rows
        return s < 0 ? s + rows : s
    }

    /// 網格第 k 列、第 j 欄目前的高度（測試用）。
    func value(k: Int, column j: Int) -> Float {
        let slot = Self.slot(head: head, k: min(rows - 1, max(0, k)), rows: rows)
        return mirror[(slot * columns + min(columns - 1, max(0, j))) * 4]
    }

    /// 網格第 k 列的起音標記（測試用）。
    func beat(k: Int) -> Float {
        let slot = Self.slot(head: head, k: min(rows - 1, max(0, k)), rows: rows)
        return mirror[slot * columns * 4 + 1]
    }

    /// 前進一幀；回傳畫面是否可能改變。靜音時什麼都不做（凍結）。
    func advance(values: [Float], features f: AudioFeatures, dt: Double) -> Bool {
        guard !f.isSilent else {
            lastTime = f.time
            return false
        }
        var delta = 0.0
        if let lastTime { delta = f.time - lastTime }
        lastTime = f.time
        if !delta.isFinite || delta < 0 || delta > 0.5 { delta = 0 }
        // 地形的進度 = 音訊時鐘 × activity²：播放中 activity ≈ 1，完全照音訊時鐘；聲音停下時頻段值
        // 幾乎立刻歸零，但音訊時鐘還會慢慢走約 0.25 秒，這裡讓地形收得更快，凍結的畫面保留最後的音樂形狀。
        // 開始播放時也因此有自然的漸入。
        let activity = f.activity.isFinite ? Double(min(1, max(0, f.activity))) : 0
        delta *= activity * activity
        let rate = rowsPerSecond.isFinite ? max(0, rowsPerSecond) : 0
        accumulator += delta * rate
        var commits = 0
        while accumulator >= 1 && commits < 6 {
            commit()
            accumulator -= 1
            commits += 1
        }
        if accumulator >= 1 { accumulator -= accumulator.rounded(.down) }
        frac = Float(accumulator)

        computeTarget(values)
        // 平滑也走音訊時鐘（跟切片同一個時間軸）：聲音停止、時鐘放慢時，最前面的形狀跟著凍結，
        // 而不是在少數幾列裡塌成一道牆。dt 只當作上限（避免時鐘跳動時一次走太多）。
        let wall = dt.isFinite ? min(0.05, max(0, dt)) : 0
        let step = min(delta, max(wall, 1.0 / 240))
        // 快速成分的起音時間常數跟切片間隔相稱（避免取樣鋸齒）；慢速成分讓持續的音色連成往遠方延伸的山脈。
        let interval = rate > 0 ? 1 / rate : 0.05
        let attack = Float(1 - exp(-step / max(0.01, interval * 0.5)))
        let release = Float(1 - exp(-step / 0.11))
        let slowAttack = Float(1 - exp(-step / 0.22))
        let slowRelease = Float(1 - exp(-step / 0.45))
        let w = Self.fastWeight
        var j = 0
        while j < columns {
            let goal = target[j]
            fast[j] = Self.follow(fast[j], goal, goal > fast[j] ? attack : release)
            slow[j] = Self.follow(slow[j], goal, goal > slow[j] ? slowAttack : slowRelease)
            live[j] = w * fast[j] + (1 - w) * slow[j]
            j += 1
        }
        let envelope = f.onsetEnvelope.isFinite ? min(1, max(0, f.onsetEnvelope)) : 0
        liveBeat = envelope * envelope
        frontGlow = envelope
        writeLiveRow()
        writeParams()
        return true
    }

    /// 指數追隨；夠接近時直接等於目標（靜止狀態是精確值）。
    private static func follow(_ value: Float, _ goal: Float, _ amount: Float) -> Float {
        let next = value + (goal - value) * amount
        return abs(next - goal) < 1e-4 ? goal : next
    }

    /// 提交即時列：它變成最新的切片，最舊的槽變成新的即時列。
    private func commit() {
        head = (head + 1) % rows
        sliceCount &+= 1
    }

    /// 頻段值（容忍 NaN、長度不定）經過空間平滑核得到每欄的目標高度。
    private func computeTarget(_ values: [Float]) {
        let n = values.count
        if n != kernel.bands { kernel = TerrainKernel(columns: columns, bands: n) }
        let taps = kernel.taps
        var j = 0
        while j < columns {
            var sum: Float = 0
            let first = kernel.start[j]
            let count = kernel.count[j]
            var t = 0
            while t < count {
                let v = values[first + t]
                sum += kernel.weights[j * taps + t] * (v.isFinite ? min(1, max(0, v)) : 0)
                t += 1
            }
            target[j] = min(1, max(0, sum))
            j += 1
        }
    }

    private func writeLiveRow() {
        let slot = Self.slot(head: head, k: 0, rows: rows)
        let base = slot * columns * 4
        var j = 0
        while j < columns {
            mirror[base + j * 4] = live[j]
            mirror[base + j * 4 + 1] = liveBeat
            mirror[base + j * 4 + 2] = 0
            mirror[base + j * 4 + 3] = 1
            j += 1
        }
        upload(row: slot, x: 0, width: columns)
    }

    /// 參數 texel：(head, frac, 線條相位, 前緣起音光)。
    func writeParams() {
        let base = rows * columns * 4
        mirror[base] = Float(head)
        mirror[base + 1] = frac
        // 以 2 × lineStep 取餘數：「每隔一條」的線條層級也固定黏在同一批切片上，不會閃爍。
        mirror[base + 2] = Float((sliceCount &+ 1) % (2 * lineStep))
        mirror[base + 3] = frontGlow
        upload(row: rows, x: 0, width: 1)
    }

    private func upload(row: Int, x: Int, width: Int) {
        guard let texture else { return }
        let offset = (row * columns + x) * 4
        mirror.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(x, row, width, 1), mipmapLevel: 0,
                            withBytes: base + offset, bytesPerRow: columns * 16)
        }
    }

    private func uploadAll() {
        writeParams()
        guard let texture else { return }
        mirror.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, columns, rows + 1), mipmapLevel: 0,
                            withBytes: base, bytesPerRow: columns * 16)
        }
    }
}
