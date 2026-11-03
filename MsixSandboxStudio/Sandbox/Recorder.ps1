# MSIX Recorder: control panel INSIDE the sandbox for recording a manual installation or an update.
#   Preparing  Bootstrap.ps1 installs driver + Packaging Tool (progress read from status.json)
#   Ready      user checks the package fields, clicks "Start recording"
#   Recording  Packaging Tool captures; RecordingHold.ps1 is the template's installer: it restores the base
#              package (updates), starts the setup and waits. Every click is documented with a screenshot,
#              plus a frame sequence of the whole screen. The window shrinks to a bar with "Stop recording".
#   Building   Packaging Tool builds the .msix into the job folder
#   Done       documentation + logs go to out\, status.json reports the package, the sandbox shuts down
# While recording, nothing is written outside %TEMP% (excluded from captures).
# Look: same design as the host GUI (MSIX Sandbox Studio / M365 MFA tool family).
# -PreviewPath renders every state to PNG files and exits (used for screenshots/tests).
param(
    [string]$JobDir = 'C:\MsixStudio\Job',
    # Local copy of the job input made by Bootstrap.ps1: the Packaging Tool cannot use mapped folders.
    [string]$LocalDir = 'C:\MsixStudioLocal',
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
$DocDir     = Join-Path $TempDir 'doc'
$ToolFamily = 'Microsoft.MSIXPackagingTool_8wekyb3d8bbwe'
New-Item -ItemType Directory $TempDir -Force | Out-Null
$LocalInput = Join-Path $LocalDir 'input'
$LocalOut   = Join-Path $LocalDir 'out'
$job = Get-Content (Join-Path $JobDir 'job.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$BaseFile = if ($job.BasePackage) { Join-Path $LocalInput "base\$($job.BasePackage)" } else { $null }

$StopEvent     = New-RecorderEvent 'MsixStudioStopRecording'
$CancelEvent   = New-RecorderEvent 'MsixStudioCancelRecording'
$RestoredEvent = New-RecorderEvent 'MsixStudioRestored'
$RestoreFailed = New-RecorderEvent 'MsixStudioRestoreFailed'

# Click/screen documentation (C#). Without it the recording still works, just undocumented.
$script:DocError = $null
try {
    Add-Type -Path (Join-Path $PSScriptRoot 'ClickRecorder.cs') -ReferencedAssemblies System.Drawing, System.Windows.Forms, UIAutomationClient, UIAutomationTypes, WindowsBase
}
catch { $script:DocError = "Documentation unavailable: $($_.Exception.Message)" }

$script:State = 'Preparing'
$script:Proc = $null
$script:Started = $null
$script:Stopped = $null
$script:Cancelled = $false
$script:Countdown = 0
$script:Result = $null
$script:Clicks = $null
$script:Restoring = $false

# ---------------------------------------------------------------- look (M365 MFA tool family)
function Get-Color([string]$Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }
$C = @{
    Bg = Get-Color '#F3F5F8'; Header = Get-Color '#0F172A'; HeaderSub = Get-Color '#94A3B8'; Card = [System.Drawing.Color]::White
    Line = Get-Color '#D0D7DE'; CardLine = Get-Color '#E1E5EA'; Text = Get-Color '#242424'; Muted = Get-Color '#64748B'
    Primary = Get-Color '#0067B8'; Success = Get-Color '#107C41'; Danger = Get-Color '#C42B1C'; Warn = Get-Color '#B45309'
    Info = Get-Color '#E0ECF8'; Slate = Get-Color '#334155'; Secondary = Get-Color '#64748B'
}
function New-Font([float]$Size, [string]$Style = 'Regular', [string]$Family = 'Segoe UI') { New-Object System.Drawing.Font($Family, $Size, [System.Drawing.FontStyle]$Style) }

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Font = (New-Font 8.5), $Color = $C.Muted) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Font = $Font; $l.ForeColor = $Color; $l.BackColor = [System.Drawing.Color]::Transparent
    $l.SetBounds($X, $Y, $W, $H)
    $l
}
function New-Input([string]$Text, [int]$X, [int]$Y, [int]$W) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $Text; $t.Font = New-Font 10; $t.BackColor = $C.Card; $t.ForeColor = $C.Text; $t.BorderStyle = 'FixedSingle'
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
$form.Add_Paint({ $_.Graphics.DrawRectangle((New-Object System.Drawing.Pen($C.Slate, 1)), 0, 0, $form.Width - 1, $form.Height - 1) })

