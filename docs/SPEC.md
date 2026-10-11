# PulseFloat 規格書

> 版本 0.1 · 2026-10-11 · 設計負責人：Claude · 實作：Codex
> 視覺與手感基準：[`docs/design/prototype.html`](design/prototype.html)（瀏覽器打開即可試玩、調參數）。
> 這份文件和原型衝突時，**以這份文件為準**；文件沒寫到的細節，**以原型為準**。

---

## 1. 產品

PulseFloat 是一個 macOS 選單列小工具：擷取「系統正在播放的聲音」，在桌面上用一個可拖曳、可縮放、可點擊穿透的浮動小視窗即時畫出頻譜（NCS 風格的跳動直條等四種主題），選單列圖示本身也是一個 7 根柱子的迷你頻譜。

### 1.1 使用情境

- 一邊聽音樂一邊工作，桌面角落放一個會跟著節拍跳的小視窗。
- 視窗可以設成「鎖定並點擊穿透」，滑鼠點下去會落到後面的視窗，完全不擋操作。
- 不想看浮動視窗時，選單列的迷你頻譜依然在動。

### 1.2 非目標（v1 不做）

- 不播放音樂、不做音訊處理或錄音存檔。
- 不支援 iOS / iPadOS。
- 不上架 Mac App Store（Core Audio Process Tap + 點擊穿透浮動視窗在沙盒外最單純；之後再評估）。
- 不使用任何第三方套件。

---

## 2. 平台與工具鏈

| 項目 | 決定 |
|---|---|
| 最低系統 | macOS 15.0（Process Tap 需要 14.2+；15 讓 SwiftUI/AppKit API 選擇單純） |
| 語言 | Swift 6 語言模式，strict concurrency = complete |
| 警告 | `SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`（所有自家 target） |
| UI | AppKit 為主（`NSStatusItem`、`NSPanel`、自訂 `NSView`）；SwiftUI 只用在快速面板與設定視窗（T05） |
| 繪圖 | Core Graphics，畫在 layer-backed `NSView`；每幀由 App 層**唯一**的 `CADisplayLink`（`NSScreen.displayLink(target:selector:)`，macOS 14+）驅動，同一幀資料分送給浮動視窗與選單列 |
| DSP | Accelerate / vDSP |
| 專案檔 | XcodeGen（`project.yml`）。`*.xcodeproj` **不進版控**，一律由 `xcodegen generate` 產生 |
| 簽章 | 本機開發用 ad-hoc（`CODE_SIGN_IDENTITY = "-"`）；正式簽章之後再說 |
| Bundle ID | `com.victorhuang.PulseFloat`（核心框架 `com.victorhuang.PulseFloatCore`） |
| App 型態 | 只在選單列（`LSUIElement = YES`），沒有 Dock 圖示、沒有主視窗 |

---

## 3. 專案結構

```
PulseFloat/
├── project.yml                 # XcodeGen 定義（唯一的專案設定來源）
├── PulseFloat/                 # App target（AppKit / SwiftUI）
│   ├── App/                    # AppDelegate、進入點、App 層組裝
│   ├── MenuBar/                # 選單列圖示（T01 靜態 → T03 迷你頻譜）
│   ├── Window/                 # 浮動視窗 NSPanel 與 VisualizerView（T03）
│   ├── Audio/                  # 系統音訊擷取（T04）
│   ├── Settings/               # 快速面板、設定視窗、持久化（T05）
│   └── Resources/              # Info.plist、Assets.xcassets（v1 不需要 entitlements 檔）
├── PulseFloatCore/             # Framework：不依賴 AppKit（只用 Foundation / Accelerate / CoreGraphics）
│   ├── Config/                 # VisualizerConfig 與列舉（T01）
│   ├── Model/                  # SpectrumFrame、SpectrumSource（T01）
│   ├── DSP/                    # 頻帶、FFT、處理管線、模擬訊號（T02）
│   ├── Render/                 # 配色與四種主題 + 選單列繪圖（T03）
│   └── Preview/                # 開發用的預覽訊號源（T03）
├── PulseFloatCoreTests/        # 單元測試（不需要 host app，Codex 沙盒內也能跑）
│   ├── Config/  DSP/  Render/  # 依模組分資料夾
│   └── Fixtures/               # 測試資料（JSON 會被 XcodeGen 自動加入 bundle resources）
├── scripts/
│   ├── build.sh                # 產生專案 + build App（Debug）
│   └── test.sh                 # 產生專案 + 跑 Core 單元測試（沙盒相容）
├── docs/
│   ├── SPEC.md  REVIEW.md
│   ├── tasks/                  # 任務單 T01…
│   ├── reviews/                # 每張任務單的審查紀錄
│   └── design/                 # 原型、golden 測試資料產生器
├── CLAUDE.md                   # 給 Claude（設計/審查/調度）
└── AGENTS.md                   # 給 Codex（實作規則）
```

