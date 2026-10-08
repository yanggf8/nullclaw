# 結構化 skill 狀態（選用）

適合執行多回合、且後續步驟所需資訊可放進少量固定欄位的流程。這是選用的試行功能；一般 `nullclaw agent` 對話仍使用原本的歷史訊息。

在 skill 的 `SKILL.md` 旁加入 `state-schema.json`：

```json
{
  "version": 1,
  "fields": {
    "goal": "string",
    "step": "integer",
    "completed": "array",
    "waiting_for_approval": "boolean"
  }
}
```

欄位型別支援 `string`、`integer`、`number`、`boolean`、`object`、`array`。模型的最終回覆必須是含 `patch` 與 `reply` 的 JSON 物件。`patch` 只能更新 schema 宣告的欄位；設為 `null` 可刪除欄位。未知欄位、型別錯誤或超出大小限制時，checkpoint 不會更新。

```sh
nullclaw agent --skill my-skill --skill-state --session task-42 -m "開始流程"
nullclaw agent --skill my-skill --skill-state --session task-42 -m "審核者已核准第二步"
```

頻道對話可用 `/iskill my-skill` 啟用。若該 skill 有 `state-schema.json`，該對話後續訊息會自動使用結構化狀態。本機處理的斜線指令仍走原本的指令流程；狀態以 skill 與對話識別碼區隔。

執行時會把 skill 規則、schema、目前狀態及最新訊息送給模型，不帶入先前回合的訊息。checkpoint 與追加式觀察記錄放在 `<workspace>/skill-state/`。每回合內的工具呼叫仍受 nullclaw 原有的工具流程與安全規則管理；**狀態在整個使用者回合結束後才驗證並儲存，不會在每次工具呼叫後更新**。

工具產生的外部效果與狀態檔並非同一筆交易。若工具已成功，但最終 JSON 無效或程序在寫入 checkpoint 前中斷，重試前應核對觀察記錄和外部系統。每個對話的檔案鎖會在程序結束時自動釋放。狀態檔是本機工作區資料，請勿放入秘密資訊。

現有測試只驗證狀態檢查與保存，尚未證實任務成功率或成本有所改善。擴大使用前，應以相同的長流程比較一般模式與結構化狀態模式的完成率、總提示 token、耗時和中斷後恢復能力。短對話可能沒有收益，因為每回合都會重送 skill 規則與 schema。若流程需要持續變更 schema，或歷史順序本身就是任務結果，這個模式也不適合。
