# NullClaw 新手入門指南

**閱讀對象：** 非技術背景的使用者。你不需要知道什麼是 vtable、sandbox 或 WASM 模組。本文使用通俗易懂的語言，從頭解釋每個概念。

---

## 頁面導航

**本文適合誰**
- 你下載或安裝了 NullClaw，想在深入設定之前先了解它是什麼。
- 你從未設定過 AI 模型、設置過 webhook 或編輯過 JSON 檔案。
- 你想用日常語言了解 NullClaw 能為你做什麼。

**開始前需要準備什麼**
- 一台執行 macOS、Linux 或 Windows 的電腦。
- 一個來自支援提供商的 API 金鑰（本指南會逐步演示如何取得）。

**看完本文後**
- 繼續閱讀 [安裝指南](./installation.md)，取得在系統上安裝 NullClaw 的具體命令。
- 然後繼續閱讀 [設定指南](./configuration.md)，逐步完成設定。
- 學習過程中可以隨時回到本文作為參考。

---

## 1. NullClaw 是什麼？

**一句話概括：** NullClaw 是一個小型、快速、安全的 AI 助手，完全執行在你自己的機器上。它沒有內建 AI 模型——你需要連接一個自己選擇並付費的模型提供商，例如 OpenRouter、OpenAI 或 Anthropic。

可以這樣理解：

| 比喻 | 含義 |
|---|---|
| NullClaw 是**大腦** | 它負責傾聽、思考、規劃和行動。 |
| 你的 AI 提供商（OpenRouter 等）是**知識引擎** | 它產生文字、回答問題、處理圖片。 |
| **頻道**（Telegram、Discord 等）是你的**通訊方式** | 就像選擇電子郵件還是簡訊——頻道負責傳遞訊息。 |

**為什麼要用它，而不是直接打開 ChatGPT？**

| 使用場景 | ChatGPT | NullClaw |
|---|---|---|
| 在 Telegram 或 Discord 裡跟機器人聊天 | 不支援 | 支援——直接連接 |
| 能讀寫你電腦上的檔案 | 非常有限 | 支援——完整存取 |
| 能執行 shell 指令 | 不支援 | 支援——安全沙箱保護 |
| 能在 5 美元的樹莓派上執行 | 不支援 | 支援 |
| 所有資料保留在本地 | 不支援 | 支援 |
| 連接到你的自有基礎設施 | 不支援 | 支援 |
| 完全離線（無需 API 金鑰） | 不支援 | 不支援——需要 API 金鑰 |

NullClaw 最適合**進階使用者**和**開發者**，他們希望 AI 按照自己的方式、在自己的硬體上執行，連接到自己的工具和頻道。

---

## 2. 你可以要求 NullClaw 做什麼？

設定完成後，NullClaw 可以處理各種任務。以下是通俗語言描述的範例：

**資訊查詢與研究**
- 「總結這個 URL 的文章內容」
- 「今天東京的天氣怎麼樣？」（透過網頁搜尋工具）
- 「找出上週所有關於專案 X 的郵件」

**檔案操作**
- 「讀取我工作區裡叫 notes.md 的檔案」
- 「把會議摘要寫到 meeting-notes.md 裡」
- 「把會議記錄追加到每日日誌中」
- 「修改 README，新增安裝說明」

**Shell 與系統**
- 「檢查還剩多少磁碟空間」
- 「顯示伺服器日誌的最後 50 行」
- 「執行備份腳本，告訴我是否成功」

**程式設計與開發**
- 「寫一個 Python 腳本，讀取 CSV 檔案並輸出柱狀圖」
- 「解釋這個錯誤訊息是什麼意思」
- 「給登入函式新增一個單元測試」

**自動化**
- 「每天早上 9 點提醒我檢查伺服器狀態」
- 「當我在 Telegram 上發送包含 'deploy' 的訊息時，執行部署腳本」
- 「把這個重要筆記存入記憶，下次我問的時候提醒我」

