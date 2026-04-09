# 外部頻道插件

這頁專門說明 `channels.external` 執行時，以及如何在不把頻道專用程式碼併入 core 的前提下為 nullclaw 增加新頻道。

## 頁面導航

**這頁適合誰**

- 需要在 `config.json` 裡接入外部頻道的運維者
- 正在實作新頻道 bridge/plugin 的作者
- 需要判斷某個整合應不應該進 core 的維護者

**下一步建議**

- 設定全貌看 [設定指南](./configuration.md)
- 想理解整體執行時模型看 [架構總覽](./architecture.md)
- 想看上線後的執行與排障看 [使用與運維](./usage.md)

## 為什麼要有 External Channel

`channels.external` 是社群頻道和站點私有頻道的乾淨擴展路徑。它的目標是：

- 不把頻道專用 SDK、sidecar、bridge 邏輯塞進 nullclaw core
- 避免 in-process ABI/plugin loading 帶來的複雜度
- 允許每個頻道的實作獨立使用自己的語言和倉庫
- 讓 host/plugin 邊界足夠窄、顯式且易於 supervision

host/plugin 邊界如下：

- transport：`stdin`/`stdout` 上逐行 JSON-RPC
- process model：由 nullclaw 啟動的子行程
- routing surface：只暴露通用 `Channel` 操作
- 頻道專用邏輯：完全留在插件內

## 什麼時候該用它

適合用 external channel 的情況：

- 這個頻道依賴很大的 SDK 或非 Zig 執行時
- 整合是小眾、實驗性或強站點定製的
- 更適合通過本地 sidecar / bridge 來接入
- 你希望獨立於 nullclaw 發布節奏快速迭代

不適合用它的情況：

- 這其實是產品層 / app 層，而不是 channel
- 你需要改動 core routing、memory、安全邊界或 agent 語義
- 這個整合更像 tools/MCP，而不是訊息傳輸層

## 設定模型

外部頻道設定放在 `channels.external.accounts.<id>` 下。

範例：

```json
{
  "channels": {
    "external": {
      "accounts": {
        "wa-web": {
          "runtime_name": "whatsapp_web",
          "transport": {
            "command": "/opt/nullclaw/plugins/nullclaw-plugin-whatsapp-web",
            "args": ["--stdio"],
            "timeout_ms": 10000,
            "env": {
              "PLUGIN_TOKEN": "secret"
            }
          },
          "config": {
            "bridge_url": "http://127.0.0.1:3301",
            "allow_from": ["*"]
          }
        }
      }
    }
  }
}
```

欄位含義：

- `runtime_name`
  執行時 channel 名稱，會參與 routing、bindings、session key、daemon dispatch，以及 `nullclaw channel start <runtime_name>`。
- `transport.command`
  插件行程的可執行路徑或命令名。
- `transport.args`
  可選參數陣列。
- `transport.env`
  僅傳給插件行程的環境變數。
- `transport.timeout_ms`
  這個帳號的 host RPC 逾時上限。host 對 supervision 敏感路徑還會繼續做更短的內部裁剪。
- `config`
  不透明 JSON object，會原樣傳給插件 `start` RPC 的 `params.config`。

校驗規則：

- `runtime_name` 不能為空，只能包含字母、數字、`_`、`-`、`.`
- `runtime_name` 必須在所有 built-in 和已設定執行時頻道中全域唯一
- `transport.command` 必填
- `transport.timeout_ms` 必須在 `[1, 600000]`
- `config` 必須是 JSON object

## 執行時架構

執行時裡，host 會為每個帳號建立一個通用 `ExternalChannel`，流程如下：

1. 啟動插件子行程
2. 取得並校驗 manifest
3. 傳送 `start`
4. 把通用 `Channel` 呼叫映射成 JSON-RPC 請求
5. 接收 `inbound_message` 通知並發布到 bus
6. 用有界健康探針做 supervision

關鍵性質：

- 一個設定帳號對應一個插件子行程
- 插件會像其他 channel runtime 一樣被 supervision
- 插件 stdout 只能輸出 JSON-RPC
- 插件 stderr 可以寫診斷資訊

## 傳輸契約

傳輸層是基於 stdio 的逐行 JSON-RPC 2.0。

規則：

- 每個 request、response、notification 都必須占一行
- stdout 只能輸出 JSON-RPC
- stderr 不參與協議，可以自由列印
- request/response 通過 JSON-RPC `id` 關聯
- 下文要求為 object 的 `params`/`result` 必須真的是 JSON object

## Manifest

host 會先發：

```json
{"jsonrpc":"2.0","id":1,"method":"get_manifest","params":{}}
```

