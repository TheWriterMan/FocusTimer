Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Stop'

$mutex = New-Object System.Threading.Mutex($false, 'Local\PersonalFocusTimer')
$locked = $false
$timer = $null
$notify = $null

try {
    try { $locked = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $locked = $true }

    if (-not $locked) {
        [System.Windows.Forms.MessageBox]::Show(
            'Focus Timer is already running in the notification area.',
            'Focus Timer', 'OK', 'Information') | Out-Null
        return
    }

    $localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $stateDirectory = Join-Path $localData 'FocusTimer'
    $stateFile = Join-Path $stateDirectory 'state.json'
    $historyFile = Join-Path $stateDirectory 'daily-history.csv'
    $legacyStateFile = Join-Path (Join-Path $localData 'WorkTimer') 'state.json'
    [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $invariantCulture = [Globalization.CultureInfo]::InvariantCulture

    $script:seconds = 0.0
    $script:running = $true
    $script:theme = 'dark'
    $script:historyEnabled = $false
    $script:allowExit = $false
    $script:lastTickUtc = [DateTime]::UtcNow
    $script:lastTickLocal = Get-Date
    $script:lastSavedSecond = -1
    $script:stateDirty = $true
    $script:stateWarningShown = $false
    $script:stateWarningPending = $false
    $script:nextStateRetryUtc = [DateTime]::MinValue
    $script:historyLoadAttempted = $false
    $script:historyValid = $false
    $script:historyRecoveryInProgress = $false
    $script:historyViewOpen = $false
    $script:historyEntries = @{}
    $script:pendingHistory = @{}
    $script:historyDirty = $false
    $script:historySaveFailed = $false
    $script:historyWarningShown = $false
    $script:historyWarningPending = $false
    $script:historyWarningMessage = ''
    $script:nextHistoryRetryUtc = [DateTime]::MinValue
    $script:lastHistoryFlushUtc = [DateTime]::UtcNow


    function Format-Time([double]$value) {
        $whole = [Math]::Floor([Math]::Max(0, $value))
        $hours = [Math]::Floor($whole / 3600)
        $minutes = [Math]::Floor(($whole % 3600) / 60)
        $secs = $whole % 60
        return '{0:00}:{1:00}:{2:00}' -f $hours, $minutes, $secs
    }

    function Test-JsonNumber($value) {
        $numericTypes = @(
            [byte], [sbyte], [int16], [uint16], [int32], [uint32],
            [int64], [uint64], [single], [double], [decimal]
        )
        foreach ($type in $numericTypes) {
            if ($value -is $type) { return $true }
        }
        return $false
    }

    function Write-AtomicText([string]$path, [string]$text) {
        $directory = [IO.Path]::GetDirectoryName($path)
        $temporary = Join-Path $directory ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($path), [Guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::WriteAllText($temporary, $text, $utf8)
            if ([IO.File]::Exists($path)) {
                [IO.File]::Replace($temporary, $path, $null)
            } else {
                [IO.File]::Move($temporary, $path)
            }
            return $true
        } catch {
            return $false
        } finally {
            try {
                if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
            } catch {}
        }
    }

    function Show-StateWarning {
        if ($script:stateWarningShown) { return }
        $script:stateWarningShown = $true
        if ($null -eq $notify) {
            $script:stateWarningPending = $true
            return
        }
        $notify.ShowBalloonTip(
            5000,
            'Focus Timer could not save',
            'Time is still being tracked. Focus Timer will keep retrying while it is open.',
            [Windows.Forms.ToolTipIcon]::Warning)
    }

    function Show-HistoryWarning([string]$message) {
        if ($script:historyWarningShown) { return }
        $script:historyWarningShown = $true
        $script:historyWarningMessage = $message
        if ($null -eq $notify) {
            $script:historyWarningPending = $true
            return
        }
        $notify.ShowBalloonTip(5000, 'Focus Timer history', $message, [Windows.Forms.ToolTipIcon]::Warning)
    }

    function Show-PendingWarnings {
        if ($script:stateWarningPending -and $null -ne $notify) {
            $script:stateWarningPending = $false
            $notify.ShowBalloonTip(
                5000,
                'Focus Timer could not save',
                'Time is still being tracked. Focus Timer will keep retrying while it is open.',
                [Windows.Forms.ToolTipIcon]::Warning)
        }
        if ($script:historyWarningPending -and $null -ne $notify) {
            $script:historyWarningPending = $false
            $notify.ShowBalloonTip(
                5000,
                'Focus Timer history',
                $script:historyWarningMessage,
                [Windows.Forms.ToolTipIcon]::Warning)
        }
    }

    function Import-State([string]$path) {
        if (-not [IO.File]::Exists($path)) { return $false }
        try {
            $saved = [IO.File]::ReadAllText($path, $utf8) | ConvertFrom-Json -ErrorAction Stop
            if ($saved -isnot [PSCustomObject]) { return $false }

            $names = @($saved.PSObject.Properties.Name)
            if ($names -contains 'seconds' -and (Test-JsonNumber $saved.seconds)) {
                $loadedSeconds = [double]$saved.seconds
                if ($loadedSeconds -ge 0 -and
                    -not [double]::IsNaN($loadedSeconds) -and
                    -not [double]::IsInfinity($loadedSeconds)) {
                    $script:seconds = $loadedSeconds
                }
            }
            if ($names -contains 'running' -and $saved.running -is [bool]) {
                $script:running = [bool]$saved.running
            }
            if ($names -contains 'theme' -and $saved.theme -is [string] -and
                @('light', 'dark') -contains [string]$saved.theme) {
                $script:theme = [string]$saved.theme
            }
            if ($names -contains 'historyEnabled' -and
                $saved.historyEnabled -is [bool] -and $saved.historyEnabled -eq $true) {
                $script:historyEnabled = $true
            }
            return $true
        } catch {
            return $false
        }
    }

    $stateSource = $stateFile
    if (-not [IO.File]::Exists($stateSource) -and [IO.File]::Exists($legacyStateFile)) {
        $stateSource = $legacyStateFile
    }
    [void](Import-State $stateSource)

    function Try-SaveState {
        $data = [ordered]@{
            seconds = [Math]::Round($script:seconds, 3)
            running = [bool]$script:running
            theme = [string]$script:theme
            historyEnabled = [bool]$script:historyEnabled
            updated = (Get-Date).ToString('o')
        }
        $json = $data | ConvertTo-Json -Compress
        if (Write-AtomicText $stateFile $json) {
            $script:stateDirty = $false
            $script:lastSavedSecond = [Math]::Floor($script:seconds)
            $script:nextStateRetryUtc = [DateTime]::MinValue
            $script:stateWarningShown = $false
            $script:stateWarningPending = $false
            return $true
        }
        $script:stateDirty = $true
        $script:nextStateRetryUtc = [DateTime]::UtcNow.AddSeconds(60)
        Show-StateWarning
        return $false
    }

    function Request-StateSave {
        $script:stateDirty = $true
        return (Try-SaveState)
    }

    function Reset-HistoryFailureEpisode {
        $script:historyWarningShown = $false
        $script:historyWarningPending = $false
        $script:historyWarningMessage = ''
    }

    function Ensure-HistoryLoaded([switch]$Force) {
        if ($script:historyRecoveryInProgress) { return $false }
        if ($script:historyValid -and -not $Force) { return $true }
        $nowUtc = [DateTime]::UtcNow
        if (-not $Force -and $script:historyLoadAttempted -and
            $script:nextHistoryRetryUtc -ne [DateTime]::MinValue -and
            $nowUtc -lt $script:nextHistoryRetryUtc) {
            return $false
        }

        $script:historyLoadAttempted = $true
        if (-not [IO.File]::Exists($historyFile)) {
            $script:historyEntries = @{}
            $script:historyValid = $true
            $script:historySaveFailed = $false
            $script:nextHistoryRetryUtc = [DateTime]::MinValue
            Reset-HistoryFailureEpisode
            return $true
        }

        try {
            $lines = [IO.File]::ReadAllLines($historyFile, $utf8)
            if ($lines.Count -lt 1 -or $lines[0] -cne 'Date,Seconds,Time') {
                throw 'History header does not match.'
            }

            $loadedEntries = @{}
            for ($index = 1; $index -lt $lines.Count; $index++) {
                $line = $lines[$index]
                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                $firstComma = $line.IndexOf(',')
                if ($firstComma -lt 1) { throw 'History row has an invalid comma shape.' }
                $secondComma = $line.IndexOf(',', $firstComma + 1)
                if ($secondComma -lt 0 -or $line.IndexOf(',', $secondComma + 1) -ge 0) {
                    throw 'History row has an invalid comma shape.'
                }

                $dateText = $line.Substring(0, $firstComma)
                $secondsText = $line.Substring($firstComma + 1, $secondComma - $firstComma - 1)
                $parsedDate = [DateTime]::MinValue
                if (-not [DateTime]::TryParseExact(
                    $dateText,
                    'yyyy-MM-dd',
                    $invariantCulture,
                    [Globalization.DateTimeStyles]::None,
                    [ref]$parsedDate)) {
                    throw 'History row has an invalid date.'
                }
                if ($parsedDate.ToString('yyyy-MM-dd', $invariantCulture) -cne $dateText) {
                    throw 'History row has an invalid date.'
                }

                $rowSeconds = 0.0
                if (-not [double]::TryParse(
                    $secondsText,
                    [Globalization.NumberStyles]::Float,
                    $invariantCulture,
                    [ref]$rowSeconds)) {
                    throw 'History row has invalid seconds.'
                }
                if ($rowSeconds -lt 0 -or [double]::IsNaN($rowSeconds) -or [double]::IsInfinity($rowSeconds)) {
                    throw 'History row has invalid seconds.'
                }

                # Time is display-only. The last row for a date wins.
                $loadedEntries[$dateText] = $rowSeconds
            }

            $script:historyEntries = $loadedEntries
            $script:historyValid = $true
            $script:historySaveFailed = $false
            $script:historyDirty = $script:pendingHistory.Count -gt 0
            $script:nextHistoryRetryUtc = [DateTime]::MinValue
            Reset-HistoryFailureEpisode
            return $true
        } catch {
            $script:historyValid = $false
            $script:historySaveFailed = $false
            $script:nextHistoryRetryUtc = $nowUtc.AddSeconds(60)
            $retryMessage = if ($script:historyEnabled -or $script:historyDirty -or $script:pendingHistory.Count -gt 0) {
                'Existing history couldn''t be read. Focus Timer will retry.'
            } elseif ($script:historyViewOpen) {
                'Existing history couldn''t be read. Focus Timer will retry while this window is open.'
            } else {
                'Existing history couldn''t be read.'
            }
            Show-HistoryWarning $retryMessage
            return $false
        }
    }

    function Add-PendingHistory([string]$date, [double]$delta) {
        if (-not $script:historyEnabled -or $delta -le 0 -or
            [double]::IsNaN($delta) -or [double]::IsInfinity($delta)) { return }
        if (-not $script:pendingHistory.ContainsKey($date)) { $script:pendingHistory[$date] = 0.0 }
        $script:pendingHistory[$date] = [double]$script:pendingHistory[$date] + $delta
        $script:historyDirty = $true
    }

    function Get-HistorySnapshot {
        $snapshot = @{}
        foreach ($key in $script:historyEntries.Keys) { $snapshot[$key] = [double]$script:historyEntries[$key] }
        foreach ($key in $script:pendingHistory.Keys) {
            if (-not $snapshot.ContainsKey($key)) { $snapshot[$key] = 0.0 }
            $snapshot[$key] = [Math]::Max(0, [double]$snapshot[$key] + [double]$script:pendingHistory[$key])
        }
        return $snapshot
    }

    function Convert-HistoryToText($entries) {
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add('Date,Seconds,Time')
        foreach ($key in @($entries.Keys | Sort-Object)) {
            $value = [Math]::Max(0, [double]$entries[$key])
            $secondsText = ([Math]::Round($value, 3)).ToString('0.###', $invariantCulture)
            $lines.Add('{0},{1},{2}' -f $key, $secondsText, (Format-Time $value))
        }
        return (($lines.ToArray() -join "`r`n") + "`r`n")
    }

    function Try-FlushHistory([switch]$Force) {
        if ($script:historyRecoveryInProgress) { return $false }
        if (-not (Ensure-HistoryLoaded -Force:$Force)) { return $false }
        if (-not $Force -and $script:historySaveFailed -and
            $script:nextHistoryRetryUtc -ne [DateTime]::MinValue -and
            [DateTime]::UtcNow -lt $script:nextHistoryRetryUtc) {
            return $false
        }
        if (-not $script:historyDirty) { return $true }

        $snapshot = Get-HistorySnapshot
        if (Write-AtomicText $historyFile (Convert-HistoryToText $snapshot)) {
            $script:historyEntries = $snapshot
            $script:pendingHistory = @{}
            $script:historyDirty = $false
            $script:historySaveFailed = $false
            $script:lastHistoryFlushUtc = [DateTime]::UtcNow
            $script:nextHistoryRetryUtc = [DateTime]::MinValue
            Reset-HistoryFailureEpisode
            return $true
        }

        $script:historyDirty = $true
        $script:historySaveFailed = $true
        $script:nextHistoryRetryUtc = [DateTime]::UtcNow.AddSeconds(60)
        Show-HistoryWarning 'History isn''t being saved. Focus Timer will retry.'
        return $false
    }

    function Try-ClearHistory {
        if (Write-AtomicText $historyFile "Date,Seconds,Time`r`n") {
            $script:historyLoadAttempted = $true
            $script:historyValid = $true
            $script:historyEntries = @{}
            $script:pendingHistory = @{}
            $script:historyDirty = $false
            $script:historySaveFailed = $false
            $script:lastHistoryFlushUtc = [DateTime]::UtcNow
            $script:nextHistoryRetryUtc = [DateTime]::MinValue
            Reset-HistoryFailureEpisode
            return $true
        }
        return $false
    }

    if ($script:historyEnabled) { [void](Ensure-HistoryLoaded) }

    function Add-AccruedHistory(
        [DateTime]$startUtc,
        [DateTime]$endUtc,
        [DateTime]$startLocal,
        [DateTime]$endLocal,
        [double]$delta) {
        if (-not $script:historyEnabled -or $delta -le 0) { return }
        $startDate = $startLocal.ToString('yyyy-MM-dd', $invariantCulture)
        $endDate = $endLocal.ToString('yyyy-MM-dd', $invariantCulture)
        if ($startDate -eq $endDate) {
            Add-PendingHistory $endDate $delta
            return
        }

        $localElapsed = ($endLocal - $startLocal).TotalSeconds
        $normalAdjacentMidnight = (
            $startLocal.Date.AddDays(1) -eq $endLocal.Date -and
            $localElapsed -ge 0 -and
            [Math]::Abs($localElapsed - $delta) -le 1)
        if ($normalAdjacentMidnight) {
            $secondsBeforeMidnight = ($startLocal.Date.AddDays(1) - $startLocal).TotalSeconds
            if ($secondsBeforeMidnight -ge 0 -and $secondsBeforeMidnight -le $delta) {
                if ($secondsBeforeMidnight -gt 0) {
                    Add-PendingHistory $startDate $secondsBeforeMidnight
                }
                if ($delta -gt $secondsBeforeMidnight) {
                    Add-PendingHistory $endDate ($delta - $secondsBeforeMidnight)
                }
                return
            }
        }

        # Clock, date, and time-zone anomalies belong wholly to the current endpoint date.
        Add-PendingHistory $endDate $delta
    }

    function Accrue-ToNow {
        $startUtc = $script:lastTickUtc
        $startLocal = $script:lastTickLocal
        $nowUtc = [DateTime]::UtcNow
        $nowLocal = Get-Date
        $delta = ($nowUtc - $startUtc).TotalSeconds

        # Advance both baselines before validating or applying elapsed time.
        $script:lastTickUtc = $nowUtc
        $script:lastTickLocal = $nowLocal

        if ($script:running -and $delta -ge 0 -and $delta -le 5) {
            $script:seconds += $delta
            $script:stateDirty = $true
            Add-AccruedHistory $startUtc $nowUtc $startLocal $nowLocal $delta
        }
        return $delta
    }

    function ConvertFrom-TimeText([string]$text) {
        $match = [regex]::Match($text.Trim(), '^(?<hours>\d+):(?<minutes>[0-5]\d):(?<seconds>[0-5]\d)$')
        if (-not $match.Success) { return $null }
        try {
            $hours = [Convert]::ToDouble($match.Groups['hours'].Value, $invariantCulture)
            $minutes = [int]$match.Groups['minutes'].Value
            $secs = [int]$match.Groups['seconds'].Value
            $value = ($hours * 3600) + ($minutes * 60) + $secs
            if ($value -lt 0 -or [double]::IsInfinity($value) -or [double]::IsNaN($value)) { return $null }
            return [double]$value
        } catch {
            return $null
        }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Focus Timer'
    $form.ClientSize = New-Object System.Drawing.Size(360, 220)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.MinimumSize = $form.Size

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'FOCUS TIMER'
    $titleLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $titleLabel.TextAlign = 'MiddleCenter'
    $titleLabel.SetBounds(65, 14, 230, 24)
    $titleLabel.AccessibleName = 'Focus Timer'

    $themeButton = New-Object System.Windows.Forms.Button
    $themeButton.SetBounds(294, 12, 52, 30)
    $themeButton.FlatStyle = 'Flat'
    $themeButton.FlatAppearance.BorderSize = 1
    $themeButton.TabIndex = 4
    $themeButton.AccessibleDescription = 'Switches the color theme.'

    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Font = New-Object Drawing.Font('Consolas', 30, [Drawing.FontStyle]::Bold)
    $timeLabel.TextAlign = 'MiddleCenter'
    $timeLabel.SetBounds(20, 54, 320, 48)
    $timeLabel.AccessibleName = 'Total focus time'

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
    $statusLabel.TextAlign = 'MiddleCenter'
    $statusLabel.SetBounds(30, 108, 300, 22)
    $statusLabel.AccessibleName = 'Timer status'

    $toggleButton = New-Object System.Windows.Forms.Button
    $toggleButton.SetBounds(12, 158, 78, 36)
    $toggleButton.FlatStyle = 'Flat'
    $toggleButton.FlatAppearance.BorderSize = 1
    $toggleButton.TabIndex = 0

    $setTimeButton = New-Object System.Windows.Forms.Button
    $setTimeButton.Text = 'Set time'
    $setTimeButton.SetBounds(98, 158, 78, 36)
    $setTimeButton.FlatStyle = 'Flat'
    $setTimeButton.FlatAppearance.BorderSize = 1
    $setTimeButton.TabIndex = 1

    $resetButton = New-Object System.Windows.Forms.Button
    $resetButton.Text = 'Reset'
    $resetButton.SetBounds(184, 158, 78, 36)
    $resetButton.FlatStyle = 'Flat'
    $resetButton.FlatAppearance.BorderSize = 1
    $resetButton.TabIndex = 2

    $hideButton = New-Object System.Windows.Forms.Button
    $hideButton.Text = 'Hide'
    $hideButton.SetBounds(270, 158, 78, 36)
    $hideButton.FlatStyle = 'Flat'
    $hideButton.FlatAppearance.BorderSize = 1
    $hideButton.TabIndex = 3
    $hideButton.AccessibleDescription = 'Hides the window and keeps the timer in the notification area.'

    $form.Controls.AddRange(@(
        $titleLabel, $themeButton, $timeLabel, $statusLabel,
        $toggleButton, $setTimeButton, $resetButton, $hideButton
    ))

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Enabled = $false
    $showItem = New-Object System.Windows.Forms.ToolStripMenuItem('Show timer')
    $toggleItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $setTimeItem = New-Object System.Windows.Forms.ToolStripMenuItem('Set time...')
    $resetItem = New-Object System.Windows.Forms.ToolStripMenuItem('Reset timer')
    $themeItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $historyMenu = New-Object System.Windows.Forms.ToolStripMenuItem('History')
    $historyToggleItem = New-Object System.Windows.Forms.ToolStripMenuItem('Record daily history')
    $historyToggleItem.CheckOnClick = $false
    $viewHistoryItem = New-Object System.Windows.Forms.ToolStripMenuItem('View history...')
    $viewHistoryItem.Enabled = $true
    [void]$historyMenu.DropDownItems.Add($historyToggleItem)
    [void]$historyMenu.DropDownItems.Add($viewHistoryItem)
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit timer')
    [void]$menu.Items.Add($statusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($showItem)
    [void]$menu.Items.Add($toggleItem)
    [void]$menu.Items.Add($setTimeItem)
    [void]$menu.Items.Add($resetItem)
    [void]$menu.Items.Add($themeItem)
    [void]$menu.Items.Add($historyMenu)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($exitItem)

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [Drawing.SystemIcons]::Information
    $notify.ContextMenuStrip = $menu
    $notify.Visible = $true

    function Get-ThemeColors {
        if ($script:theme -eq 'dark') {
            return @{
                Background = [Drawing.Color]::FromArgb(24, 24, 27)
                Foreground = [Drawing.Color]::FromArgb(250, 250, 250)
                Muted = [Drawing.Color]::FromArgb(161, 161, 170)
                Surface = [Drawing.Color]::FromArgb(32, 32, 36)
                SurfaceHover = [Drawing.Color]::FromArgb(44, 44, 50)
                Border = [Drawing.Color]::FromArgb(82, 82, 91)
                Accent = [Drawing.Color]::FromArgb(103, 232, 249)
                Running = [Drawing.Color]::FromArgb(74, 222, 128)
                Paused = [Drawing.Color]::FromArgb(250, 204, 21)
                Danger = [Drawing.Color]::FromArgb(252, 165, 165)
            }
        }
        return @{
            Background = [Drawing.Color]::FromArgb(250, 250, 249)
            Foreground = [Drawing.Color]::FromArgb(24, 24, 27)
            Muted = [Drawing.Color]::FromArgb(82, 82, 91)
            Surface = [Drawing.Color]::White
            SurfaceHover = [Drawing.Color]::FromArgb(244, 244, 245)
            Border = [Drawing.Color]::FromArgb(212, 212, 216)
            Accent = [Drawing.Color]::FromArgb(8, 145, 178)
            Running = [Drawing.Color]::FromArgb(21, 128, 61)
            Paused = [Drawing.Color]::FromArgb(161, 98, 7)
            Danger = [Drawing.Color]::FromArgb(185, 28, 28)
        }
    }

    function Style-Button($button, $colors) {
        $button.UseVisualStyleBackColor = $false
        $button.BackColor = $colors.Surface
        $button.ForeColor = $colors.Foreground
        $button.FlatStyle = 'Flat'
        $button.FlatAppearance.BorderColor = $colors.Border
        $button.FlatAppearance.MouseOverBackColor = $colors.SurfaceHover
        $button.FlatAppearance.MouseDownBackColor = $colors.Border
    }

    function Update-Display {
        $time = Format-Time $script:seconds
        $status = if ($script:running) { 'RUNNING' } else { 'PAUSED' }
        $statusLabel.Text = if ($script:running) { [char]0x25CF + ' RUNNING' } else { [char]0x2161 + ' PAUSED' }
        $timeLabel.Text = $time
        $colors = Get-ThemeColors
        $statusLabel.ForeColor = if ($script:running) { $colors.Running } else { $colors.Paused }
        $toggleButton.Text = if ($script:running) { 'Pause' } else { 'Resume' }
        $toggleItem.Text = if ($script:running) { 'Pause timer' } else { 'Resume timer' }
        $statusItem.Text = "Total: $time - $status"
        $historyToggleItem.Checked = $script:historyEnabled
        $viewHistoryItem.Enabled = $true
        $tip = "Focus Timer: $time ($status)"
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $notify.Text = $tip
    }

    function Apply-Theme {
        $colors = Get-ThemeColors
        $form.BackColor = $colors.Background
        $form.ForeColor = $colors.Foreground
        $titleLabel.BackColor = $colors.Background
        $titleLabel.ForeColor = $colors.Accent
        $timeLabel.BackColor = $colors.Background
        $timeLabel.ForeColor = $colors.Foreground
        $statusLabel.BackColor = $colors.Background
        foreach ($button in @($themeButton, $toggleButton, $setTimeButton, $resetButton, $hideButton)) {
            Style-Button $button $colors
        }
        $themeButton.Text = if ($script:theme -eq 'dark') { 'Light' } else { 'Dark' }
        $themeItem.Text = if ($script:theme -eq 'dark') { 'Use light theme' } else { 'Use dark theme' }
        Update-Display
    }

    function Show-TimerWindow {
        [void](Accrue-ToNow)
        [void](Request-StateSave)
        if (-not $form.Visible) { $form.Show() }
        $form.WindowState = 'Normal'
        $form.Activate()
        $toggleButton.Focus()
        Update-Display
    }

    function Show-SetTimeDialog {
        [void](Accrue-ToNow)
        [void](Request-StateSave)
        $colors = Get-ThemeColors
        $dialog = New-Object System.Windows.Forms.Form
        $dialog.Text = 'Set timer'
        $dialog.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
        $dialog.ClientSize = New-Object Drawing.Size(380, 210)
        $dialog.MinimumSize = New-Object Drawing.Size(360, 200)
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.MaximizeBox = $false
        $dialog.MinimizeBox = $false
        $dialog.ShowInTaskbar = $false
        $dialog.StartPosition = if ($form.Visible) { 'CenterParent' } else { 'CenterScreen' }
        $dialog.TopMost = -not $form.Visible
        $dialog.BackColor = $colors.Background
        $dialog.ForeColor = $colors.Foreground

        $layout = New-Object System.Windows.Forms.TableLayoutPanel
        $layout.Dock = 'Fill'
        $layout.Padding = New-Object Windows.Forms.Padding(20)
        $layout.ColumnCount = 1
        $layout.RowCount = 4
        [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))

        $inputLabel = New-Object System.Windows.Forms.Label
        $inputLabel.Text = 'Timer total (HH:MM:SS)'
        $inputLabel.AutoSize = $true
        $inputLabel.Dock = 'Fill'
        $inputLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 6)

        $timeInput = New-Object System.Windows.Forms.TextBox
        $timeInput.Text = Format-Time $script:seconds
        $timeInput.Font = New-Object Drawing.Font('Consolas', 16, [Drawing.FontStyle]::Bold)
        $timeInput.TextAlign = 'Center'
        $timeInput.Dock = 'Top'
        $timeInput.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 6)
        $timeInput.AccessibleName = 'Timer total in hours, minutes, and seconds'
        $timeInput.BackColor = $colors.Surface
        $timeInput.ForeColor = $colors.Foreground
        $timeInput.TabIndex = 0

        $errorLabel = New-Object System.Windows.Forms.Label
        $errorLabel.Text = ' '
        $errorLabel.AutoSize = $true
        $errorLabel.Dock = 'Top'
        $errorLabel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
        $errorLabel.ForeColor = $colors.Danger
        $errorLabel.AccessibleName = 'Time input error'

        $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $buttonPanel.AutoSize = $true
        $buttonPanel.Dock = 'Fill'
        $buttonPanel.FlowDirection = 'RightToLeft'
        $buttonPanel.WrapContents = $false
        $buttonPanel.Margin = New-Object Windows.Forms.Padding(0)

        $cancelButton = New-Object System.Windows.Forms.Button
        $cancelButton.Text = 'Cancel'
        $cancelButton.AutoSize = $true
        $cancelButton.MinimumSize = New-Object Drawing.Size(90, 34)
        $cancelButton.DialogResult = 'Cancel'
        $cancelButton.TabIndex = 2
        Style-Button $cancelButton $colors

        $saveButton = New-Object System.Windows.Forms.Button
        $saveButton.Text = 'Save time'
        $saveButton.AutoSize = $true
        $saveButton.MinimumSize = New-Object Drawing.Size(90, 34)
        $saveButton.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
        $saveButton.TabIndex = 1
        Style-Button $saveButton $colors

        $buttonPanel.Controls.Add($cancelButton)
        $buttonPanel.Controls.Add($saveButton)
        $layout.Controls.Add($inputLabel, 0, 0)
        $layout.Controls.Add($timeInput, 0, 1)
        $layout.Controls.Add($errorLabel, 0, 2)
        $layout.Controls.Add($buttonPanel, 0, 3)
        $dialog.Controls.Add($layout)
        $dialog.AcceptButton = $saveButton
        $dialog.CancelButton = $cancelButton
        $saveButton.Add_Click({
            [void](Accrue-ToNow)
            $newValue = ConvertFrom-TimeText $timeInput.Text
            if ($null -eq $newValue) {
                $errorLabel.Text = 'Use HH:MM:SS, for example 07:30:00.'
                $timeInput.AccessibleDescription = $errorLabel.Text
                $timeInput.SelectAll()
                $timeInput.Focus()
                return
            }
            $script:seconds = [double]$newValue
            $script:lastTickUtc = [DateTime]::UtcNow
            $script:lastTickLocal = Get-Date
            [void](Request-StateSave)
            Update-Display
            $dialog.DialogResult = 'OK'
            $dialog.Close()
        })
        $dialog.Add_Shown({ $timeInput.SelectAll(); $timeInput.Focus() })
        if ($form.Visible) { [void]$dialog.ShowDialog($form) } else { [void]$dialog.ShowDialog() }
        $dialog.Dispose()
    }

    function Toggle-Timer {
        [void](Accrue-ToNow)
        $script:running = -not $script:running
        $script:lastTickUtc = [DateTime]::UtcNow
        $script:lastTickLocal = Get-Date
        [void](Request-StateSave)
        Update-Display
    }

    function Toggle-Theme {
        [void](Accrue-ToNow)
        $script:theme = if ($script:theme -eq 'dark') { 'light' } else { 'dark' }
        Apply-Theme
        [void](Request-StateSave)
    }

    function Show-OperationError([string]$message, [string]$title) {
        if ($form.Visible) {
            [Windows.Forms.MessageBox]::Show(
                $form, $message, $title, 'OK', 'Error') | Out-Null
        } else {
            [Windows.Forms.MessageBox]::Show(
                $message, $title, 'OK', 'Error') | Out-Null
        }
    }

    function Reset-Timer {
        [void](Accrue-ToNow)
        [void](Request-StateSave)
        $answer = [Windows.Forms.MessageBox]::Show(
            "Reset the total to 00:00:00? The timer's running or paused state and daily history will not change.",
            'Reset timer', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }

        [void](Accrue-ToNow)
        $script:seconds = 0.0
        $script:lastTickUtc = [DateTime]::UtcNow
        $script:lastTickLocal = Get-Date
        [void](Request-StateSave)
        Update-Display
    }

    function Toggle-History {
        [void](Accrue-ToNow)
        if ($script:historyEnabled) {
            $historyHasPendingData = $script:historyDirty -or $script:pendingHistory.Count -gt 0
            if ($historyHasPendingData) {
                $script:historyDirty = $true
                if (-not (Try-FlushHistory -Force)) {
                    if ($script:historyValid) {
                        Show-OperationError -message 'Daily history is still on because all recorded time could not be saved. Focus Timer will keep retrying.' -title 'Unable to turn off daily history'
                    } else {
                        Show-OperationError -message 'Daily history is still on because existing history could not be read. Go to History > View history... > Start new history....' -title 'Unable to turn off daily history'
                    }
                    Update-Display
                    return
                }
            }

            $script:historyEnabled = $false
            if (-not (Try-SaveState)) {
                $script:historyEnabled = $true
                $script:stateDirty = $true
                Show-OperationError -message 'Daily history is still on because the setting could not be saved. Focus Timer will keep retrying.' -title 'Unable to turn off daily history'
                Update-Display
                return
            }
            $script:nextHistoryRetryUtc = [DateTime]::MinValue
            Reset-HistoryFailureEpisode
        } else {
            $script:historyEnabled = $true
            if (-not (Try-SaveState)) {
                $script:historyEnabled = $false
                $script:stateDirty = $true
                Show-OperationError -message 'Daily history remains off because the setting could not be saved. Focus Timer will keep retrying.' -title 'Unable to turn on daily history'
                Update-Display
                return
            }
            [void](Ensure-HistoryLoaded -Force)
        }
        Update-Display
    }

    function Apply-DialogTheme($dialog, $controls, $buttons) {
        $colors = Get-ThemeColors
        $dialog.BackColor = $colors.Background
        $dialog.ForeColor = $colors.Foreground
        foreach ($control in $controls) {
            $control.BackColor = $colors.Background
            $control.ForeColor = $colors.Foreground
        }
        foreach ($button in $buttons) { Style-Button $button $colors }
    }

    function Show-ClearHistoryConfirmation($owner) {
        $colors = Get-ThemeColors
        $dialog = New-Object System.Windows.Forms.Form
        $dialog.Text = 'Clear history'
        $dialog.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
        $dialog.ClientSize = New-Object Drawing.Size(440, 204)
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.MaximizeBox = $false
        $dialog.MinimizeBox = $false
        $dialog.ShowInTaskbar = $false
        $dialog.StartPosition = if ($null -ne $owner) { 'CenterParent' } else { 'CenterScreen' }
        $dialog.TopMost = $null -eq $owner
        $dialog.BackColor = $colors.Background
        $dialog.ForeColor = $colors.Foreground
        $dialog.AccessibleName = 'Clear history confirmation'

        $heading = New-Object System.Windows.Forms.Label
        $heading.Text = 'Clear all history?'
        $heading.Font = New-Object Drawing.Font('Segoe UI Semibold', 12)
        $heading.SetBounds(24, 22, 392, 28)

        $message = New-Object System.Windows.Forms.Label
        $message.Text = 'This permanently removes every saved date and any pending history. If recording is on, it stays on and new time will appear. If recording is off, it stays off.'
        $message.SetBounds(24, 58, 392, 64)

        $clearButton = New-Object System.Windows.Forms.Button
        $clearButton.Text = 'Clear history'
        $clearButton.SetBounds(222, 148, 108, 36)
        $clearButton.DialogResult = [Windows.Forms.DialogResult]::Yes
        $clearButton.TabIndex = 0
        Style-Button $clearButton $colors
        $clearButton.ForeColor = $colors.Danger
        $clearButton.AccessibleDescription = 'Permanently removes all saved history.'

        $cancelButton = New-Object System.Windows.Forms.Button
        $cancelButton.Text = 'Cancel'
        $cancelButton.SetBounds(338, 148, 78, 36)
        $cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
        $cancelButton.TabIndex = 1
        Style-Button $cancelButton $colors

        $dialog.AcceptButton = $clearButton
        $dialog.CancelButton = $cancelButton
        $dialog.Controls.AddRange(@($heading, $message, $clearButton, $cancelButton))
        $dialog.Add_Shown({ $cancelButton.Focus() })
        $result = if ($null -ne $owner) { $dialog.ShowDialog($owner) } else { $dialog.ShowDialog() }
        $dialog.Dispose()
        return $result -eq [Windows.Forms.DialogResult]::Yes
    }

    function Show-StartNewHistoryConfirmation($owner) {
        $body = 'Existing history cannot be read and will be permanently replaced. Newly recorded pending time will be kept. The timer total and history recording setting will not change.'
        $colors = Get-ThemeColors
        $dialog = New-Object System.Windows.Forms.Form
        $dialog.Text = 'Start new history'
        $dialog.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
        $dialog.ClientSize = New-Object Drawing.Size(520, 244)
        $dialog.FormBorderStyle = 'FixedDialog'
        $dialog.MaximizeBox = $false
        $dialog.MinimizeBox = $false
        $dialog.ShowInTaskbar = $false
        $dialog.StartPosition = if ($null -ne $owner) { 'CenterParent' } else { 'CenterScreen' }
        $dialog.TopMost = $null -eq $owner
        $dialog.BackColor = $colors.Background
        $dialog.ForeColor = $colors.Foreground
        $dialog.AccessibleName = 'Start new history confirmation'

        $heading = New-Object System.Windows.Forms.Label
        $heading.Text = 'Replace unreadable history?'
        $heading.Font = New-Object Drawing.Font('Segoe UI Semibold', 12)
        $heading.SetBounds(24, 22, 472, 28)

        $message = New-Object System.Windows.Forms.Label
        $message.Text = $body
        $message.SetBounds(24, 58, 472, 92)

        $startButton = New-Object System.Windows.Forms.Button
        $startButton.Text = 'Start new history'
        $startButton.SetBounds(268, 184, 132, 36)
        $startButton.DialogResult = [Windows.Forms.DialogResult]::Yes
        $startButton.TabIndex = 0
        Style-Button $startButton $colors
        $startButton.ForeColor = $colors.Danger
        $startButton.AccessibleDescription = 'Permanently replaces unreadable history while keeping newly recorded pending time.'

        $cancelButton = New-Object System.Windows.Forms.Button
        $cancelButton.Text = 'Cancel'
        $cancelButton.SetBounds(408, 184, 88, 36)
        $cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
        $cancelButton.TabIndex = 1
        $cancelButton.AccessibleDescription = $body
        Style-Button $cancelButton $colors

        $dialog.AcceptButton = $startButton
        $dialog.CancelButton = $cancelButton
        $dialog.Controls.AddRange(@($heading, $message, $startButton, $cancelButton))
        $dialog.Add_Shown({ $cancelButton.Focus() })
        $result = if ($null -ne $owner) { $dialog.ShowDialog($owner) } else { $dialog.ShowDialog() }
        $dialog.Dispose()
        return $result -eq [Windows.Forms.DialogResult]::Yes
    }

    function Start-NewHistory($owner) {
        if ($script:historyRecoveryInProgress) { return $false }
        $script:historyRecoveryInProgress = $true
        try {
            if (-not (Show-StartNewHistoryConfirmation $owner)) { return $false }

            [void](Accrue-ToNow)
            if ($script:historyValid) { return $false }

            $normalizedEntries = @{}
            foreach ($key in $script:pendingHistory.Keys) {
                $value = [double]$script:pendingHistory[$key]
                if ($value -lt 0 -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) {
                    $value = 0.0
                }
                $normalizedEntries[$key] = [Math]::Round($value, 3)
            }

            if (-not (Write-AtomicText $historyFile (Convert-HistoryToText $normalizedEntries))) {
                Show-OperationError -message 'A new history could not be started. The unreadable file and newly recorded pending time were left unchanged. Check file access, then try again.' -title 'Unable to start new history'
                return $false
            }

            $script:historyLoadAttempted = $true
            $script:historyEntries = $normalizedEntries
            $script:pendingHistory = @{}
            $script:historyValid = $true
            $script:historyDirty = $false
            $script:historySaveFailed = $false
            $script:lastHistoryFlushUtc = [DateTime]::UtcNow
            $script:nextHistoryRetryUtc = [DateTime]::MinValue
            Reset-HistoryFailureEpisode
            Update-Display
            return $true
        } finally {
            $script:historyRecoveryInProgress = $false
        }
    }

    function Clear-History($owner) {
        [void](Accrue-ToNow)
        if (-not (Ensure-HistoryLoaded -Force)) {
            Show-OperationError -message 'History was not cleared because the existing file could not be loaded and validated. The file and pending history were left unchanged.' -title 'Unable to clear history'
            return $false
        }
        if (-not (Show-ClearHistoryConfirmation $owner)) { return $false }

        [void](Accrue-ToNow)
        if (-not (Try-ClearHistory)) {
            Show-OperationError -message 'History could not be cleared. The file and in-memory history were left unchanged. Check file access, then try again.' -title 'Unable to clear history'
            return $false
        }
        [void](Request-StateSave)
        Update-Display
        return $true
    }

    function Fill-HistoryGrid(
        $grid,
        $summaryLabel,
        $emptyLabel,
        $clearButton,
        [string]$selectedIso,
        [string]$firstIso,
        [int]$fallbackFirstIndex,
        [bool]$selectFirst) {
        $grid.Rows.Clear()
        $recordingSentence = if ($script:historyEnabled) {
            'Recording is on.'
        } else {
            'Recording is off. Existing history is preserved.'
        }
        if (-not $script:historyValid) {
            $retrySentence = if ($script:historyEnabled -or $script:historyDirty -or $script:pendingHistory.Count -gt 0) {
                'Existing history couldn''t be read. Focus Timer will retry.'
            } else {
                'Existing history couldn''t be read. Focus Timer will retry while this window is open.'
            }
            $summaryLabel.Text = "$recordingSentence $retrySentence"
            $emptyLabel.Text = 'History can''t be shown because existing history couldn''t be read.'
            $emptyLabel.Visible = $true
            $clearButton.Text = 'Start new history...'
            $clearButton.AccessibleDescription = 'Permanently replaces unreadable history while keeping newly recorded pending time.'
            $clearButton.Enabled = $true
            return
        }

        $clearButton.Text = 'Clear history...'
        $clearButton.AccessibleDescription = 'Opens a confirmation before permanently removing history.'
        $snapshot = Get-HistorySnapshot
        $total = 0.0
        $selectedIndex = -1
        $firstIndex = -1
        foreach ($key in @($snapshot.Keys | Sort-Object -Descending)) {
            $value = [double]$snapshot[$key]
            $total += $value
            $parsedDate = [DateTime]::MinValue
            [void][DateTime]::TryParseExact(
                $key,
                'yyyy-MM-dd',
                $invariantCulture,
                [Globalization.DateTimeStyles]::None,
                [ref]$parsedDate)
            $displayDate = $parsedDate.ToString('D', [Globalization.CultureInfo]::CurrentCulture)
            $rowIndex = $grid.Rows.Add($key, $displayDate, (Format-Time $value))
            if ($key -ceq $selectedIso) { $selectedIndex = $rowIndex }
            if ($key -ceq $firstIso) { $firstIndex = $rowIndex }
        }

        $count = $snapshot.Count
        $summaryText = $recordingSentence
        if ($script:historySaveFailed) {
            $summaryText += ' History isn''t being saved. Focus Timer will retry.'
        } elseif ($script:historyDirty) {
            $summaryText += ' New history is waiting to be saved.'
        }
        if ($count -eq 1) {
            $summaryText += " 1 date, $(Format-Time $total) total."
        } elseif ($count -gt 1) {
            $summaryText += " $count dates, $(Format-Time $total) total."
        }
        $summaryLabel.Text = $summaryText
        $emptyLabel.Text = if ($script:historyEnabled) {
            'No history recorded yet. New accepted running time will appear here.'
        } else {
            'No history recorded. Turn on Record daily history to start.'
        }
        $emptyLabel.Visible = $count -eq 0
        $clearButton.Enabled = $count -gt 0

        if ($count -gt 0) {
            $grid.ClearSelection()
            if ($selectedIndex -ge 0) {
                $grid.Rows[$selectedIndex].Selected = $true
                $grid.CurrentCell = $grid.Rows[$selectedIndex].Cells['Date']
            } elseif ($selectFirst) {
                $grid.Rows[0].Selected = $true
                $grid.CurrentCell = $grid.Rows[0].Cells['Date']
            }

            if ($firstIndex -lt 0 -and $fallbackFirstIndex -ge 0) {
                $firstIndex = [Math]::Min($fallbackFirstIndex, $grid.Rows.Count - 1)
            }
            if ($firstIndex -ge 0) {
                try { $grid.FirstDisplayedScrollingRowIndex = $firstIndex } catch {}
            }
        }
    }

    function Show-HistoryDialog {
        $script:historyViewOpen = $true
        $dialog = $null
        $historyDialogTimer = $null
        try {
        [void](Accrue-ToNow)
        [void](Request-StateSave)
        [void](Ensure-HistoryLoaded -Force)
        if ($script:historyValid -and $script:historyDirty) { [void](Try-FlushHistory) }
        $colors = Get-ThemeColors

        $dialog = New-Object System.Windows.Forms.Form
        $dialog.Text = 'Focus history'
        $dialog.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
        $dialog.ClientSize = New-Object Drawing.Size(700, 450)
        $dialog.MinimumSize = New-Object Drawing.Size(560, 380)
        $dialog.FormBorderStyle = 'Sizable'
        $dialog.MaximizeBox = $true
        $dialog.MinimizeBox = $false
        $dialog.ShowInTaskbar = $false
        $dialog.StartPosition = if ($form.Visible) { 'CenterParent' } else { 'CenterScreen' }
        $dialog.TopMost = -not $form.Visible
        $dialog.BackColor = $colors.Background
        $dialog.ForeColor = $colors.Foreground
        $dialog.AccessibleName = 'Focus history'

        $layout = New-Object System.Windows.Forms.TableLayoutPanel
        $layout.Dock = 'Fill'
        $layout.Padding = New-Object Windows.Forms.Padding(20)
        $layout.ColumnCount = 1
        $layout.RowCount = 4
        [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 38)))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 44)))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 52)))

        $heading = New-Object System.Windows.Forms.Label
        $heading.Text = 'Focus history'
        $heading.Font = New-Object Drawing.Font('Segoe UI Semibold', 15)
        $heading.Dock = 'Fill'
        $heading.TextAlign = 'MiddleLeft'

        $summaryLabel = New-Object System.Windows.Forms.Label
        $summaryLabel.Dock = 'Fill'
        $summaryLabel.ForeColor = $colors.Muted
        $summaryLabel.AccessibleName = 'History recording, load, and save status'

        $contentPanel = New-Object System.Windows.Forms.Panel
        $contentPanel.Dock = 'Fill'
        $contentPanel.Padding = New-Object Windows.Forms.Padding(0, 8, 0, 0)

        $grid = New-Object System.Windows.Forms.DataGridView
        $grid.Dock = 'Fill'
        $grid.ReadOnly = $true
        $grid.AllowUserToAddRows = $false
        $grid.AllowUserToDeleteRows = $false
        $grid.AllowUserToOrderColumns = $false
        $grid.AllowUserToResizeRows = $false
        $grid.AutoSizeColumnsMode = 'Fill'
        $grid.BackgroundColor = $colors.Surface
        $grid.BorderStyle = 'FixedSingle'
        $grid.CellBorderStyle = 'SingleHorizontal'
        $grid.ColumnHeadersBorderStyle = 'None'
        $grid.EnableHeadersVisualStyles = $false
        $grid.MultiSelect = $false
        $grid.RowHeadersVisible = $false
        $grid.SelectionMode = 'FullRowSelect'
        $grid.TabIndex = 0
        $grid.AccessibleName = 'History by date'
        $grid.AccessibleDescription = 'Read-only full-row table of recorded focus time by local date, newest first.'
        $grid.DefaultCellStyle.BackColor = $colors.Surface
        $grid.DefaultCellStyle.ForeColor = $colors.Foreground
        $grid.DefaultCellStyle.SelectionBackColor = $colors.Accent
        $grid.DefaultCellStyle.SelectionForeColor = $colors.Background
        $grid.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding(8, 4, 8, 4)
        $grid.ColumnHeadersDefaultCellStyle.BackColor = $colors.SurfaceHover
        $grid.ColumnHeadersDefaultCellStyle.ForeColor = $colors.Foreground
        $grid.ColumnHeadersDefaultCellStyle.Padding = New-Object Windows.Forms.Padding(8, 5, 8, 5)
        $grid.RowTemplate.Height = 32

        $isoColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $isoColumn.Name = 'IsoDate'
        $isoColumn.HeaderText = 'ISO date'
        $isoColumn.Visible = $false
        $isoColumn.ReadOnly = $true
        $isoColumn.SortMode = [Windows.Forms.DataGridViewColumnSortMode]::NotSortable
        [void]$grid.Columns.Add($isoColumn)

        $dateColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $dateColumn.Name = 'Date'
        $dateColumn.HeaderText = 'Date'
        $dateColumn.ReadOnly = $true
        $dateColumn.SortMode = [Windows.Forms.DataGridViewColumnSortMode]::NotSortable
        [void]$grid.Columns.Add($dateColumn)

        $timeColumn = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $timeColumn.Name = 'FocusTime'
        $timeColumn.HeaderText = 'Focus time'
        $timeColumn.ReadOnly = $true
        $timeColumn.SortMode = [Windows.Forms.DataGridViewColumnSortMode]::NotSortable
        [void]$grid.Columns.Add($timeColumn)

        $emptyLabel = New-Object System.Windows.Forms.Label
        $emptyLabel.Dock = 'Bottom'
        $emptyLabel.Height = 64
        $emptyLabel.TextAlign = 'MiddleCenter'
        $emptyLabel.ForeColor = $colors.Muted
        $emptyLabel.BackColor = $colors.Surface
        $emptyLabel.AccessibleName = 'History status'
        $emptyLabel.Visible = $false
        $contentPanel.Controls.Add($grid)
        $contentPanel.Controls.Add($emptyLabel)
        $emptyLabel.BringToFront()

        $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
        $buttonPanel.Dock = 'Fill'
        $buttonPanel.FlowDirection = 'RightToLeft'
        $buttonPanel.WrapContents = $false
        $buttonPanel.Padding = New-Object Windows.Forms.Padding(0, 10, 0, 0)

        $closeButton = New-Object System.Windows.Forms.Button
        $closeButton.Text = 'Close'
        $closeButton.Size = New-Object Drawing.Size(88, 36)
        $closeButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
        $closeButton.TabIndex = 2
        Style-Button $closeButton $colors

        $clearButton = New-Object System.Windows.Forms.Button
        $clearButton.Text = 'Clear history...'
        $clearButton.Size = New-Object Drawing.Size(148, 36)
        $clearButton.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
        $clearButton.TabIndex = 1
        $clearButton.AccessibleDescription = 'Opens a confirmation before permanently removing history.'
        Style-Button $clearButton $colors
        $clearButton.ForeColor = $colors.Danger

        $buttonPanel.Controls.Add($closeButton)
        $buttonPanel.Controls.Add($clearButton)
        $layout.Controls.Add($heading, 0, 0)
        $layout.Controls.Add($summaryLabel, 0, 1)
        $layout.Controls.Add($contentPanel, 0, 2)
        $layout.Controls.Add($buttonPanel, 0, 3)
        $dialog.Controls.Add($layout)
        $dialog.CancelButton = $closeButton

        Fill-HistoryGrid $grid $summaryLabel $emptyLabel $clearButton '' '' -1 $true
        $clearButton.Add_Click({
            $completed = if ($script:historyValid) {
                Clear-History $dialog
            } else {
                Start-NewHistory $dialog
            }
            if ($completed) {
                Fill-HistoryGrid $grid $summaryLabel $emptyLabel $clearButton '' '' -1 $false
                $closeButton.Focus()
            }
        })
        $dialog.Add_Shown({
            if ($grid.Rows.Count -gt 0) { $grid.Focus() } else { $closeButton.Focus() }
        })

        $refreshState = @{
            LastWholeSecond = [Math]::Floor($script:seconds)
            Status = ('{0}|{1}|{2}|{3}|{4}|{5}' -f
                $script:historyValid,
                $script:historyDirty,
                $script:historySaveFailed,
                $script:historyEnabled,
                $script:historyEntries.Count,
                $script:pendingHistory.Count)
        }
        $historyDialogTimer = New-Object System.Windows.Forms.Timer
        $historyDialogTimer.Interval = 250
        $historyDialogTimer.Add_Tick({
            $whole = [Math]::Floor($script:seconds)
            $statusKey = ('{0}|{1}|{2}|{3}|{4}|{5}' -f
                $script:historyValid,
                $script:historyDirty,
                $script:historySaveFailed,
                $script:historyEnabled,
                $script:historyEntries.Count,
                $script:pendingHistory.Count)
            if ($whole -eq $refreshState.LastWholeSecond -and $statusKey -ceq $refreshState.Status) { return }
            $refreshState.LastWholeSecond = $whole
            $refreshState.Status = $statusKey

            $selectedIso = ''
            $selectedColumnName = ''
            if ($null -ne $grid.CurrentRow) {
                $selectedIso = [string]$grid.CurrentRow.Cells['IsoDate'].Value
            }
            if ($null -ne $grid.CurrentCell) {
                $selectedColumnName = [string]$grid.CurrentCell.OwningColumn.Name
            }
            $firstIndex = -1
            $firstIso = ''
            if ($grid.Rows.Count -gt 0) {
                try { $firstIndex = $grid.FirstDisplayedScrollingRowIndex } catch {}
                if ($firstIndex -ge 0 -and $firstIndex -lt $grid.Rows.Count) {
                    $firstIso = [string]$grid.Rows[$firstIndex].Cells['IsoDate'].Value
                }
            }
            $horizontalOffset = $grid.HorizontalScrollingOffset
            $gridFocused = $grid.Focused
            $clearFocused = $clearButton.Focused
            $closeFocused = $closeButton.Focused

            Fill-HistoryGrid $grid $summaryLabel $emptyLabel $clearButton $selectedIso $firstIso $firstIndex $false
            if ($selectedColumnName -in @('Date', 'FocusTime') -and $null -ne $grid.CurrentRow) {
                $grid.CurrentCell = $grid.CurrentRow.Cells[$selectedColumnName]
            }
            try { $grid.HorizontalScrollingOffset = $horizontalOffset } catch {}
            if ($gridFocused) { $grid.Focus() }
            elseif ($clearFocused -and $clearButton.Enabled) { $clearButton.Focus() }
            elseif ($closeFocused) { $closeButton.Focus() }
        })

        $historyDialogTimer.Start()
        if ($form.Visible) { [void]$dialog.ShowDialog($form) } else { [void]$dialog.ShowDialog() }
        } finally {
            $script:historyViewOpen = $false
            if (-not $script:historyEnabled -and -not $script:historyDirty -and $script:pendingHistory.Count -eq 0) {
                $script:nextHistoryRetryUtc = [DateTime]::MinValue
                Reset-HistoryFailureEpisode
            }
            if ($null -ne $historyDialogTimer) {
                $historyDialogTimer.Stop()
                $historyDialogTimer.Dispose()
            }
            if ($null -ne $dialog) { $dialog.Dispose() }
        }
    }

    function Exit-Timer {
        [void](Accrue-ToNow)
        $historyRequired = $script:historyEnabled -or $script:historyDirty -or $script:pendingHistory.Count -gt 0
        $historySaved = $true
        $historyLoaded = $true
        if ($historyRequired) {
            if ($script:pendingHistory.Count -gt 0) { $script:historyDirty = $true }
            $historySaved = Try-FlushHistory -Force
            $historyLoaded = $script:historyValid
        }
        $stateSaved = Try-SaveState

        if (-not $historyLoaded -or -not $historySaved -or -not $stateSaved) {
            if (-not $historyLoaded -and $script:pendingHistory.Count -gt 0) {
                $message = 'Focus Timer is still running because existing history could not be read. Go to History > View history... > Start new history....'
                if (-not $stateSaved) {
                    $message += ' Timer state also could not be saved; Focus Timer will keep retrying.'
                }
                Show-OperationError -message $message -title 'Unable to exit Focus Timer'
                Update-Display
                return
            }

            $failedParts = New-Object 'System.Collections.Generic.List[string]'
            if (-not $historyLoaded) { $failedParts.Add('history could not be loaded') }
            elseif (-not $historySaved) { $failedParts.Add('history could not be saved') }
            if (-not $stateSaved) { $failedParts.Add('timer state could not be saved') }
            Show-OperationError -message ("Focus Timer is still running because {0}. Resolve the file access problem, then exit again." -f ($failedParts -join ' and ')) -title 'Unable to exit Focus Timer'
            Update-Display
            return
        }

        $script:allowExit = $true
        [Windows.Forms.Application]::Exit()
    }

    $toggleButton.Add_Click({ Toggle-Timer })
    $setTimeButton.Add_Click({ Show-SetTimeDialog })
    $resetButton.Add_Click({ Reset-Timer })
    $hideButton.Add_Click({
        [void](Accrue-ToNow)
        [void](Request-StateSave)
        $form.Hide()
    })
    $themeButton.Add_Click({ Toggle-Theme })
    $showItem.Add_Click({ Show-TimerWindow })
    $toggleItem.Add_Click({ Toggle-Timer })
    $setTimeItem.Add_Click({ Show-SetTimeDialog })
    $resetItem.Add_Click({ Reset-Timer })
    $themeItem.Add_Click({ Toggle-Theme })
    $viewHistoryItem.Add_Click({ Show-HistoryDialog })
    $historyToggleItem.Add_Click({ Toggle-History })
    $notify.Add_DoubleClick({ Show-TimerWindow })
    $exitItem.Add_Click({ Exit-Timer })
    $menu.Add_Opening({
        [void](Accrue-ToNow)
        Update-Display
    })

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $script:allowExit -and $eventArgs.CloseReason -eq 'UserClosing') {
            [void](Accrue-ToNow)
            [void](Request-StateSave)
            $eventArgs.Cancel = $true
            $form.Hide()
        }
    })

    $form.Add_Resize({
        if ($form.WindowState -eq 'Minimized') {
            [void](Accrue-ToNow)
            [void](Request-StateSave)
            $form.Hide()
            $form.WindowState = 'Normal'
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        [void](Accrue-ToNow)
        $nowUtc = [DateTime]::UtcNow
        $whole = [Math]::Floor($script:seconds)
        $stateRetryDue = $script:nextStateRetryUtc -ne [DateTime]::MinValue -and $nowUtc -ge $script:nextStateRetryUtc
        if ($stateRetryDue -or ($script:nextStateRetryUtc -eq [DateTime]::MinValue -and $whole -ne $script:lastSavedSecond)) {
            [void](Try-SaveState)
        }

        $historyNeeded = (
            $script:historyEnabled -or
            $script:historyViewOpen -or
            $script:historyDirty -or
            $script:pendingHistory.Count -gt 0)
        if ($historyNeeded -and -not $script:historyRecoveryInProgress) {
            $historyRetryPending = $script:nextHistoryRetryUtc -ne [DateTime]::MinValue
            $historyRetryDue = $historyRetryPending -and $nowUtc -ge $script:nextHistoryRetryUtc
            if (-not $script:historyValid) {
                $loadDue = -not $script:historyLoadAttempted -or $historyRetryDue
                if ($loadDue -and (Ensure-HistoryLoaded)) {
                    if ($script:historyDirty) { [void](Try-FlushHistory) }
                }
            } elseif ($script:historyDirty) {
                $flushDue = ($nowUtc - $script:lastHistoryFlushUtc).TotalSeconds -ge 60
                if ($historyRetryDue -or (-not $historyRetryPending -and $flushDue)) {
                    [void](Try-FlushHistory)
                }
            }
        }
        Show-PendingWarnings
        Update-Display
    })

    Apply-Theme
    [void](Try-SaveState)
    if ($script:historyEnabled -and $script:historyValid) { [void](Try-FlushHistory) }
    $timer.Start()
    if (-not $script:stateWarningPending -and -not $script:historyWarningPending) {
        $notify.ShowBalloonTip(
            2000,
            'Focus Timer',
            "Running in the notification area at $(Format-Time $script:seconds).",
            [Windows.Forms.ToolTipIcon]::Info)
    }
    Show-PendingWarnings
    [System.Windows.Forms.Application]::Run()
}
finally {
    try { if ($null -ne $timer) { $timer.Stop(); $timer.Dispose() } } catch {}
    if (-not $script:allowExit) {
        try {
            if (Get-Variable stateFile -ErrorAction SilentlyContinue) { [void](Try-SaveState) }
        } catch {}
        try {
            if ((Get-Variable historyFile -ErrorAction SilentlyContinue) -and
                ($script:historyEnabled -or $script:historyDirty -or $script:pendingHistory.Count -gt 0)) {
                [void](Try-FlushHistory -Force)
            }
        } catch {}
    }
    try { if ($null -ne $notify) { $notify.Visible = $false; $notify.Dispose() } } catch {}
    if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
