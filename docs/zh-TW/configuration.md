# 設定指南

NullClaw 與 OpenClaw 設定結構相容，使用 `snake_case` 欄位風格。

## 頁面導航

- 這頁適合誰：已經裝好 NullClaw，準備產生、修改或審查 `config.json` 的使用者與運維者。
- 看完去哪裡：要把設定真正跑起來看 [使用與運維](./usage.md)；要理解安全邊界看 [安全機制](./security.md)；要查看命令入口與覆蓋參數看 [命令參考](./commands.md)；要接非 core 頻道看 [外部頻道插件](./external-channels.md)。
- 如果你是從某頁來的：從 [安裝指南](./installation.md) 來，下一步通常就是產生初始設定；從 [Gateway API](./gateway-api.md) 來，這頁可回查 `gateway` 與 channel 相關欄位；從 [安全機制](./security.md) 來，這頁提供具體設定落點與範例。

## 設定檔位置

- macOS/Linux: `~/.nullclaw/config.json`
- Windows: `%USERPROFILE%\\.nullclaw\\config.json`

建議先執行：

```bash
nullclaw onboard --interactive
```

這會自動產生初始設定檔。

## 最小可執行設定

下面範例可在本地 CLI 模式跑通（需要替換 API Key）：

```json
{
  "models": {
    "providers": {
      "openrouter": {
        "api_key": "YOUR_OPENROUTER_API_KEY"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openrouter/anthropic/claude-sonnet-4"
      }
    }
  },
  "channels": {
    "cli": true
  },
  "memory": {
    "backend": "sqlite",
    "auto_save": true
  },
  "gateway": {
    "host": "127.0.0.1",
    "port": 3000,
    "require_pairing": true
  },
  "autonomy": {
    "level": "supervised",
    "workspace_only": true,
    "max_actions_per_hour": 20
  },
  "security": {
    "sandbox": {
      "backend": "auto"
    },
    "audit": {
      "enabled": true
    }
  }
}
```

## 核心設定區塊說明

### `diagnostics`

- 用於控制執行時診斷與可觀測性輸出。
- 設定 OpenTelemetry 時，請使用巢狀的 `diagnostics.otel` 物件。
- OTEL spans 會在回合完成、agent 結束等自然執行邊界觸發 flush；更長執行流程仍保留批次 flush 作為兜底。

範例：

```json
{
  "diagnostics": {
    "backend": "otel",
    "log_tool_calls": true,
    "log_message_receipts": true,
    "log_message_payloads": true,
    "log_llm_io": true,
    "otel": {
      "endpoint": "http://otel:4318",
      "service_name": "nullclaw",
      "headers": {
        "Authorization": "Bearer example-token"
      }
    }
  }
}
```

### `models.providers`

- 定義各 LLM provider 的連接參數與 API Key。
- 常見 provider：`openrouter`、`openai`、`anthropic`、`groq` 等。

範例：

```json
{
  "models": {
    "providers": {
      "openrouter": { "api_key": "sk-or-..." },
      "anthropic": { "api_key": "sk-ant-..." },
      "openai": { "api_key": "sk-..." }
    }
  }
}
```

常見的 provider 級欄位：

- `api_key`：該 provider 條目的憑證。
- `base_url`：用於自訂或自托管 OpenAI 相容端點的地址覆蓋。
- `api_mode`：為相容 provider 選擇 `chat_completions` 或 `responses`。
- `user_agent`：可選的 `User-Agent` 請求標頭覆蓋。
- `max_streaming_prompt_bytes`：當估算 prompt 大小超過該閾值時跳過串流請求。
- `chat_template_enable_thinking_param`：針對自訂 OpenAI 相容的 vLLM/Qwen 端點，把 `reasoning_effort` 對應到 `chat_template_kwargs.enable_thinking`。

### `agents.defaults.model.primary`

- 設定預設模型路由，格式通常為：`provider/vendor/model`。
- 範例：`openrouter/anthropic/claude-sonnet-4`

### `model_routes`

