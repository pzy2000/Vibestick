# Vibestick RP2040 Firmware Skeleton

This directory is the planned firmware side of the Windows auto-start flow. It is intentionally a minimal TinyUSB skeleton, not a finished hardware feature build.

## USB identity

- VID: `0x2E8A`
- PID: `0x4002`
- Product: `Vibestick RP2040`
- Device interface GUID: `{AF77C38F-7C8C-4D86-9F2D-F7C40A8E08E5}`
- Transport: vendor-specific USB interface with Microsoft OS 2.0 descriptors for automatic WinUSB binding.

The current UF2 bootloader still appears as `USB\VID_2E8A&PID_0003` with volume label `RPI-RP2`. The Windows watcher treats that as "bootloader only" and does not launch the GUI until the firmware identity above is present.

## Build outline

Install the Raspberry Pi Pico SDK and TinyUSB-capable toolchain, then configure with CMake:

```powershell
cmake -S firmware\rp2040-vibestick -B firmware\rp2040-vibestick\build -DPICO_SDK_PATH=C:\path\to\pico-sdk
cmake --build firmware\rp2040-vibestick\build
```

Copy the generated `.uf2` to the `RPI-RP2` drive while the board is in bootloader mode.

## Host behavior

After `scripts\install-device-watcher.ps1` has been run once on the PC, inserting a board running this firmware should make Windows bind standard composite/serial drivers plus WinUSB automatically and the watcher should launch `vibestick-gui.exe`.
