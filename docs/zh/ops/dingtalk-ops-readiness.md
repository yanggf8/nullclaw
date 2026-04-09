# DingTalk 運維就緒

這頁聚焦 DingTalk 頻道的專項驗證，以及「能發不能收」這類問題的最快排查路徑。

## 頁面導航

**這頁適合誰**

- 正在驗證 DingTalk 新部署的運維者
- 排查入站訊息缺失或 channel 健康異常的維護者
- 需要判斷問題究竟來自設定漂移、過舊二進位還是 DingTalk 側投遞的貢獻者

**看完先去哪裡**

- 通用服務化和日誌流程看 [使用與運維](../usage.md)
- 主設定上下文看 [設定指南](../configuration.md)
- 要放寬 `allow_from` 前先看 [安全機制](../security.md)

## 健康狀態應該是什麼樣

- 目前版本會把 DingTalk 作為 gateway-loop channel 啟動，所以日誌裡應看到
  `dingtalk gateway started`，而不是 `dingtalk started (send-only)`。
- 只有 runtime 已執行且 DingTalk stream websocket 已連通時，channel 健康狀態才為真。
- 即使入站壞了，只要 session webhook 目標還新鮮，出站回覆仍可能成功；因此
  「能發不能收」通常優先看 stream 鏈路，而不是 reply 鏈路。

## 上線前檢查清單

1. 先確認你執行的是目前版本。如果日誌裡還出現
   `dingtalk started (send-only)`，先升級。
2. 檢查 `channels.dingtalk.accounts.<id>.client_id` 和 `client_secret`
   是否來自同一個 DingTalk 應用。
3. 檢查 `allow_from` 不是空陣列。`allow_from: []` 會拒絕所有入站訊息。
4. 用 `nullclaw gateway` 啟動 runtime，再用 `nullclaw channel status`
   確認 DingTalk 顯示為 healthy。
5. 如果懷疑憑證問題，可執行
   `nullclaw --probe-channel-health --channel dingtalk --account <id>`
   驗證 token 取得鏈路。

## 如果入站訊息始終收不到

1. 確認 DingTalk 應用已按 stream mode 設定入站投遞。目前 runtime 會透過
   DingTalk 的 gateway connection API 開啟 websocket；只有出站能力還不夠。
2. 確認應用訂閱了你期望接收的訊息事件。若 DingTalk 根本沒發這些回呼，
   nullclaw 就沒有東西可 ingest。
3. 前台執行並先記錄第一條 DingTalk 錯誤，再考慮重啟。最關鍵的日誌通常是
   `dingtalk websocket cycle failed`、
   `dingtalk websocket read failed` 和
   `dingtalk envelope handling failed`。
4. 用一個明確出現在 `allow_from` 裡的傳送者重新測試。白名單未命中看起來像
   「訊息被忽略」，而不是傳輸層失敗。

## 回覆目標與回退行為

- 新鮮的回覆目標會直接使用入站事件攜帶的 `sessionWebhook` URL。
- 群聊回覆目標過期後，nullclaw 可以利用快取的 conversation id 回退到
  DingTalk AI interaction API。
- 直聊回覆目標沒有這個群聊回退；session webhook 過期後，需要新的入站事件或
  顯式 proactive target。
- 任意 `https://...` webhook 目標會被有意拒絕，出站媒體載荷目前也不支援。

## 建議的驗證順序

```bash
nullclaw doctor
nullclaw status
nullclaw channel status
nullclaw gateway
```

然後讓一個已放行的 DingTalk 傳送者發訊息，優先記錄第一條執行時錯誤，再做後續操作。