- 頂層可選路由表，用於 `nullclaw agent` 在每一輪對話裡自動選擇模型。
- 每個條目用 `hint` 對應到具體的 `provider` 和 `model`。
- 目前 daemon 識別的路由提示詞包括：`fast`、`balanced`、`deep`、`reasoning`、`vision`。
- 設定了 `balanced` 時，它會作為一般兜底路線。`fast` 更適合簡短的狀態/列表/檢查類請求，以及提取、計數、分類、只返回結果這類邊界清晰的短結構化任務。`deep` 和 `reasoning` 更適合調查、規劃、權衡分析和長上下文。`vision` 用於圖片輸入回合。
- `api_key` 是可選的；如果不填，會繼續使用 `models.providers.<provider>` 裡的一般憑證。
- `cost_class` 是可選中繼資料，可選值為 `free`、`cheap`、`standard`、`premium`。
- `quota_class` 是可選中繼資料，可選值為 `unlimited`、`normal`、`constrained`。

範例：

```json
{
  "model_routes": [
    { "hint": "fast", "provider": "groq", "model": "llama-3.3-70b", "cost_class": "free", "quota_class": "unlimited" },
    { "hint": "balanced", "provider": "openrouter", "model": "anthropic/claude-sonnet-4", "cost_class": "standard", "quota_class": "normal" },
    { "hint": "deep", "provider": "openrouter", "model": "anthropic/claude-opus-4", "cost_class": "premium", "quota_class": "constrained" },
    { "hint": "vision", "provider": "openrouter", "model": "openai/gpt-4.1", "cost_class": "standard", "quota_class": "normal" }
  ]
}
```

說明：

- 只有在目前會話沒有被顯式 pin 到某個模型時，`model_routes` 才會生效。
- 如果同時設定了 `deep` 和 `reasoning`，深度分析類請求會優先選擇 `deep`。
- `/model` 還會顯示最近一次自動路由決策，方便查看選中了哪條路線以及原因。
- 如果自動路由命中的提供方遇到配額或限流錯誤，這條路線會被臨時降級，直到冷卻時間結束才會再次嘗試。
- 路由中繼資料只會輕微影響評分，不會推翻保守策略。含糊請求仍然優先留在 `balanced`，`fast` 只給高置信度且便宜的任務，強烈的深度分析訊號仍然會壓過更便宜的路線。

### `agents.list`

- 定義可供 `/delegate` 等工具使用的命名 agent 設定。
- 每個條目既可以顯式寫 `provider` + `model`，也可以直接在 `model.primary` 中寫完整的 `provider/model` 參照。
- 範例：

```json
{
  "agents": {
    "list": [
      {
        "id": "coder",
        "model": { "primary": "ollama/qwen3.5:cloud" },
        "system_prompt": "You're an experienced coder"
      }
    ]
  }
}
```

#### `agents.list[].workspace_path`

當某個命名 agent 需要使用獨立工作區而不是全域工作區時，使用 `workspace_path`。

範例：

```json
{
  "agents": {
    "list": [
      {
        "id": "coder",
        "model": { "primary": "ollama/qwen2.5-coder:14b" },
        "system_prompt": "Focus on implementation and tests.",
        "workspace_path": "agents/coder"
      }
    ]
  }
}
```

行為說明：

