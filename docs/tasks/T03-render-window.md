# T03 繪圖、浮動視窗、選單列迷你頻譜

| 項目 | 內容 |
|---|---|
| 依賴 | T01（`VisualizerConfig`、`SpectrumFrame`、`SpectrumSource`、App 骨架） |
| 分支 | `task/T03-render-window`（從 `task/T01-scaffold` 開，獨立 worktree） |
| 平行 | 與 T02 同時進行；**不得**修改 T02 範圍內的檔案 |
| 實作 | Codex |
| 審查 | Claude，依 `docs/REVIEW.md` |

## 目標

做出「看得到、摸得到」的 PulseFloat：四種主題的繪圖、浮動視窗（毛玻璃/透明、拖曳、縮放、鎖定穿透、隱藏）、選單列 7 柱迷你頻譜。資料先由一個**預覽訊號源**驅動（T04 才接真正的音訊與 DSP）。

規格：`docs/SPEC.md` §7。視覺基準：`docs/design/prototype.html` 的 `drawBars`、`drawRadial`、`drawNeon`、`drawLed`、`drawMenu`、`PALETTES`、主迴圈 `frame()`、`.float` / `.hud` / `.grip` 的 CSS。

## 範圍（只能新增/修改這些路徑）

- `PulseFloatCore/Render/**`、`PulseFloatCore/Preview/**`
- `PulseFloatCoreTests/Render/**`
- `PulseFloat/Window/**`、`PulseFloat/MenuBar/**`
- `PulseFloat/App/AppDelegate.swift`（只做組裝：建立 FrameClock、預覽訊號源、浮動視窗，交給 status item）

不要動 `project.yml`、`Config/`、`Model/`、`DSP/`、`docs/`。如果真的需要改共用契約，停下來在回報裡說明，不要自己改。

### 與 T02 共用 module 的規則（避免之後合併時編譯失敗）

`PulseFloatCore` 與 `PulseFloatCoreTests` 是 T02/T03 共用的 module，兩邊看不到彼此的程式碼：
1. 檔名用具體型別名（`Palette.swift`、`BarsRenderer.swift`…；其他檔案加 `Render` / `Preview` 前綴）。禁止 `Math.swift`、`Extensions.swift`、`Helpers.swift`、`Utilities.swift`、`TestHelpers.swift` 這類通用檔名。
2. 不得對 `Float`/`Double`/`CGFloat`/`Comparable`/`Array`/`SpectrumFrame`/`VisualizerConfig` 新增 internal 或 public 的 extension 成員，也不得新增頂層函式。helper 一律 `private`/`fileprivate`，或放進自己的命名空間：`enum RenderMath`、測試用 `enum RenderTestSupport`。

## 要做的事

### 1. 配色（`PulseFloatCore/Render/Palette.swift`）
- 四組三色漸層，色碼照原型 `PALETTES`：aurora `#21e6c1 → #3a9bff → #a35cff`、ember `#ffd23f → #ff6b35 → #ff2d87`、glacier `#eaf7ff → #8fd3ff → #4c6fff`、mono `#ffffff → #d5dae5 → #98a1b4`。
- `color(at t: Double) -> RGB`（0…1，超出夾住），照原型 `palAt`：兩段線性內插、各通道 `.rounded()` 到整數 0…255。另提供轉 `CGColor`（sRGB）的方法。
- 頻帶顏色可快取（原型 `bandColors`），快取 key = palette + band 數。

### 2. Renderer（`PulseFloatCore/Render/`）
- 協定（名稱可調整，但要寫文件註解）：
  ```swift
  public protocol SpectrumRenderer: AnyObject {
      /// size 單位為 pt；context 已是 y 向下座標、已套用 backing scale。
      func draw(in context: CGContext, size: CGSize, frame: SpectrumFrame,
                look: VisualizerConfig.Look, options: RenderOptions)
  }
  public struct RenderOptions: Sendable {
      public var isThumbnail: Bool
      /// neon 殘影淡出量 0…1 = 1 − exp(−dt / 0.07)（原型 frame()），由呼叫端用夾過的 dt 計算
      public var fade: Double
      /// 點 → 像素倍率；view 傳 window.backingScaleFactor，測試傳 1 或 2
      public var scale: CGFloat
      public init(isThumbnail: Bool = false, fade: Double, scale: CGFloat = 1)
  }
  ```
