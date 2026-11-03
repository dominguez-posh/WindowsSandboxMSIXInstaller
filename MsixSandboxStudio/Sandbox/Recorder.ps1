# MSIX Recorder: control panel INSIDE the sandbox for recording a manual installation.
#   Preparing  Bootstrap.ps1 installs driver + Packaging Tool (progress read from status.json)
#   Ready      user checks the package fields, clicks "Start recording"
#   Recording  Packaging Tool captures; RecordingHold.ps1 is the template's installer and starts the setup;
#              the window shrinks to a small bar with timer and "Stop recording"
#   Building   Packaging Tool builds the .msix into the job folder
#   Done       status.json reports the package to the host, the sandbox shuts down
# While recording, nothing is written outside %TEMP% (excluded from captures).
# -PreviewPath renders every state to PNG files and exits (used for screenshots/tests).
param(
    [string]$JobDir = 'C:\MsixStudio\Job',
    [string]$PreviewPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'RecorderTemplate.ps1')

$InputDir   = Join-Path $JobDir 'input'
$OutDir     = Join-Path $JobDir 'out'
$StatusPath = Join-Path $JobDir 'status.json'
$TempDir    = Join-Path $env:TEMP 'msixstudio'
$ToolFamily = 'Microsoft.MSIXPackagingTool_8wekyb3d8bbwe'
New-Item -ItemType Directory $TempDir -Force | Out-Null
$job = Get-Content (Join-Path $JobDir 'job.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$StopEvent   = New-RecorderEvent 'MsixStudioStopRecording'
$CancelEvent = New-RecorderEvent 'MsixStudioCancelRecording'

$script:State = 'Preparing'
$script:Proc = $null
$script:Started = $null
$script:Cancelled = $false
$script:Countdown = 0
$script:Result = $null

# ---------------------------------------------------------------- look
function Get-Color([string]$Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }
$C = @{
    Bg = Get-Color '#0B1020'; Card = Get-Color '#141C32'; Input = Get-Color '#0F1730'; Line = Get-Color '#243052'
    Text = Get-Color '#E6EAF2'; Muted = Get-Color '#8A96B0'; Accent = Get-Color '#7C5CFF'; Accent2 = Get-Color '#22D3EE'
    Ok = Get-Color '#10B981'; Rec = Get-Color '#EF4444'; Warn = Get-Color '#FBBF24'
}
function New-Font([float]$Size, [string]$Style = 'Regular', [string]$Family = 'Segoe UI') { New-Object System.Drawing.Font($Family, $Size, [System.Drawing.FontStyle]$Style) }

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Font = (New-Font 9), $Color = $C.Muted) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Font = $Font; $l.ForeColor = $Color; $l.BackColor = [System.Drawing.Color]::Transparent
    $l.SetBounds($X, $Y, $W, $H)
    $l
}
function New-Input([string]$Text, [int]$X, [int]$Y, [int]$W) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $Text; $t.Font = New-Font 10; $t.BackColor = $C.Input; $t.ForeColor = $C.Text; $t.BorderStyle = 'FixedSingle'
    $t.SetBounds($X, $Y, $W, 26)
    $t
}
function New-FlatButton([string]$Text, [System.Drawing.Color]$Back, [int]$X, [int]$Y, [int]$W, [int]$H, [float]$Size = 10) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back; $b.ForeColor = [System.Drawing.Color]::White; $b.Font = New-Font $Size 'Bold'
    $b.Cursor = 'Hand'; $b.SetBounds($X, $Y, $W, $H)
    $b
}

# Drag a borderless window by any of these controls
Add-Type -Namespace MsixRecorder -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ReleaseCapture();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int SendMessage(System.IntPtr hWnd, int msg, int wParam, int lParam);
'@
function Enable-Drag($Control) {
    $Control.Add_MouseDown({
        if ($_.Button -eq 'Left') { [void][MsixRecorder.Native]::ReleaseCapture(); [void][MsixRecorder.Native]::SendMessage($form.Handle, 0xA1, 2, 0) }
    })
}

