# 安裝指南

本指南涵蓋 macOS、Linux、Windows 的主流安裝方式。

## 頁面導航

- 這頁適合誰：剛準備安裝 NullClaw，或者要確認本機環境、容器部署、升級與卸載路徑的人。
- 看完去哪裡：安裝完成後先看 [設定指南](./configuration.md)；想直接跑一遍常用命令看 [使用與運維](./usage.md)；想先瀏覽 CLI 入口看 [命令參考](./commands.md)。
- 如果你是從某頁來的：從 [README](./README.md) 來，這頁就是落地安裝的第一站；從 [命令參考](./commands.md) 來，適合回頭補齊本機安裝與 PATH；從 [開發指南](./development.md) 來，可把本頁當作本地環境準備清單。

## 前置要求

- 如果走原始碼建置：必須使用 **Zig 0.15.2**。
- Git（原始碼安裝需要）。

檢查 Zig 版本：

```bash
zig version
```

輸出必須是 `0.15.2`。

## 方式一：使用二進位檔案
### Homebrew（macOS/Linux推薦）

```bash
brew install nullclaw
nullclaw --help
```
如果命令可用，說明安裝成功。

### 命令行（CMD）(Windows)

直接將下載的nullclaw二進位檔案（.exe)在命令行中作為命令執行即可，

比如檢查nullclaw版本號的命令如下：

```cmd
x:\path\nullclaw-xxx version
```

## 方式二：官方容器映像（Docker / Podman）

NullClaw 目前提供官方 OCI 映像：`ghcr.io/nullclaw/nullclaw`。

容器內的持久化目錄統一放在 `/nullclaw-data`：

- 設定檔：`/nullclaw-data/config.json`
- 工作區：`/nullclaw-data/workspace`

映像內自帶的初始設定已經使用目前設定結構（`agents.defaults.model.primary` 和 `models.providers`），因此在你填入 provider 憑證之前，`latest` 也應能正常啟動。

### 單次命令

```bash
docker run --rm -it \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/nullclaw/nullclaw:latest status
```

互動式初始化設定：

```bash
docker run --rm -it \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/nullclaw/nullclaw:latest onboard --interactive
```

執行互動式 agent：

```bash
docker run --rm -it \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/nullclaw/nullclaw:latest agent
```

執行 HTTP gateway：

```bash
docker run --rm -it \
  -p 127.0.0.1:3000:3000 \
  -v nullclaw-data:/nullclaw-data \
  ghcr.io/nullclaw/nullclaw:latest
```

### Docker Compose

倉庫根目錄自帶 `docker-compose.yml`，預設直接使用官方映像。

互動式初始化：

```bash
docker compose --profile agent run --rm agent onboard --interactive
```

互動式 agent 會話：

```bash
docker compose --profile agent run --rm agent
```

長期執行 gateway：

```bash
docker compose --profile gateway up -d gateway
```

Profile 含義：

- `agent`：一次性的互動式 CLI 容器
- `gateway`：長期執行的 HTTP gateway，預設發布到宿主機回環地址 `3000`

如果你需要區域網路或公網存取，請顯式修改發布地址，並先閱讀 [安全指南](./security.md)。

如果你要固定版本標籤，或者以後切換到其他映像倉庫，可以覆蓋 `NULLCLAW_IMAGE`：

```bash
NULLCLAW_IMAGE=ghcr.io/nullclaw/nullclaw:v2026.3.11 docker compose --profile gateway up -d gateway
```

## 方式三：原始碼建置（通用）

```bash
git clone https://github.com/nullclaw/nullclaw.git
cd nullclaw
zig build -Doptimize=ReleaseSmall
zig build test --summary all
```

建置產物：

- `zig-out/bin/nullclaw`

## 方式四：Android / Termux

有三種常見路徑：

- 直接下載官方發布的 Android / Termux 預建置二進位
- 在手機上的 Termux 裡原生建置
- 在另一台機器上交叉編譯 Android 二進位

### Termux 原生建置

```bash
pkg update
pkg install git zig
git clone https://github.com/nullclaw/nullclaw.git
cd nullclaw
zig version
zig build -Doptimize=ReleaseSmall
./zig-out/bin/nullclaw --help
```