- 四個實作：`BarsRenderer`、`RadialRenderer`、`NeonRenderer`、`LedRenderer`，加上 `MenuBarRenderer`（輸入 `VisualizerConfig.MenuBar` 與 palette）。`RendererFactory.make(theme: ThemeID) -> SpectrumRenderer`。
- 幾何、比例、透明度、線寬、陰影值一律照原型對應函式移植（`small` → `isThumbnail`）。只允許 Canvas 2D ↔ Core Graphics 的 API 對應差異：
  - `globalCompositeOperation = "lighter"` → `CGBlendMode.plusLighter`
  - `destination-out` 淡出 → `CGBlendMode.destinationOut` 填半透明黑
  - `shadowBlur`/`shadowColor` → `setShadow(offset: .zero, blur:, color:)`（數值照抄即可；neon 例外，見下方光暈 pass）
  - `roundRect` → `CGPath(roundedRect:…)`，半徑夾在寬高一半以內
- `bandCount == 0`，或 values/peaks 長度不一致時：只清空、不畫柱、不 crash。
- **NeonRenderer 的殘影與光暈**（第 1 輪審查後修訂）：
  - **trail**（殘影）：renderer 自己持有一張 offscreen bitmap，每幀先 `destinationOut` 淡出再疊加，最後畫回目標 context。用 **16-bit half-float**：`bitsPerComponent: 16`、色彩空間 **`CGColorSpace(name: CGColorSpace.sRGB)`**（不要用 extendedSRGB：float context 的 plusLighter 不夾顏色，extendedSRGB 在 P3 螢幕上會爆白）、`bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue`。8-bit 會讓 destinationOut 卡在 alpha 2/255，留下永久殘影。
  - 大小 = `ceil(size.width·scale) × ceil(size.height·scale)` px；建立後套 `translateBy(x: 0, y: hPx)` + `scaleBy(x: scale, y: −scale)`（y 向下、單位 pt）；size 或 scale 改變就重建。
  - 合成回目標時**必須局部翻回**：`ctx.saveGState(); ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1); ctx.draw(image, in: CGRect(origin: .zero, size: size)); ctx.restoreGState()`。直接 `draw(_:in:)` 到 y 向下的 context 會上下顛倒。
  - 不要從 `context.ctm` 推算 scale（layer-backed view 的 `draw(_:)` 裡是 identity），一律用 `options.scale`。
  - **光暈不用逐線 `setShadow`**（64 次陰影模糊 ≈ 14 ms／幀）。改用每幀一次的低解析度光暈 pass：glow buffer（8-bit premultiplied sRGB，`ceil(wPx/d) × ceil(hPx/d)`，`d = isThumbnail ? 1 : 4`）清空 → 以相同幾何（縮放 1/d）`plusLighter` 畫所有線段（不加陰影）→ `vImageTentConvolve_ARGB8888` 模糊（buffer 預先配置；σ_full = blur/2、blur = isThumbnail ? 3 : 14 + 10·bass（裝置像素）、σ_q = σ_full/d、tent 寬 W = 2b − 1、b = max(2, round(sqrt(6·σ_q² + 1)))）→ 以 `plusLighter`、`interpolationQuality = .medium` 放大畫進 trail → 再以 `plusLighter` 畫線段本體 → 水平線照舊。
  - 效能：Release、520×200 pt @2x、全 1 frame ≤ 2 ms。
- `RadialRenderer` 的中心圓盤：v1 不放專輯封面，照原型畫深色圓 + 漸層外框 + 隨 bass 變化的內圈。

