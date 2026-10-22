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
    $legacyStateFile = Join-Path (Join-Path $localData 'WorkTimer') 'state.json'
    [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $invariantCulture = [Globalization.CultureInfo]::InvariantCulture

    $script:seconds = 0.0
    $script:running = $true
    $script:theme = 'dark'
    $script:allowExit = $false
    $script:lastTickUtc = [DateTime]::UtcNow
    $script:lastTickLocal = Get-Date
    $script:lastSavedSecond = -1
    $script:stateDirty = $true
    $script:stateWarningShown = $false
    $script:stateWarningPending = $false
    $script:nextStateRetryUtc = [DateTime]::MinValue
    $script:lastRenderedIconText = ''

    function Format-Time([double]$value) {
        $whole = [Math]::Floor([Math]::Max(0, $value))
        $hours = [Math]::Floor($whole / 3600)
        $minutes = [Math]::Floor(($whole % 3600) / 60)
        $secs = $whole % 60
        return '{0:00}:{1:00}:{2:00}' -f $hours, $minutes, $secs
    }

    Add-Type -MemberDefinition @'
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
'@ -Name IconHelper -Namespace Win32 -ErrorAction SilentlyContinue

    # Ask Windows for the real tray icon size at the current DPI
    # (16 @100%, 20 @125%, 24 @150%, 32 @200%)
    $script:iconSize = [Win32.IconHelper]::GetSystemMetrics(49)  # SM_CXSMICON
    if ($script:iconSize -lt 16) { $script:iconSize = 16 }

    # The tray digits are a bold readout on a dark tile. Semibold hinted too
    # thin at 16-24px, so this is Segoe UI Bold.
    $script:iconDigitFamily = 'Segoe UI'
    $script:iconDigitStyle = [System.Drawing.FontStyle]::Bold

    # Build a real ICO container around an uncompressed 32-bit BGRA frame.
    #
    # Bitmap.GetHicon() collapses alpha into a 1-bit mask, which destroys
    # antialiased text. A PNG-compressed frame would keep the alpha but legacy
    # GDI+ paths cannot decode it, so an uncompressed DIB frame is used instead:
    # full 8-bit alpha, and every renderer understands it.
    function ConvertTo-Icon($bitmap) {
        $w = $bitmap.Width
        $h = $bitmap.Height
        $stride = $w * 4

        $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $data = $bitmap.LockBits(
            $rect,
            [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $pixels = New-Object byte[] ($stride * $h)
        for ($row = 0; $row -lt $h; $row++) {
            [System.Runtime.InteropServices.Marshal]::Copy(
                [IntPtr]::Add($data.Scan0, $row * $data.Stride),
                $pixels, $row * $stride, $stride)
        }
        $bitmap.UnlockBits($data)

        # The AND mask stays all-zero; the alpha channel does the masking.
        $maskStride = [int]([Math]::Floor(($w + 31) / 32) * 4)
        $maskSize = $maskStride * $h
        $dibSize = 40 + ($stride * $h) + $maskSize

        $stream = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.BinaryWriter($stream)

        # ICONDIR
        $writer.Write([int16]0)                  # reserved
        $writer.Write([int16]1)                  # type 1 = icon
        $writer.Write([int16]1)                  # one frame

        # ICONDIRENTRY
        $writer.Write([byte]($w -band 0xFF))
        $writer.Write([byte]($h -band 0xFF))
        $writer.Write([byte]0)                   # palette count
        $writer.Write([byte]0)                   # reserved
        $writer.Write([int16]1)                  # colour planes
        $writer.Write([int16]32)                 # bits per pixel
        $writer.Write([int32]$dibSize)
        $writer.Write([int32]22)                 # payload offset: 6 + 16

        # BITMAPINFOHEADER — double height covers the XOR image plus AND mask
        $writer.Write([int32]40)
        $writer.Write([int32]$w)
        $writer.Write([int32]($h * 2))
        $writer.Write([int16]1)
        $writer.Write([int16]32)
        $writer.Write([int32]0)                  # BI_RGB
        $writer.Write([int32]($stride * $h))
        $writer.Write([int32]0)
        $writer.Write([int32]0)
        $writer.Write([int32]0)
        $writer.Write([int32]0)

        # XOR image, bottom-up
        for ($row = $h - 1; $row -ge 0; $row--) {
            $writer.Write($pixels, $row * $stride, $stride)
        }
        $writer.Write((New-Object byte[] $maskSize))

        $writer.Flush()
        $stream.Position = 0
        $icon = New-Object System.Drawing.Icon($stream)
        $writer.Dispose()
        return $icon
    }

    # Draw text to a scratch surface, then crop to the actual ink bounds.
    # Positioning by text rectangle is unreliable at these sizes because font
    # ascent/descent padding pushes glyphs off the canvas; cropping to real ink
    # lets us place each line on exact pixel rows instead.
    function Get-InkBitmap([string]$text, [int]$px, $color) {
        # Big enough for three digits at the largest tray size.
        $pad = [Math]::Max(40, $px * 2 + 16)
        $scratch = New-Object System.Drawing.Bitmap($pad, $pad, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($scratch)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $font = New-Object System.Drawing.Font($script:iconDigitFamily, $px, $script:iconDigitStyle, [System.Drawing.GraphicsUnit]::Pixel)
        $brush = New-Object System.Drawing.SolidBrush($color)
        $sf = [System.Drawing.StringFormat]::GenericTypographic.Clone()
        $sf.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $g.DrawString($text, $font, $brush, 8.0, 8.0, $sf)
        $font.Dispose(); $brush.Dispose(); $sf.Dispose(); $g.Dispose()

        $minX = $pad; $minY = $pad; $maxX = -1; $maxY = -1
        for ($yy = 0; $yy -lt $pad; $yy++) {
            for ($xx = 0; $xx -lt $pad; $xx++) {
                if ($scratch.GetPixel($xx, $yy).A -gt 24) {
                    if ($xx -lt $minX) { $minX = $xx }
                    if ($yy -lt $minY) { $minY = $yy }
                    if ($xx -gt $maxX) { $maxX = $xx }
                    if ($yy -gt $maxY) { $maxY = $yy }
                }
            }
        }
        if ($maxX -lt 0) { $scratch.Dispose(); return $null }

        $w = $maxX - $minX + 1
        $h = $maxY - $minY + 1
        $ink = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $ig = [System.Drawing.Graphics]::FromImage($ink)
        $ig.DrawImage(
            $scratch,
            (New-Object System.Drawing.Rectangle(0, 0, $w, $h)),
            (New-Object System.Drawing.Rectangle($minX, $minY, $w, $h)),
            [System.Drawing.GraphicsUnit]::Pixel)
        $ig.Dispose(); $scratch.Dispose()
        return $ink
    }

    function New-StackedIcon([int]$hours, [int]$minutes, [bool]$isRunning) {
        $sz = $script:iconSize
        $textColor = if ($isRunning) {
            [System.Drawing.Color]::White
        } else {
            [System.Drawing.Color]::FromArgb(255, 250, 204, 21)
        }

        $bmp = New-StackedBitmap $sz $hours $minutes $isRunning $textColor
        $icon = ConvertTo-Icon $bmp
        $bmp.Dispose()
        return $icon
    }

    # Dark rounded tile filling the icon, bold hours stacked over minutes, and
    # (at 20px and up) a short cyan bar under the digits while running.
    function New-StackedBitmap([int]$sz, [int]$hours, [int]$minutes, [bool]$isRunning, $textColor) {
        $topText = '{0}' -f $hours
        $botText = '{0:00}' -f $minutes
        $gap = if ($sz -ge 24) { 2 } else { 1 }
        $barH = if ($sz -ge 20) { [Math]::Max(2, [int][Math]::Round($sz * 0.08)) } else { 0 }
        $inset = 1
        $areaW = $sz - 2 * $inset
        $areaH = $sz - 2 * $inset - $(if ($barH -gt 0) { $barH + 1 } else { 0 })

        # Start as large as the icon and shrink until both lines fit.
        $px = $sz
        $top = $null; $bot = $null
        while ($true) {
            if ($null -ne $top) { $top.Dispose() }
            if ($null -ne $bot) { $bot.Dispose() }
            $top = Get-InkBitmap $topText $px $textColor
            $bot = Get-InkBitmap $botText $px $textColor
            $fits = (
                $top.Width -le $areaW -and $bot.Width -le $areaW -and
                ($top.Height + $gap + $bot.Height) -le $areaH)
            if ($fits -or $px -le 6) { break }
            $px--
        }

        $bmp = New-Object System.Drawing.Bitmap($sz, $sz, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $r = [Math]::Max(3, [int][Math]::Round($sz * 0.22))
        $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = 2 * $r
        $tile.AddArc(0, 0, $d, $d, 180, 90)
        $tile.AddArc($sz - $d - 0.5, 0, $d, $d, 270, 90)
        $tile.AddArc($sz - $d - 0.5, $sz - $d - 0.5, $d, $d, 0, 90)
        $tile.AddArc(0, $sz - $d - 0.5, $d, $d, 90, 90)
        $tile.CloseFigure()
        $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 44, 44, 50))
        $g.FillPath($fill, $tile)
        $fill.Dispose(); $tile.Dispose()

        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
        $blockH = $top.Height + $gap + $bot.Height
        $startY = $inset + [int][Math]::Floor(($areaH - $blockH) / 2.0)
        $g.DrawImage($top, [int][Math]::Floor(($sz - $top.Width) / 2.0), $startY)
        $g.DrawImage($bot, [int][Math]::Floor(($sz - $bot.Width) / 2.0), ($startY + $top.Height + $gap))

        if ($barH -gt 0 -and $isRunning) {
            $barW = [Math]::Max(4, [int][Math]::Round($sz * 0.36))
            $cyan = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 103, 232, 249))
            $g.FillRectangle($cyan, [int][Math]::Floor(($sz - $barW) / 2.0), ($sz - $inset - $barH), $barW, $barH)
            $cyan.Dispose()
        }
        $top.Dispose(); $bot.Dispose(); $g.Dispose()
        return $bmp
    }

    function Update-TrayIcon {
        $whole = [Math]::Floor([Math]::Max(0, $script:seconds))
        $h = [int][Math]::Floor($whole / 3600)
        $m = [int][Math]::Floor(($whole % 3600) / 60)
        $key = "$h|$m|$($script:running)"
        if ($key -ceq $script:lastRenderedIconText) { return }
        $script:lastRenderedIconText = $key
        $oldIcon = $notify.Icon
        $notify.Icon = New-StackedIcon $h $m $script:running
        if ($null -ne $oldIcon -and $oldIcon -ne [Drawing.SystemIcons]::Information) {
            try { $oldIcon.Dispose() } catch {}
        }
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

    function Show-PendingWarnings {
        if ($script:stateWarningPending -and $null -ne $notify) {
            $script:stateWarningPending = $false
            $notify.ShowBalloonTip(
                5000,
                'Focus Timer could not save',
                'Time is still being tracked. Focus Timer will keep retrying while it is open.',
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

    function Accrue-ToNow {
        $nowUtc = [DateTime]::UtcNow
        $delta = ($nowUtc - $script:lastTickUtc).TotalSeconds
        $script:lastTickUtc = $nowUtc
        $script:lastTickLocal = Get-Date

        if ($script:running -and $delta -ge 0 -and $delta -le 5) {
            $script:seconds += $delta
            $script:stateDirty = $true
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

    # --- UI ---

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
    $themeButton.AccessibleDescription = 'Switch between light and dark themes.'

    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Text = Format-Time $script:seconds
    $timeLabel.Font = New-Object Drawing.Font('Consolas', 28, [Drawing.FontStyle]::Bold)
    $timeLabel.TextAlign = 'MiddleCenter'
    $timeLabel.SetBounds(15, 58, 330, 48)
    $timeLabel.AccessibleName = 'Total elapsed time'

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 9)
    $statusLabel.TextAlign = 'MiddleCenter'
    $statusLabel.SetBounds(100, 112, 160, 22)
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
    $setTimeButton.AccessibleDescription = 'Opens a dialog to set the timer total to any value.'

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

    # --- Tray context menu ---

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Enabled = $false
    $showItem = New-Object System.Windows.Forms.ToolStripMenuItem('Show timer')
    $toggleItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $setTimeItem = New-Object System.Windows.Forms.ToolStripMenuItem('Set time...')
    $resetItem = New-Object System.Windows.Forms.ToolStripMenuItem('Reset timer')
    $themeItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit timer')
    [void]$menu.Items.Add($statusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($showItem)
    [void]$menu.Items.Add($toggleItem)
    [void]$menu.Items.Add($setTimeItem)
    [void]$menu.Items.Add($resetItem)
    [void]$menu.Items.Add($themeItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($exitItem)

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [Drawing.SystemIcons]::Information
    $notify.ContextMenuStrip = $menu
    $notify.Visible = $true

    # --- Theme ---

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
        $tip = "Focus Timer: $time ($status)"
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $notify.Text = $tip
        Update-TrayIcon
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

    # --- Actions ---

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

    function Reset-Timer {
        [void](Accrue-ToNow)
        [void](Request-StateSave)
        $answer = [Windows.Forms.MessageBox]::Show(
            'Reset the total to 00:00:00?',
            'Reset timer', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }

        [void](Accrue-ToNow)
        $script:seconds = 0.0
        $script:lastTickUtc = [DateTime]::UtcNow
        $script:lastTickLocal = Get-Date
        [void](Request-StateSave)
        Update-Display
    }

    function Exit-Timer {
        [void](Accrue-ToNow)
        [void](Try-SaveState)
        $script:allowExit = $true
        [Windows.Forms.Application]::Exit()
    }

    # --- Wire events ---

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

    # --- Main tick ---

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
        Show-PendingWarnings
        Update-Display
    })

    Apply-Theme
    [void](Try-SaveState)
    $timer.Start()
    if (-not $script:stateWarningPending) {
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
    }
    try { if ($null -ne $notify) { $notify.Visible = $false; $notify.Dispose() } } catch {}
    if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
