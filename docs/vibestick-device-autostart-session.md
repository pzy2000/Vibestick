# Vibestick Device Auto-Start Session Notes

This note exports the Windows RP2040 auto-start work so the same product behavior can be implemented for the macOS version later.

## Outcome Recap

- Windows `autorun.inf` was rejected. Modern Windows does not reliably allow arbitrary USB auto-execution, and the RP2040 `RPI-RP2` UF2 bootloader drive is not a durable application distribution volume.
- The implemented model is: install a trusted host companion once, flash the RP2040 firmware once, then let the host companion launch the existing GUI when the finished device is inserted.
- Pico SDK was installed at:

```text
C:\Users\ROG\pico-sdk
```

- ARM GNU toolchain was installed through winget:

```powershell
winget install --id Arm.GnuArmEmbeddedToolchain --source winget --accept-package-agreements --accept-source-agreements --silent
```

- Final flashed firmware enumerated as:

```text
USB\VID_2E8A&PID_4002\VS-RP2040-0002
```

- Windows exposed the flashed board as:

```text
USB Composite Device
Vibestick RP2040
USB 串行设备 (COM5)
```

- The Windows companion was installed under:

```text
%LOCALAPPDATA%\Vibestick\app\current
```

- The per-user startup registration was:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run\VibestickDeviceWatcher
```

with this value shape:

```text
"%LOCALAPPDATA%\Vibestick\app\current\vibestick-device-watcher.exe" --gui-path "%LOCALAPPDATA%\Vibestick\app\current\vibestick-gui.exe"
```

## Implementation Facts

- Host watcher project: `src/Vibestick.DeviceWatcher`
- Core detection logic:
  - `src/Vibestick.Core/DeviceDetector.cs`
  - `src/Vibestick.Core/DeviceModels.cs`
  - `src/Vibestick.Core/WindowsDeviceSnapshotSource.cs`
- Firmware project: `firmware/rp2040-vibestick`
- Install scripts:
  - `scripts/install-device-watcher.ps1`
  - `scripts/uninstall-device-watcher.ps1`
- Final USB identity:

```text
VID: 0x2E8A
PID: 0x4002
Serial: VS-RP2040-0002
Interface GUID: {AF77C38F-7C8C-4D86-9F2D-F7C40A8E08E5}
```

- The intermediate `PID_4001` attempt should be avoided. Windows cached it as a failed unknown vendor device after the single vendor-interface firmware did not auto-bind correctly.
- The working firmware shape is a composite device with CDC plus vendor/WinUSB interface. That enumerated cleanly as a composite device, a serial port, and the Vibestick vendor interface.
- Bootloader identity remains separate:

```text
USB\VID_2E8A&PID_0003
Volume label: RPI-RP2
INFO_UF2.TXT Board-ID: RPI-RP2
```

The watcher treats this as firmware flashing/setup state and does not launch the GUI from it.

## Command Log

Install ARM GNU toolchain:

```powershell
winget install --id Arm.GnuArmEmbeddedToolchain --source winget --accept-package-agreements --accept-source-agreements --silent
```

Clone Pico SDK:

```powershell
git clone --recurse-submodules https://github.com/raspberrypi/pico-sdk.git C:\Users\ROG\pico-sdk
```

Persist local environment variables:

```powershell
[Environment]::SetEnvironmentVariable('PICO_SDK_PATH', 'C:\Users\ROG\pico-sdk', 'User')
$toolchainBin = 'C:\Program Files (x86)\Arm GNU Toolchain arm-none-eabi\14.2 rel1\bin'
$path = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($path -notlike "*$toolchainBin*") {
    [Environment]::SetEnvironmentVariable('Path', ($path.TrimEnd(';') + ';' + $toolchainBin), 'User')
}
```

Configure and build firmware in the current shell:

```powershell
$env:PICO_SDK_PATH = 'C:\Users\ROG\pico-sdk'
$env:Path = 'C:\Program Files (x86)\Arm GNU Toolchain arm-none-eabi\14.2 rel1\bin;' + $env:Path
cmake -S firmware\rp2040-vibestick -B firmware\rp2040-vibestick\build -G Ninja -DPICO_SDK_PATH="$env:PICO_SDK_PATH" -DPICO_BOARD=pico
cmake --build firmware\rp2040-vibestick\build
```

Flash UF2:

```powershell
Copy-Item -LiteralPath firmware\rp2040-vibestick\build\vibestick_rp2040.uf2 -Destination E:\ -Force
```

To enter UF2 mode on this board: unplug Type-C, hold `BOOTSEL`, plug Type-C back in while still holding `BOOTSEL`, wait for the `RPI-RP2` drive, then release `BOOTSEL`.

Verify watcher behavior without launching another GUI:

```powershell
dotnet run --project src\Vibestick.DeviceWatcher -- --once --no-launch --log-path artifacts\device-autostart\device-watcher-after-flash.log
```

Install the Windows companion:

```powershell
.\scripts\install-device-watcher.ps1
```

If files are locked by an existing installed watcher or GUI, stop them and rerun:

```powershell
Get-Process -Name vibestick-device-watcher,vibestick-gui -ErrorAction SilentlyContinue | Stop-Process -Force
.\scripts\install-device-watcher.ps1
```

Final verification commands:

```powershell
dotnet build Vibestick.sln
cmake --build firmware\rp2040-vibestick\build
dotnet run --project tests\Vibestick.Tests
```

Verified results in this session:

```text
dotnet build Vibestick.sln: passed, 0 warnings, 0 errors
firmware cmake build: passed
dotnet run --project tests\Vibestick.Tests: All 39 tests passed
```

## macOS Port Notes

- Replace the Windows HKCU Run entry with a per-user `LaunchAgent`.
- Replace WMI and SetupAPI scanning with IOKit USB matching by VID/PID and, if useful, interface class/interface number.
- macOS does not need WinUSB. It can detect the composite USB device directly by identity.
- Keep the firmware as composite CDC plus vendor interface. The single vendor-interface attempt was less reliable on Windows and caused a failed `PID_4001` cache entry.
- Preserve the bootloader distinction. `RPI-RP2` means firmware flashing/setup state; it should not be treated as a final product insertion event.
- The macOS companion should launch the existing macOS app target and reuse the existing macOS core services. Do not duplicate sleep-policy logic in a separate helper unless the macOS permission/helper boundary requires it.
- Expected macOS flow:
  - Install Vibestick app plus a lightweight watcher/agent.
  - Register the agent with `launchctl`.
  - Agent monitors USB attach events for `VID 0x2E8A`, `PID 0x4002`.
  - Agent launches or focuses the Vibestick macOS app when the final firmware device appears.
  - Agent ignores the `RPI-RP2` bootloader except to surface setup/flashing status if the UI wants that later.

## macOS Implementation Notes

- SwiftPM product: `VibestickDeviceWatcher`.
- User LaunchAgent label: `com.pzy.vibestick.device-watcher`.
- User LaunchAgent path:

```text
~/Library/LaunchAgents/com.pzy.vibestick.device-watcher.plist
```

- Default log path:

```text
~/Library/Logs/Vibestick/device-watcher.log
```

- CLI surface:

```bash
dist/vibestickctl device-watcher status
dist/vibestickctl device-watcher install --app-path "$PWD/dist/Vibestick.app"
dist/vibestickctl device-watcher uninstall
swift run VibestickDeviceWatcher -- --once --no-launch --log-path artifacts/device-autostart/mac-watcher.log
```

## Acceptance Notes

- This markdown is documentation only. It should not be read as evidence that the repository working tree is clean.
- At the time of this export, the working tree already contained unrelated pre-existing changes alongside the Windows auto-start work.
- The Windows implementation verified in this session is the canonical reference for the macOS auto-start port.