### 3. 預覽訊號源（`PulseFloatCore/Preview/PreviewSpectrumSource.swift`）
- `@MainActor public final class PreviewSpectrumSource: SpectrumSource`。
- 產生**看起來像音樂**的 `SpectrumFrame`：128 BPM 的低頻脈衝 + 2～3 個緩慢移動的高斯峰 + 往高頻遞減的底，values 0…1，peaks 用簡單的停留 + 掉落，bass 跟著脈衝。
- **決定性**：同樣的 dt 序列 → 同樣的輸出（不要用 `random`，或用可注入的種子）。
- 這是開發用暫代品；T04 會換成真正的 `VisualizerEngine`。檔案頂端註解寫明。

### 4. 驅動、浮動視窗（`PulseFloat/Window/`）

**FrameClock（App 內唯一的 tick 來源）** — `Window/FrameClock.swift`，`@MainActor final class`：
- 用 `(NSScreen.main ?? NSScreen.screens.first)?.displayLink(target:selector:)` 建 `CADisplayLink`，設 `preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)`，**必須** `add(to: .main, forMode: .common)`（不加不會觸發）。link 會 retain target，`stop()` 時 `invalidate()`。
- 每個 callback：`dt = link.targetTimestamp − 上一次的 targetTimestamp`，第一幀 dt = 0，夾在 0…0.05 s；**只呼叫一次** `source.nextFrame(dt:)`，把同一個 `SpectrumFrame` 推給浮動視窗（`VisualizerView.show(frame:dt:)`，視窗可見時存起來並 `needsDisplay = true`）與 `StatusItemController`（自行節流）。
- `VisualizerView` 與 `StatusItemController` 都**不得**自己呼叫 `nextFrame`，也不要用 `NSView.displayLink`（視窗 orderOut 後就不觸發，選單列會跟著停）。

**FloatingPanel: NSPanel**：
- `styleMask: [.borderless, .nonactivatingPanel]`、`level = .floating`、`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`、`isOpaque = false`、`backgroundColor = .clear`、`hidesOnDeactivate = false`（NSPanel 預設是 true）、`isMovableByWindowBackground = true`（鎖定時 false）。
- `canBecomeKey` 回傳 false（不搶焦點；HUD 按鈕仍可點，已實測）。
- **`ignoresMouseEvents = false` 要明確設定**：沒設時透明像素的點擊會穿透到後面的視窗（bare 模式只能抓著柱子拖、滑過時 HUD 不出現）。鎖定 → `true`；解除鎖定 → 明確設回 `false`。
- 預設 520×200 pt，最小 **182×70**（= 70 × 2.6，比例固定 2.6:1）。`contentAspectRatio` / `minSize` 對程式呼叫的 `setFrame` 無效、borderless 也沒有系統縮放，所以比例與最小值由抓把自己算。
- 初始位置（AppKit 座標 y 向上）：`vf` = 主螢幕 `visibleFrame`（用 guard 取，不要 force unwrap）；`origin.x = vf.minX + 0.08·vf.width`、`origin.y = vf.maxY − 0.40·vf.height − 200`（視窗上緣在可視區由上往下 40%）。
- `alphaValue = look.opacity`。

**VisualizerView: NSView**：`isFlipped = true`、`wantsLayer = true`；在 `draw(_:)` 用目前的 renderer 畫最新 frame，`RenderOptions.scale = window?.backingScaleFactor ?? 2`、`fade = 1 − exp(−dt/0.07)`。切換主題時清掉舊畫面（neon 重建 offscreen）。