**原則**：凡是能脫離 AppKit 測試的邏輯（設定、DSP、繪圖幾何）都放 `PulseFloatCore`；App target 只做組裝、視窗、系統整合。

---

## 4. 架構

```
            音訊來源                          分析                         呈現
 ┌──────────────────────────┐
 │ SystemAudioTap (T04)     │─ PCM ─▶ SampleRingBuffer ─▶ SpectrumAnalyzer ─┐
 │  Core Audio Process Tap  │        (SPSC, lock-free)    FFT→各頻帶 dBFS   │
 └──────────────────────────┘                                              ▼
 ┌──────────────────────────┐                                     SpectrumPipeline ─▶ SpectrumFrame ─┬─▶ 浮動視窗 renderer
 │ SimulatedSpectrum (T02)  │──────── 直接產生各頻帶 dB ─────────▶ (tilt→AGC→正規化                 └─▶ 選單列 renderer
 └──────────────────────────┘                                      →gamma→平滑→峰值)
                                    VisualizerEngine (T04, @MainActor) 每個 display frame 驅動一次
```

- **音訊執行緒**（Core Audio IOProc）只做一件事：把 PCM 降成單聲道寫進 ring buffer。不配置記憶體、不上鎖、不碰 Swift actor、不呼叫 Objective-C；IOProc block 必須是 `@Sendable` / nonisolated（見 §8）。
- **主執行緒**每個 display frame：從 ring buffer 取最新 4096 個樣本 → `SpectrumAnalyzer` → `SpectrumPipeline.process(dt:)` → 得到 `SpectrumFrame` → 交給所有 renderer。64 頻帶的分析+處理在主執行緒上成本極低（預算見 §9）。
- **沒有聲音就不動**（使用者回饋，2026-10-11）：靜音或權限被拒（tap 只送全 0）時柱子自然落回最低點，不顯示模擬動畫；0.25 秒沒有新樣本時改餵 −160 dB。`SimulatedSpectrum` 只保留給設定預覽與測試。選單顯示目前是否有聲音，並提供開啟錄音權限設定的入口。
- 每幀只有一個驅動者（App 層的 `FrameClock`，T03 建立）呼叫一次 `SpectrumSource.nextFrame(dt:)`，同一份 `SpectrumFrame` 分送給所有 renderer。

### 4.1 共用契約（T01 建立，之後所有任務共用；修改要經過設計負責人）

```swift
// PulseFloatCore/Model/SpectrumFrame.swift
// 不變式：values.count == peaks.count == bandCount；bandCount 可以是 0（renderer 必須能處理）。
public struct SpectrumFrame: Sendable, Equatable {
    public var values: [Float]   // 每個頻帶 0...1，低頻→高頻
    public var peaks: [Float]    // 每個頻帶 0...1，峰值帽位置
    public var bass: Float       // 0...1，平滑後的低頻能量（給脈動效果用）
    public init(values: [Float], peaks: [Float], bass: Float)
    public var bandCount: Int { get }
    public static func silent(bandCount: Int) -> SpectrumFrame
}

// PulseFloatCore/Model/SpectrumSource.swift
@MainActor
public protocol SpectrumSource: AnyObject {
    /// 前進 dt 秒並回傳這一幀要畫的資料。每次螢幕刷新在主執行緒呼叫一次。
    func nextFrame(dt: TimeInterval) -> SpectrumFrame
}
```

`VisualizerConfig` 見 §5。

---

## 5. 參數模型 `VisualizerConfig`

原型裡的 `DEFAULTS` 物件就是規格；Swift 端 `VisualizerConfig` 的 JSON 編碼必須和它**一模一樣**（key 名稱、巢狀結構、值），這樣原型「複製參數 JSON」的結果可以直接貼進 App。

