# Termux 指南

本頁專門講 Android / Termux 下執行 NullClaw 的實際路徑。

## 頁面導航

- 這頁適合誰：想直接在 Android 手機的 Termux 裡建置和執行 NullClaw 的使用者。
- 看完去哪裡：二進位能跑起來後，繼續看 [設定指南](./configuration.md)；準備驗證常用命令時看 [使用與運維](./usage.md)。
- 如果你想先看完整安裝矩陣：先回到 [安裝指南](./installation.md)。

## 先有預期

Termux 更適合：

- 前台使用
- 手動測試
- 輕量本地部署

Termux 不太適合：

- 手機上直接跑高負載、本地推理
- 必須長期穩定常駐背景的服務

如果 Android 因為記憶體壓力殺掉進程，這通常是 Android / Termux 的執行約束，不一定是 NullClaw 自身的 bug。

## 前置要求

- **Zig 0.15.2，必須精確匹配**
- Git
- 足夠的本地儲存空間

先確認 Zig 版本：

```bash
zig version
```

輸出必須是 `0.15.2`。

## 直接在 Termux 裡建置

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

- 在原生 Termux 環境裡，一般 **不需要** 額外傳 `-Dtarget`。
- 優先使用 `-Doptimize=ReleaseSmall` 或 `-Doptimize=ReleaseFast`。
- 不要再用舊範例裡的 `-Drelease-fast` 語法。

## 低相依性建置路徑

如果 SQLite 的拉取或建置在 Termux 裡失敗，先走輕量引擎集：

```bash
zig build -Doptimize=ReleaseSmall -Dengines=base
```

`-Dengines=base` 包含 `markdown,memory,api,none`，不相依 SQLite。

也可以顯式指定：

```bash
zig build -Doptimize=ReleaseSmall -Dengines=markdown,memory
```

對記憶體和相依性都更緊的 Android 裝置，這通常是更穩妥的第一步。

## 常見錯誤：`build.zig.zon` 提示 `expected string literal`

如果你看到類似錯誤：

```text
build.zig.zon:2:14: error: expected string literal
```

最常見原因是 Zig 版本不對，不是 NullClaw 原始碼本身有問題。

排查順序：

1. 執行 `zig version`
2. 確認輸出是 `0.15.2`
3. 如果不是，先替換 Zig，再重新建置

不要為了相容舊 Zig 去本地修改 `build.zig.zon`。專案目前就是固定在 Zig 0.15.2。

## 第一次執行怎麼驗

編譯通過後，先驗證最基礎的兩個入口：

```bash
./zig-out/bin/nullclaw agent
./zig-out/bin/nullclaw gateway --host 127.0.0.1 --port 3001
```

先跑前台，再考慮指令碼包裝、常駐背景或者別的自動化方式。

## 從別的機器交叉編譯 Android 二進位

如果你是在另一台機器上為 Android / Termux 裝置建置，除了 Zig target，還需要提供 Android 的 libc/sysroot 檔案；只傳 `-Dtarget` 還不夠：

```bash
zig build -Dtarget=aarch64-linux-android.24 -Doptimize=ReleaseSmall --libc /path/to/android-libc-aarch64.txt
```

常見目標：

- `aarch64-linux-android.24`
- `arm-linux-androideabi.24` 搭配 `-Dcpu=baseline+v7a`
- `x86_64-linux-android.24`

按裝置架構選擇目標即可。完整的 `--libc` 檔案產生範例可參考 [`.github/workflows/release.yml`](../../.github/workflows/release.yml)。

## 實用建議

- 第一階段目標要小：先成功建置，再跑 `--help`，再跑 `agent` 或 `gateway`。
- 如果裝置記憶體緊張，優先接遠端 provider，不要先上本地大模型。
- 如果你需要長期穩定常駐，Termux 更適合作為試驗場，而不是最終宿主。

## 相關頁面

- [安裝指南](./installation.md)
- [設定指南](./configuration.md)
- [使用與運維](./usage.md)
- [命令參考](./commands.md)
