import Foundation
import Synchronization

/// 單一寫入者（Core Audio IO 執行緒）／單一讀取者（主執行緒）的 lock-free PCM 環形緩衝。
/// 主軌是單聲道 mid = (L+R)/2（頻譜分析用）；另一條同步的 side = (L−R)/2 軌給立體聲寬度與平衡（單聲道輸入時為 0）。
/// 寫入端不配置記憶體、不上鎖、不碰 actor；讀取端只複製最新的 N 個樣本，不消耗資料。
public final class SampleRingBuffer: @unchecked Sendable {
    // 安全性：storage 只由唯一的寫入者寫入，寫完後以 release 發布 writeCount；
    // 讀取者以 acquire 讀 writeCount 後只讀已發布的範圍。讀取期間若寫入者繞圈覆寫，
    // copyLatest 會偵測並重試，因此不會回傳撕裂的資料（重試仍失敗時回傳最後一次結果）。

    /// 可保存的樣本數（2 的次方，至少 1024）。
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let sideStorage: UnsafeMutablePointer<Float>
    private let writeCount = Atomic<Int>(0)

    /// 建立緩衝；capacity 會向上取到 2 的次方（最少 1024）。只在初始化時配置記憶體。
    public init(capacity: Int = 16_384) {
        var size = 1024
        while size < capacity { size <<= 1 }
        self.capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
        sideStorage = .allocate(capacity: size)
        sideStorage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        sideStorage.deinitialize(count: capacity)
        sideStorage.deallocate()
    }

    /// 至今寫入過的樣本總數（任意執行緒可讀）；主執行緒用來判斷是否有新資料。
    public var totalWritten: Int { writeCount.load(ordering: .acquiring) }

    /// IO 執行緒：寫入單聲道樣本。不配置記憶體；超過 capacity 時只保留最新的部分。
    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let skip = max(0, count - capacity)
        let start = writeCount.load(ordering: .relaxed)
        var index = skip
        while index < count {
            let slot = (start + index - skip) & mask
            storage[slot] = samples[index]
            sideStorage[slot] = 0
            index += 1
        }
        writeCount.store(start + count - skip, ordering: .releasing)
    }

    /// IO 執行緒：把交錯（interleaved）Float32 PCM 平均降成單聲道後寫入。不配置記憶體。
    public func writeInterleaved(_ samples: UnsafePointer<Float>, frameCount: Int, channelCount: Int) {
        guard frameCount > 0, channelCount > 0 else { return }
        let skip = max(0, frameCount - capacity)
        let start = writeCount.load(ordering: .relaxed)
        let scale = 1 / Float(channelCount)
        var frame = skip
        while frame < frameCount {
            var sum: Float = 0
            var channel = 0
            let base = frame * channelCount
            while channel < channelCount {
                sum += samples[base + channel]
                channel += 1
            }
            let slot = (start + frame - skip) & mask
            storage[slot] = sum * scale
            sideStorage[slot] = channelCount >= 2 ? (samples[base] - samples[base + 1]) * 0.5 : 0
            frame += 1
        }
        writeCount.store(start + frameCount - skip, ordering: .releasing)
    }

    /// IO 執行緒：把非交錯的左右聲道平均成單聲道後寫入；right 為 nil 時直接寫 left。不配置記憶體。
    public func writeDeinterleaved(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, frameCount: Int) {
        guard frameCount > 0 else { return }
        guard let right else {
            write(left, count: frameCount)
            return
        }
        let skip = max(0, frameCount - capacity)
        let start = writeCount.load(ordering: .relaxed)
        var frame = skip
        while frame < frameCount {
            let slot = (start + frame - skip) & mask
            storage[slot] = (left[frame] + right[frame]) * 0.5
            sideStorage[slot] = (left[frame] - right[frame]) * 0.5
            frame += 1
        }
        writeCount.store(start + frameCount - skip, ordering: .releasing)
    }

    /// 主執行緒：把最新的 count 個樣本依時間順序（舊 → 新）複製到 destination。
    /// 可用樣本不足 count 時前面補 0；一次最多讀 capacity × 3/4 個（其餘保留給寫入中的區塊）。
    /// 回傳實際複製的真實樣本數。不配置記憶體。
    @discardableResult
    public func copyLatest(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        copyLatest(into: destination, side: nil, count: count)
    }

    /// 同 `copyLatest(into:count:)`，並把同一段時間的 side 軌複製到 side（nil 時略過）。不配置記憶體。
    @discardableResult
    public func copyLatest(into destination: UnsafeMutablePointer<Float>, side: UnsafeMutablePointer<Float>?, count: Int) -> Int {
        guard count > 0 else { return 0 }
        // 寫入者在發布 writeCount 之前就會寫進 storage，所以額外保留 capacity/4 的邊帶給「寫到一半」的區塊
        // （Core Audio 每次 IOProc 的區塊遠小於此）。
        let margin = capacity / 4
        var attempt = 0
        var copied = 0
        while true {
            let end = writeCount.load(ordering: .acquiring)
            copied = min(end, count, capacity - margin)
            let padding = count - copied
            var index = 0
            while index < padding {
                destination[index] = 0
                side?[index] = 0
                index += 1
            }
            let start = end - copied
            index = 0
            while index < copied {
                let slot = (start + index) & mask
                destination[padding + index] = storage[slot]
                side?[padding + index] = sideStorage[slot]
                index += 1
            }
            let advanced = writeCount.load(ordering: .acquiring) - end
            let overwritten = advanced + margin - (capacity - copied)
            if overwritten <= 0 { break }
            attempt += 1
            if attempt < 3 { continue }
            // 重試仍被追上：把可能被覆寫的最舊部分清成 0，只回報保證完整的最新樣本。
            let invalid = min(copied, overwritten)
            index = 0
            while index < invalid {
                destination[padding + index] = 0
                side?[padding + index] = 0
                index += 1
            }
            copied -= invalid
            break
        }
        return copied
    }
}
