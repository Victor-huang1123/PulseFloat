# T04 系統音訊擷取與 LiveSpectrumSource 整合

| 項目 | 內容 |
|---|---|
| 依賴 | T02（DSP）、T03（繪圖、FrameClock） |
| 分支 | `task/T04-audio-engine`（從 `task/T03-render-window` 開，合併 `task/T02-dsp-core`） |
| 實作 | Claude（使用者指定，不交給 Codex；簡化流程） |

## 範圍

- `PulseFloatCore/Audio/SampleRingBuffer.swift` — SPSC lock-free 單聲道環形緩衝（`Synchronization.Atomic`），寫入端零配置；讀取端只複製最新 N 個樣本，保留 capacity/4 邊帶給寫入中的區塊。
- `PulseFloatCore/Audio/LiveSpectrumSource.swift` — `SpectrumSource` 實作：ring → `SpectrumAnalyzer` → `SpectrumPipeline`。沒有聲音時柱子落回最低點、不顯示模擬動畫（使用者回饋後修訂）；0.25 秒沒有新樣本時改餵 −160 dB；`mode`（live／silent，2 秒判定）只用於選單提示。
- `PulseFloat/Audio/SystemAudioTap.swift` — Core Audio Process Tap（SPEC §8）：全系統排除自己 → 私有 aggregate device（預設輸出為主子裝置、drift compensation）→ IOProc（nonisolated 建立、零配置、不用 for…in）→ 啟動；監聽預設輸出裝置改變並重建；失敗時記錄並維持模擬訊號。
- `PulseFloat/App/AppDelegate.swift` — FrameClock 改用 `LiveSpectrumSource`；結束時停止 tap。
- `PulseFloat/MenuBar/StatusItemController.swift` — 選單加入「音訊來源」狀態列與「開啟『螢幕與系統錄音』設定…」。
- 測試：`PulseFloatCoreTests/Audio/`（ring buffer 10 項、LiveSpectrumSource 7 項）。

## 驗收

1. `scripts/build.sh` 零警告、`scripts/test.sh` 全過。
2. IOProc 路徑在 Debug 建置下每次回呼 0 次堆積配置。
3. 實機：第一次啟動跳出系統錄音權限提示；允許並播放音樂後，選單顯示「音訊來源：系統音訊（播放中）」，頻譜跟著音樂動；暫停後柱子落下、不再跳動。
4. 切換輸出裝置（例如耳機／喇叭）後仍持續擷取。

## 已知限制（留給 T05/T06）

- 同一裝置的取樣率在執行中被改動時不會重建（換裝置會）。
- ad-hoc 簽章每次重 build 權限會失效（SPEC §8 開發注意）。
- 設定（頻帶數等）尚未接到 UI，`LiveSpectrumSource.setConfig` 已備好。