# ---------------------------------------------------------------- window
$form = New-Object System.Windows.Forms.Form
$form.Text = 'MSIX Recorder'
$form.FormBorderStyle = 'None'
$form.BackColor = $C.Bg
$form.ForeColor = $C.Text
$form.ShowInTaskbar = $true
$form.StartPosition = 'Manual'
$form.Font = New-Font 9
# 1 px accent frame
$form.Padding = New-Object System.Windows.Forms.Padding(1)
$form.Add_Paint({ $_.Graphics.DrawRectangle((New-Object System.Drawing.Pen($C.Line, 1)), 0, 0, $form.Width - 1, $form.Height - 1) })

# ----- full layout
$full = New-Object System.Windows.Forms.Panel
$full.SetBounds(1, 1, 438, 598)
$full.BackColor = $C.Bg
$form.Controls.Add($full)

$header = New-Object System.Windows.Forms.Panel
$header.SetBounds(0, 0, 438, 70)
$header.BackColor = $C.Card
$header.Add_Paint({
    $g = $_.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $rect = New-Object System.Drawing.Rectangle 20, 16, 38, 38
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $C.Accent, $C.Accent2, 45)
    $g.FillEllipse($brush, $rect)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($C.Card)), 31, 27, 16, 16)
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($C.Rec)), 35, 31, 8, 8)
})
$full.Controls.Add($header)
Enable-Drag $header
$title = New-Label 'MSIX Recorder' 70 14 220 26 (New-Font 14 'Bold') $C.Text
$sub = New-Label 'MSIX Sandbox Studio' 71 40 220 18 (New-Font 8.5) $C.Accent2
$header.Controls.AddRange(@($title, $sub))
Enable-Drag $title; Enable-Drag $sub

$pill = New-Label 'PREPARING' 300 24 116 24 (New-Font 8.5 'Bold') $C.Bg
$pill.TextAlign = 'MiddleCenter'
$pill.BackColor = $C.Warn
$header.Controls.Add($pill)

$step = New-Label 'Starting ...' 20 84 400 36 (New-Font 9.5) $C.Text
$full.Controls.Add($step)
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30
$progress.SetBounds(20, 122, 398, 4)
$full.Controls.Add($progress)

$full.Controls.Add((New-Label 'PACKAGE' 20 140 200 18 (New-Font 8 'Bold') $C.Accent2))
$full.Controls.Add((New-Label 'App name' 20 160 200 18))
$txtDisplay = New-Input $job.DisplayName 20 178 398
$full.Controls.Add($txtDisplay)
$full.Controls.Add((New-Label 'Package name (identity)' 20 212 190 18))
$txtName = New-Input $job.PackageName 20 230 250
$full.Controls.Add($txtName)
$full.Controls.Add((New-Label 'Version' 284 212 120 18))
$txtVersion = New-Input $job.Version 284 230 134
$full.Controls.Add($txtVersion)
$full.Controls.Add((New-Label 'Publisher display name' 20 264 190 18))
$txtPublisherDisplay = New-Input $job.PublisherDisplayName 20 282 250
$full.Controls.Add($txtPublisherDisplay)
$full.Controls.Add((New-Label 'Publisher (certificate)' 284 264 140 18))
$full.Controls.Add((New-Label $job.Publisher 284 286 140 36 (New-Font 8.5) $C.Text))
# Auto-fill the identity from the app name until the user edits it
$script:NameEdited = [bool]$job.PackageName
$txtName.Add_KeyPress({ $script:NameEdited = $true })
$txtDisplay.Add_TextChanged({
    if (-not $script:NameEdited) { $txtName.Text = ($txtDisplay.Text -replace '[^A-Za-z0-9\.\-]', '') }
})

