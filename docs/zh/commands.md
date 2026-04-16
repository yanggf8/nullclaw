# 命令參考

本頁按使用場景整理 NullClaw CLI，目標是讓你先找到正確命令，再去看更細的輸出。

`nullclaw help` 提供的是頂層摘要；本頁與其保持對齊，並繼續展開到子命令與注意事項。

## 頁面導航

- 這頁適合誰：已經準備使用 CLI，但還不確定命令名、子命令或常見入口的人。
- 看完去哪裡：首次設定看 [設定指南](./configuration.md)；日常執行和排障看 [使用與運維](./usage.md)；如果你在改 CLI 或文件，去 [開發指南](./development.md)。
- 如果你是從某頁來的：從 [README](./README.md) 來，可先看「先看這幾條」；從 [安裝指南](./installation.md) 來，通常下一步是 `onboard`、`agent` 和 `gateway`；從 [開發指南](./development.md) 來，請把本頁當作 CLI 行為和範例索引。

## 先看這幾條

- 看總說明：`nullclaw help`
- 看版本：`nullclaw version` 或 `nullclaw --version`
- 首次初始化：`nullclaw onboard --interactive`
- 單條對話驗證：`nullclaw agent -m "hello"`
- 長期執行：`nullclaw gateway`

## 初始化與互動

| 命令 | 說明 |
|---|---|
| `nullclaw help` | 顯示頂層說明 |
| `nullclaw version` / `nullclaw --version` | 查看 CLI 版本 |
| `nullclaw onboard --interactive` | 互動式初始化設定 |
| `nullclaw onboard --api-key sk-... --provider openrouter` | 快速寫入 provider 與 API Key |
| `nullclaw onboard --api-key ... --provider ... --model ... --memory ...` | 一次性指定 provider、model、memory backend |
| `nullclaw onboard --channels-only` | 只重設 channel / allowlist |
| `nullclaw agent -m "..."` | 單條訊息模式 |
| `nullclaw agent` | 互動會話模式 |

### 互動式模型路由

- 在 `nullclaw agent` 裡，`/model` 會顯示目前模型以及已設定的路由/回退狀態。
- `/config reload` 會熱重載 `config.json` 中支援的設定項目（包括 Agent Profile 的更新）。
- 如果設定了自動路由，`/model` 還會顯示最近一次自動路由決策以及選擇原因。
- 如果某條自動路由命中的提供方暫時被限流或額度耗盡，`/model` 會把這條路線標成 degraded，直到冷卻結束。
- `/model` 還會列出已設定的自動路由及其 `cost_class`、`quota_class` 中繼資料。
- `/model <provider/model>` 會把目前會話 pin 到該模型，並關閉自動路由。
- `/model auto` 會清除這個使用者 pin，把會話還原到設定裡的預設模型，並讓後續回合重新使用 `model_routes`。
- 如果沒有設定 `model_routes`，`/model auto` 仍然會清除 pin，並把會話切回設定裡的預設模型。
- 透過 `--model` 或 `--provider` 啟動 `nullclaw agent` 時，也會把該次執行 pin 到顯式模型，從而繞過 `model_routes`。

## 執行與運維

| 命令 | 說明 |
|---|---|
| `nullclaw gateway` | 啟動長期執行 runtime，預設讀取設定中的 host/port |
| `nullclaw gateway --port 8080` | 用 CLI 覆蓋閘道器連接埠 |
| `nullclaw gateway --host 0.0.0.0 --port 8080` | 用 CLI 覆蓋監聽地址與連接埠 |
| `nullclaw service install` | 安裝背景服務 |
| `nullclaw service start` | 啟動背景服務 |
| `nullclaw service stop` | 停止背景服務 |
| `nullclaw service restart` | 重新啟動背景服務 |
| `nullclaw service status` | 查看背景服務狀態 |
| `nullclaw service uninstall` | 卸載背景服務 |
| `nullclaw status` | 查看全域狀態總覽 |
| `nullclaw doctor` | 執行系統診斷 |
| `nullclaw update --check` | 僅檢查是否有更新 |
| `nullclaw update --yes` | 自動確認並安裝更新 |
| `nullclaw auth login openai-codex` | 為 `openai-codex` 做 OAuth 登入 |
| `nullclaw auth login openai-codex --import-codex` | 從 `~/.codex/auth.json` 匯入登入狀態 |
| `nullclaw auth status openai-codex` | 查看認證狀態 |
| `nullclaw auth logout openai-codex` | 刪除本地認證資訊 |

說明：

- `auth` 目前只支援 `openai-codex`。
- `gateway` 只是覆蓋 host/port，其他安全策略仍以設定檔為準。

## 頻道、任務與擴充

### Channel

| 命令 | 說明 |
|---|---|
| `nullclaw channel list` | 列出已知 / 已設定頻道 |
| `nullclaw channel start` | 啟動預設可用頻道 |
| `nullclaw channel start telegram` | 啟動指定頻道 |
| `nullclaw channel status` | 查看頻道健康狀態 |
| `nullclaw channel add <type>` | 提示如何往設定裡新增某類頻道 |
| `nullclaw channel remove <name>` | 提示如何從設定裡移除頻道 |

