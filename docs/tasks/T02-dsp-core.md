# T02 DSP 核心：頻帶、FFT、處理管線、模擬訊號

| 項目 | 內容 |
|---|---|
| 依賴 | T01（`VisualizerConfig`、`SpectrumFrame`） |
| 分支 | `task/T02-dsp-core`（從 `task/T01-scaffold` 開，獨立 worktree） |
| 平行 | 與 T03 同時進行；**不得**修改 T03 範圍內的檔案 |
| 實作 | Codex |
| 審查 | Claude，依 `docs/REVIEW.md` |

## 目標

把原型的訊號處理完整移植成 `PulseFloatCore` 裡可測試、可在每幀熱路徑使用的 Swift 程式碼。這張單**不碰音訊擷取、不碰 UI**。

規格：`docs/SPEC.md` §6。演算法基準：`docs/design/prototype.html` 的 `rebuildBands`、`bandsFromAnalyser`、`bandsSimulated`、`processFrame`。

## 範圍（只能新增/修改這些路徑）

- `PulseFloatCore/DSP/**`
- `PulseFloatCoreTests/DSP/**`
- `PulseFloatCoreTests/Fixtures/pipeline_golden.json`（從 `docs/design/golden/pipeline_golden.json` 原樣複製，不可手改）

不要動 `project.yml`、`Config/`、`Model/`、App target、`docs/`。如果真的需要改共用契約，停下來在最後的回報裡說明原因，不要自己改。

### 與 T03 共用 module 的規則（避免之後合併時編譯失敗）

`PulseFloatCore` 與 `PulseFloatCoreTests` 是 T02/T03 共用的 module，兩邊看不到彼此的程式碼：
1. 檔名用具體型別名（`BandLayout.swift`、`SpectrumAnalyzer.swift`、`SpectrumPipeline.swift`、`SimulatedSpectrum.swift`；其他檔案加 `DSP` 前綴）。禁止 `Math.swift`、`Extensions.swift`、`Helpers.swift`、`Utilities.swift`、`TestHelpers.swift` 這類通用檔名。
2. 不得對 `Float`/`Double`/`CGFloat`/`Comparable`/`Array`/`SpectrumFrame`/`VisualizerConfig` 新增 internal 或 public 的 extension 成員，也不得新增頂層函式。helper 一律 `private`/`fileprivate`，或放進自己的命名空間：`enum DSPMath`、測試用 `enum DSPTestSupport`。

## 要做的事

### 1. `BandLayout`（struct，`Sendable`）
- `init(count:fMinHz:fMaxHz:)`，提供 `lo`、`hi`、`center`（皆 `[Double]`，**以 Double 計算**）與 `count`。analyzer/pipeline 需要 Float 時自行在 init 轉存。
- 公式見 SPEC §6.1。

### 2. `SpectrumAnalyzer`（`final class`，非 actor，單一執行緒使用）
- `init(fftSize: Int = 4096, sampleRate: Double, layout: BandLayout)`：預先配置 vDSP FFT setup、Blackman 視窗、所有工作 buffer。
- `func analyze(samples: UnsafeBufferPointer<Float>, into bandsDb: UnsafeMutableBufferPointer<Float>)`：
  - `samples.count < fftSize` → 前面補 0；`> fftSize` → 只取最後 `fftSize` 個；`bandsDb` 只寫 `min(bandsDb.count, layout.count)` 個。都不得 crash。
  - 輸出每個頻帶的 dBFS（SPEC §6.2，含 k1 < k0 時的 dB 域內插）。
  - **init 之後完全不配置記憶體。**
- `func update(sampleRate: Double, layout: BandLayout)`：取樣率或頻帶改變時重算對應表（這裡可以配置記憶體）。
- **vDSP 注意事項**（已實測）：
  - `vDSP_fft_zrip` / `vDSP.FFT.forward` / `vDSP_DFT_zrop` 的實數正向輸出是數學 DFT 的 **2 倍**；`vDSP_blkman_window(…, 0)` 是 periodic Blackman（Σw = 0.42·N）。所以 bin 中心、振幅 A 的正弦 `|Z[k]| = A·0.42·N`，**dBFS = 20·log10(|Z[k]| / (0.42·N))**（N = 4096 時分母 1720.32）。不要把原型的 +13.55 套在 `|Z|/N` 上（會高 6.02 dB）。
  - 輸入先用 `vDSP_ctoz` 打包成 N/2 個複數；輸出 `imagp[0]` 存的是 Nyquist 的實部，算幅度前設 0。
  - split-complex 的指標用 init 配置的 `UnsafeMutablePointer<Float>`（`deinit` 釋放），不要寫 `DSPSplitComplex(realp: &array, …)`（Swift 6 + warnings-as-errors 直接編譯失敗）。
  - `log10(0)` 是 −∞；非有限值一律換成 −160。

### 3. `SpectrumPipeline`（`final class` 或 struct，自行決定，單一執行緒使用）
- `init(config: VisualizerConfig)`、`setConfig(_:)`（struct 版為 `mutating`）：內部**一律先 `config.clamped()`**（golden 的 config 都在範圍內，不受影響）。
  - 頻帶設定（count / fMinHz / fMaxHz）改變 → 重建 `BandLayout`，並把狀態設回**初值**：rawDb = −160、values/peaks/peakT/peakV = 0、bass = 0、ceilDb = −12（SPEC 優先；原型的 `rebuildBands` 不重置 ceil/bass）。
  - 其他設定改變 → 保留狀態。
