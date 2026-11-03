# Win32 Test Lab: control panel INSIDE the sandbox to try a Win32 app (.intunewin content) like Intune would.
#   New installation:  Install -> Detect (expect detected) -> Uninstall -> Detect (expect not detected)
#   Update:            Install previous version -> Detect it -> Install update -> Detect -> Uninstall -> Detect
# Every step runs with one click (as SYSTEM through a scheduled task by default, like the Intune Management
# Extension), shows exit code / detection result and output, and takes a screenshot. Scripts can be edited
# here and steps repeated; edited scripts go back to the project. "Report failure" or "Finish: success"
# ends the session, reports to the host and closes the sandbox.
# -PreviewPath renders the panel to PNG files and exits (used for screenshots/tests).
param(
    [string]$JobDir = 'C:\MsixStudio\Job',
    [string]$LocalDir = 'C:\MsixStudioLocal',
    [string]$PreviewPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'Win32Shared.ps1')

$OutDir     = Join-Path $JobDir 'out'
$LabOut     = Join-Path $OutDir 'lab'
$StatusPath = Join-Path $JobDir 'status.json'
$LocalInput = Join-Path $LocalDir 'input'
$Source     = Join-Path $LocalInput 'source'
$BaseSource = Join-Path $LocalInput 'base\source'
$TempDir    = Join-Path $env:TEMP 'msixstudio'
$ShotDir    = Join-Path $TempDir 'labshots'
$DocDir     = Join-Path $TempDir 'labdoc'
New-Item -ItemType Directory $TempDir, $ShotDir -Force | Out-Null

