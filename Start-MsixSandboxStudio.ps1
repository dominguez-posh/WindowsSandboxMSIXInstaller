<#
.SYNOPSIS
    MSIX Sandbox Studio - GUI for the MsixSandboxStudio module.
.DESCRIPTION
    Long-running work (downloads, sandbox jobs, uploads) runs in a background runspace; its log lines
    are queued and shown live in the activity panel, so the window never freezes.
    Interactive sign-ins (Microsoft Graph, Azure) run on the UI thread.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:AppRoot    = $PSScriptRoot
$script:ModulePath = Join-Path $PSScriptRoot 'MsixSandboxStudio\MsixSandboxStudio.psd1'
Import-Module $script:ModulePath -Force

# ---------------------------------------------------------------- window
if (-not [System.Windows.Application]::Current) { [void](New-Object System.Windows.Application) }
[System.Windows.Application]::Current.ShutdownMode = 'OnExplicitShutdown'
[xml]$themeXml = Get-Content (Join-Path $PSScriptRoot 'UI\Theme.xaml') -Raw -Encoding UTF8
[System.Windows.Application]::Current.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($themeXml)))
[xml]$xaml = Get-Content (Join-Path $PSScriptRoot 'UI\MainWindow.xaml') -Raw -Encoding UTF8
$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))

$ui = @{}
foreach ($node in $xaml.SelectNodes("//*[@*[local-name()='Name']]")) {
    $name = $node.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value
    $ui[$name] = $window.FindName($name)
}
$ui.VersionText.Text = 'v' + (Get-Module MsixSandboxStudio).Version.ToString()

function Get-Brush([string]$Key) { [System.Windows.Application]::Current.Resources[$Key] }
$Dot = [char]0x00B7   # separator in list items (kept out of the source: PS 5.1 reads BOM-less files as ANSI)

# ---------------------------------------------------------------- log
function Add-LogLine {
    param([string]$Text, [string]$Level = 'Info')
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = switch ($Level) {
        'Success' { Get-Brush 'Ok' }
        'Warning' { Get-Brush 'Warn' }
        'Error'   { Get-Brush 'Bad' }
        default   { [System.Windows.Media.BrushConverter]::new().ConvertFrom('#AAB4CC') }
    }
    [void]$ui.LogList.Items.Add($tb)
    while ($ui.LogList.Items.Count -gt 800) { $ui.LogList.Items.RemoveAt(0) }
    $ui.LogList.ScrollIntoView($tb)
}
Set-MsixLogSink { param($line, $level) Add-LogLine $line $level }

function Show-Error([string]$Message) {
    Add-LogLine ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Message) 'Error'
    [void][System.Windows.MessageBox]::Show($window, $Message, 'MSIX Sandbox Studio', 'OK', 'Error')
}

$script:ClickActions = @{}
function Add-Click {
    # Click handler with error handling: an exception shows a message instead of killing the window.
    # Actions are looked up by sender (no GetNewClosure: that would hide this script's functions and variables).
    param($Control, [scriptblock]$Action)
    $script:ClickActions[$Control] = $Action
    $Control.Add_Click({
        param($sender)
        try { & $script:ClickActions[$sender] } catch { Show-Error $_.Exception.Message }
    })
}

# ---------------------------------------------------------------- background tasks
$script:Task = $null

function Get-GraphAccessToken {
    # Hands the UI thread's Graph sign-in to a background runspace.
    if (-not (Get-MsixIntuneContext)) { return $null }
    try {
        $resp = Invoke-MgGraphRequest -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id' -OutputType HttpResponseMessage
        $resp.RequestMessage.Headers.Authorization.Parameter
    }
    catch { $null }
}

function Start-UiTask {
    <#
    Runs $Work in a background runspace with the module loaded. $OnDone gets ($Result, $ErrorMessage)
    on the UI thread when it finishes. One task at a time (Windows Sandbox runs one instance anyway).
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Work,
        [hashtable]$Arguments = @{},
        [scriptblock]$OnDone,
        [switch]$NeedsGraph
    )
    if ($script:Task) { Show-Error 'Another task is still running.'; return }
    $token = if ($NeedsGraph) { Get-GraphAccessToken } else { $null }
    if ($NeedsGraph -and -not $token) { Show-Error 'Sign in to Intune first (Intune page).'; return }

    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $bootstrap = {
        param($ModulePath, $Queue, $WorkText, $Arguments, $Token)
        $ErrorActionPreference = 'Stop'
        $global:MsixQueue = $Queue
        Import-Module $ModulePath -Force
        Set-MsixLogSink { param($l, $lvl) $global:MsixQueue.Enqueue(@($l, $lvl)) }
        if ($Token -and -not (Get-MsixIntuneContext)) {
            Import-Module Microsoft.Graph.Authentication
            Connect-MgGraph -AccessToken (ConvertTo-SecureString $Token -AsPlainText -Force) -NoWelcome | Out-Null
        }
        & ([scriptblock]::Create($WorkText)) @Arguments
    }
    [void]$ps.AddScript($bootstrap.ToString()).AddArgument($script:ModulePath).AddArgument($queue).AddArgument($Work.ToString()).AddArgument($Arguments).AddArgument($token)
    $script:Task = @{ PS = $ps; Runspace = $rs; Handle = $ps.BeginInvoke(); Queue = $queue; OnDone = $OnDone; Title = $Title }
    Set-Busy $Title
}

function Set-Busy([string]$Title) {
    $on = [bool]$Title
    $ui.BusyPill.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
    $ui.BusyBar.Visibility = if ($on) { 'Visible' } else { 'Hidden' }
    $ui.BusyText.Text = $Title
    foreach ($b in 'BtnBuild', 'BtnBuildTest', 'BtnBuildAll', 'BtnPkgTest', 'BtnPkgSign', 'BtnPkgPublish', 'BtnDashSandbox', 'BtnDashRecord', 'BtnToolchainUpdate', 'BtnToolchainForce', 'BtnRecipeSave', 'BtnCertIntune') {
        $ui[$b].IsEnabled = -not $on
    }
    if (-not $on) { Update-PackageButtons }
}

