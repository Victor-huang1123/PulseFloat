# T01 專案骨架與共用契約

| 項目 | 內容 |
|---|---|
| 依賴 | 無 |
| 分支 | `task/T01-scaffold`（從 `main` 開） |
| 實作 | Codex |
| 審查 | Claude，依 `docs/REVIEW.md` |

## 目標

建立可以 build、可以測試、能在選單列出現圖示的最小 App，並把之後 T02/T03 會**平行**使用的共用型別一次定好。這張單做完後，T02 只動 `DSP/`、T03 只動 `Render/`、`Preview/`、`Window/`、`MenuBar/`，兩邊不會撞檔，而且**都不能再改 `Config/`、`Model/`**——所以這裡的公開 API 必須一次到位。

## 範圍（只能新增/修改這些路徑）

- `project.yml`
- `PulseFloat/App/**`、`PulseFloat/MenuBar/**`、`PulseFloat/Resources/**`
- `PulseFloatCore/Config/**`、`PulseFloatCore/Model/**`
- `PulseFloatCoreTests/Config/**`、`PulseFloatCoreTests/Model/**`、`PulseFloatCoreTests/Fixtures/**`
- `scripts/build.sh`、`scripts/test.sh`
- `.gitignore`（已存在，補齊即可）、`README.md`

不要動 `docs/`、`CLAUDE.md`、`AGENTS.md`。

## 要做的事

### 1. `project.yml`（XcodeGen）
- 專案名 `PulseFloat`。
- `options.deploymentTarget.macOS: "15.0"`（**必須放在 `options:` 底下**；放頂層會被 XcodeGen 靜默忽略）。每個 target 都寫 `platform: macOS`。
- `settings.base` 共用設定：`SWIFT_VERSION: "6.0"`、`SWIFT_STRICT_CONCURRENCY: complete`、`SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`、`GCC_TREAT_WARNINGS_AS_ERRORS: YES`、`CODE_SIGN_IDENTITY: "-"`、`CODE_SIGN_STYLE: Manual`、`DEVELOPMENT_TEAM: ""`、`ENABLE_USER_SCRIPT_SANDBOXING: YES`、`MARKETING_VERSION: 0.1.0`、`CURRENT_PROJECT_VERSION: 1`。
- Targets：
  - `PulseFloat`：`application`，sources `PulseFloat/`，依賴 `PulseFloatCore`（embed），`PRODUCT_BUNDLE_IDENTIFIER: com.victorhuang.PulseFloat`。Info.plist 放在 `PulseFloat/Resources/Info.plist`，由 XcodeGen `info.properties` 產生，至少包含：
    - `LSUIElement: true`
    - `NSAudioCaptureUsageDescription: "PulseFloat 需要讀取系統正在播放的聲音，才能即時畫出頻譜。聲音只在本機分析，不會錄音或上傳。"`
    - `CFBundleDisplayName: PulseFloat`
    - `LSApplicationCategoryType: public.app-category.music`
    - `CFBundleShortVersionString: "$(MARKETING_VERSION)"`、`CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"`（XcodeGen 預設會寫死 1.0，必須明確指定）
  - `PulseFloatCore`：`framework`，sources `PulseFloatCore/`，`GENERATE_INFOPLIST_FILE: YES`，`PRODUCT_BUNDLE_IDENTIFIER: com.victorhuang.PulseFloatCore`。**不能 import AppKit / SwiftUI**。
  - `PulseFloatCoreTests`：`bundle.unit-test`，sources `PulseFloatCoreTests/`，`dependencies: [{ target: PulseFloatCore, embed: true }]`（**必須 embed**：`xcrun xctest` 不會設 `DYLD_FRAMEWORK_PATH`，框架要在 `.xctest/Contents/Frameworks` 裡才載得到），**不設 host app**，`GENERATE_INFOPLIST_FILE: YES`，`PRODUCT_BUNDLE_IDENTIFIER: com.victorhuang.PulseFloatCoreTests`。`Fixtures/` 裡的 JSON 會被 XcodeGen 自動加入 bundle resources（攤平在 `Contents/Resources/`，用 `Bundle(for:)` 不帶子目錄讀取）。
- Schemes：
  - `PulseFloat`：build `PulseFloat`；test 包含 `PulseFloatCoreTests`。
  - `PulseFloatCore`：build `PulseFloatCore`；test `PulseFloatCoreTests`。