### Cron

| 命令 | 說明 |
|---|---|
| `nullclaw cron list [--json] [--limit N] [--all] [--skill <name>] [--channel <name>] [--to <id>] [--status <ok\|error\|paused>] [--match <substring>]` | 按時間順序顯示本週觸發計畫（人類可讀）或 JSON 陣列；多個 filter 會以 AND 合併，`--all` 不限條數顯示符合條件的任務 |
| `nullclaw cron schedule [--hours N] [--today] [--all] [--json]` | 查看指定時間窗口內的即將觸發任務 |
| `nullclaw cron status` | 排程守護進程健康摘要 |
| `nullclaw cron job-status [--json]` | 各任務最近執行狀態與時間戳記（已設定時包含 `verification_mode` 與 `repair_policy`） |
| `nullclaw cron add "0 * * * *" "command" [--tz <offset>] [--verify <mode>] [--repair <policy>]` | 新增週期性 shell 任務 |
| `nullclaw cron add-agent "0 * * * *" "prompt" --model <model> [--session-target isolated\|main] [--channel <name>] [--account <id>] [--to <id>] [--tz <offset>] [--verify <mode>] [--repair <policy>]` | 新增週期性 agent 任務 |
| `nullclaw cron add-skill "0 * * * *" <skill> [--skill-args "..."] [--deliver-to <id>] [--account <id>] [--timeout <secs>] [--tz <offset>] [--verify <mode>] [--repair <policy>] [-- <skill-args...>]` | 新增週期性技能任務。使用 `--` 可將後續參數原樣轉交技能本身（當技能自己也有 `--verify`/`--repair` 時必需） |
| `nullclaw cron once <delay> "command"` | 新增一次性延遲任務 |
| `nullclaw cron once-agent <delay> "prompt" --model <model> [--session-target isolated\|main]` | 新增一次性 agent 延遲任務 |
| `nullclaw cron run <id> [--dry-run]` | 立即執行指定任務，套用完整 verify/repair 流程（寫入 `manual=1` 執行記錄）。`--dry-run` 僅印出解析後的規格，不實際執行 |
| `nullclaw cron show <id> [--runs N] [--json]` | 顯示單一任務的完整規格、下次觸發時間，以及最近 N 筆執行（預設 10 筆） |
| `nullclaw cron explain <id> [--json]` | 顯示任務解析後的執行方式、傳送設定、驗證/修復策略與 trace 環境變數 |
| `nullclaw cron pause <id>` / `resume <id>` | 暫停 / 恢復任務 |
| `nullclaw cron remove <id>` | 刪除任務 |
| `nullclaw cron update <id> [--expression <expr>] [--command <cmd>] [--prompt <p>] [--model <m>] [--session-target isolated\|main] [--enable\|--disable] [--tz <offset>] [--verify <mode>] [--repair <policy>]` | 更新已有任務；`--enable` 同時清除 paused 標誌，`--disable` 同時設定 |
| `nullclaw cron runs <id> [--limit N] [--json]` | 查看任務最近執行記錄（包含 exit code、failure class、repair action、verified 狀態與 trace ID） |
| `nullclaw cron degraded [--hours N] [--job <id>] [--json]` | 列出時間窗內（預設 24 小時）所有失敗或降級的執行；比對條件為 `status=error` 或 `verified>=2`。有結果時附帶 `run-by-trace` 提示 |
| `nullclaw cron run-by-trace <trace_id> [--json]` | 依 `trace_id` 查詢執行記錄;無對應結果時以 exit 1 結束,方便 shell pipeline 使用 |
| `nullclaw cron backup` | 將所有任務匯出為帶時間戳記的 seed 檔案 |
| `nullclaw cron restore [<file>]` | 從 seed 檔案還原任務 |
| `nullclaw cron export-seed` | 以可攜式 JSON 格式列印任務 |
| `nullclaw cron init-seed [--rebuild]` | 將 seed 檔案載入空的 DB，供全新安裝使用；已有任務時會拒絕執行，除非傳入 `--rebuild` |

**驗證與修復策略**（`--verify` / `--repair`）:

- `--verify <mode>` — 排程器如何判定執行結果。可選值:
  - `none`（預設）— 不做驗證
  - `exit_only` — 只把非零 exit 視為失敗
  - `content_nonempty` — 空的 stdout 視為降級
  - `content_has_trace` — stdout 必須包含 job ID（技能可使用 `trace_marker.emit_trace()` 輔助函式）
  - `skill_contract` — stdout 必須同時包含 `[skill-status:ok]` 與 `[trace:<job_id>]`, 且各自獨立成行; `[skill-status:degraded]` 會記成降級執行, `[skill-status:failed]` 會記成語義硬失敗
- `--repair <policy>` — 執行被判定為降級/失敗時排程器如何處理。可選值:
  - `none`（預設）— 僅記錄結果
  - `retry_once` — 立即重試一次;重試結果會被記成 `repair_action=retried_ok` 或 `retried_failed`
  - `alert_only` — 發送操作者告警但不重試（`repair_action=alert_sent`）
  - `pause_on_fail` — 發生硬失敗（`verified=3`）後自動暫停該 job，並記成 `repair_action=paused_job`; 降級執行（`verified=2`）不會被暫停

