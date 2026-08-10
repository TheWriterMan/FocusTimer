Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Stop'

$mutex = [System.Threading.Mutex]::new($false, 'Local\PersonalFocusTimer')
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
    $legacyStateFile = Join-Path (Join-Path $localData 'WorkTimer') 'state.json'
    [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    if (-not (Test-Path -LiteralPath $stateFile) -and (Test-Path -LiteralPath $legacyStateFile)) {
        Copy-Item -LiteralPath $legacyStateFile -Destination $stateFile
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $script:seconds = 0.0
    $script:running = $true
    $script:theme = 'dark'
    $script:allowExit = $false
    $script:lastTick = [DateTime]::UtcNow
    $script:lastSavedSecond = -1

    if (Test-Path -LiteralPath $stateFile) {
        try {
            $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($null -ne $saved.seconds) { $script:seconds = [double]$saved.seconds }
            if ($null -ne $saved.running) { $script:running = [bool]$saved.running }
            if ($saved.theme -in @('light', 'dark')) { $script:theme = [string]$saved.theme }
        } catch {}
    }

    function Save-State {
        $data = [ordered]@{
            seconds = [Math]::Round($script:seconds, 3)
            running = $script:running
            theme = $script:theme
            updated = (Get-Date).ToString('o')
        }
        $json = $data | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($stateFile, $json, $utf8)
        $script:lastSavedSecond = [Math]::Floor($script:seconds)
    }

    function Format-Time([double]$value) {
        $whole = [Math]::Floor([Math]::Max(0, $value))
        $hours = [Math]::Floor($whole / 3600)
        $minutes = [Math]::Floor(($whole % 3600) / 60)
        $secs = $whole % 60
        return '{0:00}:{1:00}:{2:00}' -f $hours, $minutes, $secs
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Focus Timer'
    $form.ClientSize = New-Object System.Drawing.Size(360, 220)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = 'FOCUS TIMER'
    $titleLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $titleLabel.TextAlign = 'MiddleCenter'
    $titleLabel.SetBounds(65, 16, 230, 24)

    $themeButton = New-Object System.Windows.Forms.Button
    $themeButton.SetBounds(294, 13, 52, 28)
    $themeButton.FlatStyle = 'Flat'
    $themeButton.FlatAppearance.BorderSize = 1
    $themeButton.TabIndex = 3

    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Font = New-Object Drawing.Font('Consolas', 28, [Drawing.FontStyle]::Bold)
    $timeLabel.TextAlign = 'MiddleCenter'
    $timeLabel.SetBounds(20, 48, 320, 55)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
    $statusLabel.TextAlign = 'MiddleCenter'
    $statusLabel.SetBounds(30, 108, 300, 22)

    $toggleButton = New-Object System.Windows.Forms.Button
    $toggleButton.SetBounds(35, 150, 90, 36)
    $toggleButton.FlatStyle = 'Flat'
    $toggleButton.FlatAppearance.BorderSize = 1
    $toggleButton.TabIndex = 0

    $resetButton = New-Object System.Windows.Forms.Button
    $resetButton.Text = 'Reset'
    $resetButton.SetBounds(135, 150, 90, 36)
    $resetButton.FlatStyle = 'Flat'
    $resetButton.FlatAppearance.BorderSize = 1
    $resetButton.TabIndex = 1

    $hideButton = New-Object System.Windows.Forms.Button
    $hideButton.Text = 'Hide to tray'
    $hideButton.SetBounds(235, 150, 90, 36)
    $hideButton.FlatStyle = 'Flat'
    $hideButton.FlatAppearance.BorderSize = 1
    $hideButton.TabIndex = 2

    $form.Controls.AddRange(@(
        $titleLabel, $themeButton, $timeLabel, $statusLabel,
        $toggleButton, $resetButton, $hideButton
    ))

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Enabled = $false
    $showItem = New-Object System.Windows.Forms.ToolStripMenuItem('Show timer')
    $toggleItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $resetItem = New-Object System.Windows.Forms.ToolStripMenuItem('Reset timer')
    $themeItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit timer')
    [void]$menu.Items.Add($statusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($showItem)
    [void]$menu.Items.Add($toggleItem)
    [void]$menu.Items.Add($resetItem)
    [void]$menu.Items.Add($themeItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($exitItem)

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [Drawing.SystemIcons]::Information
    $notify.ContextMenuStrip = $menu
    $notify.Visible = $true

    function Apply-Theme {
        $isDark = $script:theme -eq 'dark'
        if ($isDark) {
            $background = [Drawing.Color]::FromArgb(24, 24, 27)
            $foreground = [Drawing.Color]::FromArgb(250, 250, 250)
            $surface = [Drawing.Color]::FromArgb(32, 32, 36)
            $surfaceHover = [Drawing.Color]::FromArgb(44, 44, 50)
            $border = [Drawing.Color]::FromArgb(82, 82, 91)
            $accent = [Drawing.Color]::FromArgb(103, 232, 249)
            $themeButton.Text = 'Light'
            $themeItem.Text = 'Use light theme'
        } else {
            $background = [Drawing.Color]::FromArgb(250, 250, 249)
            $foreground = [Drawing.Color]::FromArgb(24, 24, 27)
            $surface = [Drawing.Color]::White
            $surfaceHover = [Drawing.Color]::FromArgb(244, 244, 245)
            $border = [Drawing.Color]::FromArgb(212, 212, 216)
            $accent = [Drawing.Color]::FromArgb(8, 145, 178)
            $themeButton.Text = 'Dark'
            $themeItem.Text = 'Use dark theme'
        }

        $form.BackColor = $background
        $form.ForeColor = $foreground
        $titleLabel.BackColor = $background
        $titleLabel.ForeColor = $accent
        $timeLabel.BackColor = $background
        $timeLabel.ForeColor = $foreground
        $statusLabel.BackColor = $background

        foreach ($button in @($themeButton, $toggleButton, $resetButton, $hideButton)) {
            $button.UseVisualStyleBackColor = $false
            $button.BackColor = $surface
            $button.ForeColor = $foreground
            $button.FlatAppearance.BorderColor = $border
            $button.FlatAppearance.MouseOverBackColor = $surfaceHover
            $button.FlatAppearance.MouseDownBackColor = $border
        }
        Update-Display
    }

    function Update-Display {
        $time = Format-Time $script:seconds
        $status = if ($script:running) { 'RUNNING' } else { 'PAUSED' }
        $timeLabel.Text = $time
        $statusLabel.Text = $status
        if ($script:theme -eq 'dark') {
            $statusLabel.ForeColor = if ($script:running) { [Drawing.Color]::FromArgb(74, 222, 128) } else { [Drawing.Color]::FromArgb(250, 204, 21) }
        } else {
            $statusLabel.ForeColor = if ($script:running) { [Drawing.Color]::FromArgb(21, 128, 61) } else { [Drawing.Color]::FromArgb(161, 98, 7) }
        }
        $toggleButton.Text = if ($script:running) { 'Pause' } else { 'Resume' }
        $toggleItem.Text = if ($script:running) { 'Pause timer' } else { 'Resume timer' }
        $statusItem.Text = "$time - $status"
        $tip = "Focus Timer: $time ($status)"
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $notify.Text = $tip
    }

    function Show-TimerWindow {
        if (-not $form.Visible) { $form.Show() }
        $form.WindowState = 'Normal'
        $form.Activate()
        $toggleButton.Focus()
    }

    function Toggle-Timer {
        $script:running = -not $script:running
        $script:lastTick = [DateTime]::UtcNow
        Save-State
        Update-Display
    }

    function Toggle-Theme {
        $script:theme = if ($script:theme -eq 'dark') { 'light' } else { 'dark' }
        Apply-Theme
        Save-State
    }

    function Reset-Timer {
        $answer = [Windows.Forms.MessageBox]::Show(
            'Reset the timer to 00:00:00 and continue running?',
            'Reset Focus Timer', 'YesNo', 'Question')
        if ($answer -eq 'Yes') {
            $script:seconds = 0.0
            $script:running = $true
            $script:lastTick = [DateTime]::UtcNow
            Save-State
            Update-Display
        }
    }

    $toggleButton.Add_Click({ Toggle-Timer })
    $resetButton.Add_Click({ Reset-Timer })
    $hideButton.Add_Click({ $form.Hide() })
    $themeButton.Add_Click({ Toggle-Theme })
    $showItem.Add_Click({ Show-TimerWindow })
    $toggleItem.Add_Click({ Toggle-Timer })
    $resetItem.Add_Click({ Reset-Timer })
    $themeItem.Add_Click({ Toggle-Theme })
    $notify.Add_DoubleClick({ Show-TimerWindow })
    $exitItem.Add_Click({
        $script:allowExit = $true
        Save-State
        [Windows.Forms.Application]::Exit()
    })

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if (-not $script:allowExit -and $eventArgs.CloseReason -eq 'UserClosing') {
            $eventArgs.Cancel = $true
            $form.Hide()
        }
    })

    $form.Add_Resize({
        if ($form.WindowState -eq 'Minimized') {
            $form.Hide()
            $form.WindowState = 'Normal'
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        $now = [DateTime]::UtcNow
        $delta = ($now - $script:lastTick).TotalSeconds
        $script:lastTick = $now

        if ($script:running -and $delta -le 5) {
            $script:seconds += $delta
        }

        $whole = [Math]::Floor($script:seconds)
        if ($whole -ne $script:lastSavedSecond) { Save-State }
        Update-Display
    })

    Apply-Theme
    Save-State
    $timer.Start()
    $notify.ShowBalloonTip(2000, 'Focus Timer', "Running in the notification area at $(Format-Time $script:seconds).", 'Info')
    [Windows.Forms.Application]::Run()
}
finally {
    try { if ($null -ne $timer) { $timer.Stop(); $timer.Dispose() } } catch {}
    try { if (Get-Variable stateFile -ErrorAction SilentlyContinue) { Save-State } } catch {}
    try { if ($null -ne $notify) { $notify.Visible = $false; $notify.Dispose() } } catch {}
    if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}
