# Vibestick Mac

[English](README.md) | [中文](README.zh-CN.md)

Vibestick 的原生 macOS 实现。

## 构建

```bash
swift build
swift test
```

本地 CLI 测试时，如果不安装特权 helper，可以这样指定已构建的 helper：

```bash
export VIBESTICK_HELPER_PATH="$PWD/.build/debug/VibestickHelper"
.build/debug/vibestickctl doctor
.build/debug/vibestickctl status --json
```

`mode on`、`mode hyper`、`revert` 这类会修改系统状态的命令要求 helper 以
root 身份运行，因为它们会修改 `pmset`，并把恢复备份写入
`/Library/Application Support/Vibestick/`。正常运行前请先安装 helper：

```bash
swift build -c release
scripts/install-helper.sh
.build/debug/vibestickctl mode hyper --once
.build/debug/vibestickctl revert
```

## 组件

- `VibestickMacCore`：解析器、状态、`pmset` 策略管理、电池、coder 状态、宠物状态和 doctor 检查。
- `vibestickctl`：Mac CLI，对齐 Windows 命令表面。
- `VibestickHelper`：root helper allowlist，只允许 `status`、`apply-on`、`apply-hyper` 和 `restore`。
- `VibestickApp`：SwiftUI/AppKit 控制面板、菜单栏项和浮动宠物。

## 电源语义

- `off` / `revert`：释放 Vibestick 的 HYPER assertion，并恢复保存的 `pmset` 设置。
- `on`：保存当前 `pmset` 设置，并将系统 sleep 设为 `0`。
- `hyper`：应用 `on`，在支持的地方设置 Hyper 电池优先级 `pmset` 值，并持有 IOKit no-idle-sleep assertion。

Hyper 不使用 Windows 的低电量 warn/downgrade/revert 阈值。它会保持唤醒优先，直到用户退出 HYPER、运行 `off`/`revert`，或 macOS 应用 Vibestick 无法覆盖的硬件级保护。

## Helper

helper 安装到：

```text
/Library/PrivilegedHelperTools/com.pzy.vibestick.helper
```

LaunchDaemon plist：

```text
/Library/LaunchDaemons/com.pzy.vibestick.helper.plist
```

开发安装：

```bash
swift build -c release
scripts/install-helper.sh
```

开发卸载：

```bash
scripts/uninstall-helper.sh
```

## 发布

开发版 bundle：

```bash
scripts/build-release.sh dev
```

已公证 release 包：

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export DEVELOPER_ID_INSTALLER="Developer ID Installer: ..."
export NOTARY_PROFILE="vibestick-notary"
scripts/build-release.sh release
```