function Complete-UiTask {
    $t = $script:Task
    while ($t.Queue.Count -gt 0) {
        $item = $null
        if ($t.Queue.TryDequeue([ref]$item)) { Add-LogLine $item[0] $item[1] }
    }
    $result = $null; $err = $null
    try { $result = @($t.PS.EndInvoke($t.Handle)) }
    catch { $err = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message } }
    foreach ($e in $t.PS.Streams.Error) { Add-LogLine ('{0:HH:mm:ss}  {1}' -f (Get-Date), $e.ToString()) 'Warning' }
    $t.PS.Dispose(); $t.Runspace.Dispose()
    $script:Task = $null
    Set-Busy ''
    if ($err) { Add-LogLine ('{0:HH:mm:ss}  {1} failed: {2}' -f (Get-Date), $t.Title, $err) 'Error' }
    if ($t.OnDone) {
        try { & $t.OnDone $result $err } catch { Show-Error $_.Exception.Message }
    }
    Update-Dashboard
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:Tick = 0
$timer.Add_Tick({
    $script:Tick++
    if ($script:Task) {
        $item = $null
        while ($script:Task.Queue.TryDequeue([ref]$item)) { Add-LogLine $item[0] $item[1] }
        $ui.SpinnerRotate.Angle = ($ui.SpinnerRotate.Angle + 30) % 360
        if ($script:Task.Handle.IsCompleted) { Complete-UiTask }
    }
    if ($script:Tick % 15 -eq 0) { Update-SandboxState }
})

function Update-SandboxState {
    $running = Test-MsixSandboxRunning
    $ui.SandboxDot.Fill = if ($running) { Get-Brush 'Ok' } else { Get-Brush 'Muted' }
    $ui.SandboxStateText.Text = if ($running) { 'Sandbox running' } else { 'Sandbox idle' }
}

