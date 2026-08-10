# Focus Timer

A tiny Windows tray timer for tracking awake working time without manually starting and stopping every session.

Focus Timer keeps counting while Windows is awake, ignores long sleep/hibernate gaps, survives accidental window closure, and restores the saved total after restart. Everything stays on your computer.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 or newer
- No third-party dependencies

## Install

Open PowerShell in the downloaded or cloned folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Launch
```

To launch automatically when you sign in:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -StartWithWindows -Launch
```

The installer adds **Focus Timer** to the Desktop and Start menu. Existing Focus Timer data is preserved when reinstalling, and saved Work Timer state is migrated automatically.

## Use

- **Double-click the tray icon** to open the timer.
- **Close, minimize, or select Hide to tray** to keep it running in the notification area.
- **Right-click the tray icon** for Show, Pause/Resume, Reset, theme, and Exit controls.
- Use **Light/Dark** in the timer window to switch themes. The choice is remembered.
- **Reset** starts a new total at `00:00:00`; there is no automatic midnight reset.
- **Exit timer** stops the background process. Reopening resumes from the saved value.

Sleep and hibernation gaps longer than five seconds are ignored. If the process is closed, that closed time is not counted.

Timer state is stored at:

```text
%LOCALAPPDATA%\FocusTimer\state.json
```

## Run without installing

Double-click `FocusTimer.bat`. The timer runs in the notification area and stores state in the same location.

## Uninstall

Preserve accumulated timer data:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

Remove the application and its saved timer data:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1 -RemoveData
```

## Privacy

Focus Timer has no network requests, telemetry, accounts, or cloud storage.