### 2. App 骨架（`PulseFloat/App/`、`PulseFloat/MenuBar/`）
- 檔案固定：`PulseFloat/App/AppDelegate.swift`、`PulseFloat/MenuBar/StatusItemController.swift`（T03 會在這兩個檔案上擴充）。
- AppKit 生命週期，**不要用 SwiftUI `App`，也不要另建 `main.swift`**。專案沒有 MainMenu.xib / storyboard，AppKit 預設的 `main()` 不會建立 delegate，`applicationDidFinishLaunching` 永遠不會被呼叫；所以必須自己寫 `static func main()`（已實測可在 Swift 6 + warnings-as-errors 下零警告編譯並正常啟動）：
  ```swift
  @main
  @MainActor
  final class AppDelegate: NSObject, NSApplicationDelegate {
      static func main() {
          let app = NSApplication.shared
          let delegate = AppDelegate()
          app.delegate = delegate              // NSApplication.delegate 是 weak
          withExtendedLifetime(delegate) { app.run() }
      }
      // AppDelegate 強持有 StatusItemController（它再強持有 NSStatusItem）
  }
  ```
- 啟動後 `NSApp.setActivationPolicy(.accessory)`（和 `LSUIElement` 雙保險）。
- `StatusItemController`（`@MainActor final class`）：建立 `NSStatusItem`，圖示用 SF Symbol `waveform`（template），accessibility label「PulseFloat」。點擊顯示 `NSMenu`：
  - 「關於 PulseFloat」→ 先 `NSApp.activate()`，再 `NSApp.orderFrontStandardAboutPanel(nil)`（accessory App 不會自動變 active，不先 activate 的話面板會在其他視窗後面；不要用已棄用的 `activate(ignoringOtherApps:)`）
  - 分隔線
  - 「結束 PulseFloat」（⌘Q）→ `NSApp.terminate(nil)`
- 不能有 Dock 圖示、不能開任何視窗。

### 3. 共用契約（`PulseFloatCore/`）
- `Model/SpectrumFrame.swift`、`Model/SpectrumSource.swift`：完全照 `docs/SPEC.md` §4.1 的簽名與不變式（可以加文件註解與便利成員，但不能改既有簽名）。`silent(bandCount:)` 回傳全 0 的 values/peaks、bass 0；`bandCount` 可以是 0。
- `Config/VisualizerConfig.swift`：
  - `public struct VisualizerConfig: Codable, Equatable, Sendable`，巢狀 `Bands`、`Level`、`Motion`、`Look`、`MenuBar`（皆 `public`、`Codable, Equatable, Sendable`），屬性名稱 = JSON key（見 SPEC §5）。
  - **所有儲存屬性都是 `public var`**（不能用 `let`，T02/T03 的測試與 App target 要修改它們）。
  - 每個巢狀型別提供 `public init(...)`，**所有參數都有預設值**（= SPEC §5）；`VisualizerConfig` 提供 `public init(bands:level:motion:look:menubar:)`，參數全有預設值。
  - 列舉 `ThemeID`（bars/radial/neon/led）、`PaletteID`（aurora/ember/glacier/mono）、`WindowMode`（card/bare）、`MenuBarStyle`（bars/dots）：`public`、`String` raw value、`CaseIterable`、`Codable`、`Sendable`。
  - 預設值名稱固定為 `public static let \`default\``（不要用 `defaults`）= SPEC §5 的 JSON。
  - **寬鬆解碼**：每一層都自訂 `init(from:)`，用 `decodeIfPresent`，缺 key 用預設值，不認得的列舉值用該欄位預設值，不認得的 key 忽略，整數字面值（如 `3`）可解成 `Double`。編碼輸出的 key 與巢狀結構必須和 SPEC §5 一致。
  - `public func clamped() -> VisualizerConfig`：照 SPEC §5 範圍表夾值；`bands.count` 先四捨五入到最近的 4 的倍數（`.toNearestOrAwayFromZero`）再夾到 16…128；最後確保 `fMaxHz ≥ fMinHz × 4`（夾值後其實必然成立，保留這行作為防護）。
  - 每個欄位都要有一行文件註解（單位與意義）。