# ---------------------------------------------------------------- navigation
$pages = [ordered]@{
    Dashboard   = @('Dashboard', 'Readiness of this computer and quick start')
    Recipes     = @('Recipes', 'One recipe per app: installer, silent arguments, package identity')
    Packages    = @('Packages', 'Signed packages in the output folder: test, re-sign, publish')
    Certificate = @('Certificate', 'Code-signing certificate used for every package')
    Intune      = @('Intune', 'Microsoft Graph sign-in and assignment for published apps')
    Settings    = @('Settings', 'Toolchain, sandbox resources and signing options')
}
function Show-Page([string]$Name) {
    foreach ($p in $pages.Keys) { $ui["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
    $ui.PageTitle.Text = $pages[$Name][0]
    $ui.PageSubtitle.Text = $pages[$Name][1]
    $ui["Nav$Name"].IsChecked = $true
    switch ($Name) {
        'Dashboard'   { Update-Dashboard }
        'Recipes'     { Update-RecipeList }
        'Packages'    { Update-PackageList }
        'Certificate' { Update-CertificateView }
        'Intune'      { Update-IntuneView }
        'Settings'    { Update-SettingsView }
    }
}
foreach ($p in $pages.Keys) {
    $ui["Nav$p"].Add_Checked({
        param($sender)
        $name = $sender.Name -replace '^Nav', ''
        if ($ui["Page$name"].Visibility -ne 'Visible') { Show-Page $name }
    })
}

# ---------------------------------------------------------------- dashboard
function New-ReadinessCard {
    param([string]$Glyph, [string]$Title, [ValidateSet('ok', 'warn', 'bad')][string]$State, [string]$Text, [string]$ActionText, [scriptblock]$Action)
    $color = @{ ok = 'Ok'; warn = 'Warn'; bad = 'Bad' }[$State]
    $border = New-Object System.Windows.Controls.Border
    $border.Style = $window.FindResource('Card')
    $border.Margin = '0,0,16,16'
    $sp = New-Object System.Windows.Controls.StackPanel
    $head = New-Object System.Windows.Controls.DockPanel
    $ico = New-Object System.Windows.Controls.TextBlock
    $ico.Text = $Glyph; $ico.FontFamily = Get-Brush 'Icons'; $ico.FontSize = 18; $ico.Foreground = Get-Brush 'Accent2'
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 10; $dot.Height = 10; $dot.Fill = Get-Brush $color
    [System.Windows.Controls.DockPanel]::SetDock($dot, 'Right')
    [void]$head.Children.Add($dot); [void]$head.Children.Add($ico)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Title; $t.FontWeight = 'SemiBold'; $t.FontSize = 14; $t.Margin = '0,12,0,4'
    $d = New-Object System.Windows.Controls.TextBlock
    $d.Text = $Text; $d.Style = $window.FindResource('Hint'); $d.MinHeight = 34
    [void]$sp.Children.Add($head); [void]$sp.Children.Add($t); [void]$sp.Children.Add($d)
    if ($ActionText) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $ActionText; $b.Style = $window.FindResource('Small'); $b.HorizontalAlignment = 'Left'; $b.Margin = '0,10,0,0'
        Add-Click $b $Action
        [void]$sp.Children.Add($b)
    }
    $border.Child = $sp
    $border
}

function Update-Dashboard {
    $s = Get-MsixHostStatus
    $ui.ReadinessGrid.Children.Clear()
    $cards = @(
        @{ Glyph = [char]0xE7F4; Title = 'Windows Sandbox'
           State = $(if ($s.SandboxEnabled) { 'ok' } elseif ($s.EditionSupported) { 'bad' } else { 'bad' })
           Text = $(if ($s.SandboxEnabled) { "Enabled on $($s.OsCaption) ($($s.OsBuild))" } elseif ($s.EditionSupported) { 'Feature not enabled' } else { 'Not available on Windows Home' })
           ActionText = $(if (-not $s.SandboxEnabled -and $s.EditionSupported) { 'Enable (admin, reboot)' })
           Action = { Enable-MsixSandboxFeature } }
        @{ Glyph = [char]0xE950; Title = 'Virtualization'
           State = $(if ($s.HypervisorPresent) { 'ok' } else { 'bad' })
           Text = $(if ($s.HypervisorPresent) { 'Hypervisor running' } else { 'Enable virtualization in BIOS/UEFI' }) }
        @{ Glyph = [char]0xE896; Title = 'Toolchain'
           State = $(if ($s.ToolchainReady) { 'ok' } else { 'warn' })
           Text = $(if ($s.ToolchainReady) { "Packaging Tool $($s.Toolchain.Version), SDK $($s.Toolchain.SdkToolsVersion)" } else { 'Not downloaded yet (about 60 MB)' })
           ActionText = $(if (-not $s.ToolchainReady) { 'Download now' })
           Action = { Invoke-ToolchainUpdate $false } }
        @{ Glyph = [char]0xEB95; Title = 'Signing certificate'
           State = $(if ($s.CertificateReady) { 'ok' } elseif ($s.Certificate) { 'warn' } else { 'warn' })
           Text = $(if ($s.CertificateReady) { "$($s.Certificate.Subject), valid until $($s.Certificate.NotAfter.ToString('d'))" } elseif ($s.Certificate -and $s.Certificate.IsExpired) { 'Expired' } else { 'None configured' })
           ActionText = $(if (-not $s.CertificateReady) { 'Set up' })
           Action = { Show-Page 'Certificate' } }
        @{ Glyph = [char]0xE753; Title = 'Microsoft Graph'
           State = $(if ($s.GraphModule) { 'ok' } else { 'warn' })
           Text = $(if ($s.GraphModule) { 'Module installed, Intune publishing available' } else { 'Install Microsoft.Graph.Authentication for Intune' }) }
        @{ Glyph = [char]0xE77B; Title = 'Intune session'
           State = $(if (Get-MsixIntuneContext) { 'ok' } else { 'warn' })
           Text = $(if ($c = Get-MsixIntuneContext) { $c.Account } else { 'Not signed in' })
           ActionText = $(if (-not (Get-MsixIntuneContext)) { 'Sign in' })
           Action = { Show-Page 'Intune' } }
    )
    foreach ($c in $cards) { [void]$ui.ReadinessGrid.Children.Add((New-ReadinessCard @c)) }
    $ui.StatRecipes.Text = @(Get-MsixRecipe).Count
    $ui.StatPackages.Text = @(Get-ChildItem (Get-MsixWorkspace).Output -Filter '*.msix' -ErrorAction SilentlyContinue).Count
    Update-SandboxState
}

# Pipeline chips in the hero card
$steps = @(@([char]0xE8FD, 'Recipe'), @([char]0xE7F4, 'Package'), @([char]0xEB95, 'Sign'), @([char]0xEBE8, 'Test'), @([char]0xE753, 'Intune'))
for ($i = 0; $i -lt $steps.Count; $i++) {
    $chip = New-Object System.Windows.Controls.Border
    $chip.CornerRadius = 14; $chip.Padding = '12,6'; $chip.Margin = '0,0,6,6'
    $chip.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#33FFFFFF')
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    $ic = New-Object System.Windows.Controls.TextBlock; $ic.Text = $steps[$i][0]; $ic.FontFamily = Get-Brush 'Icons'; $ic.Margin = '0,0,6,0'; $ic.VerticalAlignment = 'Center'
    $tx = New-Object System.Windows.Controls.TextBlock; $tx.Text = $steps[$i][1]; $tx.FontWeight = 'SemiBold'
    [void]$sp.Children.Add($ic); [void]$sp.Children.Add($tx); $chip.Child = $sp
    [void]$ui.PipelineChips.Children.Add($chip)
    if ($i -lt $steps.Count - 1) {
        $arrow = New-Object System.Windows.Controls.TextBlock
        $arrow.Text = [char]0xE76C; $arrow.FontFamily = Get-Brush 'Icons'; $arrow.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#A5B4FC')
        $arrow.Margin = '0,0,6,6'; $arrow.VerticalAlignment = 'Center'
        [void]$ui.PipelineChips.Children.Add($arrow)
    }
}

function Invoke-ToolchainUpdate([bool]$Force) {
    Start-UiTask -Title 'Updating toolchain' -Arguments @{ Force = $Force } -Work {
        param($Force) Update-MsixToolchain -Force:$Force | Out-Null
    } -OnDone { Update-SettingsView }
}

Add-Click $ui.BtnDashNewRecipe { Show-Page 'Recipes'; Clear-RecipeForm }
Add-Click $ui.BtnDashRecord {
    if (-not (Get-MsixCertificate)) { throw 'Set up a signing certificate first (Certificate page).' }
    if (Test-MsixSandboxRunning) { throw 'A Windows Sandbox is already open; close it first (Windows runs one at a time).' }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Installer to record (optional: Cancel to record without, e.g. to download it in the sandbox)'
    $dlg.Filter = 'Installers (*.msi;*.exe)|*.msi;*.exe|All files (*.*)|*.*'
    $installer = ''
    $prefill = @{}
    if ($dlg.ShowDialog($window)) {
        $installer = $dlg.FileName
        $info = Get-MsixInstallerInfo -Path $installer
        $prefill = @{
            DisplayName          = $info.ProductName
            PackageName          = ConvertTo-MsixPackageName (($info.Manufacturer -split '\s')[0] + '.' + $info.ProductName)
            Version              = $info.Version
            PublisherDisplayName = $info.Manufacturer
        }
    }
    Start-UiTask -Title 'Recording: Start recording in the sandbox, install the app, Stop recording' -Arguments @{ Installer = $installer; Prefill = $prefill } -Work {
        param($Installer, $Prefill)
        Start-MsixRecording -InstallerPath $Installer @Prefill
    } -OnDone {
        param($result, $err)
        if ($err -or -not $result) { return }
        $r = $result[-1]
        if ($r.PackagePath) { Show-Page 'Packages'; Select-Package $r.PackagePath }
    }
}
Add-Click $ui.BtnDashSandbox {
    if (Test-MsixSandboxRunning) { throw 'A Windows Sandbox is already open; Windows runs one at a time.' }
    Start-UiTask -Title 'Starting interactive sandbox' -Work { Start-MsixSandbox | Out-Null }
}

# ---------------------------------------------------------------- recipes
$script:CurrentRecipe = $null

function New-ListItemContent([string]$Title, [string]$Sub, [string]$Badge, [string]$BadgeColor = 'Accent2') {
    $grid = New-Object System.Windows.Controls.DockPanel
    if ($Badge) {
        $bd = New-Object System.Windows.Controls.Border
        $bd.CornerRadius = 8; $bd.Padding = '8,2'; $bd.VerticalAlignment = 'Top'
        $bd.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom('#1B2547')
        $bt = New-Object System.Windows.Controls.TextBlock; $bt.Text = $Badge; $bt.FontSize = 10; $bt.Foreground = Get-Brush $BadgeColor
        $bd.Child = $bt
        [System.Windows.Controls.DockPanel]::SetDock($bd, 'Right')
        [void]$grid.Children.Add($bd)
    }
    $sp = New-Object System.Windows.Controls.StackPanel
    $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $Title; $t.FontWeight = 'SemiBold'; $t.TextTrimming = 'CharacterEllipsis'
    $s = New-Object System.Windows.Controls.TextBlock; $s.Text = $Sub; $s.Style = $window.FindResource('Hint'); $s.Margin = '0,2,0,0'
    [void]$sp.Children.Add($t); [void]$sp.Children.Add($s)
    [void]$grid.Children.Add($sp)
    $grid
}

function Update-RecipeList {
    $selected = if ($script:CurrentRecipe) { $script:CurrentRecipe.PackageName } else { $null }
    $ui.RecipeList.Items.Clear()
    foreach ($r in Get-MsixRecipe | Sort-Object DisplayName) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $badge = if ($r.InstallMode -eq 'Manual') { 'MANUAL' } else { [IO.Path]::GetExtension($r.Installer).TrimStart('.').ToUpper() }
        $item.Content = New-ListItemContent $r.DisplayName "$($r.PackageName)  $Dot  $($r.Version)" $badge $(if ($r.InstallMode -eq 'Manual') { 'Warn' } else { 'Accent2' })
        $item.Tag = $r
        [void]$ui.RecipeList.Items.Add($item)
        if ($r.PackageName -eq $selected) { $item.IsSelected = $true }
    }
    Update-PublisherHint
}

