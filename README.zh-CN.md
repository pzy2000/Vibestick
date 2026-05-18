# Vibestick

[English](README.md) | [中文](README.zh-CN.md)

Vibestick 是一个桌面睡眠策略钥匙和桌面宠物原型。

原有 Windows 实现仍保留在 `src/` 和 `tests/`。新的原生 macOS 产品线位于 `macos/`，包含 SwiftUI/AppKit UI、`vibestickctl`，以及用于修改 `pmset` 电源策略的特权 helper。

核心工作流：

- `off`：恢复原始合盖策略，并释放保持唤醒状态。
- `on`：把当前平台的睡眠策略切换为 Vibestick 管控的保持唤醒行为。
- `hyper`：应用 `on`，加入电池策略、长时间 coder 任务检测，并可保持前台防睡眠守护进程。

## Windows 前置条件

- Windows 10/11
- .NET 8 SDK

该仓库有意不依赖外部 NuGet 包。

## Windows 命令

```powershell
dotnet run --project src/Vibestick.Cli -- status
dotnet run --project src/Vibestick.Cli -- status --json
dotnet run --project src/Vibestick.Cli -- doctor
dotnet run --project src/Vibestick.Cli -- mode on
dotnet run --project src/Vibestick.Cli -- mode hyper
dotnet run --project src/Vibestick.Cli -- mode hyper --once
dotnet run --project src/Vibestick.Cli -- mode off
dotnet run --project src/Vibestick.Cli -- revert
```

如果 SDK 通过 `dotnet-install` 安装在 `%USERPROFILE%\.dotnet`，可以直接使用包装脚本：

```powershell
.\scripts\vibestick.ps1 status
.\scripts\vibestick.ps1 doctor --json
```

`mode hyper` 会保持一个前台守护进程运行，使 Windows idle sleep 在进程存活期间被阻止。使用 `Ctrl+C` 停止守护进程。`mode hyper --once` 只应用电源策略后退出，进程退出后不会继续持有 sleep assertion。

## GUI

GUI 默认以桌面宠物启动。宠物置顶显示，像经典 QQ 宠物一样沿桌面底部巡逻，可拖拽或调整大小，点击后打开控制面板：

```powershell
.\scripts\vibestick-gui.ps1
```

右键宠物可以暂停或恢复行走、打开控制面板、刷新或退出。托盘图标也提供控制面板、宠物和退出操作。控制面板提供状态刷新、诊断、ON、HYPER、停止 HYPER Guard、OFF/Revert 控制。GUI 中的 HYPER 会在控制面板打开期间，或直到手动停止 guard 前，保持 sleep blocker 激活。

## 桌面宠物 Coder 状态

Vibestick 默认随宠物启动本地 Codex 状态桥。桥接器会监听 `%USERPROFILE%\.codex\sessions` 下的 Codex session JSONL 文件，把新的 Codex 事件映射成宠物状态摘要，并写入：

```text
%LOCALAPPDATA%\Vibestick\coder-status\*.json
```

启动宠物后正常使用 Codex 即可；随着 Codex session 事件更新，宠物会在 thinking、tool-calling、success 等 mood 之间切换。不同 Codex session 会按 session id 单独跟踪，因此并发对话会显示为宠物上方的多个任务卡，而不是相互覆盖。

任务卡标题来自每个 Codex session 中第一条实质性用户请求；环境上下文、图片 payload、skill 链接、本地路径和过长文本会被剥离。最近的 assistant 进展会作为卡片详情展示。未完成 session 会在近期活跃时保持可见；完成的 session 会短暂显示 success 后过期。

默认最多显示三个任务卡。如果活跃 session 更多，折叠按钮旁会出现 `+N`；点击按钮展开受限任务列表，再次点击折叠。点击任务卡会尝试把匹配的 Codex 或编辑器窗口置前；如果找不到匹配窗口，则回退打开控制面板。

调试时可关闭自动 Codex 监控：

```powershell
.\scripts\vibestick-gui.ps1 --no-codex-monitor
```

当没有 adapter 状态时，Vibestick 会回退到白名单进程检测，例如 Codex、Claude、Docker 等长时间运行的 coder 任务。

