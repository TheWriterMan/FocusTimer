# Focus Timer

A tiny Windows tray timer for tracking awake working time without manually starting and stopping every session.

Focus Timer keeps a continuous total while Windows is awake, ignores long sleep and hibernation gaps, survives accidental window closure, and restores the saved total after restart. Everything stays on your computer.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 or newer
- No third-party dependencies

## Install

Open PowerShell in the downloaded or cloned folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Launch
```

Add `-StartWithWindows` to launch Focus Timer whenever you sign in. The installer adds **Focus Timer** to the Desktop and Start menu, preserves existing Focus Timer data when reinstalling, and migrates saved Work Timer state automatically.

## Use

- **Double-click the tray icon** to open the timer.
- **Close, minimize, or select Hide** to keep it running in the notification area.
- **Pause/Resume** controls whether awake time is added to the continuous total.
- **Set time** changes only the continuous total. **Reset** returns only that total to `00:00:00`.
- Set and Reset do not change history or whether the timer is running or paused.
- **Right-click the tray icon** to set the time, open history, switch themes, or exit.
- Use **Light/Dark** in the timer window to switch themes. The choice is remembered.
- **Exit timer** saves pending changes before stopping. Save failures warn and retry while Focus Timer remains open.

Sleep and hibernation gaps longer than five seconds are ignored. Time while Focus Timer is closed is not counted. The continuous total never resets at midnight or when the calendar date changes.

### Optional history

Daily history is off by default. Enable it with **History > Record daily history**. While enabled, it records accepted running time independently for each local date. Setting or resetting the continuous total never changes history.

Use **History > View history...** to view or clear history in the app. If existing history becomes unreadable, View history offers Start new history to replace unreadable records while keeping newly pending time. History remains local plaintext. Turning recording off preserves existing history. If history cannot be read or saved, Focus Timer warns you and retries when history is needed.

## Run without installing

Double-click `FocusTimer.bat` to run Focus Timer in the notification area.

## Uninstall

Run `Uninstall.ps1` to remove the app while preserving timer data. Run `Uninstall.ps1 -RemoveData` to remove the app and all saved timer data, including daily history.

## Privacy

Focus Timer has no network requests, telemetry, accounts, or cloud storage.
