# 架構總覽

NullClaw 採用 vtable 可插拔架構。多數能力透過介面實作並在工廠註冊，不需要改核心呼叫鏈。

## 頁面導航

- 這頁適合誰：想理解 NullClaw 模組邊界、擴展點和實作取捨的開發者與維護者。
- 看完去哪裡：準備改程式碼看 [開發指南](./development.md)；要對照執行時設定看 [設定指南](./configuration.md)；涉及高風險邊界看 [安全機制](./security.md)。
- 如果你是從某頁來的：從 [README](./README.md) 來，這頁提供整體腦圖；從 [開發指南](./development.md) 來，這頁用於補齊介面與工廠層理解；從 [安全機制](./security.md) 來，可在這裡回看 `security`、`runtime`、`gateway` 所在層次。

## 設計核心

- 所有子系統透過統一介面抽象：`ptr: *anyopaque + vtable`。
- 執行時透過工廠選擇實作，替換 provider/channel/tool/memory 不需要改業務層。
- 目標是低開銷、可移植、可擴展。

## 子系統與擴展點

| 子系統 | 介面 | 內建實作（節選） | 擴展方式 |
|---|---|---|---|
| AI Models | `Provider` | OpenRouter、Anthropic、OpenAI、Azure OpenAI、Gemini、Vertex AI、Ollama、Groq、Mistral、xAI、DeepSeek、Together、Fireworks、Perplexity、Cohere、Bedrock、Venice 等 50+ | 新增 provider 實作並註冊 |
| Channels | `Channel` | CLI、Telegram、Signal、Discord、Slack、Matrix、WhatsApp、Nostr、IRC、Lark、Line、DingTalk、Email、OneBot、QQ、MaixCam、Mattermost、iMessage、Web | 新增 channel 實作並註冊 |
| Memory | `Memory` | SQLite（hybrid 檢索）、Markdown、ClickHouse、PostgreSQL、Redis、LanceDB、Lucid、LRU、API、None | 新增 memory backend |
| Tools | `Tool` | shell、file_read、file_write、file_edit、file_edit_hashed、file_read_hashed、file_append、http_request、web_fetch、web_search、delegate、screenshot、browser_open 等 35+ | 新增 tool 實作 |
| Observability | `Observer` | Noop、Log、File、Multi | 對接監控系統 |
| Runtime | `RuntimeAdapter` | Native、Docker、WASM | 新增 runtime adapter |
| Security | `Sandbox` | Landlock、Firejail、Bubblewrap、Docker(auto) | 新增 sandbox backend |
| Tunnel | `Tunnel` | None、Cloudflare、Tailscale、ngrok、Custom | 新增 tunnel provider |
| Peripheral | `Peripheral` | Serial、Arduino、RPi GPIO、STM32/Nucleo | 新增硬體外設驅動 |

## Memory 子系統

| 層 | 實作 |
|---|---|
| Vector 檢索 | embedding 以 BLOB 儲存在 SQLite，使用 cosine similarity |
| Keyword 檢索 | SQLite FTS5 + BM25 |
| Hybrid 合併 | vector + keyword 加權合併 |
| EmbeddingProvider | 透過 vtable 接入 OpenAI/自訂/noop |
| 資料生命週期 | 自動歸檔 + 清理 |
| 快照遷移 | 全量匯出/匯入 memory 狀態 |
| 引擎 | SQLite（預設）、Markdown、ClickHouse、PostgreSQL、Redis、LanceDB、Lucid、LRU、API、None |

## 架構約束（實戰建議）

1. 優先透過新增實作擴展，不直接侵入核心流程。
2. 保持模組職責單一：provider 不跨層相依 channel 內部。
3. 變更高風險路徑（security/runtime/gateway/tools）時，必須補失敗路徑驗證。

## 下一步

- 要開始改實作：繼續看 [開發指南](./development.md)，再回到本頁對照模組邊界。
- 要確認 CLI 與使用者側入口：繼續看 [命令參考](./commands.md) 與 [設定指南](./configuration.md)。
- 要審視高風險模組：繼續看 [安全機制](./security.md) 和 [Gateway API](./gateway-api.md)。

## 相關頁面

- [中文說明文件入口](./README.md)
- [開發指南](./development.md)
- [設定指南](./configuration.md)
- [安全機制](./security.md)