function Update-PublisherHint {
    $cert = Get-MsixCertificate
    $ui.TxtPublisherHint.Text = if ($cert) { "Publisher: $($cert.Subject) (from the signing certificate)" } else { 'No signing certificate yet: set one up on the Certificate page before building.' }
}

function Clear-RecipeForm {
    $script:CurrentRecipe = $null
    $ui.RecipeList.SelectedItem = $null
    foreach ($n in 'TxtInstaller', 'TxtArguments', 'TxtPackageName', 'TxtDisplayName', 'TxtPublisherDisplay', 'TxtDescription', 'TxtInstallLocation') { $ui[$n].Text = '' }
    $ui.TxtVersion.Text = '1.0.0.0'
    $ui.RecipeEditorTitle.Text = 'New recipe'
    $ui.FrameworkBadge.Visibility = 'Collapsed'
    $ui.BtnRecipeDelete.IsEnabled = $false
    $ui.ModeSilent.IsChecked = $true
    Update-ModeView
}

function Test-ManualMode { [bool]$ui.ModeManual.IsChecked }

function Update-ModeView {
    # Manual: installer optional, no silent arguments, build buttons say "Record".
    $manual = Test-ManualMode
    $ui.ManualInfo.Visibility = if ($manual) { 'Visible' } else { 'Collapsed' }
    $ui.ArgumentsPanel.Visibility = if ($manual) { 'Collapsed' } else { 'Visible' }
    $ui.LblInstaller.Text = if ($manual) { 'Installer (optional: ready to run in the sandbox; leave empty to download or copy it yourself)' } else { 'Installer (.msi / .exe)' }
    $ui.BuildHint.Text = if ($manual) {
        'Saves the recipe and opens the MSIX Recorder in a sandbox. After Stop recording there, everything else runs by itself.'
    } else { 'Saves the recipe, then runs the steps unattended. Each sandbox closes by itself when it is done.' }
    $ui.BtnBuild.Content = if ($manual) { 'Record + sign' } else { 'Package + sign' }
    $ui.BtnBuildTest.Content = if ($manual) { 'Record + sign + test' } else { 'Package + sign + test' }
}
$ui.ModeSilent.Add_Checked({ Update-ModeView })
$ui.ModeManual.Add_Checked({ Update-ModeView })

function Show-Recipe($r) {
    $script:CurrentRecipe = $r
    if ($r.InstallMode -eq 'Manual') { $ui.ModeManual.IsChecked = $true } else { $ui.ModeSilent.IsChecked = $true }
    Update-ModeView
    $ui.TxtInstaller.Text = $r.Installer
    $ui.TxtArguments.Text = $r.Arguments
    $ui.TxtPackageName.Text = $r.PackageName
    $ui.TxtVersion.Text = $r.Version
    $ui.TxtDisplayName.Text = $r.DisplayName
    $ui.TxtPublisherDisplay.Text = $r.PublisherDisplayName
    $ui.TxtDescription.Text = $r.Description
    $ui.TxtInstallLocation.Text = $r.InstallLocation
    $ui.RecipeEditorTitle.Text = $r.DisplayName
    $ui.FrameworkBadge.Visibility = 'Collapsed'
    $ui.BtnRecipeDelete.IsEnabled = $true
}