**通訊頻道**
- 「給我的 Discord 頻道發一則訊息」
- 「回覆剛剛給我發訊息的 Telegram 使用者」
- 「在我們的 Slack 頻道發布一則更新」

**硬體操作（進階）**
- 「讀取連接到我樹莓派的溫度感測器的資料」
- 「讓連接在 Arduino 13 號腳位的 LED 閃爍」

---

## 3. 核心概念：各部分如何配合運作

在設定任何東西之前，理解三個核心部分會很有幫助：

### 部分 1 — 聊天介面（如何與它對話）

與 NullClaw 互動有兩種方式：

**CLI 模式（命令列）：** 在終端機視窗中輸入訊息。適合快速任務和測試。

```bash
nullclaw agent -m "2 + 2 等於多少？"
```

**互動模式：** 一個更對話化的會話，保持開啟狀態：

```bash
nullclaw agent
# 然後輸入你的訊息
```

**Gateway 模式：** 最強大的設定方式。啟動一個本地 Web 伺服器，監聽訊息。其他程式或頻道（Telegram、Discord 等）可以連接到它並投遞使用者訊息。這就是讓 NullClaw 在 Telegram 或 Discord 裡回應的方法。

```bash
nullclaw gateway
# 執行在 http://127.0.0.1:3000
```

### 部分 2 — 頻道（訊息如何進出）

**頻道**是 NullClaw 和訊息服務之間的橋樑。就像一條電話線——每個頻道是不同的電話號碼。

NullClaw 開箱即支援多種頻道：

| 頻道 | 連接目標 |
|---|---|
| CLI | 你的終端機（無外部連接） |
| Telegram | 你的 Telegram 機器人 |
| Discord | 你的 Discord 機器人 |
| Signal | 你的 Signal 帳號 |
| Slack | 你的 Slack 工作區 |
| WhatsApp | 你的 WhatsApp Business 帳號 |
| Email | 你的電子郵件收件匣和發信服務 |
| Matrix | Matrix/Element 訊息平台 |
| Nostr | Nostr 去中心化協定 |
| Webhook | 任何 HTTP 端點（用於自訂整合） |
| IRC | 網際網路中繼聊天 |
| Lark / 飛書 | 飛書工作區 |
| DingTalk | 釘釘工作區 |
| QQ | QQ 訊息平台 |
| iMessage | macOS iMessage |
| Mattermost | Mattermost 自託管聊天 |

**重要的安全概念：** 預設情況下，頻道只接受來自你指定的白名單使用者的訊息。白名單為空的頻道不接受任何人。這是刻意的設計——防止陌生人控制你的 AI。

### 部分 3 — Gateway（訊息路由器）

**Gateway** 是中心樞紐，負責：
1. 從頻道（Telegram、Discord 等）接收訊息
2. 將訊息發送給 AI 進行處理
3. 將 AI 的回應透過正確的頻道發回去

```
使用者發送訊息
       ↓
   頻道（Telegram/Discord 等）
       ↓
   Gateway（訊息路由器，連接埠 :3000）
       ↓
   AI 模型（OpenRouter/OpenAI 等）
       ↓
   NullClaw 大腦（思考、使用工具、決策）
       ↓
   回覆
       ↓
   Gateway → 頻道 → 使用者
```

預設情況下，Gateway 只監聽你本地機器（`127.0.0.1:3000`）。這意味著外部沒有任何人能存取它。要允許外部存取（例如接收來自網際網路的 Telegram 訊息），你需要使用**隧道（Tunnel）**——一種透過 Cloudflare 或 ngrok 等服務將你的本地 Gateway 安全暴露給外部世界的方式。

---

## 4. 五分鐘快速上手

### 步驟 1 — 取得 API 金鑰

NullClaw 需要一個 AI 模型來思考。你需要提供 API 金鑰。最簡單的開始方式是 **OpenRouter**，它透過單一帳號提供對多種模型的存取：

