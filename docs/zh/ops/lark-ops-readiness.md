# Lark 運維就緒

本指南定義 Lark/飛書頻道的專項運維檢查項。

## 健康語義

- websocket 模式下，僅當 running 與 connected 同時為真時才算健康。
- webhook 模式下，執行態有效且回呼路徑可達才算健康。

## 認證與權限

1. 校驗租戶 token 取得與刷新行為。
2. 業務碼非零應視為執行失敗。
3. 權限/scope 類錯誤應立即升級處理。

## `error.LarkApiError` 快速排查

1. 先執行 `nullclaw doctor`，確認頻道設定在結構上是有效的。
2. 啟動後執行 `nullclaw channel status`，確認是否處於 running 但未 connected 的狀態。
3. 如果持續出現 `warning(lark): lark websocket cycle failed: error.LarkApiError`，優先按下面三類排查：
   - Lark/飛書應用權限或 scope 缺失
   - 區域端點選擇錯誤（`use_feishu`）
   - websocket 回呼設定下發失敗
4. 如果舊版 Linux 二進位在進入穩定重連日誌前就直接崩潰，先升級版本，再繼續做權限排查。

## 事件處置步驟

1. 在飛書/Lark 控制台檢查應用權限與 scope。
2. 驗證回呼端點與 websocket 路徑可達。
3. 確認傳送者白名單（`allow_from`）與群聊 @ 觸發邏輯。
4. 僅在完成根因記錄後重啟頻道實例。

## SLO 信號

- auth_fail_total
- reconnect_total
- outbound_send_fail_total
- healthcheck_fail_total