# ----- full layout
$full = New-Object System.Windows.Forms.Panel
$full.SetBounds(1, 1, 438, 678)
$full.BackColor = $C.Bg
$form.Controls.Add($full)

$header = New-Object System.Windows.Forms.Panel
$header.SetBounds(0, 0, 438, 74)
$header.BackColor = $C.Header
$full.Controls.Add($header)
Enable-Drag $header
$title = New-Label 'MSIX Recorder' 20 12 260 28 (New-Font 15 'Bold') ([System.Drawing.Color]::White)
$sub = New-Label 'MSIX Sandbox Studio' 21 42 260 18 (New-Font 8.5) $C.HeaderSub
$header.Controls.AddRange(@($title, $sub))
Enable-Drag $title; Enable-Drag $sub
$pill = New-Label 'PREPARING' 300 26 118 24 (New-Font 8.5 'Bold') ([System.Drawing.Color]::White)
$pill.TextAlign = 'MiddleCenter'
$pill.BackColor = $C.Warn
$header.Controls.Add($pill)

$step = New-Label 'Starting ...' 20 86 400 36 (New-Font 9.5) $C.Text
$full.Controls.Add($step)
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Style = 'Marquee'; $progress.MarqueeAnimationSpeed = 30
$progress.SetBounds(20, 124, 398, 4)
$full.Controls.Add($progress)

# Card with package fields
$card = New-Object System.Windows.Forms.Panel
$card.SetBounds(12, 138, 414, 236)
$card.BackColor = $C.Card
$card.Add_Paint({ $_.Graphics.DrawRectangle((New-Object System.Drawing.Pen($C.CardLine, 1)), 0, 0, $card.Width - 1, $card.Height - 1) })
$full.Controls.Add($card)
$card.Controls.Add((New-Label 'Package' 12 10 200 20 (New-Font 9.5 'Bold') $C.Text))
$card.Controls.Add((New-Label 'App name' 12 36 200 16))
$txtDisplay = New-Input $job.DisplayName 12 53 388
$card.Controls.Add($txtDisplay)
$card.Controls.Add((New-Label 'Package name (identity)' 12 86 190 16))
$txtName = New-Input $job.PackageName 12 103 250
$card.Controls.Add($txtName)
$card.Controls.Add((New-Label 'Version' 274 86 120 16))
$txtVersion = New-Input $job.Version 274 103 126
$card.Controls.Add($txtVersion)
$card.Controls.Add((New-Label 'Publisher display name' 12 136 190 16))
$txtPublisherDisplay = New-Input $job.PublisherDisplayName 12 153 250
$card.Controls.Add($txtPublisherDisplay)
$card.Controls.Add((New-Label 'Publisher (certificate)' 274 136 130 16))
$card.Controls.Add((New-Label $job.Publisher 274 156 130 34 (New-Font 8.5) $C.Text))
$chkDoc = New-Object System.Windows.Forms.CheckBox
$chkDoc.Text = 'Document every click with screenshots and record the screen'
$chkDoc.ForeColor = $C.Text; $chkDoc.Font = New-Font 9; $chkDoc.BackColor = [System.Drawing.Color]::Transparent
$chkDoc.SetBounds(12, 196, 390, 24)
$chkDoc.Checked = -not $script:DocError
$chkDoc.Enabled = -not $script:DocError
$card.Controls.Add($chkDoc)
# Auto-fill the identity from the app name until the user edits it
$script:NameEdited = [bool]$job.PackageName
$txtName.Add_KeyPress({ $script:NameEdited = $true })
$txtDisplay.Add_TextChanged({
    if (-not $script:NameEdited) { $txtName.Text = ($txtDisplay.Text -replace '[^A-Za-z0-9\.\-]', '') }
})

