[CmdletBinding()]
param(
    [switch]$StartWithWindows,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$localData = [Environment]::GetFolderPath('LocalApplicationData')
$root = Join-Path $localData 'FocusTimer'
$app = Join-Path $root 'App'
$exePath = Join-Path $app 'FocusTimer.exe'
$legacyRoot = Join-Path $localData 'WorkTimer'
$stateFile = Join-Path $root 'state.json'
$legacyStateFile = Join-Path $legacyRoot 'state.json'
$legacyStartupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Work Timer.lnk'
$hadLegacyStartup = Test-Path -LiteralPath $legacyStartupShortcut

# Stop any running instance (new exe or legacy PowerShell)
Get-Process -Name 'FocusTimer' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $exePath } |
    ForEach-Object { $_.CloseMainWindow() | Out-Null; if (-not $_.WaitForExit(3000)) { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } }
$legacyScriptPath = Join-Path $app 'FocusTimerTray.ps1'
Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match '^powershell(\.exe)?$' -and $_.CommandLine -like "*${legacyScriptPath}*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Migrate legacy WorkTimer state
$null = [IO.Directory]::CreateDirectory($root)
if (-not (Test-Path -LiteralPath $stateFile) -and (Test-Path -LiteralPath $legacyStateFile)) {
    Move-Item -LiteralPath $legacyStateFile -Destination $stateFile
}
[IO.Directory]::CreateDirectory($app) | Out-Null

# Copy the exe
$sourceExe = Join-Path $source 'FocusTimer.exe'
if (-not (Test-Path -LiteralPath $sourceExe)) { throw 'Missing required file: FocusTimer.exe' }
Copy-Item -LiteralPath $sourceExe -Destination $exePath -Force

# Clean up legacy files from the app directory
@('FocusTimerTray.ps1', 'FocusTimerTray.vbs', 'FocusTimer.bat') | ForEach-Object {
    $legacy = Join-Path $app $_
    Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
}

# Create shortcuts
function New-FocusTimerShortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $exePath
    $shortcut.WorkingDirectory = $app
    $shortcut.Description = 'Run Focus Timer in the notification area'
    $shortcut.Save()
}

$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Focus Timer.lnk'
$startMenuShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Focus Timer.lnk'

# Remove legacy shortcuts
@(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Work Timer.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Work Timer.lnk'),
    $legacyStartupShortcut
) | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }

# Remove legacy app directory
$legacyApp = Join-Path $legacyRoot 'App'
Remove-Item -LiteralPath $legacyApp -Recurse -Force -ErrorAction SilentlyContinue
$legacyTmp = Join-Path $legacyRoot 'state.json.tmp'
Remove-Item -LiteralPath $legacyTmp -Force -ErrorAction SilentlyContinue
if ((Test-Path -LiteralPath $legacyRoot) -and -not (Get-ChildItem -LiteralPath $legacyRoot -Force)) {
    Remove-Item -LiteralPath $legacyRoot -Force
}

New-FocusTimerShortcut $desktopShortcut
New-FocusTimerShortcut $startMenuShortcut

if ($StartWithWindows -or $hadLegacyStartup) {
    $startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Focus Timer.lnk'
    New-FocusTimerShortcut $startupShortcut
}

Write-Host "Installed Focus Timer to $app" -ForegroundColor Green
Write-Host 'Your accumulated timer data was preserved.'
if ($StartWithWindows -or $hadLegacyStartup) { Write-Host 'Focus Timer will start when you sign in.' }
if ($Launch) { Start-Process $exePath }