說明：

- 必須使用 **Zig 0.15.2**
- 如果 `zig build` 一開始就失敗，先確認 Zig 版本
- Termux 原生建置使用目前環境的 native target，通常不需要手動傳 `-Dtarget`
- 在 Android / Termux 上，建議先跑前景命令（如 `agent`、`gateway`），確認沒問題後再考慮背景托管
- 官方 release 提供 `aarch64`、`armv7`、`x86_64` 的 Android / Termux 預建置二進位
- 更完整的說明和排錯見 [Termux 指南](./termux.md)。

### 為 Android 交叉編譯

如果你是在另一台機器上給 Android / Termux 裝置建置，需要顯式傳入 Zig target，並提供 Android 的 libc/sysroot 檔案；只傳 `-Dtarget` 還不夠：

```bash
zig build -Dtarget=aarch64-linux-android.24 -Doptimize=ReleaseSmall --libc /path/to/android-libc-aarch64.txt
```

常見 Android targets：

- `aarch64-linux-android.24`
- `arm-linux-androideabi.24`，配合 `-Dcpu=baseline+v7a`
- `x86_64-linux-android.24`

選擇與目標手機或模擬器架構相符的 target。完整的 `--libc` 檔案產生範例可參考 [`.github/workflows/release.yml`](../../.github/workflows/release.yml)。官方 release 也附帶基於 Android API 24 建置的對應二進位。

## 將二進位加入 PATH

### 使用編譯後的二進位檔案

#### macOS/Linux（zsh/bash）

```bash
zig build -Doptimize=ReleaseSmall -p "$HOME/.local"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
# bash 使用者改為 ~/.bashrc
source ~/.zshrc
```

#### Windows（PowerShell）

```powershell
zig build -Doptimize=ReleaseSmall -p "$HOME\.local"

$bin = "$HOME\.local\bin"
$user_path = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not ($user_path -split ";" | Where-Object { $_ -eq $bin })) {
  [Environment]::SetEnvironmentVariable("Path", "$user_path;$bin", "User")
}
$env:Path = "$env:Path;$bin"
```

### 直接使用下載的二進位檔案（Windows,Powershell)
可將下載的nullclaw二進位檔案（.exe)改名為nullclaw.exe，再以系統管理員權限在Powershell中執行如下命令，將該檔案所在的路徑加入到windows系統變數PATH中：

```Powershell 
$old = [Environment]::GetEnvironmentVariable("Path", "Machine")
$new = "$old;x:\nullclaw二進位檔案所在目錄"
[Environment]::SetEnvironmentVariable("Path", $new, "Machine")
```

## 安裝驗證

```bash
nullclaw --help
nullclaw --version
nullclaw status
```

若 `status` 能正常輸出元件狀態，說明安裝與執行環境基本可用。

## 升級與卸載

### 使用二進位檔案

#### Homebrew（macOS/Linux推薦）

```bash
brew update
brew upgrade nullclaw
brew uninstall nullclaw
```
#### 命令行（CMD)（Windows）

- 升級： `nullclaw update`
- 卸載：直接刪除nullclaw二進位檔案。
檢查系統變數PATH，若存在就將nullclaw二進位檔案的所在目錄從中刪除。

### 原始碼安裝

- 升級：`git pull` 後重新執行 `zig build -Doptimize=ReleaseSmall`
- 卸載：刪除安裝位置中的 `nullclaw` 二進位，並移除 PATH 設定行

## 下一步

- 要開始初始化設定：繼續看 [設定指南](./configuration.md)，先產生可執行的 `config.json`。
- 要快速跑通一遍：繼續看 [使用與運維](./usage.md)，按首次啟動流程驗證安裝結果。
- 要核對 CLI 命令：繼續看 [命令參考](./commands.md)，確認 `onboard`、`agent`、`gateway` 等入口。

## 相關頁面

- [中文文件入口](./README.md)
- [Termux 指南](./termux.md)
- [設定指南](./configuration.md)
- [使用與運維](./usage.md)
- [命令參考](./commands.md)
