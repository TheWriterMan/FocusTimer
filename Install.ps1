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
$legacyRoot = Join-Path $localData 'WorkTimer'
$legacyApp = Join-Path $legacyRoot 'App'
$stateFile = Join-Path $root 'state.json'
$legacyStateFile = Join-Path $legacyRoot 'state.json'
$legacyTemporaryStateFile = Join-Path $legacyRoot 'state.json.tmp'
$legacyStartupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Work Timer.lnk'
$hadLegacyStartup = Test-Path -LiteralPath $legacyStartupShortcut

$legacyScriptPattern = 'WorkTimerTray\.ps1'
Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match '^powershell(\.exe)?$' -and $_.CommandLine -match $legacyScriptPattern } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$null = [IO.Directory]::CreateDirectory($root)
if (-not (Test-Path -LiteralPath $stateFile) -and (Test-Path -LiteralPath $legacyStateFile)) {
    Move-Item -LiteralPath $legacyStateFile -Destination $stateFile
}
[IO.Directory]::CreateDirectory($app) | Out-Null

$files = @('FocusTimerTray.ps1', 'FocusTimerTray.vbs', 'FocusTimer.bat')
foreach ($file in $files) {
    $path = Join-Path $source $file
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing required file: $file" }
    Copy-Item -LiteralPath $path -Destination (Join-Path $app $file) -Force
}

function New-FocusTimerShortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcut.Arguments = '"' + (Join-Path $app 'FocusTimerTray.vbs') + '"'
    $shortcut.WorkingDirectory = $app
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Run Focus Timer in the notification area'
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,167"
    $shortcut.Save()
}

$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Focus Timer.lnk'
$startMenuShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Focus Timer.lnk'
@(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Work Timer.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Work Timer.lnk'),
    $legacyStartupShortcut
) | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $legacyApp -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $legacyTemporaryStateFile -Force -ErrorAction SilentlyContinue
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
if ($Launch) { Start-Process $desktopShortcut }