$job = Get-Content (Join-Path $JobDir 'job.json') -Raw -Encoding UTF8 | ConvertFrom-Json
# The project definition comes with the job input (mapped folder, readable at any time)
$project = Get-Content (Join-Path $JobDir 'input\project.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$baseFile = Join-Path $JobDir 'input\base\intune-app.json'
$base = if (Test-Path $baseFile) { Get-Content $baseFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

$script:DocError = $null
try { Add-Type -Path (Join-Path $PSScriptRoot 'ClickRecorder.cs') -ReferencedAssemblies System.Drawing, System.Windows.Forms, UIAutomationClient, UIAutomationTypes, WindowsBase }
catch { $script:DocError = $_.Exception.Message }

# ---------------------------------------------------------------- steps
function New-LabStep([string]$Kind, [string]$Target, [string]$Title, [string]$Expect, [bool]$ExpectDetected = $true) {
    [pscustomobject]@{
        Index = 0; Kind = $Kind; Target = $Target; Title = $Title; Expect = $Expect; ExpectDetected = $ExpectDetected
        State = 'NotRun'; ExitCode = $null; Detected = $null; Detail = ''; Output = ''; Seconds = $null; User = ''; Screenshot = ''; Time = ''
    }
}
$steps = @()
if ($base) {
    $steps += New-LabStep 'Install' 'base' "Install previous version $($base.displayVersion)" 'Exit code is a success code'
    $steps += New-LabStep 'Detect' 'base' "Detect previous version $($base.displayVersion)" 'Detected'
    $steps += New-LabStep 'Install' 'new' "Install update $($project.Version)" 'Success code (over the previous version)'
    $steps += New-LabStep 'Detect' 'new' "Detect version $($project.Version)" 'Detected'
}
else {
    $steps += New-LabStep 'Install' 'new' "Install $($project.Version)" 'Exit code is a success code'
    $steps += New-LabStep 'Detect' 'new' 'Detect after install' 'Detected'
}
$steps += New-LabStep 'Uninstall' 'new' 'Uninstall' 'Exit code is a success code'
$steps += New-LabStep 'Detect' 'new' 'Detect after uninstall' 'Not detected' $false
for ($i = 0; $i -lt $steps.Count; $i++) { $steps[$i].Index = $i + 1 }

$script:State = 'Preparing'
$script:Running = $null      # @{ Step; Handle }
$script:Clicks = $null
$script:Started = Get-Date

# ---------------------------------------------------------------- look (M365 MFA tool family)
function Get-Color([string]$Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }
$C = @{
    Bg = Get-Color '#F3F5F8'; Header = Get-Color '#0F172A'; HeaderSub = Get-Color '#94A3B8'; Card = [System.Drawing.Color]::White
    CardLine = Get-Color '#E1E5EA'; Text = Get-Color '#242424'; Muted = Get-Color '#64748B'; Primary = Get-Color '#0067B8'
    Success = Get-Color '#107C41'; Danger = Get-Color '#C42B1C'; Warn = Get-Color '#B45309'; Secondary = Get-Color '#64748B'
    ChipOk = Get-Color '#DCFCE7'; ChipOkText = Get-Color '#166534'; ChipBad = Get-Color '#FEE2E2'; ChipBadText = Get-Color '#991B1B'
    ChipIdle = Get-Color '#E2E8F0'; ChipIdleText = Get-Color '#334155'; ChipRun = Get-Color '#DBEAFE'; ChipRunText = Get-Color '#1E40AF'
}
function New-Font([float]$Size, [string]$Style = 'Regular', [string]$Family = 'Segoe UI') { New-Object System.Drawing.Font($Family, $Size, [System.Drawing.FontStyle]$Style) }
function New-Label([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, $Font = (New-Font 8.5), $Color = $C.Muted) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Font = $Font; $l.ForeColor = $Color; $l.BackColor = [System.Drawing.Color]::Transparent
    $l.SetBounds($X, $Y, $W, $H); $l
}
function New-FlatButton([string]$Text, [System.Drawing.Color]$Back, [int]$X, [int]$Y, [int]$W, [int]$H, [float]$Size = 9) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back; $b.ForeColor = [System.Drawing.Color]::White; $b.Font = New-Font $Size 'Bold'
    $b.Cursor = 'Hand'; $b.SetBounds($X, $Y, $W, $H); $b
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Win32 Test Lab'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = $C.Bg
$form.Font = New-Font 9
$form.StartPosition = 'Manual'
$form.ClientSize = New-Object System.Drawing.Size(580, (330 + 58 * $steps.Count))
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($area.Right - $form.Width - 16), [Math]::Max($area.Top + 10, $area.Bottom - $form.Height - 16))

$header = New-Object System.Windows.Forms.Panel
$header.SetBounds(0, 0, 580, 74); $header.BackColor = $C.Header
$form.Controls.Add($header)
$header.Controls.Add((New-Label 'Win32 Test Lab' 20 10 330 30 (New-Font 15 'Bold') ([System.Drawing.Color]::White)))
$scenario = if ($base) { "Update $($base.displayVersion) -> $($project.Version)" } else { 'New installation' }
$header.Controls.Add((New-Label "$($project.DisplayName) $($project.Version)  $([char]0x00B7)  $scenario" 21 42 400 18 (New-Font 8.5) $C.HeaderSub))
$pill = New-Label 'PREPARING' 440 25 120 24 (New-Font 8.5 'Bold') ([System.Drawing.Color]::White)
$pill.TextAlign = 'MiddleCenter'; $pill.BackColor = $C.Warn
$header.Controls.Add($pill)

$info = New-Label 'Preparing the sandbox ...' 20 84 540 20 (New-Font 9.5) $C.Text
$form.Controls.Add($info)
$chkSystem = New-Object System.Windows.Forms.CheckBox
$chkSystem.Text = 'Run as SYSTEM (like Intune)'; $chkSystem.Checked = ($project.RunAs -ne 'user'); $chkSystem.Font = New-Font 9
$chkSystem.SetBounds(20, 108, 250, 22)
$chkDoc = New-Object System.Windows.Forms.CheckBox
$chkDoc.Text = 'Document clicks with screenshots'; $chkDoc.Checked = -not $script:DocError; $chkDoc.Enabled = -not $script:DocError; $chkDoc.Font = New-Font 9
$chkDoc.SetBounds(280, 108, 280, 22)
$form.Controls.AddRange(@($chkSystem, $chkDoc))

# Step rows
$rows = @{}
$top = 140
foreach ($s in $steps) {
    $row = New-Object System.Windows.Forms.Panel
    $row.SetBounds(12, $top, 556, 52); $row.BackColor = $C.Card
    $row.Add_Paint({ param($src, $e) $e.Graphics.DrawRectangle((New-Object System.Drawing.Pen($C.CardLine, 1)), 0, 0, $src.Width - 1, $src.Height - 1) })
    $num = New-Label "$($s.Index)" 10 14 26 24 (New-Font 10 'Bold') $C.ChipIdleText
    $num.TextAlign = 'MiddleCenter'; $num.BackColor = $C.ChipIdle
    $title = New-Label $s.Title 46 7 300 20 (New-Font 9.5 'Bold') $C.Text
    $expect = New-Label "Expected: $($s.Expect)" 46 27 300 18 (New-Font 8)
    $chip = New-Label 'not run' 352 15 100 22 (New-Font 8 'Bold') $C.ChipIdleText
    $chip.TextAlign = 'MiddleCenter'; $chip.BackColor = $C.ChipIdle
    $run = New-FlatButton 'Run' $C.Primary 462 11 82 30
    $run.Tag = $s.Index
    $run.Add_Click({ param($src) Invoke-Safe { Start-LabStep ([int]$src.Tag) } })
    $chip.Tag = $s.Index
    $chip.Cursor = 'Hand'
    $chip.Add_Click({ param($src) Show-StepOutput ([int]$src.Tag) })
    $row.Controls.AddRange(@($num, $title, $expect, $chip, $run))
    $form.Controls.Add($row)
    $rows[$s.Index] = @{ Chip = $chip; Run = $run; Num = $num }
    $top += 58
}

$output = New-Object System.Windows.Forms.TextBox
$output.Multiline = $true; $output.ReadOnly = $true; $output.ScrollBars = 'Vertical'
$output.Font = New-Font 8.5 'Regular' 'Consolas'; $output.BackColor = $C.Card
$output.SetBounds(12, $top + 2, 556, 84)
$output.Text = 'Output of the last step appears here. Click a result to see its output.'
$form.Controls.Add($output)
$top += 94

$tools = @(
    @('Install.ps1', { Open-LabScript 'Install.ps1' }), @('Detect.ps1', { Open-LabScript 'Detect.ps1' }),
    @('Uninstall.ps1', { Open-LabScript 'Uninstall.ps1' }), @('Content', { Start-Process explorer.exe $Source }),
    @('IME logs', { $d = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'; New-Item -ItemType Directory $d -Force | Out-Null; Start-Process explorer.exe $d }))
$x = 12
$form.Controls.Add((New-Label 'Edit / open:' $x ($top + 6) 70 18))
$x += 74
foreach ($t in $tools) {
    $b = New-FlatButton $t[0] $C.Secondary $x $top 90 26 8
    $b.Tag = $t[1]
    $b.Add_Click({ param($src) Invoke-Safe { & $src.Tag } })
    $form.Controls.Add($b)
    $x += 96
}
$top += 38

$btnFail = New-FlatButton 'Report failure' $C.Danger 12 $top 272 44 10
$btnOk = New-FlatButton 'Finish: success' $C.Success 296 $top 272 44 10
$form.Controls.AddRange(@($btnFail, $btnOk))

# ---------------------------------------------------------------- behavior
function Invoke-Safe([scriptblock]$Action) {
    try { & $Action } catch { [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Win32 Test Lab', 'OK', 'Warning') }
}

function Write-JobStatus([string]$State, [string]$Step, [string]$Message = '', $Result = $null) {
    $status = [ordered]@{ State = $State; Step = $Step; Message = $Message; Result = $Result; Updated = (Get-Date).ToString('o') }
    $tmp = Join-Path $JobDir 'status.tmp'
    $status | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $StatusPath -Force
}

function Open-LabScript([string]$Name) {
    $file = Join-Path $Source $Name
    if (-not (Test-Path $file)) { throw "$Name is not part of the package." }
    Start-Process notepad.exe -ArgumentList "`"$file`""
}

function Set-StepView($s) {
    $r = $rows[$s.Index]
    $map = @{
        NotRun  = @('not run', $C.ChipIdle, $C.ChipIdleText)
        Running = @('running ...', $C.ChipRun, $C.ChipRunText)
        Passed  = @('passed', $C.ChipOk, $C.ChipOkText)
        Failed  = @('failed', $C.ChipBad, $C.ChipBadText)
    }[$s.State]
    $text = $map[0]
    if ($s.State -in 'Passed', 'Failed') {
        $text = if ($s.Kind -eq 'Detect') { if ($s.Detected) { 'detected' } else { 'not detected' } } else { "exit $($s.ExitCode)" }
    }
    $r.Chip.Text = $text; $r.Chip.BackColor = $map[1]; $r.Chip.ForeColor = $map[2]
    $r.Num.BackColor = $map[1]; $r.Num.ForeColor = $map[2]
    $r.Run.Text = if ($s.State -eq 'NotRun') { 'Run' } else { 'Run again' }
}

function Show-StepOutput([int]$Index) {
    $s = $steps[$Index - 1]
    $output.Text = "Step $($s.Index): $($s.Title)`r`n$($s.Detail)`r`n`r`n$($s.Output -replace "`r?`n", "`r`n")"
}

function Get-StepContext($s) {
    # Command lines, working folder and detection of the new package or of the previous version
    if ($s.Target -eq 'base') {
        [pscustomobject]@{ Folder = $BaseSource; Install = $base.installCommandLine; Uninstall = $base.uninstallCommandLine; Detection = $base.detection }
    }
    else {
        [pscustomobject]@{ Folder = $Source; Install = $project.InstallCommand; Uninstall = $project.UninstallCommand; Detection = $project.Detection }
    }
}

function Start-LabStep([int]$Index) {
    if ($script:State -ne 'Ready') { return }
    if ($script:Running) { throw 'Another step is still running.' }
    $s = $steps[$Index - 1]
    $ctx = Get-StepContext $s
    $s.State = 'Running'; $s.Output = ''; $s.Detail = ''; $s.Time = (Get-Date).ToString('HH:mm:ss')
    Set-StepView $s
    $asSystem = $chkSystem.Checked
    switch ($s.Kind) {
        'Install'   { $script:Running = @{ Step = $s; Handle = Start-LabCommand -CommandLine $ctx.Install -WorkingDirectory $ctx.Folder -AsSystem:$asSystem } }
        'Uninstall' { $script:Running = @{ Step = $s; Handle = Start-LabCommand -CommandLine $ctx.Uninstall -WorkingDirectory $ctx.Folder -AsSystem:$asSystem } }
        'Detect' {
            if ($ctx.Detection.Type -eq 'Script') {
                # Intune runs detection scripts 64-bit (runAs32Bit = false) in the system context
                $cmd = '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File ".\Detect.ps1"'
                $script:Running = @{ Step = $s; Handle = Start-LabCommand -CommandLine $cmd -WorkingDirectory $ctx.Folder -AsSystem:$asSystem }
            }
            else {
                $t0 = Get-Date
                $d = Test-LabDetection -Detection $ctx.Detection
                Complete-LabStep $s ([pscustomobject]@{ ExitCode = $null; Output = $d.Detail; Seconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1); User = [Environment]::UserName; Detected = $d.Detected })
            }
        }
    }
    $info.Text = "Running step $($s.Index): $($s.Title) ..."
    $pill.Text = 'RUNNING'; $pill.BackColor = $C.Primary
}

function Complete-LabStep($s, $r) {
    $s.Seconds = $r.Seconds; $s.User = $r.User; $s.Output = $r.Output
    if ($s.Kind -eq 'Detect') {
        $detected = if ($null -ne $r.PSObject.Properties['Detected'] -and $null -ne $r.Detected) { [bool]$r.Detected } else { $r.ExitCode -eq 0 -and [bool]$r.Output }
        $s.Detected = $detected; $s.ExitCode = $r.ExitCode
        $s.State = if ($detected -eq $s.ExpectDetected) { 'Passed' } else { 'Failed' }
        $s.Detail = "$(if ($detected) { 'Detected' } else { 'Not detected' }) (expected: $($s.Expect))" + $(if ($null -ne $r.ExitCode) { ", exit code $($r.ExitCode)" })
    }
    else {
        $s.ExitCode = $r.ExitCode
        $s.State = if (Test-LabSuccessCode $r.ExitCode) { 'Passed' } else { 'Failed' }
        $s.Detail = "Exit code $($r.ExitCode) in $($r.Seconds) s as $($r.User)" + $(switch ($r.ExitCode) { 3010 { ' (soft reboot required)' } 1641 { ' (hard reboot initiated)' } default { '' } })
    }
    # Screenshot of the screen after the step
    Start-Sleep -Milliseconds 400
    try {
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $name = "step-$($s.Index)-$(Get-Date -Format 'HHmmss').png"
        $bmp.Save((Join-Path $ShotDir $name), [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        $s.Screenshot = "shots/$name"
    }
    catch { }
    Set-StepView $s
    Show-StepOutput $s.Index
    Update-Summary
}

function Update-Summary {
    $passed = @($steps | Where-Object State -eq 'Passed').Count
    $failed = @($steps | Where-Object State -eq 'Failed').Count
    $info.Text = "$passed of $($steps.Count) steps passed" + $(if ($failed) { ", $failed failed: fix the script (Edit) and run the step again, or report the failure." } else { '.' })
    if ($failed) { $pill.Text = 'ISSUES'; $pill.BackColor = $C.Danger }
    elseif ($passed -eq $steps.Count) { $pill.Text = 'ALL PASSED'; $pill.BackColor = $C.Success }
    else { $pill.Text = 'READY'; $pill.BackColor = $C.Success }
}

function Save-LabResults([string]$Verdict, [string]$Notes) {
    if ($script:Clicks) { try { $script:Clicks.Stop() } catch { } }
    New-Item -ItemType Directory $LabOut -Force | Out-Null
    if (Test-Path $ShotDir) { Copy-Item $ShotDir (Join-Path $LabOut 'shots') -Recurse -Force }
    if ($script:Clicks) {
        try {
            $script:Clicks.Steps | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $DocDir 'steps.json') -Encoding UTF8
            $script:Clicks.Frames | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $DocDir 'frames.json') -Encoding UTF8
            Copy-Item $DocDir (Join-Path $LabOut 'doc') -Recurse -Force
        }
        catch { $script:DocError = $_.Exception.Message }
    }
    [ordered]@{
        Scenario = $scenario; AsSystem = $chkSystem.Checked; Verdict = $Verdict; Notes = $Notes
        Started = $script:Started.ToString('o'); Finished = (Get-Date).ToString('o'); DocumentationError = $script:DocError
        Steps = @($steps)
    } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $LabOut 'results.json') -Encoding UTF8
    # Scripts as they are now (edited ones go back to the project)
    $scriptsOut = Join-Path $OutDir 'scripts'
    New-Item -ItemType Directory $scriptsOut -Force | Out-Null
    Get-ChildItem $Source -Filter '*.ps1' -ErrorAction SilentlyContinue | Copy-Item -Destination $scriptsOut -Force
}

function Close-Lab {
    if ($PreviewPath) { return }
    $form.Hide()
    Start-Sleep -Seconds 2
    shutdown.exe /s /t 0
}

$btnOk.Add_Click({
    Invoke-Safe {
        if ($script:Running) { throw 'A step is still running.' }
        $open = @($steps | Where-Object State -ne 'Passed')
        if ($open) {
            $answer = [System.Windows.Forms.MessageBox]::Show($form, "$($open.Count) step(s) did not pass. Report success anyway?", 'Finish: success', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
        }
        $notes = [Microsoft.VisualBasic.Interaction]::InputBox('Notes for the documentation (optional):', 'Finish: success', '')
        Save-LabResults 'Passed' $notes
        $summary = "$(@($steps | Where-Object State -eq 'Passed').Count) of $($steps.Count) steps passed."
        Write-JobStatus Succeeded 'Done' "Test lab passed. $summary" ([ordered]@{ Verdict = 'Passed'; Notes = $notes; Summary = $summary })
        $pill.Text = 'PASSED'; $pill.BackColor = $C.Success
        $info.Text = 'Reported success. The sandbox closes now.'
        [System.Windows.Forms.Application]::DoEvents()
        Close-Lab
    }
})
$btnFail.Add_Click({
    Invoke-Safe {
        $notes = [Microsoft.VisualBasic.Interaction]::InputBox('What went wrong? (goes into the documentation)', 'Report failure', '')
        if ($notes -eq '' -and [System.Windows.Forms.MessageBox]::Show($form, 'Report the failure without a note?', 'Report failure', 'YesNo', 'Question') -ne 'Yes') { return }
        Save-LabResults 'Failed' $notes
        $failedSteps = (@($steps | Where-Object State -eq 'Failed') | ForEach-Object Title) -join ', '
        $message = "Test lab failed." + $(if ($failedSteps) { " Failed steps: $failedSteps." }) + $(if ($notes) { " Note: $notes" })
        Write-JobStatus Failed 'Done' $message ([ordered]@{ Verdict = 'Failed'; Notes = $notes })
        $pill.Text = 'FAILED'; $pill.BackColor = $C.Danger
        $info.Text = 'Reported failure. The sandbox closes now.'
        [System.Windows.Forms.Application]::DoEvents()
        Close-Lab
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    try {
        if ($script:State -eq 'Preparing') {
            $st = $null
            try { $st = Get-Content $StatusPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { }
            if ($st -and $st.State -eq 'Failed') { $info.Text = "Preparation failed: $($st.Message)"; $pill.Text = 'FAILED'; $pill.BackColor = $C.Danger; $script:State = 'Failed' }
            elseif ($st -and $st.Step -eq 'Ready') {
                $script:State = 'Ready'
                Update-Summary
                $info.Text = 'Ready. Run the steps in order and check the app in between (Start menu, files, settings).'
                if ($chkDoc.Checked -and -not $script:DocError) {
                    $script:Clicks = New-Object MsixStudio.ClickRecorder($DocDir, 2000, 1600)
                    $script:Clicks.Start()
                }
            }
            elseif ($st -and $st.Step) { $info.Text = "$($st.Step) ..." }
            return
        }
        if ($script:Running) {
            $r = Get-LabCommandResult $script:Running.Handle
            if ($r) {
                $s = $script:Running.Step
                $script:Running = $null
                Complete-LabStep $s $r
            }
        }
    }
    catch { $info.Text = $_.Exception.Message }
})
$form.Add_FormClosing({
    param($src, $e)
    if ($PreviewPath) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Close the test lab without a result? The host gets "cancelled".', 'Win32 Test Lab', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { $e.Cancel = $true; return }
    Save-LabResults 'Cancelled' ''
    Write-JobStatus Failed 'Done' 'Test lab closed without a result.'
    Close-Lab
})

# ---------------------------------------------------------------- run
if ($PreviewPath) {
    New-Item -ItemType Directory $PreviewPath -Force | Out-Null
    $script:State = 'Ready'
    $steps[0].State = 'Passed'; $steps[0].ExitCode = 0; $steps[0].Detail = 'Exit code 0 in 12.4 s as SYSTEM'; $steps[0].Output = 'Installer exit code: 0'
    $steps[1].State = 'Passed'; $steps[1].Detected = $true; $steps[1].Detail = 'Detected (expected: Detected), exit code 0'; $steps[1].Output = 'Detected Contoso Tool 2.4.1'
    $steps[2].State = 'Failed'; $steps[2].ExitCode = 1603; $steps[2].Detail = 'Exit code 1603 in 3.1 s as SYSTEM'; $steps[2].Output = 'Uninstall failed: uninstall string not found'
    foreach ($s in $steps) { Set-StepView $s }
    Update-Summary
    Show-StepOutput 3
    $form.Show()
    $form.Location = New-Object System.Drawing.Point(-20000, 0)
    [System.Windows.Forms.Application]::DoEvents()
    $bmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
    $bmp.Save((Join-Path $PreviewPath 'win32lab.png'))
    $bmp.Dispose()
    $form.Close()
    return
}
$timer.Start()
[void]$form.ShowDialog()
