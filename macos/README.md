# Vibestick Mac

[English](README.md) | [中文](README.zh-CN.md)

Native macOS implementation for Vibestick.

## Build

```bash
swift build
swift test
```

For local CLI testing without installing the privileged helper:

```bash
export VIBESTICK_HELPER_PATH="$PWD/.build/debug/VibestickHelper"
.build/debug/vibestickctl doctor
.build/debug/vibestickctl status --json
```

Mutating commands such as `mode on`, `mode hyper`, and `revert` require the
helper to run as root because they change `pmset` and write the restore backup
under `/Library/Application Support/Vibestick/`. Install the helper before
running them normally:

```bash
swift build -c release
scripts/install-helper.sh
.build/debug/vibestickctl mode hyper --once
.build/debug/vibestickctl revert
```

## Components

- `VibestickMacCore`: parsers, state, `pmset` policy manager, battery, coder status, pet state, doctor checks.
- `vibestickctl`: Mac CLI mirroring the Windows command surface.
- `VibestickHelper`: root helper allowlist for `status`, `apply-on`, `apply-hyper`, and `restore`.
- `VibestickDeviceWatcher`: per-user LaunchAgent companion that watches for the finished RP2040 USB identity and starts or focuses the app.
- `VibestickApp`: SwiftUI/AppKit control panel, menu bar item, and floating pet.

## Power Semantics

- `off` / `revert`: release Vibestick's HYPER assertion and restore the saved `pmset` settings.
- `on`: save current `pmset` settings and set system sleep to `0`.
- `hyper`: apply `on`, set Hyper battery-priority `pmset` values where supported, and hold an IOKit no-idle-sleep assertion.

Hyper does not use the Windows low-battery warn/downgrade/revert thresholds.
It keeps wake priority until the user exits HYPER, runs `off`/`revert`, or macOS
applies a hardware-level protection outside Vibestick control.

## Helper

The helper is installed into:

```text
/Library/PrivilegedHelperTools/com.pzy.vibestick.helper
```

LaunchDaemon plist:

```text
/Library/LaunchDaemons/com.pzy.vibestick.helper.plist
```

Development install:

```bash
swift build -c release
scripts/install-helper.sh
```

Development uninstall:

```bash
scripts/uninstall-helper.sh
```

## Device Auto-Start

The macOS auto-start path uses a per-user LaunchAgent, not USB autorun. The
watcher detects the finished firmware device `0x2E8A:0x4002` and starts or
focuses `Vibestick.app`. It treats the RP2040 `RPI-RP2` bootloader volume or
`0x2E8A:0x0003` identity as setup/flashing state and does not launch the app.

Development install after building the app bundle:

```bash
scripts/build-release.sh dev
scripts/install-device-watcher.sh
```

CLI surface:

```bash
dist/vibestickctl device-watcher status
dist/vibestickctl device-watcher install --app-path "$PWD/dist/Vibestick.app"
dist/vibestickctl device-watcher uninstall
swift run VibestickDeviceWatcher -- --once --no-launch --log-path artifacts/device-autostart/mac-watcher.log
```

LaunchAgent plist and logs:

```text
~/Library/LaunchAgents/com.pzy.vibestick.device-watcher.plist
~/Library/Logs/Vibestick/device-watcher.log
```

## Release

Development bundle:

```bash
scripts/build-release.sh dev
```

Development drag-to-install DMG:

```bash
scripts/build-dmg.sh dev
```

Notarized release package:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export DEVELOPER_ID_INSTALLER="Developer ID Installer: ..."
export NOTARY_PROFILE="vibestick-notary"
scripts/build-release.sh release
```

Notarized drag-to-install DMG:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: ..."
export NOTARY_PROFILE="vibestick-notary"
scripts/build-dmg.sh release
```

The DMG contains `Vibestick.app` and an `Applications` shortcut. Drag the app
to Applications, then open it from Applications. First launch shows a
"complete install" prompt for the privileged helper and the user LaunchAgent.
Opening the app directly from `/Volumes/...` disables that action because the
helper and LaunchAgent must point at the installed app bundle.