function Set-InstallerFromFile([string]$Path) {
    $info = Get-MsixInstallerInfo -Path $Path
    $ui.TxtInstaller.Text = $info.Path
    # Fill only what is empty, so an edited recipe keeps its values.
    if (-not $ui.TxtDisplayName.Text) { $ui.TxtDisplayName.Text = $info.ProductName }
    if (-not $ui.TxtPackageName.Text) { $ui.TxtPackageName.Text = ConvertTo-MsixPackageName (($info.Manufacturer -split '\s')[0] + '.' + $info.ProductName) }
    if (-not $ui.TxtPublisherDisplay.Text) { $ui.TxtPublisherDisplay.Text = $info.Manufacturer }
    if (-not $script:CurrentRecipe -or $ui.TxtVersion.Text -eq '1.0.0.0') { $ui.TxtVersion.Text = $info.Version }
    if (-not $ui.TxtArguments.Text) { $ui.TxtArguments.Text = $info.SuggestedArguments }
    $ui.FrameworkText.Text = "$($info.Type) $Dot $($info.Framework)"
    $ui.FrameworkBadge.Visibility = 'Visible'
    if ($info.Type -eq 'EXE' -and -not $info.SuggestedArguments) {
        Add-LogLine ('{0:HH:mm:ss}  Setup framework not recognized: enter the silent arguments yourself.' -f (Get-Date)) 'Warning'
    }
}

function Get-RecipeForm {
    $manual = Test-ManualMode
    if ($ui.TxtInstaller.Text -and -not (Test-Path -LiteralPath $ui.TxtInstaller.Text)) { throw 'The installer file does not exist.' }
    if (-not $manual -and -not $ui.TxtInstaller.Text) { throw 'Choose an installer, or switch to manual recording.' }
    if (-not $ui.TxtPackageName.Text) { throw 'Package name is required.' }
    if (-not $ui.TxtDisplayName.Text) { throw 'Display name is required.' }
    if ($ui.TxtVersion.Text -notmatch '^\d+(\.\d+){0,3}$') { throw 'Version must look like 1.2.3.4.' }
    @{
        InstallerPath        = $ui.TxtInstaller.Text
        PackageName          = $ui.TxtPackageName.Text
        DisplayName          = $ui.TxtDisplayName.Text
        PublisherDisplayName = $ui.TxtPublisherDisplay.Text
        Version              = $ui.TxtVersion.Text
        Arguments            = $ui.TxtArguments.Text
        Description          = $ui.TxtDescription.Text
        InstallLocation      = $ui.TxtInstallLocation.Text
        InstallMode          = $(if ($manual) { 'Manual' } else { 'Silent' })
    }
}

$ui.RecipeList.Add_SelectionChanged({
    if ($ui.RecipeList.SelectedItem) { Show-Recipe $ui.RecipeList.SelectedItem.Tag }
})
Add-Click $ui.BtnRecipeNew { Clear-RecipeForm }
Add-Click $ui.BtnRecipeRefresh { Update-RecipeList }
Add-Click $ui.BtnRecipeBrowse {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Installers (*.msi;*.exe)|*.msi;*.exe|All files (*.*)|*.*'
    if ($dlg.ShowDialog($window)) { Set-InstallerFromFile $dlg.FileName }
}
Add-Click $ui.BtnRecipeSave {
    $form = Get-RecipeForm
    Start-UiTask -Title 'Saving recipe' -Arguments @{ R = $form } -Work { param($R) Save-MsixRecipe @R } -OnDone {
        param($result, $err)
        if (-not $err -and $result) { $script:CurrentRecipe = $result[-1]; Update-RecipeList }
    }
}
Add-Click $ui.BtnRecipeDelete {
    if (-not $script:CurrentRecipe) { return }
    $answer = [System.Windows.MessageBox]::Show($window, "Delete recipe '$($script:CurrentRecipe.DisplayName)' and its copy of the installer?", 'Delete recipe', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    Remove-MsixRecipe -Name $script:CurrentRecipe.PackageName
    Clear-RecipeForm
    Update-RecipeList
}

function Start-Build {
    param([ValidateSet('Package', 'Test', 'All')][string]$Mode)
    $form = Get-RecipeForm
    if (-not (Get-MsixCertificate)) { throw 'Set up a signing certificate first (Certificate page).' }
    if (Test-MsixSandboxRunning) { throw 'A Windows Sandbox is already open; close it first (Windows runs one at a time).' }
    $title = @{ Package = 'Packaging'; Test = 'Packaging and testing'; All = 'Running full pipeline' }[$Mode]
    $title = "$title $($form.DisplayName)"
    if ($form.InstallMode -eq 'Manual') { $title = "Recording $($form.DisplayName): Start recording in the sandbox, install, Stop recording" }
    Start-UiTask -Title $title -NeedsGraph:($Mode -eq 'All') -Arguments @{
        R = $form; Mode = $Mode; GroupId = $script:SelectedGroupId; Intent = (Get-Intent)
    } -Work {
        param($R, $Mode, $GroupId, $Intent)
        $recipe = Save-MsixRecipe @R
        if ($Mode -eq 'Package') { Invoke-MsixPackaging -RecipeName $recipe.PackageName }
        else { Invoke-MsixPipeline -RecipeName $recipe.PackageName -Publish:($Mode -eq 'All') -GroupId $GroupId -Intent $Intent }
    } -OnDone {
        param($result, $err)
        Update-RecipeList
        if ($err -or -not $result) { return }
        $r = $result[-1]
        if ($r.PackagePath) {
            Show-Page 'Packages'
            Select-Package $r.PackagePath
            if ($r.Test) { Show-TestResult $r.Test }
        }
    }
}
Add-Click $ui.BtnBuild { Start-Build 'Package' }
Add-Click $ui.BtnBuildTest { Start-Build 'Test' }
Add-Click $ui.BtnBuildAll { Start-Build 'All' }

# Drag & drop an installer or package onto the window
$window.Add_PreviewDragOver({ param($s, $e) $e.Effects = 'Copy'; $e.Handled = $true })
$window.Add_Drop({
    param($s, $e)
    try {
        $file = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))[0]
        if (-not $file) { return }
        switch ([IO.Path]::GetExtension($file).ToLower()) {
            { $_ -in '.msi', '.exe' } { Show-Page 'Recipes'; Clear-RecipeForm; Set-InstallerFromFile $file }
            '.msix' { Add-PackageFile $file }
            default { Show-Error 'Drop an .msi or .exe (new recipe) or an .msix (packages).' }
        }
    }
    catch { Show-Error $_.Exception.Message }
})

