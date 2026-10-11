/// 3D 主題共用的音訊特徵（每幀一份，可跨執行緒傳遞）。
/// 全部是平滑後的值；靜音時除了 `centroid`（保留最後的音色）以外都回到精確的 0，`time` 也停止前進，
/// 所以只用這些值驅動的畫面在靜音時一定是靜止的。
public struct AudioFeatures: Sendable, Equatable {
    /// 整體響度：窗內 RMS，−60...0 dBFS 對應 0...1。
    public var level: Float = 0
    /// 窗內峰值：−60...0 dBFS 對應 0...1（立即上升、0.15 秒下降）。
    public var peak: Float = 0
    /// 低頻（< 150 Hz）能量 0...1（各段都是頻段平均與最大值的中間）。
    public var bass: Float = 0
    /// 中頻（150 Hz...2 kHz）能量 0...1。
    public var mid: Float = 0
    /// 高頻（2...16 kHz）能量 0...1。
    public var treble: Float = 0
    /// 頻譜重心在 30 Hz...16 kHz 對數軸上的位置：0 低沉 ... 1 明亮。靜音時保留最後的值。
    public var centroid: Float = 0.5
    /// 正向頻譜變化量（自適應正規化）0...1。
    public var flux: Float = 0
    /// 這一幀是否偵測到起音（只在該幀為 true）。
    public var onset: Bool = false
    /// 起音包絡：起音時跳到強度 0...1，之後以 0.25 秒時間常數衰減。
    public var onsetEnvelope: Float = 0
    /// 起音累計次數（單調遞增）。
    public var onsetCount: Int = 0
    /// 立體聲寬度：0 單聲道 ... 1 左右完全不相關（更寬也夾在 1）。
    public var stereoWidth: Float = 0
    /// 左右平衡：−1 偏左 ... +1 偏右。
    public var balance: Float = 0
    /// 顯示頻段的平均高度 0...1。
    public var energy: Float = 0
    /// 活動量：有聲音時趨近 1，靜音後約 1.5 秒內平滑到精確 0。主題的動作幅度應乘上它。
    public var activity: Float = 0
    /// 音訊時鐘（秒）：以 `activity` 的速率前進，靜音時停止。主題的旋轉、流動都用它而不是牆上時間。
    public var time: Double = 0

    /// activity 為 0：畫面應該完全靜止。
    public var isSilent: Bool { activity == 0 }

    /// 全部歸零（centroid 0.5）的靜音特徵。
    public static let silent = AudioFeatures()

    public init() {}
}
