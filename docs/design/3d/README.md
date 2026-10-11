# PulseFloat 3D 主題：共用架構與工作規則

原始需求：[SPEC-3D.md](SPEC-3D.md)（使用者提供的原文）。

## 架構

```
SystemAudioTap (IO 執行緒)
  └─ SampleRingBuffer：mid = (L+R)/2、side = (L−R)/2 兩條同步軌，lock-free、不配置記憶體
LiveSpectrumSource (主執行緒，唯一的 FrameClock 每幀呼叫一次)
  ├─ SpectrumAnalyzer：唯一的一次 FFT（4096 點 Blackman）
  ├─ SpectrumPipeline：顯示頻段（AGC、閘門、attack/release、峰值）
  └─ AudioFeatureExtractor：重用同一次 FFT 的每 bin dB → AudioFeatures
       level/peak、bass/mid/treble、centroid、flux、onset/onsetEnvelope/onsetCount、
       stereoWidth/balance、energy、activity、time（音訊時鐘）
SpectrumFrame { values, peaks, bass, features }
  ├─ Core Graphics 主題（RendererFactory）
  └─ PulseFloatScene.SceneRenderer（SCNRenderer → 自己的 Metal pass）
        ├─ 即時：畫進 CAMetalLayer 的 drawable；主題靜止時整個略過（GPU 也不工作）
        └─ 離屏：測試、截圖（PulseFloatShots）、主題預覽；GPU 時間精確到該幀
```

- `SceneTheme`（`PulseFloatScene/SceneTheme.swift`）：`stage`、`scene`、`pointOfView`、`apply(_:)`、`update(frame:dt:)`、`isAtRest`。
- `SceneStage`：相機（精簡／雕塑兩組 `CameraPose`）、三點燈光、程式產生的攝影棚環境反射、雕塑模式的台座與只收陰影的透明地面、
  雕塑模式下依 `features.time` 環繞（純函數，靜音即停）、使用者拖曳／縮放偏移。
- `SceneMaterials` / `SceneLook`：由 8 種 `SculptureStyle`（+ 配色）推導主色、光色、金屬度、粗糙度、是否為亮色風格。
- `SceneSettings`：風格、配色、呈現方式（compact / sculpture）、畫質（low / medium / high）、寬高比、地形外觀（線框／曲面）。
  對應 `VisualizerConfig.Look` 的 `sculptureStyle`、`palette`、`presentation`、`quality`、`terrainSurface`（寬鬆解碼，舊設定照讀）。
- MSAA：LOW 1×、MEDIUM/HIGH 4×（`SceneRenderer.sampleCount`）。

## 主題必須遵守

1. 動畫只能由 `frame`（values / peaks / features）與 `dt` 推動；所有流動、旋轉用 `features.time`。
   禁止牆上時間、SceneKit `u_time`、`SCNParticleSystem`、`SCNAction`、`SCNAnimation`、隱式 `SCNTransaction` 動畫。
2. **靜音必須是靜止畫面**：`features.isSilent` 後內部狀態要在幾秒內收斂到固定值，之後逐像素不變，`isAtRest == true`。
3. CPU 每幀（update + SceneKit encode）目標 < 2 ms（Release）：不要每幀重建幾何或配置記憶體；
   重的運算放 shader modifier，CPU 只更新 uniform 或小貼圖（例如 64 個頻段、地形歷史）。
4. 透明背景（不設 `scene.background`）。視窗以 premultiplied alpha 疊在桌布上：純加法光在淺色桌布上看不到，
   主體需要有 alpha 的部分（深色核心、半透明面、描邊），深色與淺色桌布都要清楚。bloom 節制，只在 HIGH 使用。
5. 支援 8 種雕塑色彩、兩種呈現方式、三種畫質；寬高比固定約 2.6:1（浮動條）。

## 截圖與效能

```bash
scripts/shots.sh <輸出資料夾> --themes blackhole --styles --perf
```

Release build 的 `PulseFloatShots` 用真正的 `SceneRenderer` 與經過真實特徵引擎的合成音樂（`DemoAudio`，120 BPM，
主歌／副歌每 8 秒切換）產生：`<theme>-sheet.png`（精簡／雕塑 × 深色／淺色桌布 × 主歌、副歌拍點、靜音）、
`<theme>-styles.png`（8 種風格）、`perf.json` 與 `report.md`（CPU update、CPU encode、GPU 的中位數與 p95，
以及靜音時的 CPU）。

## 測試

`scripts/test.sh` 跑 Core 與 Scene 兩組測試；`PulseFloatSceneTests/SceneRendererTests.swift` 是三個主題共同的契約測試
（畫得出東西、靜音逐像素靜止且回報 isAtRest、所有風格／畫質／呈現方式可套用、異常 frame 安全、CPU 上限）。