無法辨識的值會直接被拒絕並列出合法選項 — `cron update` 時的拼字錯誤不會靜默清除既有策略。

### Skills

| 命令 | 說明 |
|---|---|
| `nullclaw skills list` | 列出已安裝 skill |
| `nullclaw skills install <source>` | 從 GitHub URL 或本地路徑安裝 skill |
| `nullclaw skills remove <name>` | 移除 skill |
| `nullclaw skills info <name>` | 查看 skill 中繼資訊 |

### History

| 命令 | 說明 |
|---|---|
| `nullclaw history list [--limit N] [--offset N] [--json]` | 列出會話記錄 |
| `nullclaw history show <session_id> [--limit N] [--offset N] [--json]` | 查看指定會話的訊息詳情 |

## 資料、模型與工作區

### Memory

| 命令 | 說明 |
|---|---|
| `nullclaw memory stats` | 查看目前 memory 設定與關鍵計數 |
| `nullclaw memory count` | 查看總條目數 |
| `nullclaw memory reindex` | 重建向量索引 |
| `nullclaw memory search "query" --limit 10` | 執行檢索 |
| `nullclaw memory get <key>` | 查看單條 memory |
| `nullclaw memory list --category task --limit 20` | 按分類列出 memory |
| `nullclaw memory list --session <id>` | 列出指定 session 範圍的條目 |
| `nullclaw memory list --show-age` | 列出條目並顯示新鮮度標籤（≥7d、≥30d） |
| `nullclaw memory drain-outbox` | 清空 durable vector outbox 佇列 |
| `nullclaw memory forget <key>` | 刪除一條 memory（所有 session） |
| `nullclaw memory forget <key> --session <id>` | 僅刪除指定 session 範圍的條目 |
| `nullclaw memory run-hygiene` | 立即執行 memory hygiene（跳過 12h 冷卻） |

### Workspace / Capabilities / Models / Migrate

| 命令 | 說明 |
|---|---|
| `nullclaw workspace edit AGENTS.md` | 用 `$EDITOR` 開啟 bootstrap 檔案 |
| `nullclaw workspace reset-md --dry-run` | 預覽將要重置的 markdown prompt 檔案 |
| `nullclaw workspace reset-md --include-bootstrap --clear-memory-md` | 重置 bundled markdown，並可附帶清理 bootstrap / memory 檔案 |
| `nullclaw capabilities` | 輸出執行時能力摘要 |
| `nullclaw capabilities --json` | 輸出 JSON manifest |
| `nullclaw models list` | 列出 provider 與預設模型 |
| `nullclaw models info <model>` | 查看模型說明 |
| `nullclaw models benchmark` | 執行模型延遲基準 |
| `nullclaw models refresh` | 重新整理模型目錄 |
| `nullclaw migrate openclaw --dry-run` | 預演遷移 OpenClaw |
| `nullclaw migrate openclaw --source /path/to/workspace` | 指定來源工作區路徑遷移 |

說明：

- `workspace edit` 只適用於 file-based backend（如 `markdown`、`hybrid`）。
- 如果目前 memory backend 把 bootstrap 資料放在資料庫裡，CLI 會提示改用 agent 的 `memory_store` 工具，或切回 file-based backend。

## 硬體與自動化整合

| 命令 | 說明 |
|---|---|
| `nullclaw hardware scan` | 掃描已連接硬體 |
| `nullclaw hardware flash <firmware_file> [--target <board>]` | 燒錄韌體（目前輸出提示，尚未完整實作） |
| `nullclaw hardware monitor` | 監控硬體（目前輸出提示，尚未完整實作） |

## 頂層 machine-facing flags

這組入口更偏自動化、整合、探針，不是一般使用者的第一閱讀路徑：

| 命令 | 說明 |
|---|---|
| `nullclaw --export-manifest` | 匯出 manifest |
| `nullclaw --list-models` | 列出模型資訊 |
| `nullclaw --probe-provider-health` | 探測 provider 健康狀態 |
| `nullclaw --probe-channel-health` | 探測 channel 健康狀態 |
| `nullclaw --from-json` | 從 JSON 輸入執行特定流程 |

## 推薦的日常排查順序

1. `nullclaw doctor`
2. `nullclaw status`
3. `nullclaw channel status`
4. `nullclaw agent -m "self-check"`
5. 如涉及閘道器，再執行 `curl http://127.0.0.1:3000/health`

## 下一步

- 要把命令真正跑起來：繼續看 [設定指南](./configuration.md) 和 [使用與運維](./usage.md)。
- 要部署長期執行：繼續看 [使用與運維](./usage.md) 和 [Gateway API](./gateway-api.md)。
- 要修改命令實作或補測試：繼續看 [開發指南](./development.md) 和 [架構總覽](./architecture.md)。

## 相關頁面

- [中文文件入口](./README.md)
- [安裝指南](./installation.md)
- [設定指南](./configuration.md)
- [開發指南](./development.md)
