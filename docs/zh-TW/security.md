# 安全機制

NullClaw 預設走 secure-by-default：本地綁定、配對鑑權、沙箱隔離、最小權限。

## 頁面導航

- 這頁適合誰：要評估預設安全邊界、審查風險設定，或準備把 NullClaw 接到長期執行環境的人。
- 看完去哪裡：要落到具體欄位看 [設定指南](./configuration.md)；要對外提供 webhook 看 [Gateway API](./gateway-api.md)；想理解這些邊界在系統中的位置看 [架構總覽](./architecture.md)。
- 如果你是從某頁來的：從 [設定指南](./configuration.md) 來，這頁補的是風險判斷與預設建議；從 [使用與運維](./usage.md) 來，這頁可作為上線前安全檢查表；從 [Gateway API](./gateway-api.md) 來，這頁幫助確認 pairing、public bind 與 token 管理原則。

## 基線能力

| 項 | 狀態 | 說明 |
|---|---|---|
| 網關預設不公網暴露 | 已啟用 | 預設綁定 `127.0.0.1`；無 tunnel/顯式放開時拒絕公網綁定 |
| 配對鑑權 | 已啟用 | 啟動時一次性 6 位 pairing code，`POST /pair` 換 token |
| 檔案系統範圍限制 | 已啟用 | 預設 `workspace_only = true`，阻止越界存取 |
| 隧道存取控制 | 已啟用 | 公網場景優先通過 Tailscale/Cloudflare/ngrok/custom tunnel |
| 沙箱隔離 | 已啟用 | 自動選擇 Landlock/Firejail/Bubblewrap/Docker |
| 金鑰加密 | 已啟用 | 憑證採用 ChaCha20-Poly1305 本地加密儲存 |
| 資源限制 | 已啟用 | 可設定記憶體/CPU/子行程等限制 |
| 稽核日誌 | 已啟用 | 可開啟並設定保留策略 |

## Channel allowlist 規則

- **預設 fail-closed（破壞性變更）：** 空的或省略的 `allow_from` 現在會在每個頻道**拒絕所有入站發送者**。未填寫 `allow_from` 的頻道會保持靜默，直到你列出可信 ID。
- `allow_from: ["*"]`：允許所有來源（高風險，僅顯式確認後使用）；空清單已不再代表「允許全部」。
- 其他：按精確匹配允許清單，或頻道專屬的群組策略行為。
- 此規則一致套用於所有入站路徑：gateway webhook（Telegram、LINE、WeChat、WeCom）與直連頻道（Discord、IRC、MaixCam、OneBot、WhatsApp、Weixin）。
- Telegram webhook 另可用 `webhook_secret` 鑑權（Telegram 會在 `X-Telegram-Bot-Api-Secret-Token` 標頭回傳）；設定後，secret 不符的請求會被拒絕。

## Pairing 與 Webhook 鑑權邊界

- `/pair` 僅支援 POST，並要求 `X-Pairing-Code`。
- 多次錯誤 pairing 嘗試會觸發限流，並可能進入暫時鎖定。
- `/.well-known/agent.json` 與 `/.well-known/agent-card.json` 在啟用 A2A 時屬於公開發現文件。
- 保持 `gateway.require_pairing = true` 時，`/webhook` 與 `/a2a` 仍在 bearer 鑑權之後；若關閉 pairing，這兩個端點就不再要求 bearer token。
- 各 channel 專用入站 webhook 繼續使用各自的鑑權或簽名規則，不應一概寫成 gateway bearer 鑑權。

## Nostr 特殊規則

- `owner_pubkey` 始終允許（即使 `dm_allowed_pubkeys` 更嚴格）。
- 私鑰使用 `enc2:` 加密格式落盤，僅執行時解密到記憶體；停止 channel 後清理。

## 推薦安全設定

```json
{
  "gateway": {
    "host": "127.0.0.1",
    "port": 3000,
    "require_pairing": true,
    "allow_public_bind": false
  },
  "autonomy": {
    "level": "supervised",
    "workspace_only": true,
    "max_actions_per_hour": 20
  },
  "security": {
    "sandbox": { "backend": "auto" },
    "audit": { "enabled": true, "retention_days": 90 }
  }
}
```

## Shell 環境變數

預設情況下，只有最小的安全環境變數集（`PATH`、`HOME`、`TERM` 等）會傳遞給 shell 子行程，防止 API 金鑰洩露（CWE-200）。

### 路徑驗證環境變數

某些部署場景（如 Kubernetes 中通過 volume mount 注入工具鏈）需要 `LD_LIBRARY_PATH` 等環境變數來定位共享庫，但無條件傳遞這類變數存在庫注入風險。

`tools.path_env_vars` 允許指定值為平台路徑清單（Unix 用 `:`，Windows 用 `;`）的環境變數。每個路徑元件在傳遞給子行程前都會經過以下驗證：

1. 每個元件必須是絕對路徑
2. 每個元件通過 `realpath` 解析（規範化，跟隨符號連結）
3. 每個元件必須在工作區或 `allowed_paths` 範圍內
4. 系統黑名單路徑（`/etc`、`/usr/lib`、`/bin` 等）始終被拒絕

如果任何一個元件驗證失敗，整個變數會被丟棄。

```json
{
  "autonomy": { "allowed_paths": ["/opt/tools"] },
  "tools": { "path_env_vars": ["LD_LIBRARY_PATH", "PYTHONHOME", "NODE_PATH"] }
}
```

以上述設定為例，當容器環境中 `LD_LIBRARY_PATH=/opt/tools/usr/lib:/opt/tools/lib` 時，shell tool 會驗證兩個路徑元件均在 `/opt/tools`（通過 `allowed_paths`）範圍內，然後放行。而攻擊者控制的值如 `/tmp/evil:/opt/tools/lib` 會被拒絕，因為 `/tmp/evil` 不在工作區或允許路徑內。

## 高風險設定提醒

以下設定會顯著擴大權限邊界，應僅用於受控環境：

- `autonomy.level = "full"`
- `autonomy.level = "yolo"`
- `allowed_commands = ["*"]`
- `allowed_paths = ["*"]`
- `gateway.allow_public_bind = true`

## 下一步

- 要把建議落實到設定：繼續看 [設定指南](./configuration.md)，逐項對照 `gateway`、`autonomy`、`security`。
- 要驗證對外接入面：繼續看 [Gateway API](./gateway-api.md)，檢查鑑權與呼叫方式。
- 要做上線前回歸：繼續看 [使用與運維](./usage.md)，按診斷與健康檢查順序執行。

## 相關頁面

- [設定指南](./configuration.md)
- [使用與運維](./usage.md)
- [Gateway API](./gateway-api.md)
- [架構總覽](./architecture.md)