1. 前往 [openrouter.ai](https://openrouter.ai) 並建立一個免費帳號。
2. 進入**金鑰（Keys）**頁面，建立一個新 API 金鑰。複製它——你只會看到一次。
3. （選用）為帳號儲值，以便 AI 能實際回應。即使 5 美元也足夠嘗試所有功能。

> **什麼是 API 金鑰？** 可以把它想像成密碼。它向 AI 服務證明你是誰，並記錄你的用量。妥善保管它——任何擁有你金鑰的人都可以使用你的帳號。

### 步驟 2 — 安裝 NullClaw

**macOS / Linux（推薦）：**

```bash
brew install nullclaw
```

**Windows：**

從 [NullClaw 發布頁](https://github.com/nullclaw/nullclaw/releases) 下載 Windows `.zip` 壓縮包，解壓後將其中的 `nullclaw.exe` 放到你能找到的地方。

**從原始碼建置（所有平台）：**

```bash
git clone https://github.com/nullclaw/nullclaw.git
cd nullclaw
zig build -Doptimize=ReleaseSmall
# 二進位檔案位於 zig-out/bin/nullclaw
```

### 步驟 3 — 設定 NullClaw

執行互動式設定精靈：

```bash
nullclaw onboard --interactive
```

精靈會問你一些問題。以下是每個問題的含義：

| 問題 | 如何回答 |
|---|---|
| Provider（提供商） | 選擇 `openrouter` |
| API Key | 貼上你的 OpenRouter 金鑰 |
| Default model（預設模型） | 直接按 Enter 接受建議的模型 |
| Workspace directory（工作區目錄） | 直接按 Enter 使用預設路徑（NullClaw 存放檔案的地方） |
| Gateway host | 直接按 Enter（保持本地和安全） |
| Gateway port | 直接按 Enter（預設為 3000） |
| Enable channels?（啟用頻道？） | 如果只想先試用 CLI 模式，輸入 `n` |

### 步驟 4 — 測試

```bash
nullclaw agent -m "你好！你能介紹一下你自己嗎？"
```

幾秒內你應該會收到 AI 的回覆。

### 步驟 5 — 啟動 Gateway

如果你想讓 NullClaw 監聽來自 Telegram、Discord 或其他頻道的訊息：

```bash
nullclaw gateway
```

你會看到確認訊息，表明 Gateway 正在 `127.0.0.1:3000` 執行。

要停止它，按 `Ctrl+C`。

---

## 5. 記憶系統如何運作

NullClaw 內建了記憶系統。這意味著它可以記住你在多次對話中告訴它的事情。

### 它如何存放記憶

記憶存放在你電腦上的本地資料庫中（預設情況下是 `~/.nullclaw/memory.db` 的 SQLite 資料庫）。除非你設定了遠端記憶後端，否則不會發送到雲端。

### 記憶操作類型

| 命令 | 功能 |
|---|---|
| `/memory-store <事實>` | 將一個事實儲存到長期記憶 |
| `/memory-recall <主題>` | 擷取與某個主題相關的事實 |
| `/memory-forget <事實>` | 從記憶中刪除一個特定事實 |
| `/memory-list` | 列出目前記憶中所有內容 |
| `/scratch` | 開啟一個暫時記事本，用於快速記錄 |

### 對話範例

```
你：記住，我的伺服器管理員密碼是 SuperSecret123。
NullClaw：好的。我已經把這個事實安全地存入記憶了。

你：我之前跟你說過關於我伺服器的什麼？
NullClaw：你提到過你的伺服器管理員密碼是 SuperSecret123。
```

### 何時清理記憶

- 你不小心分享了敏感資訊 → 使用 `/memory-forget` 或讓 NullClaw 刪除它。
- 記憶變得不準確了 → 用更正確的版本更新它。
- 你想要一個全新的開始 → 執行 `nullclaw memory purge` 清除所有內容。

> **隱私提示：** 預設情況下，所有記憶資料都保留在你的機器上。NullClaw 不會把你的對話歷史或記憶內容發送到 AI 提供商，除非你明確設定了遠端記憶後端。

---

## 6. 安全功能：保護你自己

NullClaw 內建了多項安全功能。你不需要理解技術細節——只需要知道它們存在。

### 功能 1 — 工作區隔離（它能存取哪些檔案）

預設情況下，NullClaw 只能在名為**工作區（workspace）**的特定資料夾中讀寫檔案。它無法存取你的整個檔案系統。這防止它意外讀取敏感檔案，如密碼、SSH 金鑰或個人文件。

工作區通常位於 `~/.nullclaw/workspace/`。你可以在設定中更改它。

### 功能 2 — 沙箱（它能執行哪些指令）

當 NullClaw 需要執行 shell 指令（如 `ls` 或 `git`）時，它會在**沙箱（sandbox）**中執行——一個限制指令行為的受限環境。它不能：
- 存取工作區以外的檔案
- 修改系統設定
- 安裝軟體
- 存取其他使用者的資料

### 功能 3 — 配對（誰能使用 Gateway）

當 Gateway 執行時，它使用**配對（pairing）**——一個安全檢查，要求任何連接者提供有效的配對碼。這防止陌生人對你的 NullClaw 透過 Gateway 發送指令。

### 功能 4 — 頻道白名單（哪些使用者可以和它說話）

每個訊息頻道都有一個**白名單（allowlist）**——批准的使用者 ID 或使用者名稱列表。只有白名單上的使用者才能透過該頻道向 NullClaw 發送訊息。白名單為空的頻道不接受任何人。

### 功能 5 — 加密的金鑰

你的 API 金鑰和其他敏感憑證使用強加密演算法（ChaCha20-Poly1305）**加密存放**在磁碟上。即使有人複製了你的設定檔，沒有加密金鑰也無法讀取你的 API 金鑰。

### 預設情況下 NullClaw 不能做什麼

- 存取工作區以外的檔案
- 沒有設定郵件憑證就發送郵件
- 沒有正確的機器人令牌就發布到頻道
- 不經過沙箱就執行任意 shell 指令
- 沒有明確的隧道設定就不能暴露給公共網際網路

---

## 7. 新手常見錯誤

### 錯誤 1 — 在不理解的情況下將 Gateway 暴露到網際網路

**會發生什麼：** 你設定了 `gateway.host = "0.0.0.0"` 使 Gateway 可從任何地方存取。預設情況下，這是被刻意阻止的。如果你繞過它而沒有設定配對和白名單，陌生人可能會向你的 AI 發送指令。

**解決方法：** 使用隧道（Cloudflare Tunnel、ngrok 或 Tailscale）而不是直接開放連接埠。隧道允許你從外部存取本地 Gateway，同時保持安全控制。

### 錯誤 2 — 公共頻道白名單為空

**會發生什麼：** 你連接了 Telegram 機器人但把 `allow_from` 留空。沒有人能給它發訊息。

**解決方法：** 把你的 Telegram 使用者 ID 設定到 `allow_from` 中。在 Telegram 上使用 `@userinfobot` 可以找到你的使用者 ID。

### 錯誤 3 — API 金鑰和提供商不匹配

**會發生什麼：** 你貼上了 OpenAI 的金鑰但在設定中把提供商設定為 `openrouter`。NullClaw 會拒絕它，因為 OpenRouter 和 OpenAI 的金鑰格式不同。

**解決方法：** 把提供商名稱與金鑰所屬的服務匹配。OpenRouter 金鑰以 `sk-or-` 開頭，OpenAI 金鑰以 `sk-` 開頭。

### 錯誤 4 — 忘記保持 Gateway 執行

**會發生什麼：** 你用 CLI（`nullclaw agent`）開始對話，但期望它回應 Telegram 訊息。CLI 模式和 Gateway 模式是分開的——頻道訊息需要 Gateway 執行才能運作。

**解決方法：** 在終端機視窗中保持 Gateway 執行，或作為背景服務執行（`nullclaw service start`）。使用 `nullclaw service status` 檢查它是否正在執行。

### 錯誤 5 — 把敏感資訊存在錯誤的地方

**會發生什麼：** 你用 `/memory-store` 讓 NullClaw 記住你的密碼。雖然記憶在靜態時是加密的，但在使用時會解密到記憶體中。

**解決方法：** 對於真正敏感的資料使用金鑰管理功能，或者只在記憶系統中存放非敏感的偏好和事實。

---

## 8. 通俗排障指南

| 症狀 | 可能原因 | 嘗試方法 |
|---|---|---|
| 「API 金鑰無效」錯誤 | 金鑰錯誤、提供商錯誤或金鑰已過期 | 執行 `nullclaw onboard --interactive` 重新輸入金鑰 |
| Telegram 機器人無回應 | 機器人令牌錯誤、webhook 未設定或機器人未啟動 | 執行 `nullclaw channel start telegram` 並檢查 Telegram 中的機器人隱私設定 |
| Gateway 無法啟動 | 連接埠 3000 已被佔用 | 用 `nullclaw gateway --port 3001` 更換連接埠 |
| AI 回應但不記得之前的訊息 | 會話歷史未載入或記憶不運作 | 檢查設定中 `memory.auto_save` 是否為 `true` |
| NullClaw 找不到檔案 | 檔案在工作區以外 | 把檔案移入工作區，或檢查你的 `allowed_paths` 設定 |
| 速率限制錯誤（429） | 你觸發了 API 提供商的用量限制 | 等待，或切換到不同的提供商/模型 |

### 診斷指令

執行以下指令取得完整健康檢查：

```bash
nullclaw doctor
```

它會檢查所有內容——設定有效性、API 金鑰、頻道狀態、記憶等。如果需要幫助偵錯，請分享輸出結果。

---

## 9. 術語表

| 術語 | 通俗解釋 |
|---|---|
| **API 金鑰** | 一個密碼，讓 NullClaw 能夠與 AI 服務通訊。妥善保管。 |
| **頻道（Channel）** | 訊息到達 NullClaw 的方式——Telegram、Discord、郵件等。 |
| **Gateway** | 在頻道和 AI 之間路由訊息的中心樞紐。 |
| **提供商（Provider）** | NullClaw 連接的 AI 服務——OpenRouter、OpenAI、Anthropic 等。 |
| **模型（Model）** | 用於特定任務的 AI 大腦——Claude Sonnet、GPT-4o、Llama 等。 |
| **工作區（Workspace）** | NullClaw 被允許存取的電腦上的特定資料夾。 |
| **沙箱（Sandbox）** | 一個受限環境，防止指令做有害的事情。 |
| **配對（Pairing）** | 一個安全碼，防止陌生人使用你的 Gateway。 |
| **白名單（Allowlist）** | 允許透過某個頻道發送訊息的批准使用者列表。 |
| **隧道（Tunnel）** | 一種安全隧道，將你的本地 Gateway 暴露到網際網路。 |
| **記憶（Memory）** | NullClaw 在多次對話中存放事實和偏好的長期儲存。 |
| **工具（Tool）** | NullClaw 可以使用的功能——讀取檔案、執行指令、發送訊息等。 |
| **Agent** | 一個設定好的 NullClaw 實例，有自己的身份、模型和工作區。 |
| **vtable** | （技術術語）一種在不更改呼叫程式碼的情況下交換實作的模式。使用 NullClaw 不需要理解這個。 |

---

## 10. 下一步

- **[安裝指南](./installation.md)** — 在你的系統上安裝 NullClaw。
- **[設定指南](./configuration.md)** — 逐步完成設定。
- **[使用與運維](./usage.md)** — 日常命令和服務管理。
- **[命令參考](./commands.md)** — 完整的 CLI 命令參考。

如果本指南中有不清楚的地方，請在 [github.com/nullclaw/nullclaw](https://github.com/nullclaw/nullclaw) 提交 issue——你的回饋有助於改進文件。
