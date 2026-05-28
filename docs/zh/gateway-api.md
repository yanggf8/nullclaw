# Gateway API

預設網關位址：`http://127.0.0.1:3000`

## 頁面導航

- 這頁適合誰：要對接 webhook、做健康檢查，或調試網關配對與鑑權流程的人。
- 看完去哪裡：要看網關欄位與監聽策略看 [設定指南](./configuration.md)；要排查服務啟動與長期執行看 [使用與運維](./usage.md)；要確認暴露邊界與 token 管理看 [安全機制](./security.md)。
- 如果你是從某頁來的：從 [使用與運維](./usage.md) 來，這頁補的是 HTTP 端點與請求範例；從 [設定指南](./configuration.md) 來，可在這裡確認 `gateway` 設定對應的實際介面；從 [安全機制](./security.md) 來，這頁提供配對和 bearer token 的具體呼叫面。

## 端點總覽

| Endpoint | Method | 鑑權 | 說明 |
|---|---|---|---|
<<<<<<< HEAD
| `/health` | GET | 無 | 健康檢查 |
| `/pair` | POST | `X-Pairing-Code` | 用一次性配對碼換取 bearer token |
| `/webhook` | POST | `Authorization: Bearer <token>` | 傳送訊息：`{"message":"..."}` |
| `/cron` | GET | 已存在配對 token 時需要 `Authorization: Bearer <token>` | 查看執行中 daemon 的即時 scheduler 任務 |
| `/cron/add` | POST | 已存在配對 token 時需要 `Authorization: Bearer <token>` | 新增即時 cron 任務 |
| `/cron/remove` | POST | 已存在配對 token 時需要 `Authorization: Bearer <token>` | 按 `id` 刪除即時 cron 任務 |
| `/cron/pause` | POST | 已存在配對 token 時需要 `Authorization: Bearer <token>` | 按 `id` 暫停即時 cron 任務 |
| `/cron/resume` | POST | 已存在配對 token 時需要 `Authorization: Bearer <token>` | 按 `id` 恢復即時 cron 任務 |
| `/cron/update` | POST | 已存在配對 token 時需要 `Authorization: Bearer <token>` | 部分更新即時 cron 任務 |
| `/whatsapp` | GET | Query 參數 | Meta Webhook 驗證 |
| `/whatsapp` | POST | Meta 簽名 | WhatsApp 入站訊息 |
| `/max` | POST | `X-Max-Bot-Api-Secret`（設定後必填） | Max 入站 webhook |
| `/.well-known/agent-card.json` | GET | 無 | A2A Agent Card 發現（公開） |
| `/a2a` | POST | `Authorization: Bearer <token>` | A2A JSON-RPC 2.0 端點 |
=======
| `/health` | GET | 无 | 健康检查 |
| `/pair` | POST | `X-Pairing-Code` | 用一次性配对码换取 bearer token（网关公开绑定时仅允许 loopback 客户端） |
| `/webhook` | POST | `Authorization: Bearer <token>` | 发送消息：`{"message":"..."}` |
| `/cron` | GET | 公开绑定时或已存在配对 token 时需要 `Authorization: Bearer <token>` | 查看运行中 daemon 的实时 scheduler 任务 |
| `/cron/add` | POST | 公开绑定时或已存在配对 token 时需要 `Authorization: Bearer <token>` | 新增实时 cron 任务 |
| `/cron/remove` | POST | 公开绑定时或已存在配对 token 时需要 `Authorization: Bearer <token>` | 按 `id` 删除实时 cron 任务 |
| `/cron/pause` | POST | 公开绑定时或已存在配对 token 时需要 `Authorization: Bearer <token>` | 按 `id` 暂停实时 cron 任务 |
| `/cron/resume` | POST | 公开绑定时或已存在配对 token 时需要 `Authorization: Bearer <token>` | 按 `id` 恢复实时 cron 任务 |
| `/cron/update` | POST | 公开绑定时或已存在配对 token 时需要 `Authorization: Bearer <token>` | 部分更新实时 cron 任务 |
| `/whatsapp` | GET | Query 参数 | Meta Webhook 验证 |
| `/whatsapp` | POST | Meta 签名 | WhatsApp 入站消息 |
| `/max` | POST | `X-Max-Bot-Api-Secret`（配置后必填） | Max 入站 webhook |
| `/api/messages` | POST | `Authorization: Bearer <Bot Framework JWT>`，以及可选的 `X-Webhook-Secret` | Teams Bot Framework 入站 webhook |
| `/.well-known/agent-card.json` | GET | 无 | A2A Agent Card 发现（公开） |
| `/a2a` | POST | `Authorization: Bearer <token>` | A2A JSON-RPC 2.0 端点 |
>>>>>>> origin/main

## 快速範例

### 1) 健康檢查

```bash
curl http://127.0.0.1:3000/health
```

### 2) 配對換 token

```bash
curl -X POST \
  -H "X-Pairing-Code: PAIRING_CODE" \
  http://127.0.0.1:3000/pair
```

預期回傳 bearer token（結構可能隨版本調整）。