```json
{
  "bands":   { "count": 64, "fMinHz": 30, "fMaxHz": 16000, "tiltDbPerOct": 3.0 },
  "level":   { "agc": true, "rangeDb": 54, "ceilingDb": -12, "agcReleaseDbPerSec": 6, "gamma": 1.3, "gateDb": -90 },
  "motion":  { "attackMs": 12, "releaseMs": 140, "spatial": 0.35, "peakHoldMs": 160, "peakGravity": 3.2 },
  "look":    { "theme": "bars", "palette": "aurora", "mirror": false, "reflection": true, "barGap": 0.28, "windowMode": "card", "opacity": 1.0 },
  "menubar": { "style": "bars", "count": 7, "colored": false }
}
```

| 欄位 | 型別 | 範圍（`clamped()` 用） | 說明 |
|---|---|---|---|
| bands.count | Int | 16…128，4 的倍數（四捨五入到最近的 4） | 柱數 |
| bands.fMinHz | Double | 20…120 | 最低頻率 |
| bands.fMaxHz | Double | 6000…20000，且 ≥ fMinHz×4 | 最高頻率 |
| bands.tiltDbPerOct | Double | 0…6 | 高頻補償，以 1 kHz 為零點 |
| level.agc | Bool | – | 自動增益 |
| level.rangeDb | Double | 24…84 | 動態範圍 |
| level.ceilingDb | Double | −40…0 | AGC 關閉時的固定上限 |
| level.agcReleaseDbPerSec | Double | 1…20 | AGC 回落速度 |
| level.gamma | Double | 0.6…2.4 | 對比 |
| level.gateDb | Double | −160…−30 | 低於此值（未補償前）直接歸零 |
| motion.attackMs | Double | 2…80 | 上升時間常數 |
| motion.releaseMs | Double | 40…600 | 回落時間常數 |
| motion.spatial | Double | 0…0.8 | 相鄰柱平滑 |
| motion.peakHoldMs | Double | 0…600 | 峰值停留 |
| motion.peakGravity | Double | 0.5…10 | 峰值掉落加速度（整個高度/秒²） |
| look.theme | enum | bars / radial / neon / led | 主題 |
| look.palette | enum | aurora / ember / glacier / mono | 配色 |
| look.mirror | Bool | – | 直條上下鏡像 |
| look.reflection | Bool | – | 直條倒影 |
| look.barGap | Double | 0.05…0.6 | 柱間距（佔 pitch 比例） |
| look.windowMode | enum | card / bare | 毛玻璃卡片 / 全透明（JSON 預設沿用原型的 card；**App 啟動預設 bare**） |
| look.opacity | Double | 0.3…1 | 視窗透明度 |
| menubar.style | enum | bars / dots | 選單列圖示樣式 |
| menubar.count | Int | 5…9 | 選單列柱數 |
| menubar.colored | Bool | – | 選單列使用配色（預設單色＝template image） |

**解碼要寬鬆**（對應原型的 `deepMerge`）：缺少的 key 用預設值補；不認得的 key 忽略；列舉值不認得就用該欄位預設值；數值超出範圍時保留原值（解碼不 clamp），由呼叫端決定要不要 `clamped()`。

持久化（T05）：`UserDefaults` key `pulsefloat.params.v1`，值為上面的 JSON 字串。

---

## 6. 訊號處理（T02）

所有公式以原型 `rebuildBands` / `bandsFromAnalyser` / `bandsSimulated` / `processFrame` 為準。這裡寫出 Swift 端必須保持的語意與單位。

### 6.1 頻帶切分
N = `bands.count`，f0 = `fMinHz`，f1 = `fMaxHz`：
`lo[i] = f0·(f1/f0)^(i/N)`，`hi[i] = f0·(f1/f0)^((i+1)/N)`，`fc[i] = √(lo[i]·hi[i])`。

