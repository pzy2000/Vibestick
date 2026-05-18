# Vibestick

Vibestick is a Windows-first CLI prototype for a physical sleep-policy key.

The MVP proves the core workflow before tray UI or real hardware:

- `off`: restore the original lid-close policy and release keep-awake state.
- `on`: set the current Windows power plan lid-close action to `Do Nothing`.
- `hyper`: apply `on`, add battery safeguards, detect long-running coder tasks, and optionally hold a foreground sleep blocker.

## Prerequisites

- Windows 10/11
- .NET 8 SDK

This repository intentionally has no external NuGet package dependencies.

## Commands

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

On this machine the SDK was installed with `dotnet-install` under `%USERPROFILE%\.dotnet`. You can use the wrapper without changing PATH:

```powershell
.\scripts\vibestick.ps1 status
.\scripts\vibestick.ps1 doctor --json
```

`mode hyper` keeps a foreground guard process alive so Windows idle sleep remains blocked while it runs. Use `Ctrl+C` to stop the guard. `mode hyper --once` applies the power policy and exits, but it cannot keep a sleep assertion after the process exits.

## GUI

The GUI starts as a desktop pet by default. It stays on top, patrols along the bottom of the desktop like a classic QQ pet, can be dragged or resized, and opens the existing control panel when clicked:

```powershell
.\scripts\vibestick-gui.ps1
```

Right-click the pet to pause or resume walking, open the control panel, refresh, or exit. The tray icon also exposes the control panel, pet, and exit actions. The control panel still exposes status refresh, diagnostics, ON, HYPER, Stop HYPER Guard, and OFF/Revert controls. HYPER in the GUI keeps a sleep blocker active while the control panel remains open or until you stop the guard.

## Desktop Pet Coder Status

Vibestick starts a local Codex status bridge with the pet by default. The bridge watches Codex session JSONL files under `%USERPROFILE%\.codex\sessions`, maps fresh Codex events to summary pet states, and writes those summaries to local adapter files under:

```text
%LOCALAPPDATA%\Vibestick\coder-status\*.json
```

Use Codex normally after starting the pet; the pet switches between thinking, tool-calling, success, and other supported moods as new Codex session events arrive. Codex sessions are tracked separately by their session id, so concurrent conversations appear as separate task cards above the pet instead of overwriting one another.

Task card titles come from the first substantive user request in each Codex session, with environment-context records, image payloads, skill links, local paths, and oversized text stripped before display. Recent assistant progress is shown as the card detail when available. Unfinished sessions stay visible while they are recently active; completed sessions show success briefly and then expire.

The pet shows up to three task cards by default. If more sessions are active, a `+N` counter appears next to the chevron button; click the chevron to expand the bounded task list, and click it again to collapse. Click a task card to bring the matching Codex or editor window forward; Vibestick falls back to the control panel if no matching window is found.

To disable automatic Codex monitoring for debugging:

```powershell
.\scripts\vibestick-gui.ps1 --no-codex-monitor
```

When no adapter state exists, Vibestick falls back to whitelisted process detection for tools such as Codex, Claude, node, Python, Docker, and similar long-running coder tasks.

Manual adapter commands remain useful for testing and non-Codex integrations:

```powershell
.\scripts\vibestick.ps1 pet status --json
.\scripts\vibestick.ps1 coder emit --agent codex --phase reasoning --message "Reading pet state code" --ttl 30 --json
.\scripts\vibestick.ps1 coder emit --agent codex --phase tool_calling --message "Running rg for status resolver" --ttl 30 --json
.\scripts\vibestick.ps1 coder emit --agent codex --phase success --message "Patch complete" --ttl 30 --json
.\scripts\vibestick.ps1 coder emit --agent codex --phase waiting_authorization --message "Approval needed" --ttl 120 --json
.\scripts\vibestick.ps1 coder emit --agent codex --session-id demo-1 --summary "Implement task cards" --detail "Reviewing card layout" --phase reasoning --message "Thinking" --ttl 120 --json
.\scripts\vibestick.ps1 coder clear --agent codex --json
```

Supported coder phases are `idle`, `sleeping`, `running`, `reasoning`, `tool_calling`, `waiting_authorization`, `error`, `success`, `offline`, and `unknown`. The pet maps them to its mascot moods, with power and battery safety warnings overriding coder animation only when they need attention.

## State

Vibestick stores local state at:

```text
%LOCALAPPDATA%\Vibestick\state.json
```

The state file records the original lid-close AC/DC values for the active power scheme so `revert` can restore them. Vibestick will not overwrite a pending backup; run `vibestick revert` before applying a fresh mode to a different active power scheme.

## Tests

```powershell
dotnet run --project tests/Vibestick.Tests
```

The test runner is a small console app so the MVP can stay dependency-free.