### 3) 傳送 webhook 訊息

```bash
curl -X POST \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"message":"hello from webhook"}' \
  http://127.0.0.1:3000/webhook
```

### 4) 查看即時 cron 任務

```bash
curl -X GET \
  -H "Authorization: Bearer YOUR_TOKEN" \
  http://127.0.0.1:3000/cron
```

### 5) 新增即時 cron 任務

```bash
curl -X POST \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"expression":"*/15 * * * *","command":"echo hello"}' \
  http://127.0.0.1:3000/cron/add
```

`/cron/add` 也支援一次性任務，例如 `{"delay":"10m","command":"echo later"}`，以及 agent 任務，例如 `{"expression":"0 * * * *","prompt":"Summarize alerts","model":"openrouter/anthropic/claude-sonnet-4"}`。

技能任務無需 `command` 或 `prompt` 欄位，只需提供 `skill_name`：

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"expression":"35 13 * * 1-5","job_type":"skill","skill_name":"cct2","skill_args":"--mode pre-market","delivery_channel":"telegram","delivery_to":"7972814626"}' \
  http://127.0.0.1:3000/cron/add
```

技能任務失敗時，警報優先投遞到任務自身的 `delivery_to` 目標；若任務未設定投遞目標，則回退到設定中的 `scheduler.alert_channel` / `scheduler.alert_to`。

`/cron/update` 傳入 `{"enabled": true}` 會同時清除 `paused` 標誌，傳入 `{"enabled": false}` 則同時設定。這樣 `--enable`/`--disable` 與 `pause`/`resume` 的語義保持一致——通過 update 重新啟用的任務將在下次排程時間正常觸發。

### 6) Max webhook 投遞

單帳號範例：

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -H "X-Max-Bot-Api-Secret: YOUR_MAX_SECRET" \
  -d '{"update_type":"bot_started","chat_id":100,"timestamp":1710000000000,"user":{"user_id":42,"first_name":"Igor"}}' \
  http://127.0.0.1:3000/max
```

多帳號範例：

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -H "X-Max-Bot-Api-Secret: YOUR_MAX_SECRET" \
  -d '{"update_type":"message_created","timestamp":1710000000000,"message":{"sender":{"user_id":42,"first_name":"Igor"},"recipient":{"chat_id":100,"chat_type":"dialog"},"body":{"mid":"m1","text":"ping"}}}' \
  "http://127.0.0.1:3000/max?account_id=main"
```

Max webhook 說明：

- `nullclaw` 對 `/max` 路由優先按 `account_id` query 參數匹配，其次按 `X-Max-Bot-Api-Secret` 匹配。
- 如果 `channels.max[].webhook_secret` 已設定，header 必須存在且完全匹配。
- Max 側設定的 webhook URL 必須使用 HTTPS。

<<<<<<< HEAD
## A2A（Agent-to-Agent 協議）
=======
Teams webhook 说明：

- `nullclaw` 会先用 Microsoft 发布的 OpenID metadata 和 signing keys 验证 Bot Framework bearer token，再接受该 activity。
- token 的 issuer 必须是 `https://api.botframework.com`，audience 必须匹配配置中的 Teams `client_id`，并且 token 中的 `serviceUrl` 必须与 activity body 一致。
- 会按 Bot Framework key metadata 中公布的 endorsement 校验 Teams `channelId`。
- 如果配置了 `channels.teams[].webhook_secret`，还会额外要求 `X-Webhook-Secret` 精确匹配。

## A2A（Agent-to-Agent 协议）
>>>>>>> origin/main

