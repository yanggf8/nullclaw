# Cron 排程與運維

本指南說明 NullClaw cron 在 claw 已經開始執行後的日常操作方式。這不是首次安裝 bootstrap 的工程文件，而是給日常維運使用。

## 運作模型

cron DB `~/.nullclaw/cron.db` 是排程器的權威資料來源。正在執行的 claw 會讀寫這個 DB；任務定義、暫停狀態、下一次執行時間與執行歷史，都以這個 DB 的 live state 為準。

日常變更請使用 CLI：

```bash
nullclaw cron add ...
nullclaw cron update <id> ...
nullclaw cron remove <id>
nullclaw cron pause <id>
nullclaw cron resume <id>
nullclaw cron run <id>
```

備份使用 live DB。`nullclaw cron backup` 會在 `~/.nullclaw/backup/` 寫入帶時間戳記的備份檔，`nullclaw cron restore [<file>]` 會還原最新備份，或還原你指定的檔案。

`~/.nullclaw/cron-seed.json` 只是在首次安裝時使用的 bootstrap artifact。claw 已經開始執行後，不要用 seed reload 來做日常變更。

`nullclaw cron init-seed` 是給空 cron DB 使用的首次安裝 bootstrap 工具。若 DB 已有任務，它會拒絕執行；只有傳入 `--rebuild` 時，才會刻意清除既有任務與執行歷史後載入 seed。它不是更新既有任務的正常方式。

## 任務類型

NullClaw cron 有三種任務類型。請依照「誰負責執行」與「誰負責送出結果」來選擇。

| 類型 | 適用時機 | 傳送語意 | 參數轉交 |
|---|---|---|---|
| `shell` | 你已經有一條命令或腳本可以完成整個任務。 | 腳本通常自行傳送結果，所以一般使用 `delivery_mode=none`，除非你刻意要讓 cron 傳送捕捉到的輸出。 | 排程器會把命令當成 shell command 執行。請明確處理 quoting。 |
| `agent` | 你要讓 NullClaw agent 用指定模型處理 prompt。 | cron 會捕捉 agent 輸出；設定 `delivery_mode=always` 或其他 delivery mode 時，由 cron 傳送結果。 | prompt 會存成任務輸入。使用 `--model` 與 `--session-target isolated|main` 控制執行方式。 |
| `skill` | 你要直接執行已安裝 skill 的腳本，並讓 skill 自己處理傳送。 | skill 應接受 `--deliver-to <chat_id>`，並透過 channel helper 自行傳送。 | 使用 `--skill-args "..."` 或 `-- <skill-args...>` 把參數轉交給 skill。`--deliver-to` 與 `--account` 也會轉交給腳本。 |

對 skill 任務而言，排程器會讀取該 skill 的 `SKILL.md`，解析 `## Script` 路徑，並以 `python3 <script> <args>` 執行，同時注入執行脈絡環境變數。不要把互動式 `/skill <name>` prompt 當作 cron 任務；cron 需要腳本路徑或一般 agent prompt，而不是背景 subagent 指令。

常見 skill 任務：

```bash
nullclaw cron add-skill "0 8 * * *" oilcon \
  --deliver-to 7972814626 \
  --account ping \
  --verify skill_contract \
  --repair alert_only \
  -- --market WTI
```

## 驗證與修復策略

驗證策略決定一次執行是否「足夠好」。修復策略決定結果不好時要採取什麼動作。

驗證模式：

| 模式 | 意義 |
|---|---|
| `none` | 除了排程器是否完成執行外，不檢查結果內容。 |
| `exit_only` | 非零 exit code 視為失敗；exit `0` 視為成功。 |
| `content_nonempty` | 要求 stdout 非空。空 stdout 會記錄為 degraded。 |
| `content_has_trace` | 要求 stdout 包含本次執行的 trace ID。skill 腳本可在成功傳送後輸出 `NULLCLAW_JOB_ID`。 |
| `skill_contract` | 要求 stdout 各自獨立成行地包含 `[skill-status:ok]` 與 `[trace:<job_id>]`。這是 self-delivering skill 任務最嚴格的模式。 |

Skill status marker 是腳本對結果的語意判定：

| Marker | 結果 |
|---|---|
| `[skill-status:ok]` | 腳本完成，且判定自己的結果可用。 |
| `[skill-status:degraded]` | 腳本有執行，但內容或上游資料品質不足。該次執行會記錄為 degraded。 |
| `[skill-status:failed]` | 腳本有執行，但回報語意上的失敗。該次執行會記錄為驗證失敗。 |
| `[trace:<id>]` | 將 stdout 綁定到排程器 trace ID。請獨立成行輸出。 |

修復策略：

