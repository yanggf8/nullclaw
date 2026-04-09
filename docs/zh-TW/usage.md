# 使用與運維

本頁聚焦日常操作、服務化執行和常見故障排查。

## 頁面導航

- 這頁適合誰：已經完成安裝與基礎設定，準備日常使用、服務化執行或排障的人。
- 看完去哪裡：命令細節繼續看 [命令參考](./commands.md)；要核對設定欄位看 [設定指南](./configuration.md)；涉及 webhook 與對外接入看 [Gateway API](./gateway-api.md)。
- 如果你是從某頁來的：從 [安裝指南](./installation.md) 來，這頁就是首次跑通的下一站；從 [設定指南](./configuration.md) 來，這頁用來驗證設定是否真能工作；從 [Gateway API](./gateway-api.md) 來，可回到這裡看長期執行與排障順序。

## 首次啟動流程

1. 執行初始化：

```bash
nullclaw onboard --interactive
```

2. 傳送一條測試訊息：

```bash
nullclaw agent -m "你好，nullclaw"
```

3. 啟動長期執行網關：

```bash
nullclaw gateway
```

## 常用命令速查

| 命令 | 用途 |
|---|---|
| `nullclaw onboard --api-key sk-... --provider openrouter` | 快速寫入 provider 與 API Key |
| `nullclaw onboard --interactive` | 互動式完整初始化 |
| `nullclaw onboard --channels-only` | 只重設 channel / allowlist |
| `nullclaw agent -m "..."` | 單條訊息模式 |
| `nullclaw agent` | 互動會話模式 |
| `nullclaw gateway` | 啟動長期執行 runtime（預設 `127.0.0.1:3000`） |
| `nullclaw service install` | 安裝背景服務 |
| `nullclaw service start` | 啟動背景服務 |
| `nullclaw service status` | 查看背景服務狀態 |
| `nullclaw service stop` | 停止背景服務 |
| `nullclaw service uninstall` | 卸載背景服務 |
| `nullclaw doctor` | 系統診斷 |
| `nullclaw status` | 全域狀態 |
| `nullclaw channel status` | 頻道健康狀態 |
| `nullclaw channel start telegram` | 啟動指定頻道 |
| `nullclaw migrate openclaw --dry-run` | 預演遷移 OpenClaw 資料 |
| `nullclaw migrate openclaw` | 執行遷移 |
| `nullclaw history list [--limit N] [--offset N] [--json]` | 列出會話記錄 |
| `nullclaw history show <session_id> [--limit N] [--offset N] [--json]` | 查看指定會話的訊息詳情 |

## 服務化執行建議

建議在長期執行場景使用 service 子命令：

- macOS 走 `launchctl`。
- Linux 環境會優先使用 `systemd --user`，在 Alpine / OpenRC 系統上會自動切換為 OpenRC。
- Windows 走 Service Control Manager。
- 如果 Linux 上既沒有可用的 `systemd --user`，也缺少必需的 OpenRC 命令，這組子命令會失敗；此時應改用前台 `nullclaw gateway` 或其他外部 supervisor。

```bash
nullclaw service install
nullclaw service start
nullclaw service status
```

如果設定改動較大，建議重啟服務：

```bash
nullclaw service stop
nullclaw service start
```

## 網關與配對（Pairing）

- 預設網關位址：`127.0.0.1:3000`
- 推薦保持 `gateway.require_pairing = true`
- 建議透過 tunnel 暴露外網存取，不直接公網監聽網關
- `/pair` 僅支援 POST，並使用 `X-Pairing-Code`；多次錯誤嘗試會觸發限流，且可能進入臨時鎖定

網關健康檢查：

```bash
curl http://127.0.0.1:3000/health
```

## 常見問題（FAQ）

### 1) 啟動失敗，提示設定錯誤

處理步驟：

1. 先跑 `nullclaw doctor` 看具體報錯。
2. 對照 `config.example.json` 檢查欄位拼寫與層級。
3. 檢查 JSON 語法（逗號、引號、括號）。

### 2) 模型呼叫失敗（401/403）

常見原因：

- API Key 無效或過期。
- provider 寫錯（例如填了 `openrouter` 但 key 屬於其他平台）。
- 模型路由字串不匹配 provider。

建議排查：

```bash
nullclaw status
```

並重新執行：

```bash
nullclaw onboard --interactive
```

### 3) 收不到頻道訊息

重點檢查：

- `channels.<name>.accounts.*` 的 token / webhook / account 欄位是否正確。
- `allow_from` 是否誤設為空陣列。
- `nullclaw channel status` 是否有 unhealthy 標記。
- 如果是 DingTalk，進一步看
  [DingTalk 運維就緒](./ops/dingtalk-ops-readiness.md)。

### 4) 網關啟動但外部不可存取

常見原因：

- 仍綁定在 `127.0.0.1`。
- 未設定 tunnel 或反向代理。
- 防火牆未放行連接埠。

### 5) provider 回傳 429 / "rate limit exceeded"

常見原因：

- 額度較低的 coding plan 往往扛不住 tool-heavy 的 agent 回合，即使普通聊天還看起來能用。
- 目前 provider 計劃對重試頻率很敏感。
- 主 provider 被限流後，沒有設定可切換的 fallback。

建議排查：

- 前台執行時先用 `nullclaw agent --verbose`。
- service 模式下查看 `~/.nullclaw/logs/daemon.stdout.log` 與 `~/.nullclaw/logs/daemon.stderr.log`。
- 跑一次 `nullclaw status`，確認目前實際使用的 provider / model。

如果 plan 本身可用但限流很嚴，建議保守調整 reliability：

```json
{
  "reliability": {
    "provider_retries": 1,
    "provider_backoff_ms": 3000,
    "fallback_providers": ["openrouter"]
  }
}
```

如果同一 provider 有多把 key，可以設定 `reliability.api_keys` 讓 NullClaw 在限流時輪轉。

## 變更後回歸檢查清單

每次改設定後，建議按順序執行：

```bash
nullclaw doctor
nullclaw status
nullclaw channel status
nullclaw agent -m "self-check"
```

對 gateway 場景，額外驗證：

```bash
nullclaw gateway
curl http://127.0.0.1:3000/health
```

## 下一步

- 要細查具體 CLI 行為：繼續看 [命令參考](./commands.md)，按子命令逐項核對。
- 要排查設定或調整 provider/channel：繼續看 [設定指南](./configuration.md)。
- 要把網關開放給外部系統：繼續看 [Gateway API](./gateway-api.md) 和 [安全機制](./security.md)。

## 相關頁面

- [安裝指南](./installation.md)
- [設定指南](./configuration.md)
- [命令參考](./commands.md)
- [Gateway API](./gateway-api.md)
