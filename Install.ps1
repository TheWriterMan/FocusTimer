[CmdletBinding()]
param(
    [switch]$StartWithWindows,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WorkTimer'
$app = Join-Path $root 'App'
[IO.Directory]::CreateDirectory($app) | Out-Null

$files = @('WorkTimerTray.ps1', 'WorkTimerTray.vbs', 'WorkTimer.bat')
foreach ($file in $files) {
    $path = Join-Path $source $file
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing required file: $file" }
    Copy-Item -LiteralPath $path -Destination (Join-Path $app $file) -Force
}

function New-WorkTimerShortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcut.Arguments = '"' + (Join-Path $app 'WorkTimerTray.vbs') + '"'
    $shortcut.WorkingDirectory = $app
    $shortcut.WindowStyle = 7
    $shortcut.Description = 'Run Work Timer in the notification area'
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,167"
    $shortcut.Save()
}

$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Work Timer.lnk'
$startMenuShortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Work Timer.lnk'
New-WorkTimerShortcut $desktopShortcut
New-WorkTimerShortcut $startMenuShortcut

if ($StartWithWindows) {
    $startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Work Timer.lnk'
    New-WorkTimerShortcut $startupShortcut
}

Write-Host "Installed Work Timer to $app" -ForegroundColor Green
Write-Host 'Your accumulated timer data was preserved.'
if ($StartWithWindows) { Write-Host 'Work Timer will start when you sign in.' }
if ($Launch) { Start-Process $desktopShortcut }
