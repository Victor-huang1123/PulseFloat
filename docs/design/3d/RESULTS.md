# 3D 主題整合結果（協調者驗收，2026-10-12）

三個主題由三個平行 worktree 實作、各自審查一次後合併到 `task/T06-3d-themes`；整合時協調者另外調整了黑洞
（射束側的高光不再截成整片純白、精簡模式的粒子流減少、外圈塵帶在淺色桌布上不再像灰色污漬、雕塑鏡頭退後讓外環完整入鏡）
以及 `SceneStage.apply(shadows:)`（自己發光的黑洞、粒子球不再跑空的陰影 pass）。

## 效能（Release，`scripts/shots.sh --perf`，1040×400 px 離屏，中位數 / p95，毫秒）

CPU = 主執行緒上的主題 update + SceneKit encode；GPU = command buffer 的 gpuEndTime − gpuStartTime（分開量，互不代表）。
靜音時主題回報靜止，即時畫面整個略過繪製（CPU update ≈ 0、GPU 0）。量測時機器上沒有其他代理在跑。

| theme | quality | presentation | CPU update | CPU encode | CPU total | GPU | silent CPU |
|---|---|---|---|---|---|---|---|
| blackhole | low | compact | 0.02 / 0.03 | 0.18 / 0.26 | 0.21 / 0.29 | 0.14 / 0.30 | 0.00 |
| blackhole | low | sculpture | 0.02 / 0.03 | 0.19 / 0.23 | 0.21 / 0.25 | 0.17 / 0.38 | 0.00 |
| blackhole | medium | compact | 0.02 / 0.03 | 0.18 / 0.24 | 0.21 / 0.26 | 0.40 / 0.58 | 0.00 |
| blackhole | medium | sculpture | 0.02 / 0.03 | 0.20 / 0.25 | 0.22 / 0.27 | 0.51 / 0.56 | 0.00 |
| blackhole | high | compact | 0.02 / 0.03 | 0.21 / 0.30 | 0.24 / 0.33 | 0.67 / 0.98 | 0.00 |
| blackhole | high | sculpture | 0.02 / 0.03 | 0.23 / 0.29 | 0.25 / 0.32 | 0.91 / 1.25 | 0.00 || particles | low | compact | 0.01 / 0.01 | 0.08 / 0.10 | 0.09 / 0.11 | 0.03 / 0.17 | 0.00 |
| particles | low | sculpture | 0.01 / 0.01 | 0.10 / 0.16 | 0.11 / 0.22 | 0.04 / 0.14 | 0.00 |
| particles | medium | compact | 0.01 / 0.01 | 0.09 / 0.10 | 0.10 / 0.11 | 0.08 / 0.16 | 0.00 |
| particles | medium | sculpture | 0.01 / 0.02 | 0.10 / 0.13 | 0.11 / 0.15 | 0.13 / 0.34 | 0.00 |
| particles | high | compact | 0.01 / 0.01 | 0.10 / 0.12 | 0.11 / 0.13 | 0.23 / 0.53 | 0.00 |
| particles | high | sculpture | 0.01 / 0.01 | 0.11 / 0.13 | 0.12 / 0.14 | 0.38 / 0.42 | 0.00 |
| terrain | low | compact | 0.00 / 0.00 | 0.01 / 0.02 | 0.02 / 0.03 | 0.06 / 0.14 | 0.00 |
| terrain | low | sculpture | 0.00 / 0.00 | 0.02 / 0.02 | 0.02 / 0.03 | 0.05 / 0.12 | 0.00 |
| terrain | medium | compact | 0.00 / 0.00 | 0.01 / 0.02 | 0.02 / 0.03 | 0.09 / 0.19 | 0.00 |
| terrain | medium | sculpture | 0.00 / 0.01 | 0.03 / 0.04 | 0.04 / 0.05 | 0.12 / 0.30 | 0.00 |
| terrain | high | compact | 0.01 / 0.01 | 0.01 / 0.02 | 0.02 / 0.03 | 0.14 / 0.45 | 0.00 |
| terrain | high | sculpture | 0.01 / 0.01 | 0.03 / 0.04 | 0.04 / 0.05 | 0.21 / 0.39 | 0.00 |
預算：CPU 目標 < 2 ms／幀 → 三個主題在所有畫質都 ≤ 0.25 ms。GPU 最重的是黑洞 HIGH 雕塑約 0.9 ms（1040×400）；
Retina 全尺寸視窗的 GPU 成本大致與像素數成正比。

## 驗證

- `scripts/test.sh`：PulseFloatCoreTests 167、PulseFloatSceneTests 44，全部通過；`scripts/build.sh` 零警告。
- 每個主題 × 兩種呈現方式：靜音 4 秒後兩幀逐像素相同、`isAtRest == true`（契約測試＋截圖工具雙重確認）。
- 截圖：`blackhole/`、`particles/`、`terrain/` 資料夾（真正的 SceneRenderer 輸出，深色／淺色桌布 × 精簡／雕塑 × 主歌／副歌拍點／靜音，及 8 種風格）。