$full.Controls.Add((New-Label 'INSTALLER' 20 326 200 18 (New-Font 8 'Bold') $C.Accent2))
$list = New-Object System.Windows.Forms.ListBox
$list.BackColor = $C.Input; $list.ForeColor = $C.Text; $list.BorderStyle = 'FixedSingle'; $list.Font = New-Font 9.5
$list.SetBounds(20, 348, 300, 66)
$files = @(Get-ChildItem $InputDir -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'signing.cer')
foreach ($f in $files) { [void]$list.Items.Add($f.Name) }
if ($files) { $list.SelectedIndex = 0 }
$full.Controls.Add($list)
$btnRun = New-FlatButton 'Run' $C.Line 330 348 88 30 9
$btnFolder = New-FlatButton 'Folder' $C.Line 330 384 88 30 9
$full.Controls.AddRange(@($btnRun, $btnFolder))
$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = 'Start the installer automatically with the recording'
$chkAuto.ForeColor = $C.Text; $chkAuto.Font = New-Font 9; $chkAuto.BackColor = [System.Drawing.Color]::Transparent
$chkAuto.SetBounds(20, 420, 398, 22)
$chkAuto.Checked = [bool]$files
$chkAuto.Enabled = [bool]$files
$full.Controls.Add($chkAuto)
$noFiles = New-Label 'No installer provided: download it in the sandbox or paste it here from the host (clipboard), then start it after the recording has begun.' 20 348 300 66 (New-Font 8.5)
$noFiles.Visible = -not $files
$full.Controls.Add($noFiles)
if (-not $files) { $list.Visible = $false; $btnRun.Enabled = $false }

$btnMain = New-FlatButton 'Preparing ...' $C.Line 20 458 398 54 12
$full.Controls.Add($btnMain)
$link = New-Object System.Windows.Forms.LinkLabel
$link.Text = 'Close sandbox'
$link.LinkColor = $C.Muted; $link.ActiveLinkColor = $C.Text; $link.Font = New-Font 9
$link.TextAlign = 'MiddleCenter'; $link.BackColor = [System.Drawing.Color]::Transparent
$link.SetBounds(20, 520, 398, 22)
$full.Controls.Add($link)
$hint = New-Label 'While recording, everything you change in this sandbox goes into the package: keep to the app.' 20 552 398 36 (New-Font 8.5)
$hint.TextAlign = 'TopCenter'
$full.Controls.Add($hint)

# ----- compact bar (while recording)
$compact = New-Object System.Windows.Forms.Panel
$compact.SetBounds(1, 1, 418, 62)
$compact.BackColor = $C.Card
$compact.Visible = $false
$form.Controls.Add($compact)
Enable-Drag $compact
$recDot = New-Object System.Windows.Forms.Panel
$recDot.SetBounds(16, 25, 12, 12)
$recDot.Add_Paint({ $_.Graphics.SmoothingMode = 'AntiAlias'; $_.Graphics.FillEllipse((New-Object System.Drawing.SolidBrush($C.Rec)), 0, 0, 11, 11) })
$compact.Controls.Add($recDot)
$recTitle = New-Label 'RECORDING' 36 10 170 20 (New-Font 9 'Bold') $C.Rec
$recTitle.AutoEllipsis = $true
$recTime = New-Label '00:00' 36 30 170 22 (New-Font 12 'Bold' 'Consolas') $C.Text
$compact.Controls.AddRange(@($recTitle, $recTime))
Enable-Drag $recTitle; Enable-Drag $recTime
$btnRunSmall = New-FlatButton 'Run' $C.Line 204 14 56 34 9
$btnStop = New-FlatButton 'Stop recording' $C.Rec 268 14 136 34 10
$compact.Controls.AddRange(@($btnRunSmall, $btnStop))
$btnRunSmall.Enabled = [bool]$files

# ---------------------------------------------------------------- state
function Write-JobStatus([string]$State, [string]$Step, [string]$Message = '', $Result = $null) {
    $status = [ordered]@{ State = $State; Step = $Step; Message = $Message; Result = $Result; Updated = (Get-Date).ToString('o') }
    $tmp = Join-Path $JobDir 'status.tmp'
    $status | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $StatusPath -Force
}

