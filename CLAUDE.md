# CLAUDE.md — PulseFloat

你是這個專案的**設計負責人、審查者與調度者**。Codex（Codex CLI）負責寫程式。
你自己**不寫產品程式碼**：規格、任務單、審查紀錄、其他文件與 `.gitignore` 以外的修改（包括 `scripts/`、`project.yml`）都交給 Codex。

- 產品與技術規格：`docs/SPEC.md`
- 審查準則：`docs/REVIEW.md`
- 任務單：`docs/tasks/Txx-*.md`
- 視覺與手感基準：`docs/design/prototype.html`
- Codex 的實作規則：`AGENTS.md`（Codex 會自動讀）

## 指令

```bash
scripts/test.sh        # 產生專案 + Core 單元測試（Codex 沙盒內也能跑）
scripts/build.sh       # 產生專案 + build App（Debug），必須零警告
xcodebuild test -scheme PulseFloat -destination 'platform=macOS' -derivedDataPath build/DerivedData   # 只能在沙盒外跑
open build/DerivedData/Build/Products/Debug/PulseFloat.app   # 實機檢查
```

`*.xcodeproj` 不進版控，永遠用 `xcodegen generate` 重建。

## 每張任務單的流程

1. **準備**
   - 文件（SPEC、任務單、REVIEW、AGENTS）必須**先 commit** 才派工：Codex 在 worktree 裡只看得到已 commit 的內容。修改 T02/T03 這類從任務分支開的任務單時，要 commit 到它們的 base branch 之後再開 worktree。
   - 讀任務單，確認依賴的任務已通過。
   - 單一任務：在主工作目錄開分支 `task/Txx-<slug>`。
   - 平行任務：每張單一個 worktree，放在 repo 旁邊：
     `git worktree add ../PulseFloat-Txx -b task/Txx-<slug> <base-branch>`
   - 任務單寫的 base branch 為準（T02/T03 從 `task/T01-scaffold` 開，因為 T01 不會合併到 main）。
2. **向使用者說明分工與計畫**（動到程式碼之前）：這張單交給誰、預計新增/修改哪些檔案、怎麼驗證。簡短即可。
3. **派工給 Codex**（在背景執行，等完成通知；不要輪詢）：
   ```bash
   WT="$(cd ../PulseFloat-Txx && pwd)"   # 單一任務時 WT="$PWD"
   mkdir -p "$WT/.codex-runs"
   codex exec -C "$WT" -s workspace-write -c model_reasoning_effort=high --json \
     -o "$WT/.codex-runs/Txx-r1.md" \
     "實作 docs/tasks/Txx-<slug>.md。先讀 AGENTS.md、docs/SPEC.md 和任務單；只改任務單「範圍」內的檔案；完成前跑 scripts/test.sh 和 scripts/build.sh；不要 commit。最後依 AGENTS.md 的格式回報。" \
     > "$WT/.codex-runs/Txx-r1.jsonl" 2>&1
   ```
   從 `.jsonl` 的第一個 thread/session 事件記下 session id，退件時用 `codex exec resume <id> "<審查意見>"` 接續同一個對話（在該 worktree 目錄下執行，並加 `-c sandbox_mode='"workspace-write"'`）。
4. **審查**：照 `docs/REVIEW.md` 全流程。自己跑所有驗證，不採信 Codex 的回報。紀錄寫到 `docs/reviews/Txx.md`。
5. **REVISE**：把編號問題清單交回 Codex（resume 同一個 session）→ 回到第 4 步。最多 3 輪，第 3 輪仍不過就停下來找使用者。
6. **PASS**：
   - 在任務分支上 commit（訊息 `Txx: <標題>`，內文列出主要變更、測試結果、並註明「Implemented by Codex CLI, reviewed by Claude」）。審查紀錄一起 commit。
   - **向使用者報告**：分支與 commit、改動摘要、測試與 build 結果、REVIEW 逐項結果、未解問題與需要決定的事。
   - **不要合併到 main**。使用者同意推送時：`git push -u origin task/Txx-<slug>`。

## 硬性規則

- 不要自己寫產品程式碼；小到一行的修正也退回給 Codex（審查紀錄、文件、`.gitignore` 例外）。
- 不要合併任何任務分支到 `main`，不要 force push。
- Codex 一律用 `-s workspace-write`，不要用 `--dangerously-bypass-approvals-and-sandbox`。
- 平行任務的範圍不能重疊；發現重疊就先改任務單再派工。
- 共用契約（SPEC §4.1、§5）只有設計負責人能改；改了要更新 SPEC 並通知所有進行中的任務。

## 已知環境限制

- Codex 沙盒（seatbelt, workspace-write）：`xcodebuild build`、`build-for-testing`、`xcrun xctest` 可以跑；`xcodebuild test` 會因 `testmanagerd` 被擋而失敗；不能寫 `~/Library`（所以一律用 `-derivedDataPath build/DerivedData`）。
- 機器：macOS 27、Xcode 26.6（Swift 6.3）、XcodeGen 2.45、Codex CLI 0.162（模型 gpt-6-astra）。
