[CmdletBinding()]
param([switch]$RemoveData)

$ErrorActionPreference = 'Stop'
$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WorkTimer'
$app = Join-Path $root 'App'
$scriptPath = Join-Path $app 'WorkTimerTray.ps1'

Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match '^powershell(\.exe)?$' -and $_.CommandLine -like "*${scriptPath}*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

@(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Work Timer.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Work Timer.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Startup')) 'Work Timer.lnk')
) | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }

Remove-Item -LiteralPath $app -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveData) {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Work Timer and its saved timer data were removed.' -ForegroundColor Green
} else {
    Write-Host 'Work Timer was removed. Saved timer data was preserved.' -ForegroundColor Green
}
