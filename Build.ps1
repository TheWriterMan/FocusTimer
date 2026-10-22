# Builds FocusTimer.exe from FocusTimerTray.ps1
# Requires: Install-Module ps2exe -Scope CurrentUser
$ErrorActionPreference = 'Stop'
Invoke-ps2exe -inputFile "$PSScriptRoot\FocusTimerTray.ps1" -outputFile "$PSScriptRoot\FocusTimer.exe" -noConsole -title "Focus Timer" -description "Tray timer for tracking focus time" -product "Focus Timer" -version "2.0.0.0" -noError
Write-Host 'Built FocusTimer.exe' -ForegroundColor Green