- 相對路徑會相對於 `config.json` 所在目錄解析。
- 絕對路徑會原樣使用。
- 設定中可以寫 `/` 或 `\`，執行時會按目前作業系統規範化路徑分隔符。
- `workspace_path` 不會停用 `system_prompt`。如果兩者同時設定，nullclaw 仍會套用命名 agent 的 profile prompt，並從該獨立工作區載入 bootstrap 上下文。
- 首次使用時，如果工作區不存在，nullclaw 會自動建立並初始化：
  - `AGENTS.md`
  - `SOUL.md`
  - `IDENTITY.md`
  - `MEMORY.md`

隔離模型：

- 該 agent 的檔案操作、markdown memory 檔案以及 workspace 相關上下文都會使用這個工作區。
- 設定 `workspace_path` 後，該 agent 還會獲得一個持久 memory namespace，格式為 `agent:<agent-id>`。
- 這個 namespace 會用於：
  - `nullclaw agent --agent <id>`
  - `/subagents spawn --agent <id> ...`
  - 透過 `bindings` 路由到該命名 agent 的會話

實際效果：

- 兩個命名 agent 即使使用相同的 provider/model，也可以保持各自獨立的持久筆記和工作區。
- `workspace_path` 本身不會決定聊天路由；路由仍然由 `bindings`、`/bind` 或顯式 `--agent` / `/subagents spawn --agent` 決定。

### `messages.inbound`

- `debounce_ms` 用來延遲處理連續快速到達的純文字入站訊息，把短時間內的多條碎片合併成一次 turn。
- 預設值：`3000`。
- 作用範圍包括 daemon 路由的入站文字和 Agent CLI REPL。
- 設為 `0` 可關閉。
- slash 命令和帶媒體的入站訊息會跳過 debounce。
- Telegram 仍保留自己的長訊息分段合併邏輯；這裡的值會作為那條邏輯的基礎 debounce 窗口。

範例：

```json
{
  "messages": {
    "inbound": {
      "debounce_ms": 1500
    }
  }
}
```

### `reliability`

- 設定 LLM 提供者的全域重試和故障轉移行為。
- `provider_retries`: 重試失敗的 LLM 請求的次數（預設值：2）。
- `provider_backoff_ms`: 重試之間的初始指數退避延遲（預設值：500 毫秒）。
- `fallback_providers`: 當未顯式指定 provider 的模型需要在主要提供方之外繼續嘗試時，可使用的備用提供方名稱列表。
- `model_fallbacks`: 模型到有序備用模型列表的對應。每個備用項既可以是裸模型名，也可以是顯式的 `provider/model` 參照。

範例：

```json
{
  "reliability": {
    "provider_retries": 2,
    "provider_backoff_ms": 500,
    "fallback_providers": ["groq", "openai"],
    "model_fallbacks": [
      {
        "model": "anthropic/claude-sonnet-4",
        "fallbacks": ["openai/gpt-4o", "groq/llama-3.3-70b"]
      }
    ]
  }
}
```

備註：

- 裸模型名的故障轉移順序：先嘗試主要提供方，再依次嘗試每個列出的 `fallback_provider`。
- 像 `openai/gpt-4o` 這樣的顯式 `provider/model` 備用項會直接路由到對應 provider，不會再走通用 provider 扇出鏈路。
- `api_keys`: (可選) 用於在速率限制 (429) 錯誤時輪換的額外 API 金鑰列表。
### `identity`（AIEOS v1.1）

如果你希望執行時身分來自 AIEOS 文件，可以使用這一節。設定後，nullclaw 會把解析後的 AIEOS 內容連同 `AGENTS.md`、`IDENTITY.md` 等工作區身分檔案一起注入 system prompt：

```json
{
  "identity": {
    "format": "aieos",
    "aieos_path": "./identity/aieos.identity.json"
  }
}
```

也可以直接把同樣的文件內聯到設定裡：

```json
{
  "identity": {
    "format": "aieos",
    "aieos_inline": "{\"identity\":{\"names\":{\"first\":\"nullclaw-assistant\"},\"bio\":\"通用自主助手\"},\"linguistics\":{\"style\":\"concise\"},\"motivations\":{\"core_drive\":\"安全地幫助操作者完成任務\"}}"
  }
}
```

最小 AIEOS v1.1 範例檔案（`identity/aieos.identity.json`）：

```json
{
  "identity": {
    "names": {
      "first": "nullclaw-assistant"
    },
    "bio": "通用自主助手"
  },
  "linguistics": {
    "style": "concise"
  },
  "motivations": {
    "core_drive": "安全地幫助操作者完成任務"
  }
}
```

說明：

- AIEOS payload 採用 `identity`、`psychology`、`linguistics`、`motivations`、`capabilities` 等頂層 section。
- 為了可維護性和版本控制可讀性，優先使用 `aieos_path`。
- 只有在你確實需要單檔案自包含設定時，再使用 `aieos_inline`。
- `identity.format` 應與 payload 來源保持一致，也就是 `aieos`。
- 相對路徑的 `aieos_path` 會優先按目前 workspace 解析，找不到時再按目前工作目錄解析。

### `channels`

- 頻道設定統一在 `channels.<name>` 下。
- 多帳號頻道通常用 `accounts` 包裹。

外部頻道插件範例：

```json
{
  "channels": {
    "external": {
      "accounts": {
        "wa-web": {
          "runtime_name": "whatsapp_web",
          "transport": {
            "command": "nullclaw-plugin-whatsapp-web",
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

外部頻道說明：

完整的協定、生命週期、metadata 約定和插件作者契約，請繼續看
[外部頻道插件](./external-channels.md)。

- `runtime_name` 是 nullclaw 內部使用的執行時頻道 id，routing、bindings、session key 和出站分發都會使用它。它不能複用內建 channel 名稱，也不能和任何其他已設定 channel 已佔用的執行時名字衝突。
- `transport.command` 和可選的 `transport.args` 會把插件作為子行程啟動，並透過 stdio 上的逐行 JSON-RPC 通訊。
- `transport.timeout_ms` 會限制 host 到插件的 RPC 等待時間；同時 nullclaw 還會在內部對 control-plane 請求做上限裁剪，避免一個壞插件把 supervision 卡住幾分鐘。
- `transport.env` 只會傳給插件行程本身。
- `config` 必須是 JSON object；它會原樣透傳給插件 `start` 請求裡的 `params.config`。
- 插件必須回應 `get_manifest`，處理 `start`、`send`、`stop`；建議實作 `health`，這樣 supervision 才能識別「行程活著但 sidecar 已斷開」的狀態。
- `get_manifest.result` 現在必須顯式宣告 `protocol_version: 2`；`capabilities.health`、`capabilities.streaming`、`capabilities.send_rich`、`capabilities.typing`、`capabilities.edit`、`capabilities.delete`、`capabilities.reactions`、`capabilities.read_receipts` 都是可選能力標記。
- `health.result` 必須返回顯式布林值（`healthy`）或顯式健康訊號（`ok`、`connected`、`logged_in`）；空物件會被視為無效回應。
- `start.params` 現在包含巢狀的 `runtime` 物件，裡面有 `name`、`account_id` 和 host 提供的 `state_dir`。
- `start.result` 必須返回 `started: true`；`send`、`send_rich`、`edit_message`、`delete_message` 以及其他 typing/message-action RPC 在真正接受動作時都必須返回 `result.accepted: true`。僅僅沒有 JSON-RPC `error` 已經不夠了。
- `send.params` 現在也拆成巢狀的 `runtime` 和 `message` 物件；文字欄位統一使用 `message.text`。
- 如果插件同時宣告了 `capabilities.edit=true` 和 `capabilities.delete=true`，那麼 `send.result` 還可以返回 `message_id`，或者返回 `message { target?, message_id }`；這樣 nullclaw 就能在不支援原生 `.chunk` 串流發送的頻道上維護一條可編輯的草稿訊息。
- 如果 `capabilities.streaming=true`，nullclaw 可能在模型串流輸出時發送 `.chunk` 階段的 `send` 事件；如果缺省或為 `false`，只會發送最終結果。
- 如果 `capabilities.send_rich=true`，host 還可能呼叫 `send_rich`，其參數同樣包含巢狀的 `runtime` 和 `message { target, text, attachments, choices }`。
- 如果 `capabilities.typing=true`，host 還可能呼叫 `start_typing` / `stop_typing`，參數包含巢狀的 `runtime` 和 `recipient`。
- 如果宣告了 `capabilities.edit=true` / `capabilities.delete=true`，host 還可能呼叫 `edit_message` / `delete_message`。
- 如果宣告了 `capabilities.reactions=true` 或 `capabilities.read_receipts=true`，host 還可能呼叫 `set_reaction` 和 `mark_read`。
- `inbound_message.params.message` 必須包含 `sender_id`、`chat_id`、`text`；如果帶了 `metadata`，它必須是 JSON object；如果帶了 `media`，它必須是由非空字串組成的陣列。
- 如果希望 unknown channel 也能正確做 routing/bindings，建議在 `metadata` 裡帶上 `peer_kind` 和 `peer_id`。
- unknown/external channel 也可以提供 `metadata.is_group`、`metadata.is_dm` 或 `metadata.typing_recipient`，nullclaw 會把這些資訊提升到 prompt 的 conversation context 和處理狀態路由裡。
- PR #265 的 WhatsApp Web bridge 相容適配器範例放在 `examples/whatsapp-web/nullclaw-plugin-whatsapp-web`。
- 生產級的配套倉庫已經移到倉庫外：[nullclaw/nullclaw-channel-baileys](https://github.com/nullclaw/nullclaw-channel-baileys) 和 [nullclaw/nullclaw-channel-whatsmeow-bridge](https://github.com/nullclaw/nullclaw-channel-whatsmeow-bridge)。
- `nullclaw channel start external` 會啟動第一個已設定的外部帳號；`nullclaw channel start <runtime_name>` 可以直接啟動某個具體執行時名字，比如 `whatsapp_web`。

Telegram 範例：

```json
{
  "channels": {
    "telegram": {
      "accounts": {
        "main": {
          "bot_token": "123456:ABCDEF",
          "allow_from": ["YOUR_TELEGRAM_USER_ID"]
        }
      }
    }
  }
}
```

規則說明：

- `allow_from: []` 表示拒絕所有入站訊息。
- `allow_from: ["*"]` 表示允許所有來源（僅在你明確接受風險時使用）。

Telegram forum topics：

- Topic 會話隔離是自動的，`channels.telegram` 下無需單獨設定 `topic_id` 欄位。
- 實際操作流程：
  1. 在 `agents.list` 中設定命名 agent 設定
  2. 開啟目標 Telegram 群組或 forum topic
  3. 發送 `/bind <agent>`
- 如果要讓某個 forum topic 使用特定 agent，在 `bindings` 中設定 `match.peer.id = "<chat_id>:thread:<topic_id>"`。
- 如果還需要為同一 Telegram 群組的其餘部分設定兜底 agent，再新增一條 binding，peer id 為純群組 id `"<chat_id>"`。
- `/bind status` 顯示目前生效的路由和可用 agent id。
- `/bind clear` 僅移除目前 account/chat/topic 的精確 binding，讓路由回退到更寬泛的比對。
- `/bind` 會為目前 Telegram account 和 peer 寫入一條精確的 `bindings[]` 條目。
- Topic 級 binding 優先於群組級兜底（按路由優先級，與 `bindings[]` 中的順序無關）。
- Telegram 選單中 `/bind` 的可見性由 `channels.telegram.accounts.<id>.binding_commands_enabled` 控制。

範例：

```json
{
  "bindings": [
    {
      "agent_id": "coder",
      "match": {
        "channel": "telegram",
        "account_id": "main",
        "peer": { "kind": "group", "id": "-1001234567890:thread:42" }
      }
    },
    {
      "agent_id": "orchestrator",
      "match": {
        "channel": "telegram",
        "account_id": "main",
        "peer": { "kind": "group", "id": "-1001234567890" }
      }
    }
  ]
}
```

上述設定中，topic `42` 路由到 `coder`，群組其餘部分兜底到 `orchestrator`。

命名 agent 設定與 bindings 是獨立關注點：`agents.list` 定義可複用的設定，`bindings` 決定哪個設定用於哪個 chat/topic。

完整端到端範例：

```json
{
  "agents": {
    "list": [
      {
        "id": "orchestrator",
        "provider": "openrouter",
        "model": "anthropic/claude-sonnet-4"
      },
      {
        "id": "coder",
        "provider": "ollama",
        "model": "qwen2.5-coder:14b",
        "system_prompt": "You are the coding agent for this topic."
      }
    ]
  },
  "channels": {
    "telegram": {
      "accounts": {
        "main": {
          "bot_token": "123456:ABCDEF",
          "allow_from": ["YOUR_TELEGRAM_USER_ID"],
          "binding_commands_enabled": true,
          "topic_commands_enabled": true,
          "topic_map_command_enabled": true,
          "commands_menu_mode": "scoped"
        }
      }
    }
  },
  "bindings": [
    {
      "agent_id": "orchestrator",
      "match": {
        "channel": "telegram",
        "account_id": "main",
        "peer": { "kind": "group", "id": "-1001234567890" }
      }
    }
  ]
}
```

操作流程：

- 在目標 forum topic 中發送 `/bind coder`。
- `nullclaw` 會為該 topic 和 Telegram account 寫入一條新的精確 `bindings[]` 條目到 `~/.nullclaw/config.json`。
- 該 topic 中的下一條訊息將使用新路由的 agent 設定。
- `nullclaw` 必須對 `~/.nullclaw/config.json` 有寫入權限，`/bind` 才能持久化變更。

關於 `account_id`：

- `account_id` 標識的是設定中的 Telegram 帳號條目，不是 topic 也不是 agent。
- 在標準 `channels.telegram.accounts` 佈局中，物件 key 就是 account id。例如 `accounts.main` 意味著 `account_id = "main"`。
- `bindings` 中的 `match.account_id` 將 binding 限定到某個特定 Telegram 帳號。
- 如果省略 `match.account_id`，該 binding 可比對該 channel 下的任意 Telegram 帳號。
- 只有同一個 nullclaw 實例執行多個 Telegram bot 帳號/token 時，不同 account id 才有意義。

### Web UI / Browser Relay

`channels.web` 用於瀏覽器 UI / 擴充功能透過 WebSocket 接入，預設路徑是 `/ws`。

範例：

```json
{
  "channels": {
    "web": {
      "accounts": {
        "default": {
          "transport": "local",
          "listen": "127.0.0.1",
          "port": 32123,
          "path": "/ws",
          "auth_token": "replace-with-long-random-token",
          "message_auth_mode": "pairing",
          "allowed_origins": ["http://localhost:5173"]
        }
      }
    }
  }
}
```

實用規則：

- 想使用「先連上再配對」的本地體驗，保持 `listen = "127.0.0.1"`。
- 在 local transport 下，只有 loopback 才允許未驗證的 WebSocket upgrade；這樣 UI 才能先連上，再發送 `pairing_request`。
- 如果把 `listen` 改成 `0.0.0.0` 或其他非 loopback 地址，那麼 WebSocket upgrade 一開始就必須帶上 channel token：
  - `ws://host:32123/ws?token=<auth_token>`
  - 或 `Authorization: Bearer <auth_token>`
- 非 loopback bind 下，不要假設 local `pairing_request` 還能在未驗證連線上工作；這個 pairing-first 流程本來就是只給 loopback 用的。
- `message_auth_mode = "pairing"` 表示每條 `user_message` 都要帶上 pairing 流程返回的 UI `access_token`。
- `message_auth_mode = "token"` 只支援 local transport，並且要求使用設定或環境變數中的穩定 token。此模式下，UI 每條 `user_message` 發送 `auth_token`，而不是 pairing JWT。
- `auth_token` 既可以加固 WebSocket upgrade，在非 loopback bind 時也會變成必要項目。
- WebSocket 端點用的是 `/ws`。`/pair` 屬於 HTTP gateway API，不是 web channel 的 WebSocket 配對入口。
- 對於 headless/LAN 場景，更穩妥的運維路徑仍然是 SSH 隧道，或者在 loopback 綁定前面加反向代理。

遠端 / 無頭裝置範例：

```json
{
  "channels": {
    "web": {
      "accounts": {
        "default": {
          "transport": "local",
          "listen": "0.0.0.0",
          "port": 32123,
          "path": "/ws",
          "auth_token": "replace-with-long-random-token",
          "message_auth_mode": "token",
          "allowed_origins": ["https://chat-ui.example.com"]
        }
      }
    }
  }
}
```

Max 範例：

```json
{
  "channels": {
    "max": [
      {
        "account_id": "main",
        "bot_token": "MAX_BOT_TOKEN",
        "allow_from": ["YOUR_MAX_USER_ID"],
        "group_allow_from": ["YOUR_MAX_USER_ID"],
        "group_policy": "allowlist",
        "mode": "webhook",
        "webhook_url": "https://bot.example.com/max?account_id=main",
        "webhook_secret": "replace-with-random-secret",
        "require_mention": true,
        "streaming": true,
        "interactive": {
          "enabled": true,
          "ttl_secs": 900,
          "owner_only": true
        }
      }
    ]
  }
}
```

Max 說明：

- `channels.max` 是帳號條目陣列；`account_id` 用於區分多個 Max bot。
- 生產環境推薦 `mode = "webhook"`。Max 文件將 long polling 定位為開發/測試用途，webhook 是推薦的生產路徑。
- `webhook_url` 必須使用 HTTPS。
- 多帳號 webhook 場景下，每個帳號應使用獨立的 `webhook_secret` 或在 webhook URL 中使用獨立的 `account_id` query，例如 `/max?account_id=main`。
- `allow_from` 和 `group_allow_from` 接受 Max `user_id` 或使用者名稱。`user_id` 是更穩定的選擇。
- `require_mention = true` 僅影響群聊。私聊和 `bot_started` deep link 不受影響。
- Max inline button 在 nullclaw 中是一次性的：有效點擊後原始鍵盤會被清除，避免過期按鈕。

### `memory`

- `backend`: 建議從 `sqlite` 開始。可選引擎：`sqlite`、`markdown`、`clickhouse`、`postgres`、`redis`、`lancedb`、`lucid`、`memory`（LRU）、`api`、`none`。
- `auto_save`: 開啟後會自動持久化會話記憶。
- 可擴充 hybrid 檢索與 embedding 設定（見根目錄 `config.example.json`）。

**注意**：`markdown_only` 記憶體設定檔會自動啟用混合檢索和時間衰減（半衰期 30 天），以實現最佳的相關性評分。這確保了對純 markdown 檔案的時間感知能力。

### `gateway`

- 預設推薦：
  - `host = "127.0.0.1"`
  - `require_pairing = true`
- 不建議直接公網監聽；如需外網存取，優先使用 tunnel。

| 欄位 | 預設值 | 說明 |
|------|--------|------|
| `host` | `"127.0.0.1"` | 監聽地址 |
| `port` | `3000` | 監聽連接埠 |
| `require_pairing` | `true` | 所有 API 請求均需 bearer token |
| `allow_public_bind` | `false` | 允許綁定非回環地址 |
| `pair_rate_limit_per_minute` | `10` | 每 IP 每分鐘最大 `/pair` 請求數 |
| `webhook_rate_limit_per_minute` | `60` | 每 IP 每分鐘最大 webhook 請求數 |
| `idempotency_ttl_secs` | `300` | 冪等請求結果快取時長（秒） |
| `max_body_size_bytes` | `65536` | HTTP 請求體最大位元組數（64 KB）。接受圖片或檔案負載時需調高（如 `20971520` 表示 20 MB）。 |
| `request_timeout_secs` | `30` | 入站 HTTP 請求的 socket 讀取逾時（秒）。在慢速或高延遲連線下接受大體積負載時需調高。 |

### `tunnel`

隧道服務，用於將本地閘道器暴露到公網。當沒有公網 IP 但需要接收 webhook 回調時使用。

**支援的隧道：**

| 隧道 | 說明 |
|--------|------|
| `none` | 不使用隧道（預設） |
| `cloudflare` | Cloudflare Tunnel |
| `ngrok` | ngrok 隧道 |
| `tailscale` | Tailscale Funnel |
| `custom` | 自訂命令啟動隧道 |

**ngrok 範例：**

```json
{
  "tunnel": {
    "provider": "ngrok",
    "ngrok": {
      "auth_token": "YOUR_NGROK_AUTH_TOKEN",
      "domain": "your-domain.ngrok-free.app"
    }
  }
}
```

**Cloudflare 範例：**

```json
{
  "tunnel": {
    "provider": "cloudflare",
    "cloudflare": {
      "token": "YOUR_CLOUDFLARE_TUNNEL_TOKEN"
    }
  }
}
```

**注意：**

- 隧道會在閘道器啟動前自動啟動。
- 啟動後公網 URL 會列印到主控台，同時寫入 `daemon_state.json`。

### `autonomy`

- `level`: 推薦先用 `supervised`。
- `workspace_only`: 建議保持 `true`，限制檔案存取範圍。
- `max_actions_per_hour`: 建議保守設定，避免高頻自動動作。

### `security`

- `sandbox.backend = "auto"`：自動選擇可用隔離後端（如 landlock/firejail/bubblewrap/docker）。
- `audit.enabled = true`：建議開啟稽核日誌。

### 進階：Web Search + Full Shell（高風險）

僅在你明確理解風險時使用。範例：

```json
{
  "http_request": {
    "enabled": true,
    "allowed_domains": ["192.168.1.10", "*.internal.example.com"],
    "search_base_url": "https://searx.example.com",
    "search_provider": "auto",
    "search_fallback_providers": ["jina", "duckduckgo"]
  },
  "autonomy": {
    "level": "full",
    "allowed_commands": ["*"],
    "allowed_paths": ["*"],
    "require_approval_for_medium_risk": false,
    "block_high_risk_commands": false
  }
}
```

注意：

- `search_base_url`（用於 web_search 工具）：必須是 `https://host[/search]` 或本地/內網的 `http://host[:port][/search]` URL。HTTP 僅允許用於 localhost/私有主機（如 `http://localhost:8888`、`http://192.168.1.10:8888`）。此 URL 供 `web_search` 工具查詢 SearXNG 實例使用。
- `allowed_commands: ["*"]` 與 `allowed_paths: ["*"]` 會顯著擴大執行範圍。
- `http_request.allowed_domains`：繞過 SSRF 保護的網域列表，用於 `http_request` 和 `web_fetch` 工具。
  - `[]` (空陣列)：所有網域經過 SSRF 檢查（預設，最安全）。
  - `["example.com"]`：只有指定網域跳過 SSRF 保護。
  - `["*.example.com"]`：比對所有子網域（如 `api.example.com`、`www.example.com`）。
  - `["192.168.1.10"]`：IP 地址也可以加入白名單（僅支援精確比對，不支援 CIDR 範圍）。
  - `["*"]`：**危險** - 所有網域跳過 SSRF 保護和 DNS 釘扎。僅用於可信網路環境，當你控制 DNS 且需要存取任意 IP 地址時使用。這實際上停用了 SSRF 保護。
  - **範例**：如果你的 SearXNG 執行在 `192.168.1.10`，新增 `"192.168.1.10"` 即可透過 `http_request` 工具存取它。
  - **安全權衡**：白名單網域跳過 DNS 釘扎，允許存取私有 IP。這是用 DNS 重新綁定防護換取操作靈活性。
  - **HTTPS-only 策略**：`http_request` 和 `web_fetch` 工具要求使用 `https://` URL。明文 HTTP 因安全原因被拒絕。注意：這不影響 `web_search` 工具的 `search_base_url`，後者允許本地主機使用 HTTP。
  - **檢查順序**：白名單在 DNS 解析之前檢查，防止 DNS 滲漏攻擊。

## 設定變更後的驗證

每次改完設定建議執行：

```bash
nullclaw doctor
nullclaw status
nullclaw channel status
```

如果你修改了 gateway 或 channel，額外執行：

```bash
nullclaw gateway
```

確認服務能正常啟動且日誌無錯誤。

## 下一步

- 要驗證設定是否可用：繼續看 [使用與運維](./usage.md)，按回歸檢查清單逐項執行。
- 要加固預設邊界：繼續看 [安全機制](./security.md)，確認 pairing、sandbox 與 allowlist 設定。
- 要對接 webhook 或長期執行閘道器：繼續看 [Gateway API](./gateway-api.md) 和 [命令參考](./commands.md)。

## 相關頁面

- [安裝指南](./installation.md)
- [使用與運維](./usage.md)
- [安全機制](./security.md)
- [Gateway API](./gateway-api.md)