function Set-Layout([bool]$Bar) {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $full.Visible = -not $Bar
    $compact.Visible = $Bar
    if ($Bar) {
        $form.ClientSize = New-Object System.Drawing.Size(420, 64)
        $form.Location = New-Object System.Drawing.Point(($area.Right - 440), ($area.Bottom - 84))
        $form.TopMost = $true
    }
    else {
        $form.ClientSize = New-Object System.Drawing.Size(440, 600)
        $form.Location = New-Object System.Drawing.Point(($area.Right - 460), [Math]::Max($area.Top + 20, $area.Bottom - 620))
        $form.TopMost = $false
    }
    $form.Invalidate()
}

function Set-UiState([string]$State, [string]$Text) {
    $script:State = $State
    if ($Text) { $step.Text = $Text }
    $editable = $State -in 'Preparing', 'Ready'
    foreach ($t in $txtDisplay, $txtName, $txtVersion, $txtPublisherDisplay) { $t.ReadOnly = -not $editable }
    $chkAuto.Enabled = $editable -and [bool]$files
    $progress.Visible = $State -in 'Preparing', 'Building'
    $step.ForeColor = if ($State -eq 'Failed') { $C.Rec } else { $C.Text }
    switch ($State) {
        'Preparing' { $pill.Text = 'PREPARING'; $pill.BackColor = $C.Warn; $btnMain.Text = 'Preparing ...'; $btnMain.BackColor = $C.Line; $btnMain.Enabled = $false; Set-Layout $false }
        'Ready'     { $pill.Text = 'READY'; $pill.BackColor = $C.Ok; $btnMain.Text = [char]0x25CF + '   Start recording'; $btnMain.BackColor = $C.Ok; $btnMain.Enabled = $true; Set-Layout $false; $btnMain.Select() }
        'Recording' { $pill.Text = 'RECORDING'; $pill.BackColor = $C.Rec; Set-Layout $true }
        'Building'  { $pill.Text = 'BUILDING'; $pill.BackColor = $C.Accent; $btnMain.Text = 'Building package ...'; $btnMain.BackColor = $C.Line; $btnMain.Enabled = $false; Set-Layout $false }
        'Done'      { $pill.Text = 'DONE'; $pill.BackColor = $C.Ok; $btnMain.Text = 'Close sandbox now'; $btnMain.BackColor = $C.Accent; $btnMain.Enabled = $true; Set-Layout $false }
        'Failed'    { $pill.Text = 'FAILED'; $pill.BackColor = $C.Rec; $btnMain.Text = 'Close sandbox'; $btnMain.BackColor = $C.Line; $btnMain.Enabled = $true; Set-Layout $false }
    }
}

function Close-Sandbox {
    if ($PreviewPath) { return }
    if ($script:State -notin 'Done', 'Failed') { Write-JobStatus Failed 'Recording' 'The recorder was closed without a package.' }
    $form.Hide()
    Start-Sleep -Seconds 2
    shutdown.exe /s /t 0
}