插件必須回傳：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocol_version": 2,
    "capabilities": {
      "health": true,
      "streaming": false,
      "send_rich": false,
      "typing": false,
      "edit": false,
      "delete": false,
      "reactions": false,
      "read_receipts": false
    }
  }
}
```

規則：

- `protocol_version` 必須等於 `2`
- `capabilities` 可省略
- 沒宣告的 capability 一律按不支援處理

Capability 含義：

- `health`
  插件實作了 `health` RPC，可以回報頻道級健康狀態。
- `streaming`
  插件能接受模型串流輸出產生的 `.chunk` 分段傳送事件。
- `send_rich`
  插件實作了 `send_rich`。
- `typing`
  插件實作了 `start_typing` 和 `stop_typing`。
- `edit`
  插件實作了 `edit_message`，允許 host 後續原地更新同一條訊息。
- `delete`
  插件實作了 `delete_message`，允許 host 後續刪除同一條訊息。
- `reactions`
  插件實作了 `set_reaction`。
- `read_receipts`
  插件實作了 `mark_read`。

## 生命週期 RPC

### `start`

Host 請求：

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "start",
  "params": {
    "runtime": {
      "name": "whatsapp_web",
      "account_id": "wa-web",
      "state_dir": "/home/user/.nullclaw/workspace/state/channels/external/whatsapp_web/wa-web"
    },
    "config": {
      "bridge_url": "http://127.0.0.1:3301",
      "allow_from": ["*"]
    }
  }
}
```

必須回傳的成功回應：

```json
{"jsonrpc":"2.0","id":2,"result":{"started":true}}
```

說明：

- `runtime.state_dir` 是 host 分配給這個帳號的持久化目錄
- 插件應把 `config` 當成自己的 opaque settings
- 只有 JSON-RPC 成功但沒有 `result.started: true` 會被 host 拒絕

### `stop`

Host 請求：

```json
{"jsonrpc":"2.0","id":3,"method":"stop","params":{}}
```

host 不要求額外的固定欄位，但仍然建議插件回傳一個 `result` object。

## 健康檢查 RPC

如果 `capabilities.health=true`，host 可能呼叫：

```json
{"jsonrpc":"2.0","id":4,"method":"health","params":{}}
```

可接受的回應形態：

```json
{"jsonrpc":"2.0","id":4,"result":{"healthy":true}}
```

或：

```json
{"jsonrpc":"2.0","id":4,"result":{"ok":true,"connected":true,"logged_in":true}}
```

規則：

- 如果有 `healthy`，它必須是布林值
- 否則 `ok`、`connected`、`logged_in` 至少要出現一個
- 空物件 `{}` 是非法回應
- 如果插件不支援 `health`，就不要宣告 capability，不要回傳假的 stub 成功

## 出站 RPC

### `send`

Host 請求：

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "send",
  "params": {
    "runtime": {
      "name": "whatsapp_web",
      "account_id": "wa-web"
    },
    "message": {
      "target": "room-1",
      "text": "hello",
      "stage": "final",
      "media": []
    }
  }
}
```

必須回傳的成功回應：

```json
{"jsonrpc":"2.0","id":5,"result":{"accepted":true}}
```

如果插件同時宣告了 `capabilities.edit=true` 和
`capabilities.delete=true`，那麼 `send` 還可以回傳穩定的訊息引用，
這樣 host 後面就能繼續更新或刪除同一條訊息：

```json
{"jsonrpc":"2.0","id":5,"result":{"accepted":true,"message_id":"msg-42"}}
```

或者：

```json
{"jsonrpc":"2.0","id":5,"result":{"accepted":true,"message":{"target":"room-1","message_id":"msg-42"}}}
```

規則：

- `message.target` 的語義由插件自己定義
- 文字欄位統一叫 `message.text`，`content` 已經不再合法
- `message.stage` 只能是 `"final"` 或 `"chunk"`
- `message.media` 是字串陣列
- 如果插件實際上沒有接受這個動作，就不能偽造成功
- 如果要讓 host 後續執行 edit/delete，`message_id` 必須是非空且穩定的頻道訊息識別碼
- `result.message.target` 可以省略；省略時 host 會沿用原始出站目標
- 沒宣告 `edit` + `delete` 的插件，只回傳 `{"accepted": true}` 就可以

host 現在嚴格區分：

- JSON-RPC success：請求傳輸成功
- `result.accepted: true`：插件真正接受了這個動作

回傳 `{"accepted": false}` 會被當成拒絕，而不是成功。

### `send_rich`

只有在 `capabilities.send_rich=true` 時才會呼叫。

Host 請求：

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "send_rich",
  "params": {
    "runtime": {
      "name": "plugin_chat",
      "account_id": "main"
    },
    "message": {
      "target": "room-1",
      "text": "Choose one",
      "attachments": [
        {
          "kind": "image",
          "target": "/tmp/card.png",
          "caption": "preview"
        }
      ],
      "choices": [
        {
          "id": "yes",
          "label": "Yes",
          "submit_text": "yes"
        }
      ]
    }
  }
}
```