# Card with installer (and base package for updates)
$card2 = New-Object System.Windows.Forms.Panel
$card2.SetBounds(12, 384, 414, 166)
$card2.BackColor = $C.Card
$card2.Add_Paint({ $_.Graphics.DrawRectangle((New-Object System.Drawing.Pen($C.CardLine, 1)), 0, 0, $card2.Width - 1, $card2.Height - 1) })
$full.Controls.Add($card2)
$card2.Controls.Add((New-Label $(if ($BaseFile) { 'Update' } else { 'Installer' }) 12 10 200 20 (New-Font 9.5 'Bold') $C.Text))
$baseInfo = New-Label '' 12 34 388 34 (New-Font 8.5) $C.Text
$baseInfo.BackColor = $C.Info
$baseInfo.Padding = New-Object System.Windows.Forms.Padding(6, 3, 6, 3)
if ($BaseFile) { $baseInfo.Text = "Base: $($job.BaseDisplayName) $($job.BaseVersion). Its installed state is restored when the recording starts; then run your updates." }
$baseInfo.Visible = [bool]$BaseFile
$card2.Controls.Add($baseInfo)
$listTop = if ($BaseFile) { 74 } else { 36 }
$list = New-Object System.Windows.Forms.ListBox
$list.BackColor = $C.Card; $list.ForeColor = $C.Text; $list.BorderStyle = 'FixedSingle'; $list.Font = New-Font 9.5
$list.SetBounds(12, $listTop, 290, 56)
$files = @(Get-ChildItem $InputDir -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'signing.cer')
foreach ($f in $files) { [void]$list.Items.Add($f.Name) }
if ($files) { $list.SelectedIndex = 0 }
$card2.Controls.Add($list)
$btnRun = New-FlatButton 'Run' $C.Primary 312 $listTop 88 26 9
$btnFolder = New-FlatButton 'Folder' $C.Secondary 312 ($listTop + 30) 88 26 9
$card2.Controls.AddRange(@($btnRun, $btnFolder))
$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = 'Start the installer automatically with the recording'
$chkAuto.ForeColor = $C.Text; $chkAuto.Font = New-Font 9; $chkAuto.BackColor = [System.Drawing.Color]::Transparent
$chkAuto.SetBounds(12, ($listTop + 60), 390, 22)
$chkAuto.Checked = [bool]$files
$chkAuto.Enabled = [bool]$files
$card2.Controls.Add($chkAuto)
$noFiles = New-Label $(if ($BaseFile) { 'No update installer provided: start the app''s own updater or download the new setup after the recording has begun.' } else { 'No installer provided: download it in the sandbox or paste it from the host (clipboard), then start it after the recording has begun.' }) 12 $listTop 290 56 (New-Font 8.5)
$noFiles.Visible = -not $files
$card2.Controls.Add($noFiles)
if (-not $files) { $list.Visible = $false; $btnRun.Visible = $false; $btnFolder.Visible = $false }

$btnMain = New-FlatButton 'Preparing ...' $C.Secondary 12 562 414 52 12
$full.Controls.Add($btnMain)
$link = New-Object System.Windows.Forms.LinkLabel
$link.Text = 'Close sandbox'
$link.LinkColor = $C.Muted; $link.ActiveLinkColor = $C.Text; $link.Font = New-Font 9
$link.TextAlign = 'MiddleCenter'; $link.BackColor = [System.Drawing.Color]::Transparent
$link.SetBounds(12, 620, 414, 22)
$full.Controls.Add($link)
$hint = New-Label 'While recording, everything you change in this sandbox goes into the package: keep to the app.' 12 644 414 30 (New-Font 8)
$hint.TextAlign = 'TopCenter'
$full.Controls.Add($hint)