手动 adapter 命令仍可用于测试和非 Codex 集成：

```powershell
.\scripts\vibestick.ps1 pet status --json
.\scripts\vibestick.ps1 coder emit --agent codex --phase reasoning --message "Reading pet state code" --ttl 30 --json
.\scripts\vibestick.ps1 coder emit --agent codex --phase tool_calling --message "Running rg for status resolver" --ttl 30 --json
.\scripts\vibestick.ps1 coder emit --agent codex --phase success --message "Patch complete" --ttl 30 --json
.\scripts\vibestick.ps1 coder emit --agent codex --phase waiting_authorization --message "Approval needed" --ttl 120 --json
.\scripts\vibestick.ps1 coder emit --agent codex --session-id demo-1 --summary "Implement task cards" --detail "Reviewing card layout" --phase reasoning --message "Thinking" --ttl 120 --json
.\scripts\vibestick.ps1 coder clear --agent codex --json
```

支持的 coder phase 包括 `idle`、`sleeping`、`running`、`reasoning`、`tool_calling`、`waiting_authorization`、`error`、`success`、`offline` 和 `unknown`。宠物会把它们映射到对应 mascot mood；只有需要用户注意时，电源和电池安全警告才会覆盖 coder 动画。

## 状态

Vibestick 的 Windows 本地状态保存于：

```text
%LOCALAPPDATA%\Vibestick\state.json
```

状态文件记录当前电源方案原始的合盖 AC/DC 值，以便 `revert` 恢复。存在待恢复备份时，Vibestick 不会覆盖它；如果活动电源方案变化，请先运行 `vibestick revert`，再应用新的模式。

## 测试

```powershell
dotnet run --project tests/Vibestick.Tests
```

测试运行器是一个小型 console app，以保持 MVP 无外部依赖。

## macOS 原生构建

macOS 线与 Windows `.sln` 有意分离：

```bash
cd macos
swift build
swift test
```

Targets：

- `VibestickApp`：SwiftUI/AppKit 控制面板、菜单栏项和桌面宠物。
- `vibestickctl`：原生 CLI，支持 `status`、`doctor`、`mode`、`revert`、`pet` 和 `coder`。
- `VibestickHelper`：特权 helper，仅暴露固定 `pmset` 操作。
- `VibestickMacCore`：共享原生服务和解析器。

本地开发时如果不安装 helper，可让 CLI 指向已构建的 helper：

```bash
export VIBESTICK_HELPER_PATH="$PWD/.build/debug/VibestickHelper"
.build/debug/vibestickctl doctor
.build/debug/vibestickctl status --json
```

`mode on`、`mode hyper`、`revert` 等会修改电源策略的命令要求 helper 以 root
身份运行。正常运行这些命令前请先安装 helper。

`mode on` 会保存原始 `pmset` 设置，并把系统 sleep 切换为 Vibestick 管控的保持唤醒行为。`mode hyper` 还会应用 Hyper 电池优先级覆盖设置，并在 app 或 CLI guard 进程存活期间持有 IOKit no-idle-sleep assertion。在 Hyper 中，低电量保持唤醒优先，不使用 Windows 的 warn/downgrade/revert 阈值行为。

Mac 用户状态和 coder adapter 文件保存于：

```text
~/Library/Application Support/Vibestick/
```

helper 备份状态保存于：

```text
/Library/Application Support/Vibestick/power-state.json
```

## macOS Helper 与发布

构建开发版 `.app`：

```bash
macos/scripts/build-release.sh dev
```

安装 helper 以启用本地特权 `pmset` 控制：

```bash
cd macos
swift build -c release
scripts/install-helper.sh
```

卸载 helper：

```bash
macos/scripts/uninstall-helper.sh
```

Release 签名会在缺少以下配置时明确失败：

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export DEVELOPER_ID_INSTALLER="Developer ID Installer: ..."
export NOTARY_PROFILE="vibestick-notary"
macos/scripts/build-release.sh release
```

`doctor` 只报告可验证的本地状态：helper 可用性、helper 通信、`pmset`、恢复状态、电池、Vibestick assertion、Accessibility 授权和长时间运行的 coder 任务。