**card / bare 模式**：
- card：`NSVisualEffectView`（`.hudWindow`、`.behindWindow`、`.active`——panel 永遠不是 key，不能用 followsWindowActiveState）當 panel 的 `contentView`。圓角用 `maskImage`：29×29 的 `NSImage(size:flipped:drawingHandler:)` 畫半徑 14 的實心圓角矩形，`capInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)`、`resizingMode = .stretch`（這樣 window 陰影形狀才正確）。上面疊 rgba(14,16,24,0.42) 色層、0.5 pt 白色 18% 內框，VisualizerView 是子 view（各自 `layer.cornerRadius = 14`、`masksToBounds = true`）。`hasShadow = true`。
- bare：contentView 換成透明的普通 NSView（VisualizerView 搬過去），`hasShadow = false`；滑鼠滑過時畫 1 pt 白色 22% 內框。
- 切換模式與縮放結束後呼叫 `invalidateShadow()`。

**滑鼠追蹤**：在 `updateTrackingAreas()` 重建 `NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)`。**必須用 `.activeAlways`**：這個 panel 永遠不是 key window、App 永遠不會 active，`.activeInKeyWindow` / `.activeInActiveApp` 都不會觸發。滑入淡入 HUD（0.18 s，`NSAnimationContext` + `animator().alphaValue`），滑出淡出。

**HUD**：右上角（內縮 8 pt）三顆 24×24 按鈕：◐ 切換主題（依 `ThemeID.allCases` 循環）、⌖ 鎖定、✕ 隱藏。外觀照原型 `.hud button`（圓角 6、rgba(0,0,0,.45) 底、白 14% 框；鎖定按鈕按下狀態用 amber `#ffb547`）。

**ResizeGripView**（16×16，右下角內縮 2 pt）：
- `override var mouseDownCanMoveWindow: Bool { false }`（否則 `isMovableByWindowBackground` 會把拖曳當成移動視窗）。
- `mouseDown` 記下 `NSEvent.mouseLocation`（螢幕座標）與 `window.frame`；`mouseDragged`：`w = max(182, startFrame.width + (NSEvent.mouseLocation.x − startLoc.x))`、`h = w / 2.6`，**左上角固定**：`window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY − h, width: w, height: h), display: true)`。不要用 `locationInWindow`（視窗原點在動，會抖）。
- 鎖定時 `isHidden = true`。

**FloatingPanelController**（`@MainActor`）：建立 panel、持有目前的 `VisualizerConfig`（一律經過 `clamped()` 再交給 renderer）、提供切換主題 / 視窗樣式 / 鎖定 / 顯示隱藏的方法給 status item 與 HUD 呼叫。設定**只存在記憶體**（持久化是 T05）。

### 5. 選單列迷你頻譜（`PulseFloat/MenuBar/`）
- 擴充 T01 的 `StatusItemController`：圖示改由 `MenuBarRenderer` 畫成 `NSImage`（26×16 pt，用 `button.window?.backingScaleFactor` 決定 bitmap 倍率），預設 `isTemplate = true`；`colored = true` 時用配色且 `isTemplate = false`。
- `NSStatusBar.system.statusItem(withLength: 28)`（固定寬度，不用 variableLength）。
- 由 FrameClock 推送 frame，自己節流到 ≤ 30 fps（累積 dt ≥ 1/30 s 才重畫）；浮動視窗隱藏時 FrameClock 照常運作，選單列繼續動。
- 暫時的選單（T05 會換成快速面板）：
  - 顯示浮動視窗 ✓（切換）
  - 主題 ▸（四個主題，打勾目前的）
  - 視窗樣式 ▸（毛玻璃卡片 / 透明）
  - 鎖定並點擊穿透 ✓（切換）
  - 分隔線、關於 PulseFloat、結束 PulseFloat ⌘Q（沿用 T01 行為）

### 6. 測試（`PulseFloatCoreTests/Render/`）

定義：bitmap 用 `CGContext(data: nil, width:, height:, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: premultipliedLast)`，先 `translateBy(0, h)` + `scaleBy(1, -1)` 變成 y 向下再畫。「可見像素」= alpha > 0 的像素；「總 alpha」= 所有像素 alpha 的總和。