# ----- compact bar (while recording)
$compact = New-Object System.Windows.Forms.Panel
$compact.SetBounds(1, 1, 458, 62)
$compact.BackColor = $C.Header
$compact.Visible = $false
$form.Controls.Add($compact)
Enable-Drag $compact
$recDot = New-Object System.Windows.Forms.Panel
$recDot.SetBounds(16, 25, 12, 12)
$recDot.BackColor = $C.Header
$recDot.Add_Paint({ $_.Graphics.SmoothingMode = 'AntiAlias'; $_.Graphics.FillEllipse((New-Object System.Drawing.SolidBrush((Get-Color '#EF4444'))), 0, 0, 11, 11) })
$compact.Controls.Add($recDot)
$recTitle = New-Label 'RECORDING' 36 9 200 20 (New-Font 9 'Bold') (Get-Color '#FCA5A5')
$recTitle.AutoEllipsis = $true
$recTime = New-Label '00:00:00' 36 30 200 22 (New-Font 11 'Bold' 'Consolas') ([System.Drawing.Color]::White)
$compact.Controls.AddRange(@($recTitle, $recTime))
Enable-Drag $recTitle; Enable-Drag $recTime
$btnRunSmall = New-FlatButton 'Run' $C.Slate 240 14 60 34 9
$btnStop = New-FlatButton 'Stop recording' $C.Danger 308 14 136 34 10
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
        $form.ClientSize = New-Object System.Drawing.Size(460, 64)
        $form.Location = New-Object System.Drawing.Point(($area.Right - 480), ($area.Bottom - 84))
        $form.TopMost = $true
    }
    else {
        $form.ClientSize = New-Object System.Drawing.Size(440, 680)
        $form.Location = New-Object System.Drawing.Point(($area.Right - 460), [Math]::Max($area.Top + 10, $area.Bottom - 690))
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
    $chkDoc.Enabled = $editable -and -not $script:DocError
    $progress.Visible = $State -in 'Preparing', 'Building'
    $step.ForeColor = if ($State -eq 'Failed') { $C.Danger } else { $C.Text }
    switch ($State) {
        'Preparing' { $pill.Text = 'PREPARING'; $pill.BackColor = $C.Warn; $btnMain.Text = 'Preparing ...'; $btnMain.BackColor = $C.Secondary; $btnMain.Enabled = $false; Set-Layout $false }
        'Ready'     { $pill.Text = 'READY'; $pill.BackColor = $C.Success; $btnMain.Text = [char]0x25CF + '   Start recording'; $btnMain.BackColor = $C.Success; $btnMain.Enabled = $true; Set-Layout $false; $btnMain.Select() }
        'Recording' { $pill.Text = 'RECORDING'; $pill.BackColor = $C.Danger; Set-Layout $true }
        'Building'  { $pill.Text = 'BUILDING'; $pill.BackColor = $C.Primary; $btnMain.Text = 'Building package ...'; $btnMain.BackColor = $C.Secondary; $btnMain.Enabled = $false; Set-Layout $false }
        'Done'      { $pill.Text = 'DONE'; $pill.BackColor = $C.Success; $btnMain.Text = 'Close sandbox now'; $btnMain.BackColor = $C.Primary; $btnMain.Enabled = $true; Set-Layout $false }
        'Failed'    { $pill.Text = 'FAILED'; $pill.BackColor = $C.Danger; $btnMain.Text = 'Close sandbox'; $btnMain.BackColor = $C.Secondary; $btnMain.Enabled = $true; Set-Layout $false }
    }
}

function Close-Sandbox {
    if ($PreviewPath) { return }
    if ($script:State -notin 'Done', 'Failed') { Write-JobStatus Failed 'Recording' 'The recorder was closed without a package.' }
    $form.Hide()
    Start-Sleep -Seconds 2
    shutdown.exe /s /t 0
}