# ---------------------------------------------------------------- packages
$script:Shots = @()
$script:ShotIndex = 0
$script:LastTestJob = $null

function Update-PackageList {
    $selected = if ($ui.PackageList.SelectedItem) { $ui.PackageList.SelectedItem.Tag.Path } else { $null }
    $ui.PackageList.Items.Clear()
    foreach ($f in Get-ChildItem (Get-MsixWorkspace).Output -Filter '*.msix' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) {
        try { $p = Get-MsixPackageInfo -Path $f.FullName } catch { continue }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $badge = if ($p.IsSigned) { 'SIGNED' } else { 'UNSIGNED' }
        $item.Content = New-ListItemContent $p.DisplayName ("{0}  $Dot  {1}  $Dot  {2:N1} MB" -f $p.Version, $p.Architecture, ($p.SizeBytes / 1MB)) $badge $(if ($p.IsSigned) { 'Ok' } else { 'Warn' })
        $item.Tag = $p
        [void]$ui.PackageList.Items.Add($item)
        if ($p.Path -eq $selected) { $item.IsSelected = $true }
    }
    Update-PackageButtons
}

function Select-Package([string]$Path) {
    Update-PackageList
    foreach ($item in $ui.PackageList.Items) { if ($item.Tag.Path -eq $Path) { $item.IsSelected = $true } }
}

function Update-PackageButtons {
    $p = if ($ui.PackageList.SelectedItem) { $ui.PackageList.SelectedItem.Tag } else { $null }
    $idle = -not $script:Task
    $ui.BtnPkgTest.IsEnabled = $idle -and [bool]$p
    $ui.BtnPkgSign.IsEnabled = $idle -and [bool]$p
    $ui.BtnPkgPublish.IsEnabled = $idle -and [bool]$p -and $p.IsSigned
    if (-not $p) { $ui.PkgTitle.Text = 'Select a package'; $ui.PkgDetails.Text = ''; return }
    $ui.PkgTitle.Text = $p.DisplayName
    $ui.PkgDetails.Text = (@(
        "Identity   $($p.Name)"
        "Publisher  $($p.Publisher)"
        "Version    $($p.Version)  ($($p.Architecture))"
        "Apps       $(($p.Applications | ForEach-Object { "$($_.Id) -> $($_.Executable)" }) -join ', ')"
        "Signed     $($p.IsSigned)"
        "File       $($p.Path)"
    ) -join "`n")
}

function Add-PackageFile([string]$Path) {
    $target = Join-Path (Get-MsixWorkspace).Output (Split-Path $Path -Leaf)
    if ($Path -ne $target) { Copy-Item -LiteralPath $Path -Destination $target -Force }
    Show-Page 'Packages'
    Select-Package $target
}

function Show-TestResult($t) {
    $ui.TestCard.Visibility = 'Visible'
    $ok = $t.State -eq 'Succeeded'
    $ui.TestIcon.Text = if ($ok) { [char]0xE73E } else { [char]0xE783 }
    $ui.TestIcon.Foreground = if ($ok) { Get-Brush 'Ok' } else { Get-Brush 'Bad' }
    $ui.TestMessage.Text = $t.Message
    $script:Shots = @($t.Screenshots)
    $script:ShotIndex = 0
    $script:LastTestJob = $t.JobPath
    Show-Shot
}

function Show-Shot {
    if (-not $script:Shots.Count) { $ui.TestShot.Source = $null; $ui.TestShotLabel.Text = 'no screenshot'; return }
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = 'OnLoad'   # do not keep the file locked
    $bmp.UriSource = New-Object Uri $script:Shots[$script:ShotIndex]
    $bmp.EndInit()
    $ui.TestShot.Source = $bmp
    $ui.TestShotLabel.Text = '{0} / {1}  {2}' -f ($script:ShotIndex + 1), $script:Shots.Count, (Split-Path $script:Shots[$script:ShotIndex] -Leaf)
}

