# AGENTS.md — 給 Codex 的實作規則

你負責實作。設計與審查由 Claude 負責；你的工作會被逐行審查並實際執行驗證。

## 開始前

1. 讀 `docs/SPEC.md`（產品與技術規格）和指派給你的任務單 `docs/tasks/Txx-*.md`。
2. 任務單的「範圍」是硬性限制：**只能新增/修改範圍內列出的路徑**。需要動範圍外的檔案時，不要動，在最後回報裡說明原因。
3. SPEC 沒寫到的細節，以 `docs/design/prototype.html` 的行為為準。
4. 任務單與 SPEC 衝突時以任務單為準，並在回報的「假設與偏離」指出衝突處。
5. 不確定時選最單純、最符合 SPEC 的做法，並在回報裡標註你的假設。
6. 任務單如果有「共用 module 的規則」（平行任務），檔名與 extension 的限制一定要遵守——另一個任務正在同一個 module 裡同時開發，你看不到它的程式碼。

## 程式規範

- Swift 6 語言模式、strict concurrency complete、**警告視為錯誤**。
- UI 與 `SpectrumSource` 相關型別標 `@MainActor`；DSP 型別不綁 actor。
- `@unchecked Sendable`、`nonisolated(unsafe)` 只在必要時用，每一處加註解說明為何安全。
- 非測試程式碼禁止 force unwrap、`try!`、`fatalError`（AppKit 要求的 `init(coder:)` 例外）。
- `PulseFloatCore` 不能 import AppKit 或 SwiftUI。
- DSP 熱路徑在初始化後的配置限制：`analyze`（與之後的 IOProc）**完全不配置記憶體**；`process` 只允許建立回傳 `SpectrumFrame` 的 values/peaks 兩個陣列。迴圈內不建立陣列、不用 `map`/`filter`/`reduce`、不做字串插值、不 `print`。
- public API 都要有 `///` 文件註解（單位、範圍、執行緒假設）。
- 不加第三方套件、不用私有 API、不改 `project.yml`（除非任務單允許）。
- 不重新排版無關的程式碼，不留下除錯輸出或註解掉的程式碼。
- 註解與 UI 字串可用繁體中文；識別字用英文。

## 驗證（沙盒內可用的指令）

```bash
scripts/test.sh     # xcodegen generate + build-for-testing + xcrun xctest
scripts/build.sh    # xcodegen generate + build App，必須零警告
```

- **不要**跑 `xcodebuild test`：沙盒會擋 `testmanagerd`，一定失敗；審查者會在沙盒外跑。
- 一律使用 `-derivedDataPath build/DerivedData`（沙盒不能寫 `~/Library`）。
- 兩個腳本都必須通過才算完成。如果因為環境問題跑不起來，照實回報錯誤訊息，不要假裝通過。

## 版本控制

- **不要 commit、不要建立或切換分支、不要改 git 設定**。審查者會 commit。
- `*.xcodeproj` 與 `build/` 已被 `.gitignore` 排除，不要加進去。

## 最後回報格式

完成後的最後一則訊息用這個格式（繁體中文）：

```
## 摘要
（2～4 句，做了什麼）

## 變更檔案
- path/to/File.swift — 一句話說明

## 驗證
- scripts/test.sh：結果（貼最後幾行）
- scripts/build.sh：結果（警告數）

## 假設與偏離
- （SPEC/任務單沒寫清楚、你自己做的決定；或沒做到的項目與原因）

## 給審查者的注意事項
- （需要特別看的地方、已知限制）
```

收到審查意見（REVISE）時：逐條處理，回報裡依編號說明每一條怎麼修的；不同意的條目說明理由。