- 原始輸入寫入口：`func withRawDb<R>(_ body: (UnsafeMutableBufferPointer<Float>) throws -> R) rethrows -> R`（struct 版加 `mutating`），讓 analyzer 或模擬訊號直接寫入、不需複製。T04 的用法會是 `pipeline.withRawDb { raw in scratch.withUnsafeBufferPointer { analyzer.analyze(samples: $0, into: raw) } }`。
- `func process(dt: Double) -> SpectrumFrame`（struct 版加 `mutating`）：照 SPEC §6.3 八個步驟。初值同上。
- 對外唯讀：`bandLayout`、`ceilingDb`（目前 AGC 上限 dB）。
- **配置限制**：`process` 每次呼叫只允許建立回傳 `SpectrumFrame` 的 values / peaks 兩個陣列，其他一律不配置（迴圈內不建立陣列、不用 `map`/`filter`/`reduce`、不做字串插值、沒有會配置的 closure）。
- ceilDb、bass 建議用 `Double` 儲存（Float 也能過 golden，但餘裕較小）。

### 4. `SimulatedSpectrum`（struct 或 final class）
- `init(layout: BandLayout, noise: @escaping @Sendable () -> Double = { Double.random(in: -0.5...0.5) })`。
- `func fill(_ rawDb: UnsafeMutableBufferPointer<Float>, time: Double)`：照原型 `bandsSimulated`，雜訊項 = `noise() * 7`。測試時注入 `{ 0 }`。

### 5. 測試（`PulseFloatCoreTests/DSP/`）
1. **BandLayout**：`lo[0] == fMin`、`hi[N-1] == fMax`（相對誤差 1e-9）、相鄰頻帶 `hi[i] == lo[i+1]`、`center` 為幾何平均；和 golden JSON 的 `bandLowHz/bandHighHz/bandCenterHz` 相符（相對 1e-5）。
2. **Analyzer 校準**（48 kHz、4096 點）：bin 中心正弦 k = 100（1171.875 Hz，落在預設 band 37）振幅 1.0 → 該頻帶 0 ± 0.5 dBFS；振幅 0.1 → −20 ± 0.5 dBFS；全 0 輸入 → 每頻帶 ≤ −150 dBFS 且全為有限值。
3. **Analyzer 窄頻帶**（48 kHz、4096 點、預設 64 頻帶；輸入振幅 1.0、35.15625 Hz = bin 3 中心的正弦）：band 0（30–33.09 Hz，fc/binHz ≈ 2.689，k1 < k0）走 dB 域內插 → −1.40 ± 0.05 dBFS（bin 2 ≈ −4.51、bin 3 = 0.00）；band 1（33.09–36.50 Hz，k0 = k1 = 3）走最大值 → 0.00 ± 0.05 dBFS。
4. **輸入長度**：samples 少於 4096（例如 1000 個）與多於 4096（例如 5000 個）都不 crash，且多於時只看最後 4096 個（前段放雜訊、後段放正弦，結果應與只餵後 4096 個相同）。
5. **Pipeline golden**：讀 `Fixtures/pipeline_golden.json`，照 JSON 頂層的 `replay` 說明重播四個 scenario：config 用 `scenario.config` 以 `VisualizerConfig` 解碼（不要依 description 手組）；`simulated_defaults` 與 `zero_dt_frames` 用 `SimulatedSpectrum` + `noise: { 0 }` 產生 raw。每個 snapshot 的 values / peaks / bass / ceilDb 絕對誤差 ≤ 1e-4。
6. **行為測試**（獨立於 golden，給人看得懂的保證）：
   - AGC 關閉（ceilingDb −12、rangeDb 54）、gamma 1、tilt 0、spatial 0、平坦 raw −20：目標值 = 46/54 ≈ 0.8519；從 0 開始，一個 dt = 0.012 s（= attackMs）後 value = 目標 × (1 − e⁻¹) ≈ 0.5384（±1%）。
   - gate：raw −100（< −90）→ 目標 0。
   - `dt = 0` → values / peaks / bass / ceilingDb 與前一幀完全相同。
   - 峰值：推高後在 `peakHoldMs` 內不下降，之後下降且永遠 ≥ value。
   - AGC 關閉 → `ceilingDb` 等於 `level.ceilingDb`。
   - AGC 夾值：AGC 開、預設設定、平坦 raw −160、dt 1/60 跑 400 幀 → `ceilingDb == −45`；平坦 raw +20 跑 60 幀 → `ceilingDb == +6`。
   - `setConfig` 改 `bands.count` → 輸出長度跟著變，下一幀前 values/peaks 全 0、bass 0、`ceilingDb == −12`；只改 `motion.releaseMs` → 狀態保留。
   - 超出範圍的 config（例如 `fMinHz = 0`、`rangeDb = 0`）→ 經 clamped 後輸出沒有 NaN / Inf。
7. **效能**：64 頻帶 `analyze + process` 1000 次的平均在 Debug 下 < 1 ms（Release 預算是 0.3 ms，這裡只防止明顯退化）。

## 驗收標準

1. `scripts/test.sh` 全部通過；零警告（定義見 `docs/REVIEW.md`）。
2. golden 四個 scenario 全部吻合。
3. `analyze` 在 init 之後完全不配置記憶體；`process` 只配置回傳 frame 的兩個陣列（審查者讀程式碼確認）。
4. 沒有 force unwrap / `try!`（測試碼除外）；所有 public API 有文件註解。
5. 遵守「與 T03 共用 module 的規則」。
6. 只動了「範圍」列出的路徑。

## 不要做

- 不要碰 Core Audio、AVFoundation、ring buffer（T04）。
- 不要做任何繪圖或 UI（T03）。
- 不要 commit。
