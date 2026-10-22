# Focus Timer

A tiny Windows tray timer for tracking awake working time.

## Run

Double-click `FocusTimer.exe`. That's it. It appears in your system tray.

Timer data is saved automatically to `%LocalAppData%\FocusTimer\state.json`.

## Update

Close the timer (right-click tray icon → Exit timer), replace `FocusTimer.exe` with the new one, double-click it again. Your time is preserved.

## Use

- The **tray icon** shows elapsed time as `H:MM` (white = running, yellow = paused).
- **Double-click the tray icon** to open the window.
- **Pause/Resume** controls whether time accrues.
- **Set time** / **Reset** change the total.
- **Light/Dark** theme is remembered.
- Sleep and hibernation gaps over five seconds are ignored.
- Closing or minimizing the window hides it to the tray.

## Optional install

If you want desktop/start menu shortcuts and auto-start with Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -Launch -StartWithWindows
```

## Build from source

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1
```

Requires the `ps2exe` module (`Install-Module ps2exe -Scope CurrentUser`).

## Privacy

No network requests, telemetry, accounts, or cloud storage.
