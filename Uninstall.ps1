[CmdletBinding()]
param([switch]$RemoveData)

$ErrorActionPreference = 'Stop'
$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'FocusTimer'
$app = Join-Path $root 'App'
$scriptPath = Join-Path $app 'FocusTimerTray.ps1'

Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match '^powershell(\.exe)?$' -and $_.CommandLine -like "*${scriptPath}*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

@(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Focus Timer.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Focus Timer.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Startup')) 'Focus Timer.lnk')
) | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }

Remove-Item -LiteralPath $app -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveData) {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Focus Timer and its saved timer data were removed.' -ForegroundColor Green
} else {
    Write-Host 'Focus Timer was removed. Saved timer data was preserved.' -ForegroundColor Green
}