function Start-Recording {
    $version = ConvertTo-RecorderVersion $txtVersion.Text.Trim()
    $name = $txtName.Text.Trim()
    if (-not $txtDisplay.Text.Trim()) { throw 'Enter the app name.' }
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9\.\-]{2,49}$') { throw 'Package name: 3-50 letters, digits, dots or dashes.' }
    if (-not $version) { throw 'Version must look like 1.2.3.4 (each part 0-65535).' }
    $txtVersion.Text = $version
    $publisherDisplay = if ($txtPublisherDisplay.Text.Trim()) { $txtPublisherDisplay.Text.Trim() } else { $txtDisplay.Text.Trim() }

    $cli = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\MsixPackagingTool.exe'
    if (-not (Test-Path $cli)) { throw "MSIX Packaging Tool command line not found ($cli)." }

    $script:Result = [ordered]@{
        PackageFile          = '{0}_{1}.msix' -f $name, $version
        PackageName          = $name
        DisplayName          = $txtDisplay.Text.Trim()
        PublisherDisplayName = $publisherDisplay
        Version              = $version
        Installer            = $(if ($files -and $list.SelectedItem) { [string]$list.SelectedItem } else { '' })
    }
    $holdArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\RecordingHold.ps1`""
    if ($chkAuto.Checked -and $script:Result.Installer) { $holdArgs += " -Launch `"$(Join-Path $InputDir $script:Result.Installer)`"" }
    $template = New-RecorderTemplate -PackageName $name -DisplayName $script:Result.DisplayName -PublisherName $job.Publisher `
        -PublisherDisplayName $publisherDisplay -Version $version `
        -InstallerPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -InstallerArguments $holdArgs `
        -PackagePath (Join-Path $OutDir $script:Result.PackageFile)
    $templatePath = Join-Path $TempDir 'template.xml'
    [IO.File]::WriteAllText($templatePath, $template, (New-Object Text.UTF8Encoding $false))

    # Last write to the job folder before the capture starts.
    Write-JobStatus Running "Recording $($script:Result.DisplayName)"
    [void]$StopEvent.Reset(); [void]$CancelEvent.Reset()
    $script:Cancelled = $false
    $script:Proc = Start-Process -FilePath $cli -ArgumentList 'create-package', '--template', "`"$templatePath`"", '-v' `
        -RedirectStandardOutput (Join-Path $TempDir 'conversion.log') -RedirectStandardError (Join-Path $TempDir 'conversion.err.log') `
        -WindowStyle Hidden -PassThru
    $script:Started = Get-Date
    $recTitle.Text = 'RECORDING  ' + [char]0x00B7 + '  ' + $script:Result.DisplayName
    Set-UiState 'Recording'
}

function Complete-Recording {
    $exit = $script:Proc.ExitCode
    $script:Proc = $null
    # Capture is over: logs may go to the job folder now.
    Copy-Item (Join-Path $TempDir '*.log') $OutDir -Force -ErrorAction SilentlyContinue
    $diag = Join-Path $env:LOCALAPPDATA "Packages\$ToolFamily\LocalState\DiagOutputDir"
    if (Test-Path $diag) { Copy-Item $diag (Join-Path $OutDir 'PackagingToolLogs') -Recurse -Force -ErrorAction SilentlyContinue }
    $msix = Join-Path $OutDir $script:Result.PackageFile
    if (Test-Path $msix) {
        $mb = [math]::Round((Get-Item $msix).Length / 1MB, 1)
        Write-JobStatus Succeeded 'Done' "Package recorded ($mb MB)." $script:Result
        $script:Countdown = 10
        Set-UiState 'Done' "Package created ($mb MB). It is signed on the host. The sandbox closes in 10 s."
    }
    elseif ($script:Cancelled) {
        Write-JobStatus Failed 'Recording' 'Recording cancelled.'
        Set-UiState 'Failed' 'Recording cancelled. Nothing was packaged.'
    }
    else {
        $tail = (Get-Content (Join-Path $TempDir 'conversion.log') -Tail 3 -ErrorAction SilentlyContinue) -join ' '
        Write-JobStatus Failed 'Recording' "No package was created (exit code $exit). See conversion.log."
        Set-UiState 'Failed' "No package was created (exit code $exit). $tail"
    }
}

# ---------------------------------------------------------------- events
function Invoke-Safe([scriptblock]$Action) {
    try { & $Action } catch { [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'MSIX Recorder', 'OK', 'Warning') }
}
function Start-SelectedInstaller {
    if (-not $list.SelectedItem) { return }
    $file = Join-Path $InputDir $list.SelectedItem
    if ([IO.Path]::GetExtension($file) -eq '.msi') { Start-Process msiexec.exe -ArgumentList '/i', "`"$file`"" } else { Start-Process -FilePath $file }
}

