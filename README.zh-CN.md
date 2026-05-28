<p align="center">
  <img src="assets/vibestick-logo.png" width="180" alt="Vibestick logo">
</p>

<h1 align="center">Vibestick</h1>

<p align="center">
  面向 Windows 和 macOS 的桌面睡眠策略钥匙，以及能感知 coder 状态的桌面宠物。
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">中文</a>
</p>

<p align="center">
  <a href="https://github.com/pzy2000/Vibestick/actions/workflows/ci.yml"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/pzy2000/Vibestick/ci.yml?branch=main&label=CI"></a>
  <a href="https://github.com/pzy2000/Vibestick/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/pzy2000/Vibestick?style=flat"></a>
  <a href="https://github.com/pzy2000/Vibestick/releases"><img alt="GitHub release" src="https://img.shields.io/github/v/release/pzy2000/Vibestick?include_prereleases"></a>
  <a href="https://github.com/pzy2000/Vibestick/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/pzy2000/Vibestick/total"></a>
  <img alt=".NET" src="https://img.shields.io/badge/.NET-8.0-512BD4">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.0-F05138">
  <img alt="Platforms" src="https://img.shields.io/badge/platforms-Windows%20%7C%20macOS-0A7EA4">
  <img alt="License" src="https://img.shields.io/github/license/pzy2000/Vibestick">
</p>

Vibestick 会在长时间任务需要持续运行时保持电脑唤醒，在任务结束后恢复原始电源策略，并把本地 coder 活动映射成一个可以放在视野边缘的桌面伙伴。

## 运行时截图

| macOS 控制面板 | Coder 感知桌宠 |
| --- | --- |
| ![Vibestick macOS control panel](assets/screenshots/macos-control-panel.png) | ![Vibestick coder-aware desktop pet](assets/screenshots/macos-coder-pet.png) |

截图来自原生 macOS app，并使用临时 demo 状态目录捕获，避免把本机 Codex 会话、工作区路径或私人窗口内容发布到 README。

## News

- **2026-05-28**：新增 GitHub Actions CI，覆盖 Windows .NET 与 macOS Swift 构建、测试和 macOS 开发版 bundle artifact。
- **2026-05-28**：新增原生 macOS DMG 打包、首次启动 helper 安装和拖拽安装发布流程。
- **2026-05-27**：新增 RP2040 插入后启动支持：Windows 启动 companion 与 macOS per-user LaunchAgent watcher。
- **2026-05-19**：新增浮动桌宠、任务卡，以及 Codex/coder 状态桥接。

## 功能亮点

- **三种睡眠模式**：`off` 恢复策略，`on` 保持唤醒，`hyper` 在保持唤醒基础上加入电池和 coder 任务感知。
- **原生 Windows 与 macOS 双线**：Windows 位于 `src/` 和 `tests/`；macOS 位于 `macos/`，包含 SwiftUI/AppKit、`vibestickctl`，以及固定 `pmset` 操作的特权 helper。
- **Coder 感知桌宠**：桌宠读取本地 adapter 文件和 Codex session 事件，并把活动状态映射成 reasoning、tool-calling、waiting、success、error 等 mood。
- **RP2040 插入自启流程**：刷好固件的 Vibestick 板可以启动或聚焦宿主 app；BOOTSEL bootloader 仍只代表设置/刷机状态。
- **轻依赖 Windows MVP**：.NET 项目有意不引入外部 NuGet 包，测试 runner 也是一个小型 console app。

## 快速开始

### Windows

前置条件：

- Windows 10/11
- .NET 8 SDK

```powershell
dotnet run --project src/Vibestick.Cli -- status
dotnet run --project src/Vibestick.Cli -- doctor
dotnet run --project src/Vibestick.Cli -- mode on
dotnet run --project src/Vibestick.Cli -- mode hyper
dotnet run --project src/Vibestick.Cli -- mode off
dotnet run --project src/Vibestick.Cli -- revert
```

启动桌宠和控制面板：

```powershell
.\scripts\vibestick-gui.ps1
```

前台 `mode hyper` guard 可用 `Ctrl+C` 停止。`mode hyper --once` 只应用电源策略后退出，进程退出后不会继续持有 sleep assertion。

### macOS

前置条件：

- macOS 14 或更新版本
- 带 Swift 6 兼容工具链的 Xcode command line tools

```bash
cd macos
swift build
swift test
```

构建开发版 app bundle：

```bash
scripts/build-release.sh dev
```

构建开发版拖拽安装 DMG：

```bash
scripts/build-dmg.sh dev
```

本地不安装特权 helper 时，可以让 CLI 指向已构建 helper：

```bash
cd macos
export VIBESTICK_HELPER_PATH="$PWD/.build/debug/VibestickHelper"
.build/debug/vibestickctl doctor
.build/debug/vibestickctl status --json
```

`mode on`、`mode hyper`、`revert` 等会修改电源策略的命令要求 helper 以 root 身份运行。