function Stop-Documentation {
    if (-not $script:Clicks) { return }
    try { $script:Clicks.Stop() } catch { $script:DocError = $_.Exception.Message }
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
        AutoStarted          = $false
        BasePackage          = $job.BasePackage
        Documented           = $false
    }
    $holdArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\RecordingHold.ps1`""
    if ($chkAuto.Checked -and $script:Result.Installer) {
        $holdArgs += " -Launch `"$(Join-Path $LocalInput $script:Result.Installer)`""
        $script:Result.AutoStarted = $true
    }
    if ($BaseFile) {
        $root = if ($job.InstallLocation) { $job.InstallLocation } else { Join-Path $env:ProgramFiles $name }
        $holdArgs += " -Restore `"$BaseFile`" -InstallRoot `"$root`""
    }
    $template = New-RecorderTemplate -PackageName $name -DisplayName $script:Result.DisplayName -PublisherName $job.Publisher `
        -PublisherDisplayName $publisherDisplay -Version $version `
        -InstallerPath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -InstallerArguments $holdArgs `
        -PackagePath (Join-Path $LocalOut $script:Result.PackageFile)
    New-Item -ItemType Directory $LocalOut -Force | Out-Null
    $templatePath = Join-Path $TempDir 'template.xml'
    [IO.File]::WriteAllText($templatePath, $template, (New-Object Text.UTF8Encoding $false))

    # Last write to the job folder before the capture starts.
    Write-JobStatus Running "Recording $($script:Result.DisplayName)"
    foreach ($e in $StopEvent, $CancelEvent, $RestoredEvent, $RestoreFailed) { [void]$e.Reset() }
    $script:Cancelled = $false

    if ($chkDoc.Checked -and -not $script:DocError) {
        if (Test-Path $DocDir) { Remove-Item $DocDir -Recurse -Force }
        $script:Clicks = New-Object MsixStudio.ClickRecorder($DocDir, 1000, 1600)
        $script:Clicks.Start()
        if ($script:Clicks.LastError) { $script:DocError = $script:Clicks.LastError }
        $script:Result.Documented = $true
    }

    $script:Proc = Start-Process -FilePath $cli -ArgumentList 'create-package', '--template', "`"$templatePath`"", '-v' `
        -RedirectStandardOutput (Join-Path $TempDir 'conversion.log') -RedirectStandardError (Join-Path $TempDir 'conversion.err.log') `
        -WindowStyle Hidden -PassThru
    $script:Started = Get-Date
    $script:Restoring = [bool]$BaseFile
    $recTitle.Text = if ($script:Restoring) { "RESTORING  $([char]0x00B7)  $($job.BaseDisplayName) $($job.BaseVersion)" } else { "RECORDING  $([char]0x00B7)  $($script:Result.DisplayName)" }
    Set-UiState 'Recording'
}

function Save-Documentation {
    # Capture is over: the documentation may go to the job folder now.
    if (-not $script:Result.Documented) { return }
    try {
        $script:Clicks.Steps | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $DocDir 'steps.json') -Encoding UTF8
        $script:Clicks.Frames | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $DocDir 'frames.json') -Encoding UTF8
        $restoreLog = Join-Path $TempDir 'restore.log'
        [ordered]@{
            Started      = $script:Started.ToString('o')
            Stopped      = $(if ($script:Stopped) { $script:Stopped.ToString('o') } else { (Get-Date).ToString('o') })
            Clicks       = $script:Clicks.Steps.Count
            Frames       = $script:Clicks.Frames.Count
            AutoStarted  = $script:Result.AutoStarted
            Installer    = $script:Result.Installer
            BasePackage  = $job.BasePackage
            RestoreLog   = $(if (Test-Path $restoreLog) { @(Get-Content $restoreLog) } else { @() })
            Error        = $script:DocError
            Screen       = [System.Windows.Forms.SystemInformation]::VirtualScreen.Size.ToString()
        } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $DocDir 'session.json') -Encoding UTF8
        Copy-Item $DocDir (Join-Path $OutDir 'doc') -Recurse -Force
    }
    catch { $script:DocError = $_.Exception.Message }
}

function Complete-Recording {
    $exit = $script:Proc.ExitCode
    $script:Proc = $null
    Stop-Documentation
    Copy-Item (Join-Path $TempDir '*.log') $OutDir -Force -ErrorAction SilentlyContinue
    $diag = Join-Path $env:LOCALAPPDATA "Packages\$ToolFamily\LocalState\DiagOutputDir"
    if (Test-Path $diag) { Copy-Item $diag (Join-Path $OutDir 'PackagingToolLogs') -Recurse -Force -ErrorAction SilentlyContinue }
    Save-Documentation
    Copy-Item (Join-Path $LocalOut $script:Result.PackageFile) $OutDir -Force -ErrorAction SilentlyContinue
    $msix = Join-Path $OutDir $script:Result.PackageFile
    if (Test-Path $msix) {
        $mb = [math]::Round((Get-Item $msix).Length / 1MB, 1)
        $docText = if ($script:Result.Documented) { " $($script:Clicks.Steps.Count) clicks documented." } else { '' }
        Write-JobStatus Succeeded 'Done' "Package recorded ($mb MB).$docText" $script:Result
        $script:Countdown = 10
        Set-UiState 'Done' "Package created ($mb MB).$docText It is signed on the host. The sandbox closes in 10 s."
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
    $file = Join-Path $LocalInput $list.SelectedItem
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
    if ($script:Restoring) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'The installed state of the base package is still being restored. Please wait a moment.', 'Stop recording', 'OK', 'Information')
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Is the installation complete? The package is built from everything recorded so far.', 'Stop recording', 'YesNo', 'Question')
    if ($answer -eq 'Yes') {
        $script:Stopped = Get-Date
        Stop-Documentation
        [void]$StopEvent.Set()
        Set-UiState 'Building' 'Recording stopped. The MSIX Packaging Tool is building the package ...'
    }
})
$btnRun.Add_Click({ Invoke-Safe { Start-SelectedInstaller } })
$btnRunSmall.Add_Click({ Invoke-Safe { Start-SelectedInstaller } })
$btnFolder.Add_Click({ Start-Process explorer.exe $LocalInput })
$link.Add_LinkClicked({
    if ($script:State -in 'Recording', 'Building') {
        $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Cancel the recording? Nothing will be packaged.', 'Cancel recording', 'YesNo', 'Warning')
        if ($answer -eq 'Yes') { $script:Cancelled = $true; Stop-Documentation; [void]$CancelEvent.Set(); Set-UiState 'Building' 'Cancelling ...' }
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
                if ($script:State -eq 'Recording') {
                    $elapsed = ((Get-Date) - $script:Started).ToString('hh\:mm\:ss')
                    if ($script:Restoring -and $RestoredEvent.WaitOne(0)) {
                        $script:Restoring = $false
                        $recTitle.Text = "RECORDING  $([char]0x00B7)  $($script:Result.DisplayName)"
                        if ($RestoreFailed.WaitOne(0)) { $recTitle.Text = 'RECORDING  (restore incomplete, see log)' }
                    }
                    $clicks = if ($script:Clicks) { "   $([char]0x00B7)  $($script:Clicks.ClickCount) clicks" } else { '' }
                    $recTime.Text = "$elapsed$clicks"
                }
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
        @('Done', 'Package created (48.2 MB). 23 clicks documented. It is signed on the host. The sandbox closes in 10 s.'))
    $i = 0
    foreach ($s in $states) {
        Set-UiState $s[0] $s[1]
        if ($s[0] -eq 'Recording') { $recTitle.Text = "RECORDING  $([char]0x00B7)  $($txtDisplay.Text)"; $recTime.Text = "00:03:27   $([char]0x00B7)  23 clicks" }
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
