# 開發指南

本頁面向貢獻者，目標是讓你能用最短路徑搭好環境、改完說明文件或程式碼、跑完校驗並提交 PR。

## 頁面導航

- 這頁適合誰：準備改程式碼、說明文件、測試，或者想提交 PR 的貢獻者。
- 看完去哪裡：理解模組邊界看 [架構總覽](./architecture.md)；查 CLI 行為和範例看 [命令參考](./commands.md)；確認提交流程看 [貢獻指南](../../CONTRIBUTING.md)。
- 如果你是從某頁來的：從 [README](./README.md) 來，這頁就是貢獻路徑的下一站；從 [命令參考](./commands.md) 來，適合繼續補本地建置、測試和提交前校驗；從 `AGENTS.md` 來，可把本頁當作具體落地流程。

## 開發前先確認

- 本專案開發與測試固定在 **Zig 0.15.2**。
- 修改程式碼前，先讀 `AGENTS.md`。
- 如需理解工程背景、模組邊界、測試與建置約束，可繼續讀 `CLAUDE.md`。
- 如果你使用倉庫裡的 flake，則 `nix build` 和 `nix develop` 都固定為 **Zig 0.15.2**。

先確認本機 Zig 版本：

```bash
zig version
```

## 本地建置與測試

```bash
zig build
zig build -Doptimize=ReleaseSmall
zig build test --summary all
```

建議在提交前至少執行：

```bash
zig build test --summary all
```

## 常用建置參數

```bash
zig build -Dchannels=telegram,cli
zig build -Dengines=base,sqlite
zig build -Dtarget=x86_64-linux-musl
zig build -Dversion=2026.3.1
```

說明：

- `channels`：裁剪編譯進二進位中的頻道實作。
- `engines`：裁剪 memory engine。
- `target`：交叉編譯目標。
- `version`：覆蓋嵌入版本字串（預設是 `dev`；release workflow 會注入 git tag）。

## 推薦工作流

1. 先閱讀相關模組與相鄰測試。
2. 只做一個關注點的改動，不把功能、重構、雜項修復混在一起。
3. 改完立刻補說明文件或測試，不要留到最後一起補。
4. 提交前跑校驗，確認沒有把 README、命令、設定範例寫錯。

## 說明文件同步要求

如果你的改動會影響使用者、運維、貢獻者，最好在同一個 PR 裡同步說明文件：

- 根落地頁：`README.md`
- 英文說明文件：`docs/en/`
- 中文說明文件：`docs/zh/`
- 安全披露：`SECURITY.md`
- 專題部署：`SIGNAL.md`
- 貢獻流程：`CONTRIBUTING.md`

說明文件更新時建議遵循：

- 讓命令範例可以直接複製執行。
- README 只做 landing page，細節盡量放到 `docs/`。
- 命令、flags、設定欄位必須以 `src/main.zig` 和目前設定結構為準。
- 若改動同時影響中英文使用者，盡量同步更新 `docs/en/` 與 `docs/zh/`。

## Git Hooks

倉庫自帶 hooks，建議 clone 後立刻啟用：

```bash
git config core.hooksPath .githooks
```

其中：

- `pre-commit` 會執行 `zig fmt --check src/`
- `pre-push` 會執行 `zig build test --summary all`

## 提交前校驗

### 說明文件改動

至少執行：

```bash
git diff --check
```

並人工確認連結、檔案路徑、命令範例可讀可用。

### 程式碼改動

必須執行：

```bash
zig build test --summary all
```

### Release / 建置敏感改動

額外執行：

```bash
zig build -Doptimize=ReleaseSmall
```

## PR 建議

PR 說明至少寫清楚：

1. 改了什麼
2. 為什麼改
3. 跑了什麼驗證
4. 是否有風險或後續事項

可直接套用：

```text
## Summary
- ...

## Validation
- zig build test --summary all

## Notes
- ...
```

## 程式碼結構（高頻目錄）

| 路徑 | 說明 |
|---|---|
| `src/main.zig` | CLI 命令路由 |
| `src/config.zig` | 設定載入與環境覆蓋 |
| `src/gateway.zig` | 網關與 webhook |
| `src/security/` | 安全與沙箱 |
| `src/providers/` | 模型 provider 實作 |
| `src/channels/` | 訊息頻道實作 |
| `src/tools/` | tool 實作 |
| `src/memory/` | memory backend 與檢索 |

## 更多入口

- 架構：`docs/zh/architecture.md`
- 命令：`docs/zh/commands.md`
- 貢獻流程：`CONTRIBUTING.md`
- 工程協議：`AGENTS.md`

## 下一步

- 要開始改程式碼：先讀 [架構總覽](./architecture.md)，再回到本頁執行建置與測試。
- 要同步說明文件或核對 CLI：繼續看 [命令參考](./commands.md) 和 `src/main.zig`。
- 要準備提交 PR：繼續看 [貢獻指南](../../CONTRIBUTING.md)，並按本頁「提交前校驗」執行。

## 相關頁面

- [中文說明文件入口](./README.md)
- [架構總覽](./architecture.md)
- [命令參考](./commands.md)
- [貢獻指南](../../CONTRIBUTING.md)