必須回傳：

```json
{"jsonrpc":"2.0","id":6,"result":{"accepted":true}}
```

`attachments[].kind` 目前支援：

- `image`
- `document`
- `video`
- `audio`
- `voice`

如果不支援 `send_rich`，就不要宣告 capability。只有在 payload 足夠簡單時，host 才可能退化為普通 `send`。

### `edit_message`

只有在 `capabilities.edit=true` 時才會呼叫。

Host 請求：

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "edit_message",
  "params": {
    "runtime": {
      "name": "plugin_chat",
      "account_id": "main"
    },
    "message": {
      "target": "room-1",
      "message_id": "msg-42",
      "text": "patched",
      "attachments": [],
      "choices": []
    }
  }
}
```

必須回傳：

```json
{"jsonrpc":"2.0","id":7,"result":{"accepted":true}}
```

當某個頻道本身不支援原生 `.chunk` 串流傳送時，host 可能會先 `send`
一條草稿訊息，再用這個 RPC 持續更新它。

### `delete_message`

只有在 `capabilities.delete=true` 時才會呼叫。

Host 請求：

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "delete_message",
  "params": {
    "runtime": {
      "name": "plugin_chat",
      "account_id": "main"
    },
    "message": {
      "target": "room-1",
      "message_id": "msg-42"
    }
  }
}
```

必須回傳：

```json
{"jsonrpc":"2.0","id":8,"result":{"accepted":true}}
```

### `set_reaction`

只有在 `capabilities.reactions=true` 時才會呼叫。

Host 請求：

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "set_reaction",
  "params": {
    "runtime": {
      "name": "plugin_chat",
      "account_id": "main"
    },
    "message": {
      "target": "room-1",
      "message_id": "msg-42",
      "emoji": "✅"
    }
  }
}
```

必須回傳：

```json
{"jsonrpc":"2.0","id":9,"result":{"accepted":true}}
```

規則：

- `emoji` 為字串時表示設定或更新 reaction
- `emoji: null` 表示清除這個訊息上的 reaction

### `mark_read`

只有在 `capabilities.read_receipts=true` 時才會呼叫。

Host 請求：

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "mark_read",
  "params": {
    "runtime": {
      "name": "plugin_chat",
      "account_id": "main"
    },
    "message": {
      "target": "room-1",
      "message_id": "msg-42"
    }
  }
}
```

必須回傳：

```json
{"jsonrpc":"2.0","id":10,"result":{"accepted":true}}
```

### Typing RPC

只有在 `capabilities.typing=true` 時才會呼叫。

請求：

```json
{"jsonrpc":"2.0","id":11,"method":"start_typing","params":{"runtime":{"name":"plugin_chat","account_id":"main"},"recipient":"room-1"}}
```

```json
{"jsonrpc":"2.0","id":12,"method":"stop_typing","params":{"runtime":{"name":"plugin_chat","account_id":"main"},"recipient":"room-1"}}
```

必須回傳：

```json
{"jsonrpc":"2.0","id":13,"result":{"accepted":true}}
```

## 入站通知

插件通過通知上報入站訊息：

```json
{
  "jsonrpc": "2.0",
  "method": "inbound_message",
  "params": {
    "message": {
      "sender_id": "5511",
      "chat_id": "room-1",
      "text": "hello",
      "session_key": "optional-custom-session",
      "media": ["https://example.com/a.jpg"],
      "metadata": {
        "peer_kind": "group",
        "peer_id": "room-1",
        "is_group": true,
        "typing_recipient": "room-1"
      }
    }
  }
}
```

必填欄位：

- `sender_id`
- `chat_id`
- `text`

可選欄位：

- `session_key`
- `media`
- `metadata`

校驗規則：

- `sender_id` 和 `chat_id` 必須是非空字串
- `text` 必須是字串
- `media` 如果存在，必須是非空字串陣列
- `metadata` 如果存在，必須是 JSON object

## Metadata 約定

`metadata` 是頻道專用語義的主要擴展面。

推薦欄位：

- `peer_kind`
  穩定的 peer 類型，例如 `dm`、`group`、`thread`，或頻道自定義值。
- `peer_id`
  與 `peer_kind` 配套使用的穩定 peer 識別碼。
- `is_group`
  顯式 group hint。
- `is_dm`
  顯式 direct-message hint。
- `typing_recipient`
  typing indicator 應傳送到的目標。

Host 行為：

- host 會自動把 `account_id` 注入 inbound metadata
- 如果插件沒給 `session_key`，host 會按下面規則派生：
  - 優先 `runtime_name + account_id + peer_kind + peer_id`
  - 否則 `runtime_name + account_id + chat_id`
- 對 unknown/external channels，metadata 會被提升到 conversation context

## 錯誤語義