1. **Palette**：aurora `t=0` = (33,230,193)、`t=0.5` = (58,155,255)、`t=1` = (163,92,255)、`t=0.25` = (46,193,224)；`t<0`、`t>1` 夾住；其他三組各驗兩端。
2. 每個主題（正常與 thumbnail）用 320×120、scale 1 畫：
   - 全 1 的 frame（values = peaks = 1、bass = 1）→ 可見像素比例 > 10%。
   - bars：`silent` frame 且 `reflection = false` → 可見像素比例 < 5%（只有最矮的柱與峰值帽）。
   - 邊界：四周 2 px 邊框內沒有可見像素。例外：radial 在全 1 frame 時放射線依原型會超出上下邊（r0+3+len ≈ 0.494·m+3 > m/2），所以 radial 的全 1 frame 只檢查左右；上下邊界另用 values = peaks = bass = 0.5 的 frame 檢查。neon 的光暈可放寬（測試裡寫明放寬多少）。
   - `silent(bandCount: 0)` 不 crash。
3. **bars 幾何**：64 頻帶、barGap 0.28、寬 320 → padX 16、pitch 4.5、bw 3.24，第一根柱子 x ∈ [16.63, 19.87]（在 y 中段取樣驗證該範圍內有像素、範圍外左側沒有）。
4. **neon 殘影**：fade = 1 − e^(−(1/60)/0.07)。B = 新的 NeonRenderer 連畫 60 幀 silent 後的總 alpha（silent 仍會畫最短的線、光暈與水平線，所以 B > 0）。另一個 renderer 先畫 1 幀全 1、再畫 silent：第 2 幀總 alpha < 第 1 幀且 > 1.5·B（有殘影）；第 60 幀與 B 相差 ≤ 1%·B（殘影消失）。
5. **neon 方向**：畫全 1 frame，mid（h/2）以上的可見像素數 > mid 以下（線段是 mid−L 到 mid+0.55L，用來抓上下顛倒）。
6. **neon scale**：scale 2 時 offscreen 的像素尺寸是 scale 1 的 2 倍（透過可測的屬性或在 2× bitmap 上畫出的可見像素數約為 4 倍，容許 ±20%）。
7. **MenuBarRenderer**：7 根、26×16 pt；全 1 → 7 根都是滿高；template 模式：每個 alpha > 0 的像素 R == G == B（灰階；不要跨像素比較預乘值）。
8. **PreviewSpectrumSource**：兩個實例餵相同 dt 序列，輸出完全相同；values / peaks 都在 0…1，peaks ≥ values（容許 1e-6）。

## 驗收標準

1. `scripts/test.sh` 通過；零警告（定義見 `docs/REVIEW.md`）。
2. 審查者實機檢查：
   - 啟動後浮動視窗出現在預設位置，四種主題都正常動畫，切換主題沒有殘留畫面（neon 殘影會在約 0.3 s 內消失）。
   - card / bare 兩種模式外觀符合規格；bare 模式在柱子之間的空隙也能拖曳、滑過時 HUD 會出現。
   - 拖曳移動、右下角縮放（維持比例、左上角固定、不小於 182×70）、HUD 淡入淡出正常。
   - 鎖定後點擊會穿透到後面的視窗；從選單列可解除。
   - 隱藏後選單列迷你頻譜繼續動，從選單列可再顯示；視窗顯示/隱藏時，選單列的 128 BPM 脈衝速度相同。
   - 點浮動視窗不會讓其他 App 失去焦點。
   - 淺色與深色選單列下，單色圖示都清楚。
3. 主執行緒上單一主題每幀繪製 < 2 ms（Release）——審查者抽查；Debug 下不要明顯卡頓。
4. `PulseFloatCore` 仍然沒有 import AppKit/SwiftUI。
5. 遵守「與 T02 共用 module 的規則」。
6. 只動了「範圍」列出的路徑。

## 不要做

- 不要碰 Core Audio、DSP 管線（T02/T04）。
- 不要做快速面板（popover）、設定視窗、持久化、登入時啟動（T05）。
- 不要 commit。
