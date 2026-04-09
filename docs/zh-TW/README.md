# NullClaw 中文文件

本目錄提供面向使用者、運維者與貢獻者的中文文件入口。

社區： [加入 Discord](https://discord.gg/Bfmdua22Ud)

如果你剛接觸 NullClaw，先從這裡找對閱讀路徑，再進入具體章節。

## 頁面怎麼用

**這頁適合誰**

- 剛進入專案、還不知道先看哪篇文件的使用者
- 需要在運維、開發、使用三條路線之間做選擇的人
- 想從中文總覽快速跳到細節頁的貢獻者

**看完先去哪裡**

- 還沒跑起來：先看 [安裝指南](./installation.md)
- 已經裝好，準備接 provider / memory / channel：看 [設定指南](./configuration.md)
- 只想找命令：直接去 [命令參考](./commands.md)

**如果你是從這裡跳過來的**

- `README.md`：把這頁當成中文落地頁，然後按你的目標繼續往下走
- [命令參考](./commands.md)：回到這裡可重新選擇「上手 / 運維 / 開發」的閱讀路徑
- [開發指南](./development.md)：回到這裡可切換到使用者或運維視角的文件

## 從哪開始

### 0. 我沒有任何技術背景

如果這是你第一次接觸 NullClaw、從未設定過 AI 模型、沒編輯過 JSON 檔案，先從這裡開始。

[新手入門指南](./beginners-guide.md)

### 1. 我只想先跑起來

推薦順序：

1. [安裝指南](./installation.md)
2. [設定指南](./configuration.md)
3. [使用與運維](./usage.md)
4. [命令參考](./commands.md)

### 2. 我要部署和長期執行

重點看：

- [使用與運維](./usage.md)
- [安全機制](./security.md)
- [Gateway API](./gateway-api.md)
- [DingTalk 運維就緒](./ops/dingtalk-ops-readiness.md)
- [Lark 運維就緒](./ops/lark-ops-readiness.md)
- [Signal 部署專題](../../SIGNAL.md)

### 3. 我要接入內建頻道之外的系統

重點看：

- [外部頻道插件](./external-channels.md)
- [設定指南](./configuration.md)
- [使用與運維](./usage.md)
- [架構總覽](./architecture.md)

### 4. 我要開發、改程式碼、提 PR

重點看：

- [架構總覽](./architecture.md)
- [開發指南](./development.md)
- [命令參考](./commands.md)
- [貢獻指南](../../CONTRIBUTING.md)

## 文件導航

- [新手入門指南](./beginners-guide.md)  ← 第一次接觸 NullClaw，從這裡開始
- [安裝指南](./installation.md)
- [Termux 指南](./termux.md)
- [設定指南](./configuration.md)
- [使用與運維](./usage.md)
- [架構總覽](./architecture.md)
- [安全機制](./security.md)
- [Gateway API](./gateway-api.md)
- [外部頻道插件](./external-channels.md)
- [命令參考](./commands.md)
- [開發指南](./development.md)

## 運維專題

- [DingTalk 運維就緒](./ops/dingtalk-ops-readiness.md)
- [Lark 運維就緒](./ops/lark-ops-readiness.md)

## 先看這 3 條

1. NullClaw 目前要求 **Zig 0.15.2**（精確版本）。
2. 預設設定檔路徑為 `~/.nullclaw/config.json`（由 `nullclaw onboard` 產生）。
3. 首次上手建議先跑 `onboard --interactive`，再用 `agent` 和 `gateway` 驗證。

## 最短上手路徑（3 分鐘）

```bash
brew install nullclaw
nullclaw onboard --interactive
nullclaw agent -m "你好，nullclaw"
```

如果你不用 Homebrew，請按 [安裝指南](./installation.md) 走原始碼或容器流程。

## 推薦閱讀順序

### 新使用者

1. [安裝指南](./installation.md)
2. [設定指南](./configuration.md)
3. [使用與運維](./usage.md)
4. [命令參考](./commands.md)

### 運維 / 整合

1. [使用與運維](./usage.md)
2. [安全機制](./security.md)
3. [Gateway API](./gateway-api.md)
4. [Signal 部署專題](../../SIGNAL.md)

### 貢獻者

1. [架構總覽](./architecture.md)
2. [開發指南](./development.md)
3. [貢獻指南](../../CONTRIBUTING.md)

## 專題文件

- [安全揭露流程](../../SECURITY.md)
- [Signal 頻道部署](../../SIGNAL.md)
- [貢獻指南](../../CONTRIBUTING.md)

## 下一步

- 新使用者：按 [安裝指南](./installation.md) → [設定指南](./configuration.md) → [使用與運維](./usage.md) 繼續。
- 運維 / 整合：先看 [使用與運維](./usage.md)，再補 [安全機制](./security.md)、[Gateway API](./gateway-api.md) 與對應運維專題。
- 貢獻者：先讀 [開發指南](./development.md)，需要提交流程時再看 [貢獻指南](../../CONTRIBUTING.md)。

## 相關頁面

- [Termux 指南](./termux.md)
- [命令參考](./commands.md)
- [架構總覽](./architecture.md)
- [安全機制](./security.md)
- [Gateway API](./gateway-api.md)