$ui.PackageList.Add_SelectionChanged({ Update-PackageButtons })
Add-Click $ui.BtnPkgRefresh { Update-PackageList }
Add-Click $ui.BtnPkgFolder { Start-Process explorer.exe (Get-MsixWorkspace).Output }
Add-Click $ui.BtnPkgAdd {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'MSIX packages (*.msix)|*.msix'
    if ($dlg.ShowDialog($window)) { Add-PackageFile $dlg.FileName }
}
Add-Click $ui.BtnPkgTest {
    $p = $ui.PackageList.SelectedItem.Tag
    if (Test-MsixSandboxRunning) { throw 'A Windows Sandbox is already open; close it first.' }
    Start-UiTask -Title "Testing $($p.DisplayName)" -Arguments @{ Path = $p.Path } -Work { param($Path) Test-MsixPackage -Path $Path } -OnDone {
        param($result, $err)
        if (-not $err -and $result) { Show-TestResult $result[-1] }
    }
}
Add-Click $ui.BtnPkgSign {
    $p = $ui.PackageList.SelectedItem.Tag
    Start-UiTask -Title "Signing $($p.DisplayName)" -Arguments @{ Path = $p.Path } -Work { param($Path) Invoke-MsixSigning -Path $Path | Out-Null } -OnDone { Update-PackageList }
}
Add-Click $ui.BtnPkgPublish {
    $p = $ui.PackageList.SelectedItem.Tag
    $target = if ($script:SelectedGroupId) { "and assign it ($(Get-Intent)) to '$($ui.SelectedGroup.Text)'" } else { 'without assignment' }
    $answer = [System.Windows.MessageBox]::Show($window, "Upload $($p.DisplayName) $($p.Version) to Intune $target?", 'Publish to Intune', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Start-UiTask -Title "Publishing $($p.DisplayName)" -NeedsGraph -Arguments @{ Path = $p.Path; GroupId = $script:SelectedGroupId; Intent = (Get-Intent) } -Work {
        param($Path, $GroupId, $Intent) Publish-MsixToIntune -Path $Path -GroupId $GroupId -Intent $Intent | Out-Null
    }
}
Add-Click $ui.BtnTestPrevShot { if ($script:Shots.Count) { $script:ShotIndex = ($script:ShotIndex - 1 + $script:Shots.Count) % $script:Shots.Count; Show-Shot } }
Add-Click $ui.BtnTestNextShot { if ($script:Shots.Count) { $script:ShotIndex = ($script:ShotIndex + 1) % $script:Shots.Count; Show-Shot } }
Add-Click $ui.BtnTestJob { if ($script:LastTestJob) { Start-Process explorer.exe $script:LastTestJob } }

# ---------------------------------------------------------------- certificate
function Update-CertificateView {
    $c = Get-MsixCertificate
    if (-not $c) {
        $ui.CertSubject.Text = 'No certificate'
        $ui.CertDetails.Text = 'Create a self-signed certificate, import a PFX or fetch one from Azure Key Vault.'
        $ui.BtnCertIntune.IsEnabled = $false
    }
    else {
        $ui.CertSubject.Text = $c.Subject
        $state = if ($c.IsExpired) { 'EXPIRED' } else { 'valid' }
        $ui.CertDetails.Text = "Thumbprint  $($c.Thumbprint)`nValid until $($c.NotAfter.ToString('d'))  ($state)`nPFX         $($c.PfxPath)`nPassword    $(if ($c.HasPassword) { 'stored (DPAPI)' } else { 'missing - import again' })"
        $ui.BtnCertIntune.IsEnabled = -not $script:Task
    }
    $s = Get-MsixSettings
    if (-not $ui.TxtKvVault.Text) { $ui.TxtKvVault.Text = $s.KeyVaultName }
    if (-not $ui.TxtKvCert.Text) { $ui.TxtKvCert.Text = $s.KeyVaultCertName }
}

Add-Click $ui.BtnCertCreate {
    if ($ui.TxtCertSubject.Text -notmatch '^CN=.+') { throw 'Subject must start with CN=, e.g. CN=Contoso Packaging.' }
    if (-not $ui.PwdCertNew.Password) { throw 'Enter a password for the PFX.' }
    if ($ui.PwdCertNew.Password -ne $ui.PwdCertNew2.Password) { throw 'The passwords do not match.' }
    if (Get-MsixCertificate) {
        $answer = [System.Windows.MessageBox]::Show($window, 'Replace the current signing certificate? Packages signed with the old one stay valid, but new packages get a new publisher.', 'New certificate', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    New-MsixCertificate -Subject $ui.TxtCertSubject.Text -Password $ui.PwdCertNew.SecurePassword -Years ([int]$ui.TxtCertYears.Text) | Out-Null
    $ui.PwdCertNew.Clear(); $ui.PwdCertNew2.Clear()
    Update-CertificateView
}
Add-Click $ui.BtnCertBrowse {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'PFX (*.pfx;*.p12)|*.pfx;*.p12'
    if ($dlg.ShowDialog($window)) { $ui.TxtCertPfx.Text = $dlg.FileName }
}
Add-Click $ui.BtnCertImport {
    if (-not (Test-Path -LiteralPath $ui.TxtCertPfx.Text)) { throw 'Choose a PFX file.' }
    Import-MsixCertificate -PfxPath $ui.TxtCertPfx.Text -Password $ui.PwdCertImport.SecurePassword | Out-Null
    $ui.PwdCertImport.Clear()
    Update-CertificateView
}
Add-Click $ui.BtnCertKv {
    if (-not $ui.TxtKvVault.Text -or -not $ui.TxtKvCert.Text) { throw 'Enter vault and certificate name.' }
    if (-not $ui.PwdKv.Password) { throw 'Enter a password for the local PFX copy.' }
    # Runs on the UI thread: Connect-AzAccount may need an interactive sign-in.
    $window.Cursor = 'Wait'
    try { Import-MsixCertificateFromKeyVault -VaultName $ui.TxtKvVault.Text -CertificateName $ui.TxtKvCert.Text -Password $ui.PwdKv.SecurePassword | Out-Null }
    finally { $window.Cursor = $null }
    $ui.PwdKv.Clear()
    Update-CertificateView
}
Add-Click $ui.BtnCertFolder { Start-Process explorer.exe (Get-MsixWorkspace).Certificates }
Add-Click $ui.BtnCertIntune {
    $target = if ($script:SelectedGroupId) { "and assign it to '$($ui.SelectedGroup.Text)'" } else { 'without assignment' }
    $answer = [System.Windows.MessageBox]::Show($window, "Create an Intune trusted certificate profile for $((Get-MsixCertificate).Subject) $target?", 'Trust via Intune', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Start-UiTask -Title 'Creating certificate profile' -NeedsGraph -Arguments @{ GroupId = $script:SelectedGroupId } -Work {
        param($GroupId) Publish-MsixCertificateToIntune -GroupId $GroupId | Out-Null
    }
}

# ---------------------------------------------------------------- intune
$script:SelectedGroupId = $null
function Get-Intent { if ($ui.IntentAvailable.IsChecked) { 'available' } else { 'required' } }

function Update-IntuneView {
    $c = Get-MsixIntuneContext
    $ui.IntuneAccount.Text = if ($c) { $c.Account } else { 'Not signed in' }
    $ui.IntuneTenant.Text = if ($c) { "Tenant $($c.TenantId)" } else { 'Sign in to publish apps and the certificate profile.' }
    $ui.BtnIntuneSignIn.Visibility = if ($c) { 'Collapsed' } else { 'Visible' }
    $ui.TxtTenant.Visibility = if ($c) { 'Collapsed' } else { 'Visible' }
    $ui.BtnIntuneSignOut.Visibility = if ($c) { 'Visible' } else { 'Collapsed' }
}
Add-Click $ui.BtnIntuneSignIn {
    $window.Cursor = 'Wait'
    try { Connect-MsixIntune -TenantId $ui.TxtTenant.Text.Trim() | Out-Null }
    finally { $window.Cursor = $null }
    Update-IntuneView
}
Add-Click $ui.BtnIntuneSignOut { Disconnect-MsixIntune; Update-IntuneView }
Add-Click $ui.BtnGroupSearch {
    if (-not (Get-MsixIntuneContext)) { throw 'Sign in first.' }
    if (-not $ui.TxtGroupSearch.Text.Trim()) { throw 'Enter the beginning of a group name.' }
    $ui.GroupList.Items.Clear()
    foreach ($g in Find-MsixIntuneGroup -Search $ui.TxtGroupSearch.Text.Trim()) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = New-ListItemContent $g.DisplayName $g.Id ''
        $item.Tag = $g
        [void]$ui.GroupList.Items.Add($item)
    }
    if (-not $ui.GroupList.Items.Count) { Add-LogLine ('{0:HH:mm:ss}  No group found.' -f (Get-Date)) 'Warning' }
}
$ui.GroupList.Add_SelectionChanged({
    if ($ui.GroupList.SelectedItem) {
        $script:SelectedGroupId = $ui.GroupList.SelectedItem.Tag.Id
        $ui.SelectedGroup.Text = $ui.GroupList.SelectedItem.Tag.DisplayName
    }
})
Add-Click $ui.BtnGroupClear { $script:SelectedGroupId = $null; $ui.SelectedGroup.Text = 'none'; $ui.GroupList.SelectedItem = $null }

# ---------------------------------------------------------------- settings
function Update-SettingsView {
    $s = Get-MsixSettings
    $ui.SetWorkspace.Text = $s.WorkspacePath
    $ui.SetMemory.Text = $s.SandboxMemoryMB
    $ui.SetTestSeconds.Text = $s.TestDurationSeconds
    $ui.SetTimeout.Text = $s.JobTimeoutMinutes
    $ui.SetTimestamp.Text = $s.TimestampUrl
    $ui.SetVGpu.IsChecked = [bool]$s.SandboxVGpu
    $ui.SetNetworking.IsChecked = [bool]$s.PackageNetworking
    $t = Get-MsixToolchain
    $ui.ToolchainDetails.Text = if ($t) {
        "MSIX Packaging Tool  $($t.Version)`nSDK build tools      $($t.SdkToolsVersion)`nDownloaded           $($t.Downloaded.ToString('g'))`nComplete             $($t.IsComplete)"
    } else { 'Not downloaded yet. It is fetched automatically before the first sandbox run.' }
}
Add-Click $ui.BtnSettingsSave {
    foreach ($n in 'SetMemory', 'SetTestSeconds', 'SetTimeout') { if ($ui[$n].Text -notmatch '^\d+$') { throw 'Memory, run time and timeout must be numbers.' } }
    if ([int]$ui.SetMemory.Text -lt 2048) { throw 'Give the sandbox at least 2048 MB.' }
    Set-MsixSettings @{
        WorkspacePath       = $ui.SetWorkspace.Text.Trim()
        SandboxMemoryMB     = [int]$ui.SetMemory.Text
        TestDurationSeconds = [int]$ui.SetTestSeconds.Text
        JobTimeoutMinutes   = [int]$ui.SetTimeout.Text
        TimestampUrl        = $ui.SetTimestamp.Text.Trim()
        SandboxVGpu         = [bool]$ui.SetVGpu.IsChecked
        PackageNetworking   = [bool]$ui.SetNetworking.IsChecked
    } | Out-Null
    Add-LogLine ('{0:HH:mm:ss}  Settings saved.' -f (Get-Date)) 'Success'
}
Add-Click $ui.BtnToolchainUpdate { Invoke-ToolchainUpdate $false }
Add-Click $ui.BtnToolchainForce { Invoke-ToolchainUpdate $true }
Add-Click $ui.BtnToolchainFolder { Start-Process explorer.exe (Get-MsixWorkspace).Toolchain }

# ---------------------------------------------------------------- log panel
Add-Click $ui.BtnLogClear { $ui.LogList.Items.Clear() }
Add-Click $ui.BtnLogToggle {
    $hidden = $ui.LogList.Visibility -eq 'Visible'
    $ui.LogList.Visibility = if ($hidden) { 'Collapsed' } else { 'Visible' }
    $ui.BtnLogToggle.Content = if ($hidden) { 'Show' } else { 'Hide' }
}

# ---------------------------------------------------------------- run
$window.Add_Closing({
    param($s, $e)
    if ($script:Task) {
        $answer = [System.Windows.MessageBox]::Show($window, "'$($script:Task.Title)' is still running. Close anyway? A running sandbox keeps running.", 'MSIX Sandbox Studio', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $e.Cancel = $true }
    }
})
$window.Add_Closed({ $timer.Stop(); [System.Windows.Application]::Current.Shutdown() })

Add-LogLine ('{0:HH:mm:ss}  Workspace: {1}' -f (Get-Date), (Get-MsixWorkspace).Root)
Show-Page 'Dashboard'
Clear-RecipeForm
$timer.Start()
# Test hook: MSIXSTUDIO_SMOKE names a script that drives the window off-screen and renders every page.
if ($env:MSIXSTUDIO_SMOKE) { . $env:MSIXSTUDIO_SMOKE }
$window.Show()
[void][System.Windows.Application]::Current.Run()