### 4. 測試（`PulseFloatCoreTests/`）
- `Fixtures/prototype-defaults.json`：SPEC §5 的 JSON 原樣。
- 測試至少涵蓋：
  1. `VisualizerConfig.default` 編碼後，與 fixture 在**語意上**相等（解析成字典比較，數字比值，不比字串格式）。
  2. 解碼 fixture 等於 `.default`。
  3. 部分 JSON（例如只有 `{"look":{"theme":"neon"}}`）→ 其他欄位都是預設值、theme 是 neon。
  4. 不認得的列舉值（`"theme":"plasma"`）→ 回到 `bars`；不認得的 key 被忽略。
  5. 空物件 `{}` → `.default`。
  6. `clamped()`：每個數值欄位超出上下限各一個案例；`count` 62 → 64、65 → 64、66 → 68、8 → 16、200 → 128。
  7. `SpectrumFrame.silent(bandCount: 64)` 與 `silent(bandCount: 0)` 的長度與內容。
  8. round-trip：任意修改過的 config 編碼再解碼相等。
  9. `PulseFloatCoreTests/Config/PublicAPITests.swift`：**只用 `import PulseFloatCore`（不加 `@testable`）**，用 public init 建構每個巢狀型別與 `VisualizerConfig`，並修改每一個欄位、建構 `SpectrumFrame`——用來保證 App target 與其他模組拿得到所有 API。

### 5. 腳本（`scripts/`，`bash`、`set -euo pipefail`、開頭 `cd "$(dirname "$0")/.."`，可在任何目錄執行）
- `scripts/build.sh`：`xcodegen generate --quiet` → `xcodebuild build -scheme PulseFloat -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData -quiet`。
  - **必須 `-quiet`**：非 quiet 模式下 Xcode 的 appintentsmetadataprocessor 每次乾淨 build 都會印一行無法消除的 `warning: Metadata extraction skipped`。`-quiet` 仍會顯示真正的警告與錯誤。
- `scripts/test.sh`：`xcodegen generate --quiet` → `xcodebuild build-for-testing -scheme PulseFloatCore -destination 'platform=macOS' -derivedDataPath build/DerivedData -quiet` → `xcrun xctest build/DerivedData/Build/Products/Debug/PulseFloatCoreTests.xctest`。
  - **原因**：Codex 沙盒擋住 `testmanagerd`，`xcodebuild test` 在沙盒裡會失敗；`build-for-testing` + `xcrun xctest` 可以跑（已實測，失敗時 exit 1 且看得到 XCTAssert 錯誤）。
- 兩個腳本都要 `chmod +x`；失敗時 exit code 非 0。

### 6. 其他
- `.gitignore`：補齊 `*.xcodeproj/`、`build/`、`DerivedData/`、`.DS_Store`、`xcuserdata/`、`.codex-runs/`、`*.xcresult`（保留已有內容）。
- `README.md`：保留第一行標題，補上一段簡介（一句話）、需求（macOS 15、Xcode 26、XcodeGen）、`scripts/build.sh` / `scripts/test.sh` 用法、文件位置（`docs/SPEC.md`）。

## 驗收標準

「零警告」的定義（全專案通用）：`rm -rf build/DerivedData && scripts/build.sh 2>&1 | grep -E "warning:"` 輸出為空。

1. `scripts/test.sh` 通過（沙盒內外都要能跑）。
2. `scripts/build.sh` 成功，零警告。
3. 沙盒外 `xcodebuild test -scheme PulseFloat -destination 'platform=macOS' -derivedDataPath build/DerivedData` 通過（審查者執行）。
4. 用 `open build/DerivedData/Build/Products/Debug/PulseFloat.app` 啟動：選單列出現 waveform 圖示、沒有 Dock 圖示、沒有視窗；選單有「關於」與「結束」，「關於」面板出現在最前面且版本是 0.1.0，「結束」可正常退出（審查者執行）。
5. `PulseFloatCore` 沒有 import AppKit/SwiftUI（`grep` 檢查）。
6. build 出來的 `PulseFloat.app/Contents/Info.plist`：`CFBundleIdentifier` = `com.victorhuang.PulseFloat`、`LSMinimumSystemVersion` = `15.0`、`CFBundleShortVersionString` = `0.1.0`，且含 `LSUIElement` 與 `NSAudioCaptureUsageDescription`（用 `plutil -extract … raw` 檢查）。
7. `PublicAPITests` 不用 `@testable` 也能編譯通過。
8. 只動了「範圍」列出的路徑；`*.xcodeproj` 沒有進 git。

## 不要做

- 不要實作任何 DSP、繪圖、浮動視窗（那是 T02/T03）。
- 不要建立 `.entitlements`、不要開 App Sandbox 或 Hardened Runtime（Process Tap 只需要 Info.plist 的 `NSAudioCaptureUsageDescription`，不需要任何 entitlement）。
- 不要加第三方套件、不要加 SwiftLint 之類的工具。
- 不要 commit。