### 6.2 頻譜分析 `SpectrumAnalyzer`
- 輸入：單聲道 Float PCM，最新 **4096** 個樣本、取樣率（通常 48 kHz）。
- **Blackman 視窗**（a0=0.42, a1=0.5, a2=0.08，與 Web Audio AnalyserNode 相同）→ 實數 FFT（vDSP）→ 幅度。
- 換算成 dBFS：**滿刻度（振幅 1.0）的正弦波、頻率落在 bin 中心時，該 bin 讀值為 0 dBFS（±0.5 dB）**。原型裡的 `+13.55` 是在補 Blackman 的 coherent gain（20·log10(0.5·0.42) ≈ −13.55）。vDSP 的實數 FFT 輸出是數學 DFT 的 2 倍，所以 Swift 端是 `dBFS = 20·log10(|Z[k]| / (0.42·N))`，**不要**把 +13.55 套在 `|Z|/N` 上（會高 6.02 dB）。細節見 T02。
- 頻帶取值：`k0 = ceil(lo/binHz)`、`k1 = floor(hi/binHz)`（k1 夾到 fftSize/2 − 1）。`k1 ≥ k0` 時取 k0…k1 的**最大值**；**否則（k1 < k0，也就是沒有任何 bin 中心落在 [lo, hi] 內）**令 `x = fc/binHz`、`k = floor(x)`、`t = x − k`，在 **dB 域**線性內插 `v = dB[k] + (dB[k+1] − dB[k])·t`（索引夾到 fftSize/2 − 1）。判斷條件是 k1 < k0，不是「頻寬 < binHz」：48 kHz / 4096、預設 64 頻帶時 band 0–13 都比一個 bin 窄，但只有 0、2、3、5、7、9 走內插，其餘各含一個 bin 中心、走最大值。非有限值一律當 −160 dB。
- `init` 之後的 `analyze` 呼叫**不得配置記憶體**（預先配置所有 buffer）。

### 6.3 處理管線 `SpectrumPipeline.process(dt:)`
依序（細節以原型 `processFrame` 為準）：
1. **高頻補償**：`d = raw + tilt·log2(fc/1000)`，記錄這一幀最大值。
2. **AGC**：開啟時，最大值高於上限就以 50 ms 時間常數追上，否則以 `agcReleaseDbPerSec` 線性下降；上限夾在 −45…+6 dB。關閉時上限 = `ceilingDb`。初始上限 −12 dB。
3. **正規化**：`floor = ceil − rangeDb`；`raw < gateDb`（用補償前的值判斷）就是 0，否則 `(d − floor)/rangeDb`，夾到 0…1，再取 `^gamma`。
4. **相鄰柱平滑**：單趟，左右鄰居用**未平滑**的值，邊界用自己。
5. `dt ≤ 0` 時到此為止（目前值、峰值、低頻能量都不動）。
6. **快上慢下**：`α = 1 − e^(−dt/τ)`，上升用 attack、下降用 release。
7. **峰值**：被推高就重置；否則停留 `peakHoldMs` 後以 `peakGravity` 加速掉落，不低於目前值。
8. **低頻能量**：fc < 150 Hz 的頻帶平均，上升 30 ms、下降 180 ms 平滑。

輸出 `SpectrumFrame(values, peaks, bass)`。管線收到的設定一律先 `clamped()`。頻帶設定（count/fMin/fMax）改變時重建頻帶，並把狀態重置成初值：rawDb −160、values/peaks/peakT/peakV 0、bass 0、ceilDb −12（原型不重置 ceil/bass，此處以規格為準）。

**Golden 測試**：`docs/design/golden/pipeline_golden.json` 由原型演算法直接產生（見同目錄 `generate-golden.mjs`），Swift 版必須在每個記錄點都吻合（絕對誤差 1e-4）。

### 6.4 模擬訊號 `SimulatedSpectrum`
原型 `bandsSimulated` 的移植（128 BPM 的 kick / 和弦 / 掃頻 / hi-hat 頻譜形狀），用在「還沒有音訊」時。雜訊項（原型的 `Math.random()`）必須可注入，測試時注入 0 以便和 golden 比對。

---

## 7. 呈現（T03）

### 7.1 繪圖共通
- Renderer 是 `PulseFloatCore` 裡的純繪圖型別，輸入 `CGContext`、尺寸（pt）、`SpectrumFrame`、`VisualizerConfig.Look`，輸出就是畫在 context 上。
- **座標系統是 y 向下、原點左上**（和原型的 canvas 相同），讓公式可以一比一移植。`VisualizerView` 用 `isFlipped = true`；測試用的 bitmap context 也先套同樣的翻轉。
- 四種主題吃同一份 `SpectrumFrame`，只差在畫法：