以下情況應用 JSON-RPC `error`：

- 參數非法
- 方法不支援
- bridge/transport 失敗
- 插件內部錯誤

只有真的接受了動作，才回傳 `result.accepted: true`。

推薦錯誤碼：

- `-32601`
  Method not found / not implemented
- `-32602`
  Invalid params
- `-32000` 及以下
  插件自定義執行時錯誤

## 逾時與 Supervision

設定裡的 `transport.timeout_ms` 並不意味著所有 control path 都會真的等這麼久。NullClaw 會對 health 和 supervision 敏感的請求施加更短的內部上限。

這意味著：

- 掛死的插件不會把 daemon 永久卡住
- 不支援的可選 RPC 會被學習並快取
- health 結果會被短暫快取，避免高頻探測

插件自己仍然應該：

- 快速回應 `stop`
- 保持 stdout 不被阻塞
- 盡量不要在 JSON-RPC 主執行緒裡做過長耗時工作

## 安全與隔離

host/plugin 邊界雖然很窄，但插件本質上仍然是以 nullclaw 使用者權限執行的本地行程。

建議：

- 把插件視為受信任的本地軟體，而不是 sandbox 裡的不可信程式碼
- bridge URL 盡量使用本地位址或 HTTPS
- 謹慎通過 `transport.env` 或插件設定傳遞金鑰
- 不要把 token 或原始敏感訊息列印到 stderr
- 帳號持久化狀態只寫入 `runtime.state_dir`

## CLI 與執行

常用命令：

```bash
nullclaw channel start external
```

啟動第一個已設定的 external 帳號。

```bash
nullclaw channel start whatsapp_web
```

啟動 `runtime_name = whatsapp_web` 的 external 帳號。

## 參考適配器

倉庫裡提供了一個 bridge 適配器範例：

- [`examples/whatsapp-web/nullclaw-plugin-whatsapp-web`](../../examples/whatsapp-web/nullclaw-plugin-whatsapp-web)
- [`examples/external-channel-template/nullclaw-plugin-template`](../../examples/external-channel-template/nullclaw-plugin-template)

它把 PR #265 裡的 WhatsApp Web HTTP bridge 形態轉換成目前 ExternalChannel JSON-RPC 協議。

如果你要看 WhatsApp Web 的完整 operator journey，包括 bridge 鑑權和
WhatsApp 登入的職責邊界、QR/pairing 歸屬以及首次聯調步驟，請繼續看：

- [`examples/whatsapp-web/README.md`](../../examples/whatsapp-web/README.md)

如果你需要的是一個不綁定任何具體頻道的起步模板，而不是 WhatsApp
專用 bridge 範例，請看：

- [`examples/external-channel-template/README.md`](../../examples/external-channel-template/README.md)

配套的倉庫外實作：

- [nullclaw/nullclaw-channel-baileys](https://github.com/nullclaw/nullclaw-channel-baileys)
  基於 Node/Baileys 的直連 external channel 插件，包含 QR 和 pairing-code 流程。
- [nullclaw/nullclaw-channel-whatsmeow-bridge](https://github.com/nullclaw/nullclaw-channel-whatsmeow-bridge)
  獨立的 Go/whatsmeow HTTP bridge，包含 QR、pairing-code 和 deployment assets。
- `nullclaw-channel-imap-connector`
  基於 Python 的 IMAP/SMTP external channel 插件，用於雙向郵件和配套的郵箱 CLI 工作流。

推薦把真正的生產級頻道實作放在這些倉庫外 repo 中。本倉庫裡的範例主要是
reference adapter 和 authoring template。

## 插件作者檢查單

- 實作 `get_manifest`
- 實作 `start`、`send`、`stop`
- 回傳 `protocol_version: 2`
- `start` 回傳 `started: true`
- 被接受的出站動作回傳 `accepted: true`
- `inbound_message` 使用 `text`，不要再用 `content`
- peer routing 有意義時，在 metadata 裡帶上 `peer_kind` 和 `peer_id`
- 使用 `state_dir` 存放持久化帳號狀態
- 保持 stdout 只有協議資料

## 排障

`channel start <runtime_name>` 立刻失敗：

- 檢查 `transport.command`
- 檢查 manifest 的 `protocol_version` 是否為 `2`
- 檢查 `start.result.started` 是否存在且為 true

訊息進了錯誤會話：

- 顯式提供 `session_key`，或者至少提供 `metadata.peer_kind` 和 `metadata.peer_id`
- 檢查多個帳號是否複用了同一個 `runtime_name`

明明 bridge 已斷，但 health 還是綠的：

- 實作 `health`
- 如果健康結果沒有真實語義，就不要宣告 `capabilities.health=true`

插件日誌把 host 搞壞了：

- stdout 只能輸出 JSON-RPC
- 可讀日誌請寫到 stderr
