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
- `VibestickDeviceWatcher`：用户级 LaunchAgent companion，监听最终 RP2040 USB 设备并启动或聚焦 app。
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

## 插盘自启

macOS 插盘自启使用用户级 LaunchAgent，不依赖 USB autorun。watcher 检测最终固件设备
`0x2E8A:0x4002` 后启动或聚焦 `Vibestick.app`；检测到 RP2040 `RPI-RP2`
bootloader 卷或 `0x2E8A:0x0003` 时只作为刷机/设置状态处理，不启动 app。

构建 app bundle 后开发安装：

```bash
scripts/build-release.sh dev
scripts/install-device-watcher.sh
```

CLI：

```bash
dist/vibestickctl device-watcher status
dist/vibestickctl device-watcher install --app-path "$PWD/dist/Vibestick.app"
dist/vibestickctl device-watcher uninstall
swift run VibestickDeviceWatcher -- --once --no-launch --log-path artifacts/device-autostart/mac-watcher.log
```

LaunchAgent plist 和日志：

```text
~/Library/LaunchAgents/com.pzy.vibestick.device-watcher.plist
~/Library/Logs/Vibestick/device-watcher.log
```

## 发布

开发版 bundle：

```bash
scripts/build-release.sh dev
```

开发版拖拽安装 DMG：

```bash
scripts/build-dmg.sh dev
```

已公证 release 包：

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export DEVELOPER_ID_INSTALLER="Developer ID Installer: ..."
export NOTARY_PROFILE="vibestick-notary"
scripts/build-release.sh release
```

已公证拖拽安装 DMG：

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export NOTARY_PROFILE="vibestick-notary"
scripts/build-dmg.sh release
```

DMG 内包含 `Vibestick.app` 和 `Applications` 快捷方式。把 app 拖到
Applications 后再从 Applications 打开；首次启动会显示“完成安装”入口，按顺序安装
特权 Helper 和用户级插盘自启 LaunchAgent。直接从 `/Volumes/...` 打开时不会启用该
动作，因为 Helper 和 LaunchAgent 必须指向已安装的 app bundle。