| 主題 | id | 原型函式 | 重點 |
|---|---|---|---|
| 經典直條 | bars | `drawBars` | 漸層直條、峰值帽、可選倒影 / 上下鏡像 |
| 圓環放射 | radial | `drawRadial` | 左右對稱半圓放射、隨 bass 脈動的中心圓盤 |
| 霓虹光暈 | neon | `drawNeon` | 殘影（上一幀往透明淡出）、`lighter` 疊加、光暈隨 bass 變大 |
| 極簡點陣 | led | `drawLed` | 頻帶重採樣成欄、點陣亮起、峰值點 |

- 配色：四組三色漸層（原型 `PALETTES`），依頻帶位置線性內插。

### 7.2 浮動視窗
- `NSPanel`：無邊框、`nonactivatingPanel`（點它不會搶走其他 App 的焦點）、`level = .floating`、`collectionBehavior` 含 `.canJoinAllSpaces`、`.fullScreenAuxiliary`，背景透明、不透明度 = `look.opacity`。未鎖定時明確設 `ignoresMouseEvents = false`，整個矩形（含透明區域）都能拖曳與觸發滑過。
- 預設 520×200 pt（長寬比 2.6:1 固定），最小 182×70。
- **card 模式**：毛玻璃（`NSVisualEffectView`，`.hudWindow`、behind-window、`.active`，用 `maskImage` 做圓角 14 讓視窗陰影形狀正確）、0.5 pt 白色 18% 內框、陰影。**bare 模式**：完全透明只剩圖形，滑過時顯示 1 pt 白色 22% 內框。
- 拖曳任一處移動；右下角 16×16 抓把縮放（維持比例、左上角固定）。
- 滑過時右上角淡入三顆 24×24 按鈕：切換主題 ◐ / 鎖定 ⌖ / 隱藏 ✕（tracking area 必須用 `.activeAlways`，因為 panel 永遠不是 key、App 永遠不 active）。
- **鎖定** = 位置固定 + 點擊穿透（`ignoresMouseEvents = true`）；鎖定後只能從選單列解除。
- **隱藏**後從選單列重新顯示。

### 7.3 選單列圖示
- 7 根柱子（`menubar.count`）的迷你頻譜，繪圖區 26×16 pt，整個 status item **寬度不超過 28 pt**（太寬會被瀏海吃掉）。
- 預設單色並設成 template image，自動適應淺色/深色選單列；`colored = true` 時用配色、不設 template。
- 最多 30 fps 更新（由 FrameClock 推送、自行節流；浮動視窗隱藏時照樣更新）。
- 點擊行為：T01 是只有「關於 PulseFloat」與「結束 PulseFloat」的選單；T03 加上臨時選單（顯示/隱藏浮動視窗、主題、視窗樣式、鎖定）；T05 換成快速面板（規格見原型的 popover）。

---

## 8. 系統音訊擷取（T04，摘要）