NullClaw 實作了 [Google A2A 協議 v0.3.0](https://github.com/google/A2A)，基於 JSON-RPC 2.0，支援與任何相容 A2A 的代理或客戶端互操作。

### 設定

在 `~/.nullclaw/config.json` 中新增：

```json
{
  "a2a": {
    "enabled": true,
    "name": "My Agent",
    "description": "通用 AI 助手",
    "url": "https://your-public-url.example.com",
    "version": "0.3.0"
  }
}
```

| 欄位 | 預設值 | 說明 |
|------|--------|------|
| `enabled` | `false` | 啟用 A2A 端點 |
| `name` | `"NullClaw"` | Agent Card 中顯示的名稱 |
| `description` | `"AI assistant"` | 代理描述 |
| `url` | `""` | 公開 URL（用於 Agent Card 和 `supportedInterfaces`） |
| `version` | `"1.0.0"` | 代理版本號 |
| `multi_modal` | `false` | 在 Agent Card 中宣告多模態能力。當設定的模型支援圖片輸入時設為 `true`。網關啟動時會自動探測模型能力並設定此值；如需覆蓋可手動設定。 |

**多模態支援**

當 `multi_modal` 為 `true` 時，Agent Card 的 capabilities 物件中會包含 `"multi_modal": true`，向 A2A 客戶端表明該代理可接受圖片附件。A2A 訊息中可在 `text` 部件之外包含 `inlineData` 部件（base64 編碼的圖片）；網關會將其轉發給模型，格式為 `[IMAGE: <mime_type>]` 標記。

接受大型圖片負載時，需在 `gateway` 設定區塊中提高 HTTP 請求體上限和 socket 讀取逾時（參見 [configuration.md](./configuration.md) `gateway` 節）：

```json
{
  "gateway": {
    "max_body_size_bytes": 20971520,
    "request_timeout_secs": 120
  }
}
```

### Agent Card 發現

```bash
curl http://127.0.0.1:3000/.well-known/agent-card.json
```

回傳 Agent Card，包含能力宣告、技能清單、安全機制和支援的介面。無需鑑權。

### JSON-RPC 方法

所有方法通過 `POST /a2a` 呼叫，需要從 `/pair` 取得的 bearer token。

| 方法 | 說明 |
|------|------|
| `message/send` | 傳送訊息，回傳完成的任務 |
| `message/stream` | 傳送訊息，回傳 SSE 事件流 |
| `tasks/get` | 按 ID 查詢任務（支援 `historyLength`） |
| `tasks/cancel` | 取消進行中的任務 |
| `tasks/list` | 列出任務，支援 `state`/`contextId` 過濾 |
| `tasks/resubscribe` | 恢復已有任務的 SSE 流 |

### 任務生命週期

```
submitted → working → completed
                    → failed
                    → canceled
                    → input-required
                    → auth-required
                    → rejected
```

終態：`completed`、`failed`、`canceled`、`rejected`。

### 範例

**傳送訊息：**

```bash
curl -X POST \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "message/send",
    "params": {
      "message": {
        "messageId": "msg-1",
        "role": "user",
        "parts": [{"kind": "text", "text": "什麼是 nullclaw？"}]
      }
    }
  }' \
  http://127.0.0.1:3000/a2a
```

**串流回應（SSE）：**

```bash
curl -N -X POST \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "message/stream",
    "params": {
      "message": {
        "messageId": "msg-2",
        "role": "user",
        "parts": [{"kind": "text", "text": "解釋 A2A 協議"}]
      }
    }
  }' \
  http://127.0.0.1:3000/a2a
```

**查詢任務：**

```bash
curl -X POST \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tasks/get","params":{"id":"task-1"}}' \
  http://127.0.0.1:3000/a2a
```

### 多輪對話

在訊息中包含 `contextId` 將任務歸入同一對話。相同 `contextId` 的訊息共享會話狀態和對話歷史：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "message/send",
  "params": {
    "message": {
      "messageId": "msg-3",
      "contextId": "my-conversation",
      "role": "user",
      "parts": [{"kind": "text", "text": "後續問題"}]
    }
  }
}
```

### 錯誤碼

| 錯誤碼 | 名稱 | 說明 |
|--------|------|------|
| -32700 | JSONParseError | JSON 格式無效 |
| -32600 | InvalidRequestError | 請求校驗失敗 |
| -32601 | MethodNotFoundError | 未知方法 |
| -32602 | InvalidParamsError | 缺少或無效參數 |
| -32603 | InternalError | 服務端錯誤 |
| -32001 | TaskNotFoundError | 任務 ID 不存在 |
| -32002 | TaskNotCancelableError | 任務已處於終態 |
| -32003 | PushNotificationNotSupportedError | 不支援推送通知 |
| -32005 | ContentTypeNotSupportedError | 內容類型不相容 |
| -32007 | AuthenticatedExtendedCardNotConfiguredError | 未設定擴展卡片 |

## 鑑權與安全建議

1. 保持 `gateway.require_pairing = true`。
<<<<<<< HEAD
2. 網關優先綁定 `127.0.0.1`，外網存取通過 tunnel/反向代理。
3. token 視為金鑰，不寫入公開倉庫或日誌。
4. Max webhook secret 同理：每個帳號使用獨立隨機值，不跨 bot 複用。
=======
2. 网关优先绑定 `127.0.0.1`，外网访问通过 tunnel/反向代理。
3. 如果你刻意绑定到非 loopback 地址，通用端点（`/webhook`、`/cron/*`、`/a2a`）即使关闭了交互式 pairing，也仍然要求已存储的 bearer token；如果不使用 `/pair`，请预先配置 `gateway.paired_tokens`。
4. 如果是非 loopback 绑定，`/pair` 只接受 loopback 客户端；要么先在本机完成初始 pairing，要么在公开端口前预先配置 `gateway.paired_tokens`。
5. token 视为密钥，不写入公开仓库或日志。
6. Max webhook secret 同理：每个账号使用独立随机值，不跨 bot 复用。
>>>>>>> origin/main

## 下一步

- 要先把網關設定好：繼續看 [設定指南](./configuration.md)，確認 host、port、pairing 與 channel 設定。
- 要驗證服務是否穩定執行：繼續看 [使用與運維](./usage.md)，按健康檢查與回歸順序排查。
- 要審查公網暴露風險：繼續看 [安全機制](./security.md)，確認最小權限與預設拒絕策略。

## 相關頁面

- [設定指南](./configuration.md)
- [使用與運維](./usage.md)
- [安全機制](./security.md)
- [命令參考](./commands.md)