| 策略 | 意義 |
|---|---|
| `none` | 只記錄執行結果，不做自動動作。 |
| `retry_once` | 立刻用相同執行脈絡重試一次。重試結果會寫入執行歷史。 |
| `alert_only` | 執行失敗或 degraded 時送出操作者告警，但不重試。 |
| `pause_on_fail` | 發生硬失敗後暫停該任務。degraded 執行仍會保持任務啟用。 |

當 `pause_on_fail` 暫停任務後，請先修正根因、檢查近期歷史，再恢復任務：

```bash
nullclaw cron runs <id>
nullclaw cron resume <id>
```

## 時區處理

Cron expression 會依照任務設定的時區 offset 解讀。新增或更新任務時可使用 `--tz <offset>`，例如台灣時間使用 `--tz 8`，美東標準時間 offset 使用 `--tz -5`。

DB 中的排程時間以 UTC epoch seconds 儲存。任務的 timezone offset 會跟著任務一起儲存，並用於計算未來觸發時間。因此，兩個任務即使 cron expression 相同，只要 `--tz` 不同，`next_run_secs` 就可能不同。

`cron show` 可能令人困惑，因為儲存的 timestamp 是 UTC，但你設定排程時想的是任務本地時間。若任務有非零 timezone offset，先比對任務時區與 UTC 時間，再判斷任務是否提早或延後。

要看更完整的未來排程，可使用：

```bash
nullclaw cron schedule --hours 24
nullclaw cron schedule --today
```

## 執行歷史與疑難排解

每次完成的執行都會寫入 `cron_runs`。先從單一任務歷史開始：

```bash
nullclaw cron runs <id>
nullclaw cron show <id> --runs 20
```

跨任務尋找失敗或 degraded 執行：

```bash
nullclaw cron degraded --hours 24
nullclaw cron degraded --job <id> --hours 168
```

若要找任務，不需要把 JSON pipe 給 `grep`；可直接 filter `cron list`。多個 filter 會以 AND 合併：

```bash
nullclaw cron list --skill oilcon
nullclaw cron list --channel telegram --to 7972814626
nullclaw cron list --status error
nullclaw cron list --match oil --json
```

依 trace 查詢單次執行：

```bash
nullclaw cron run-by-trace <trace_id>
```

Cron 啟動的 subprocess 會收到 trace 環境變數：

| 變數 | 意義 |
|---|---|
| `NULLCLAW_EXECUTION_TRACE_ID` | 本次執行的排程器 trace ID，通常是 `<job_id>:<queue_or_time_id>`。 |
| `NULLCLAW_JOB_ID` | 同一個 trace ID 的向後相容別名。使用 trace 驗證時，skill 腳本應輸出它。 |
| `NULLCLAW_EXECUTION_SOURCE` | 執行路徑，例如 `cron_scheduler_skill`、`cron_manual_skill` 或 legacy scheduler source。 |
| `NULLCLAW_SENSORIUM_STATE` | 固定為 `session_only_not_attached`，表示 subprocess state 不會被持久化。 |

服務層級排障請看 user service journal：

```bash
journalctl --user -u nullclaw.service -n 50 --no-pager
```

健康的 skill 執行通常會出現以下順序：

```text
cron_tick: enqueued job '<id>'
cron_queue: running queued job '<id>'
cron_queue: [<id>] skill completed (ok)
```

如果看到 `cron_tick` 但沒有 `cron_queue`，worker 可能卡住。若看到 `cron_queue` 但沒有 `skill completed`，請檢查 run row 與腳本 stdout/stderr。

## 操作者範例

新增一個會送 Telegram 的 skill 任務：

```bash
nullclaw cron add-skill "0 8 * * *" oilcon \
  --deliver-to 7972814626 \
  --account ping \
  --timeout 120 \
  --tz 8 \
  --verify skill_contract \
  --repair alert_only
```

暫停不穩定任務、檢查歷史、修正並恢復：

```bash
nullclaw cron pause oilcon-daily
nullclaw cron runs oilcon-daily --limit 20
nullclaw cron show oilcon-daily --runs 20
# 修正腳本、憑證、channel 設定或任務參數。
nullclaw cron run oilcon-daily --dry-run
nullclaw cron run oilcon-daily
nullclaw cron resume oilcon-daily
```

大量變更前先備份：

```bash
nullclaw cron backup
nullclaw cron list --json
nullclaw cron update <id> --expression "*/15 * * * *"
```

變更出錯後還原：

```bash
nullclaw cron pause <bad-job-id>
nullclaw cron restore
nullclaw cron list
```

如果要指定某個備份，而不是還原最新備份：

```bash
nullclaw cron restore ~/.nullclaw/backup/cron.db.20260416-080001
```