- 使用 Core Audio Process Tap（macOS 14.2+，已對照 SDK 標頭確認）：`CATapDescription(stereoGlobalTapButExcludeProcesses:)`（自己的 process object 用 `kAudioHardwarePropertyTranslatePIDToProcessObject` 取得；取不到就傳 `[]`）→ `AudioHardwareCreateProcessTap` → 讀 `kAudioTapPropertyFormat` 取得取樣率與格式 → `AudioHardwareCreateAggregateDevice`（`kAudioAggregateDeviceIsPrivateKey: 1`、`kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid]]`、`kAudioAggregateDeviceTapAutoStartKey`，預設輸出裝置當主子裝置）→ `AudioDeviceCreateIOProcIDWithBlock` → `AudioDeviceStart`。拆除順序相反。`muteBehavior` 保持預設（unmuted），否則使用者會聽不到聲音。
- **IOProc block**：用 `AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, block)`（queue 傳 nil，block 直接在 HAL IO 執行緒執行）。block 必須寫成 `{ @Sendable inNow, inInputData, inInputTime, outOutputData, inOutputTime in … }`，或在 `nonisolated static func` 裡建立。**禁止**在 `@MainActor` 型別的方法裡直接寫不加 `@Sendable` 的 closure literal：Swift 6 會推斷成 MainActor 隔離並插入 main queue 斷言，編譯零警告，但會在 IO 執行緒 SIGTRAP（已實測）。block 只能捕捉 Sendable 的 SPSC ring buffer（例如 `Synchronization.Atomic` 讀寫索引 + 預先配置的 `UnsafeMutablePointer<Float>`，型別標 `final class …: @unchecked Sendable` 並註明理由）。
- `Info.plist` 需要 `NSAudioCaptureUsageDescription`（T01 先放好文案）；**不需要任何 entitlement**，也不開 App Sandbox。
- **權限**：系統在第一次 `AudioDeviceStart`（aggregate 內含 tap）時跳出提示；**不能**用私有 TCC API（`TCCAccessPreflight` 等）查詢或請求。被拒時表現為靜音，走 §4 的靜音規則；選單提供「開啟系統設定 › 隱私權與安全性 › 螢幕與系統錄音」的入口，並說明授權後可能需要重新啟動 App。
- 裝置切換（耳機插拔、AirPods）、取樣率改變都要能復原；預設輸出裝置改變時重建 tap 與 aggregate device。
- **開發注意**：ad-hoc 簽章的 designated requirement 是 cdhash，每次重 build 都會變，系統錄音權限會失效（再次跳提示，或設定裡開著但只收到靜音）。實機測試前先 `tccutil reset AudioCapture com.victorhuang.PulseFloat`，並用 `open …/PulseFloat.app` 啟動（直接執行 `Contents/MacOS/PulseFloat` 會把權限記在 Terminal 上）。若要權限跨 build 保留，改用固定憑證簽章（之後再決定）。
- 詳細步驟與驗收在 T04 任務單定稿；T04 驗收必須包含沙盒外實機播放音樂至少 10 秒。

---

## 9. 效能預算

| 項目 | 預算（Apple Silicon，Debug 以外的設定量測） |
|---|---|
| `SpectrumAnalyzer` + `SpectrumPipeline`，64 頻帶 | 每幀 < 0.3 ms |
| 單一主題繪製 520×200 pt @2x | 每幀 < 2 ms |
| 整個 App 在 60 fps 播放音樂時 | CPU < 8%（T06 量測） |
| 浮動視窗隱藏、選單列也被遮住時 | 停止繪製 |

---

## 10. 任務單

| 編號 | 標題 | 依賴 | 可平行 |
|---|---|---|---|
| [T01](tasks/T01-scaffold.md) | 專案骨架與共用契約 | – | – |
| [T02](tasks/T02-dsp-core.md) | DSP 核心：頻帶、FFT、處理管線、模擬訊號 | T01 | 與 T03 平行 |
| [T03](tasks/T03-render-window.md) | 繪圖、浮動視窗、選單列迷你頻譜 | T01 | 與 T02 平行 |
| [T04](tasks/T04-audio-engine.md) | 系統音訊擷取（Process Tap）與 `LiveSpectrumSource` 整合 | T02、T03 | – |
| T05 | 快速面板、設定視窗、參數持久化、登入時啟動 | T03、T04 | – |
| T06 | 效能、省電、減少動態效果、多螢幕 | T04、T05 | – |
| T07 | 指定 App 擷取（per-process tap） | T04 | 可選 |

T04 以後的任務單在 T02/T03 通過後由設計負責人撰寫。

---

## 11. 設計參考（非規格）

- **原型**：`docs/design/prototype.html` —— 參數、手感、四種主題、快速面板的唯一視覺基準。
- **Pinterest 參考圖**（pin 1151514198493675776）：深藍太空、地球邊緣的青藍光暈、漂浮的公式與電路走線、字距拉開的等寬標題。可作為日後「HUD / 軌道」主題或 App 圖示的氣氛參考，v1 不實作。
- **Bilibili 影片**（BV1pEa66NEGA）：同一個 Linux 鎖屏，「Opus 前端 + GPT 後端、改 2 輪」對比「GPT 一次全包」。對本專案的啟示：(1) 設計先行、分工實作、經過審查迭代；(2) 互動回饋要跟輸入同步（影片是每次按鍵一個脈衝，我們是 bass 驅動脈動）；(3) 錯誤狀態要有明確但會自動恢復的視覺回饋。
