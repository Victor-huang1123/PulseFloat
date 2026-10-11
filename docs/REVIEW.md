# 審查準則

審查者：Claude（設計負責人）。對象：Codex 依任務單完成的變更（尚未 commit 的工作目錄）。
每一輪審查都寫一份紀錄到 `docs/reviews/<任務編號>.md`（同一張單的多輪附加在同一個檔案）。

---

## 1. 審查流程

1. **看變更範圍**
   `git status --porcelain`、`git add -A -N && git diff --stat`、`git diff`。
   任何不在任務單「範圍」內的檔案 → 直接列為 blocker（除非是工具自動產生且已被 `.gitignore` 排除）。
2. **自己跑驗證**（不採信 Codex 的回報）
   - `scripts/test.sh`
   - **零警告**（全專案唯一定義）：`rm -rf build/DerivedData && scripts/build.sh 2>&1 | tee build/build.log`，`grep -E "warning:" build/build.log` 必須為空。一定要乾淨 build：增量 build 不會重印 ld/actool 的警告。（build.sh 用 `-quiet`，所以 Xcode 自己的 appintentsmetadataprocessor 雜訊不會出現。）
   - 沙盒外完整測試：`xcodebuild test -scheme PulseFloat -destination 'platform=macOS' -derivedDataPath build/DerivedData`
   - 任務單要求的實機檢查（用 `open build/DerivedData/Build/Products/Debug/PulseFloat.app` 啟動、截圖、操作）
   - **平行任務**（T02/T03 這類共用 module 的任務）：第二張要 PASS 之前，在暫存分支試合併另一張（`git merge --no-commit --no-ff`），跑 `scripts/test.sh` 與 `scripts/build.sh`，確認沒有檔名或宣告衝突，之後 `git merge --abort` 並刪掉暫存分支。
3. **逐條對照任務單的「要做的事」與「驗收標準」**，每一條標 ✅ / ❌ / ⚠️。
4. **程式碼品質檢查**（§2）。
5. **下結論**（§3）並寫紀錄。

## 2. 檢查清單

### 正確性
- [ ] 行為符合 `docs/SPEC.md` 與任務單；SPEC 沒寫的細節符合 `docs/design/prototype.html`。
- [ ] 邊界條件：空陣列、band 數改變、`dt = 0`、極大 `dt`、尺寸為 0 或極小的 view。
- [ ] 數值：沒有 NaN / Inf 流到輸出；除法有防護；`log` 的參數 > 0。

### Swift 6 與並行
- [ ] 零警告（含 concurrency 警告）。
- [ ] `@MainActor` 標在 UI 與 `SpectrumSource` 相關型別；DSP 型別不綁 actor。
- [ ] `@unchecked Sendable`、`nonisolated(unsafe)` 每一處都有註解說明為何安全。
- [ ] 沒有 `DispatchQueue.main.sync`、沒有在主執行緒做阻塞 I/O。

### 即時音訊安全（DSP 與之後的音訊路徑）
- [ ] 熱路徑不配置記憶體：`analyze` 與 IOProc 完全不配置；`process` 只允許建立回傳 `SpectrumFrame` 的 values/peaks 兩個陣列。檢查迴圈內沒有建立陣列、`map`/`filter`/`reduce`、字串插值、`print`、會配置的 closure。
- [ ] IOProc block 是 `@Sendable` / nonisolated，沒有在 `@MainActor` 方法裡直接寫 closure literal（SPEC §8）。
- [ ] 熱路徑不上鎖、不呼叫 Objective-C / Swift runtime 的重型操作、不碰 actor。

### AppKit / 視窗
- [ ] 浮動視窗不搶焦點（`nonactivatingPanel`、`canBecomeKey == false`）。
- [ ] display link 在視窗隱藏時停止；沒有 retain cycle（target/selector、closure 捕獲用 `weak`）。
- [ ] 座標系統：renderer 假設 y 向下，view 端有對應的 `isFlipped`。

### 程式碼衛生
- [ ] 非測試程式碼沒有 force unwrap、`try!`、`fatalError`（`init(coder:)` 這類 AppKit 必要的 unavailable 除外）。
- [ ] `PulseFloatCore` 不 import AppKit / SwiftUI。
- [ ] public API 有文件註解；命名與 SPEC 用語一致。
- [ ] 沒有無關的重新排版、沒有遺留的除錯輸出、沒有註解掉的程式碼。
- [ ] 沒有新增第三方相依、沒有使用私有 API。
- [ ] 平行任務遵守任務單的「共用 module 規則」（沒有通用檔名、沒有對共用型別加 internal/public extension 或頂層函式）。

### 測試
- [ ] 任務單列出的每一個測試都存在，而且**真的會失敗**（斷言有意義，不是 `XCTAssertTrue(true)`）。
- [ ] 數值測試有寫出容許誤差與理由。
- [ ] 測試不依賴執行順序、不依賴網路、不讀取 repo 外的檔案。

## 3. 結論與嚴重度

| 嚴重度 | 定義 | 處理 |
|---|---|---|
| **blocker** | 驗收標準未達、build/test 失敗、超出範圍、即時安全或並行錯誤、資料錯誤 | 必須修 |
| **major** | 和 SPEC/原型明顯不符、缺測試、可預見的 bug、可維護性重大問題 | 必須修 |
| **minor** | 小的不一致、命名、可讀性 | 審查者決定這輪要不要修；不修就記到後續任務 |
| **nit** | 風格偏好 | 不要求修 |

- **PASS**：沒有 blocker / major，所有驗收標準 ✅。
- **REVISE**：有任何 blocker 或 major。退回時每一條都要寫：編號、嚴重度、檔案:行號、問題、期望的修法或驗收方式。
- 同一張單最多退回 **3 輪**；第 3 輪仍未通過 → 停下來向使用者報告，由使用者決定。

## 4. 紀錄格式（`docs/reviews/Txx.md`）

```markdown
# Txx 審查紀錄

## 第 N 輪 — PASS / REVISE（YYYY-MM-DD）

**驗證**
- scripts/test.sh：✅ N tests passed
- scripts/build.sh：✅ 0 warnings
- xcodebuild test（沙盒外）：✅
- 實機檢查：✅ / ❌ 說明

**驗收標準**
1. ✅ …
2. ❌ …

**問題**
1. [blocker] `path/File.swift:42` — 問題描述。期望：…
2. [minor] …

**結論**：…
```