$btnMain.Add_Click({
    Invoke-Safe {
        switch ($script:State) {
            'Ready'  { Start-Recording }
            'Done'   { Close-Sandbox }
            'Failed' { Close-Sandbox }
        }
    }
})
$btnStop.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Is the installation complete? The package is built from everything recorded so far.', 'Stop recording', 'YesNo', 'Question')
    if ($answer -eq 'Yes') {
        [void]$StopEvent.Set()
        Set-UiState 'Building' 'Recording stopped. The MSIX Packaging Tool is building the package ...'
    }
})
$btnRun.Add_Click({ Invoke-Safe { Start-SelectedInstaller } })
$btnRunSmall.Add_Click({ Invoke-Safe { Start-SelectedInstaller } })
$btnFolder.Add_Click({ Start-Process explorer.exe $InputDir })
$link.Add_LinkClicked({
    if ($script:State -in 'Recording', 'Building') {
        $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Cancel the recording? Nothing will be packaged.', 'Cancel recording', 'YesNo', 'Warning')
        if ($answer -eq 'Yes') { $script:Cancelled = $true; [void]$CancelEvent.Set(); Set-UiState 'Building' 'Cancelling ...' }
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Close the sandbox?', 'MSIX Recorder', 'YesNo', 'Question')
    if ($answer -eq 'Yes') { Close-Sandbox }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try {
        switch ($script:State) {
            'Preparing' {
                $s = $null
                try { $s = Get-Content $StatusPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { }
                if ($s -and $s.State -eq 'Failed') { Set-UiState 'Failed' "Preparation failed: $($s.Message)" }
                elseif ($s -and $s.Step -eq 'Ready') { Set-UiState 'Ready' 'Ready. Check the package details, then start the recording.' }
                elseif ($s -and $s.Step) { $step.Text = "$($s.Step) ..." }
            }
            { $_ -in 'Recording', 'Building' } {
                if ($script:State -eq 'Recording') { $recTime.Text = ((Get-Date) - $script:Started).ToString('hh\:mm\:ss') }
                if ($script:Proc -and $script:Proc.HasExited) { Complete-Recording }
            }
            'Done' {
                $script:Countdown -= 0.5
                if ($script:Countdown -le 0) { Close-Sandbox }
                elseif ([math]::Floor($script:Countdown) -eq $script:Countdown) { $step.Text = $step.Text -replace '\d+ s\.$', "$($script:Countdown) s." }
            }
        }
    }
    catch { $step.Text = $_.Exception.Message }
})

$form.Add_FormClosing({
    param($s, $e)
    if ($PreviewPath) { return }
    if ($script:State -in 'Recording', 'Building') { $e.Cancel = $true; return }
})

# ---------------------------------------------------------------- run
Set-UiState 'Preparing' 'Starting ...'
if ($PreviewPath) {
    # Render each state off-screen for screenshots.
    New-Item -ItemType Directory $PreviewPath -Force | Out-Null
    $form.Show()
    $states = @(
        @('Preparing', 'Installing MSIX Packaging Tool ...'),
        @('Ready', 'Ready. Check the package details, then start the recording.'),
        @('Recording', ''),
        @('Building', 'Recording stopped. The MSIX Packaging Tool is building the package ...'),
        @('Done', 'Package created (48.2 MB). It is signed on the host. The sandbox closes in 10 s.'))
    $i = 0
    foreach ($s in $states) {
        Set-UiState $s[0] $s[1]
        if ($s[0] -eq 'Recording') { $recTitle.Text = 'RECORDING  ' + [char]0x00B7 + '  ' + $txtDisplay.Text; $recTime.Text = '00:03:27' }
        $form.Location = New-Object System.Drawing.Point(-20000, 0)
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
        $bmp.Save((Join-Path $PreviewPath ("{0}-{1}.png" -f $i, $s[0])))
        $bmp.Dispose()
        $i++
    }
    $form.Close()
    return
}
$timer.Start()
[void]$form.ShowDialog()