## Coder 状态 Adapter

Vibestick 默认随桌宠启动本地 Codex 状态桥。桥接器监听 Codex session JSONL，并把摘要写入本地 adapter 文件：

```text
Windows: %LOCALAPPDATA%\Vibestick\coder-status\*.json
macOS:   ~/Library/Application Support/Vibestick/coder-status/*.json
```

手动 adapter 命令可用于测试和非 Codex 集成：

```powershell
.\scripts\vibestick.ps1 coder emit --agent codex --phase reasoning --message "Reading pet state code" --ttl 30 --json
.\scripts\vibestick.ps1 coder emit --agent codex --phase tool_calling --message "Running build checks" --ttl 30 --json
.\scripts\vibestick.ps1 coder emit --agent codex --phase success --message "Patch complete" --ttl 30 --json
.\scripts\vibestick.ps1 coder clear --agent codex --json
```

支持的 phase 包括 `idle`、`sleeping`、`running`、`reasoning`、`tool_calling`、`waiting_authorization`、`error`、`success`、`offline` 和 `unknown`。

## 架构

| 模块 | 路径 | 职责 |
| --- | --- | --- |
| Windows core | `src/Vibestick.Core` | 电源策略、电池逻辑、coder 状态、设备检测、桌宠状态 |
| Windows CLI | `src/Vibestick.Cli` | `status`、`doctor`、`mode`、`revert`、`pet`、`coder` 命令 |
| Windows GUI | `src/Vibestick.Gui` | WPF 托盘 app、控制面板、桌面宠物 |
| Windows watcher | `src/Vibestick.DeviceWatcher` | RP2040 插入后启动 companion |
| macOS core | `macos/Sources/VibestickMacCore` | Swift 服务、解析器、helper client、watcher installer |
| macOS app | `macos/Sources/VibestickApp` | SwiftUI/AppKit 控制面板、菜单栏项、桌面宠物 |
| macOS CLI/helper | `macos/Sources/vibestickctl`, `macos/Sources/VibestickHelper` | CLI 表面与特权 `pmset` allowlist |
| 固件 | `firmware/rp2040-vibestick` | 宿主 watcher 识别的 RP2040 identity |

## 插入自启

Vibestick 不依赖 USB autorun。支持的模型是：

1. 先安装可信宿主 companion。
2. 再刷入 RP2040 固件。
3. 插入成品设备后启动或聚焦桌面 app。

成品固件 identity：

```text
VID: 0x2E8A
PID: 0x4002
Serial: VS-RP2040-0002
```

Bootloader 模式保持分离，永远不触发 app 启动：

```text
USB VID:PID: 0x2E8A:0x0003
Volume: RPI-RP2
Board-ID: RPI-RP2
```

macOS 使用 per-user LaunchAgent：

```bash
macos/scripts/build-release.sh dev
macos/scripts/install-device-watcher.sh
macos/dist/vibestickctl device-watcher status
macos/dist/vibestickctl device-watcher uninstall
```

Windows 使用 per-user Run key 和安装脚本：

```powershell
.\scripts\install-device-watcher.ps1
.\scripts\uninstall-device-watcher.ps1
```

## CI 与测试

GitHub Actions 会在每次 push 和 pull request 上运行：

- Windows：restore、build `Vibestick.sln`，并运行 `tests/Vibestick.Tests`。
- macOS：`swift build`、`swift test`，构建开发版 `.app`，并上传 app bundle 与 `vibestickctl` artifact。

本地工具链可用时，可以运行同样的检查：

```powershell
dotnet build Vibestick.sln --configuration Release
dotnet run --project tests/Vibestick.Tests/Vibestick.Tests.csproj --configuration Release
```

```bash
cd macos
swift build
swift test
scripts/build-release.sh dev
```

## 发布说明

Release 签名和 notarization 会在缺少以下配置时明确失败：

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export DEVELOPER_ID_INSTALLER="Developer ID Installer: ..."
export NOTARY_PROFILE="vibestick-notary"
macos/scripts/build-release.sh release
```

DMG 分发：

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export NOTARY_PROFILE="vibestick-notary"
macos/scripts/build-dmg.sh release
```

DMG 通过把 `Vibestick.app` 拖到 Applications 完成复制安装。首次从 Applications 打开后，应用会继续完成特权 helper 和 device-watcher 安装。直接从 `/Volumes/...` 打开会提示先复制 app。

## Roadmap

- 发布已签名并 notarized 的 macOS release。
- 补充更完整的 Windows/macOS 并列公开 demo 截图。
- 扩展 RP2040 设置诊断和固件刷写文档。
- 持续改进桌宠，让它更紧凑地展示长时间开发任务状态。

## 贡献

欢迎提交 issue 和 pull request。修改睡眠策略相关代码时请保持平台边界清晰，避免无关大重构，并为 parser、state、device detection 和 pet-state 变化补充聚焦测试。
