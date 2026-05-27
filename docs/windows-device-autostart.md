# Windows Device Auto-Start

Vibestick does not rely on `autorun.inf`. Modern Windows treats USB automatic execution as a security-sensitive AutoPlay feature, and the current RP2040 bootloader drive is not a durable app distribution volume.

The supported flow is:

1. Run `scripts\install-device-watcher.ps1` once on the PC.
2. Flash the RP2040 with the Vibestick firmware from `firmware\rp2040-vibestick`.
3. Insert the board. Windows binds standard composite/serial drivers plus WinUSB from the firmware's Microsoft OS 2.0 descriptors, the watcher detects `USB\VID_2E8A&PID_4002`, and `vibestick-gui.exe` starts.

## Install

```powershell
.\scripts\install-device-watcher.ps1
```

The installer publishes `Vibestick.Gui` and `Vibestick.DeviceWatcher` to:

```text
%LOCALAPPDATA%\Vibestick\app\current
```

It also registers this per-user Run entry:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run\VibestickDeviceWatcher
```

Use `-WhatIf` to verify the steps without writing files or registry values:

```powershell
.\scripts\install-device-watcher.ps1 -WhatIf
```

## Uninstall

```powershell
.\scripts\uninstall-device-watcher.ps1
```

Use `-KeepFiles` to remove only the Run entry and stop the watcher.

## Detection states

- `RPI-RP2` bootloader drive or `USB\VID_2E8A&PID_0003`: detected as bootloader only; GUI is not launched.
- `USB\VID_2E8A&PID_4002`: detected as Vibestick firmware; GUI is launched unless it is already running.
- Repeated plug events are debounced for five seconds.

Logs are written to:

```text
%LOCALAPPDATA%\Vibestick\device-watcher.log
```
