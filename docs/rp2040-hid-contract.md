# RP2040 Hardware Contract

This document defines the future hardware contract for the Vibestick RP2040 prototype. The Windows CLI MVP does not require real USB hardware support.

The Windows auto-start path now uses a vendor-specific WinUSB interface instead of HID for device discovery and driver binding. The planned firmware skeleton lives in `firmware/rp2040-vibestick` and advertises Microsoft OS 2.0 descriptors so Windows can bind WinUSB automatically.

## Auto-start USB identity

- Transport: USB vendor-specific interface with WinUSB
- VID/PID: `0x2E8A:0x4002`
- Device interface GUID: `{AF77C38F-7C8C-4D86-9F2D-F7C40A8E08E5}`
- Bootloader identity: `USB\VID_2E8A&PID_0003`, volume label `RPI-RP2`, board ID `RPI-RP2`

## Device identity

- Transport: USB HID, reserved for a later hardware-control protocol
- Logical product name: `Vibestick`
- Physical control: three-position switch
- Logical modes: `off`, `on`, `hyper`

## Input report

The device sends one input report whenever the physical switch or hardware status changes.

| Byte | Name | Values |
| --- | --- | --- |
| 0 | Report ID | `0x01` |
| 1 | Mode | `0x00` off, `0x01` on, `0x02` hyper |
| 2 | Flags | Bit 0 hardware fault, bit 1 thermal warning, bit 2 reserved |
| 3 | Firmware major | Unsigned integer |
| 4 | Firmware minor | Unsigned integer |

Unknown mode values must be treated as `off` by the desktop software.

## Output report

The desktop software may send one output report to control status lighting.

| Byte | Name | Values |
| --- | --- | --- |
| 0 | Report ID | `0x02` |
| 1 | LED pattern | `0x00` off, `0x01` solid, `0x02` breathe, `0x03` slow blink, `0x04` fast blink |
| 2 | Red | `0..255` |
| 3 | Green | `0..255` |
| 4 | Blue | `0..255` |

Recommended MVP mapping:

| Mode/status | Pattern |
| --- | --- |
| off | low white or off |
| on | solid green |
| hyper | purple breathe |
| low battery | yellow blink |
| high temperature | red blink |
| permission failure | red/white alternating in firmware V2 |

## Safety defaults

Firmware should never try to control host power directly. The desktop software owns all policy changes and recovery behavior. If the desktop software is not installed or stops responding, the device should keep reporting switch state and show a neutral missing-software light pattern.
