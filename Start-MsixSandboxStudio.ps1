<#
.SYNOPSIS
    MSIX Sandbox Studio - GUI for the MsixSandboxStudio module.
.DESCRIPTION
    Look and window technique of the M365 MFA Administration tool: shared UI\Theme.xaml, slate header with
    connection state, Start.cmd starts the console hidden; interactive sign-ins show the console centered over
    the tool only while signing in, so the Microsoft sign-in dialog is always in front (no second window).
    Long-running work (downloads, sandbox jobs, uploads) runs in a background runspace; its log lines are
    queued and shown live in the activity panel, so the window never freezes.
.PARAMETER HideConsole
    Set by Start.cmd: hides the console window of this process.
#>
[CmdletBinding()]
param([switch]$HideConsole)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$script:AppRoot    = $PSScriptRoot
$script:ModulePath = Join-Path $PSScriptRoot 'MsixSandboxStudio\MsixSandboxStudio.psd1'
Import-Module $script:ModulePath -Force

# ---------------------------------------------------------------- console window (M365 MFA tool technique)
if (-not ('MsixStudio.NativeWindow' -as [type])) {
    Add-Type -Namespace MsixStudio -Name NativeWindow -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
}

function Hide-ConsoleWindow {
    # The console is looked up again each time: Windows Terminal may take it over when it becomes visible.
    param([IntPtr]$Window = [IntPtr]::Zero)
    $native = [MsixStudio.NativeWindow]
    if ($Window -ne [IntPtr]::Zero) { [void]$native::ShowWindow($Window, 0) }
    # GA_ROOTOWNER (3): with Windows Terminal, the console window is a hidden pseudo window owned by the terminal.
    $current = $native::GetAncestor($native::GetConsoleWindow(), 3)
    if ($current -ne [IntPtr]::Zero -and $current -ne $Window) { [void]$native::ShowWindow($current, 0) }
}

function Invoke-InteractiveSignIn {
    <#
    The sign-in dialog (Web Account Manager) belongs to the console window. Windows hides windows whose owner
    is hidden, so the console is shown centered over the tool while signing in and hidden again afterwards;
    then the tool is activated again.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)
    $native = [MsixStudio.NativeWindow]
    $active = $native::GetForegroundWindow()
    $console = $native::GetAncestor($native::GetConsoleWindow(), 3)
    $state = if ($console -eq [IntPtr]::Zero) { 'None' }
             elseif ($native::IsIconic($console)) { 'Minimized' }
             elseif (-not $native::IsWindowVisible($console)) { 'Hidden' }
             else { 'Visible' }
    if ($state -in 'Minimized', 'Hidden') {
        [void]$native::ShowWindow($console, 9)   # SW_RESTORE
        $toolRect = New-Object MsixStudio.NativeWindow+RECT
        $consoleRect = New-Object MsixStudio.NativeWindow+RECT
        if ($active -ne [IntPtr]::Zero -and $native::GetWindowRect($active, [ref]$toolRect) -and $native::GetWindowRect($console, [ref]$consoleRect)) {
            $x = [int](($toolRect.Left + $toolRect.Right - ($consoleRect.Right - $consoleRect.Left)) / 2)
            $y = [int](($toolRect.Top + $toolRect.Bottom - ($consoleRect.Bottom - $consoleRect.Top)) / 2)
            [void]$native::SetWindowPos($console, [IntPtr]::Zero, $x, $y, 0, 0, 0x0001 -bor 0x0004)   # SWP_NOSIZE | SWP_NOZORDER
        }
    }
    if ($state -ne 'None') { [void]$native::SetForegroundWindow($console) }
    try { & $Action }
    finally {
        switch ($state) {
            'Minimized' { [void]$native::ShowWindow($console, 6) }   # SW_MINIMIZE
            'Hidden'    { Hide-ConsoleWindow -Window $console }
        }
        if ($active -ne [IntPtr]::Zero) { [void]$native::SetForegroundWindow($active) }
    }
}

if ($HideConsole) { Hide-ConsoleWindow }

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
$script:Version = (Get-Module MsixSandboxStudio).Version.ToString()
$window.Title = "MSIX Sandbox Studio $script:Version"

$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$Key) { [System.Windows.Application]::Current.Resources[$Key] }
function ConvertTo-Brush([string]$Hex) { $script:BrushConverter.ConvertFrom($Hex) }
$Dot = [char]0x00B7   # separator in list items (kept out of the source: PS 5.1 reads BOM-less files as ANSI)

# ---------------------------------------------------------------- log (items as in the MFA tool: Line, Brush, Weight)
$script:LogBrushes = @{
    Info    = Get-Brush 'Text'
    Success = Get-Brush 'Success'
    Warning = ConvertTo-Brush '#B45309'
    Error   = Get-Brush 'Danger'
}
function Add-LogLine {
    param([string]$Text, [string]$Level = 'Info')
    $item = [pscustomobject]@{
        Line   = $Text
        Brush  = $script:LogBrushes[$Level]
        Weight = $(if ($Level -in 'Error', 'Success') { 'SemiBold' } else { 'Normal' })
    }
    [void]$ui.LogList.Items.Add($item)
    while ($ui.LogList.Items.Count -gt 800) { $ui.LogList.Items.RemoveAt(0) }
    $ui.LogList.ScrollIntoView($item)
}
Set-MsixLogSink { param($line, $level) Add-LogLine $line $level }
function Write-UiLog([string]$Text, [string]$Level = 'Info') { Add-LogLine ('{0:HH:mm:ss}  {1}' -f (Get-Date), $Text) $Level }

function Show-Error([string]$Message) {
    Write-UiLog $Message 'Error'
    [void][System.Windows.MessageBox]::Show($window, $Message, 'MSIX Sandbox Studio', 'OK', 'Error')
}

$script:ClickActions = @{}
function Add-Click {
    # Click handler with error handling: an exception shows a message instead of killing the window.
    # Actions are looked up by sender (no GetNewClosure: that would hide this script's functions and variables).
    param($Control, [scriptblock]$Action)
    $script:ClickActions[$Control] = $Action
    $Control.Add_Click({
        param($src)
        try { & $script:ClickActions[$src] } catch { Show-Error $_.Exception.Message }
    })
}

# ---------------------------------------------------------------- background tasks
$script:Task = $null

function Get-GraphAccessToken {
    # Hands the UI thread's Graph sign-in to a background runspace.
    if (-not (Get-MsixIntuneContext)) { return $null }
    Update-MsixIntuneToken   # a Keevault sign-in is renewed here before the token goes to the task
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
    if ($NeedsGraph -and -not $token) { Show-Error 'Sign in to Intune first (Sign in, top right).'; return }

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
    $ui.BusyPanel.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
    $ui.BusyText.Text = $Title
    foreach ($b in 'BtnBuild', 'BtnBuildTest', 'BtnBuildAll', 'BtnPkgTest', 'BtnPkgSign', 'BtnPkgPublish', 'BtnPkgUpdate', 'BtnDashSandbox', 'BtnDashRecord', 'BtnToolchainUpdate', 'BtnToolchainForce', 'BtnRecipeSave', 'BtnCertIntune',
            'BtnW32Test', 'BtnW32TestUpdate', 'BtnW32Build', 'BtnW32Save', 'BtnW32Generate', 'BtnW32Publish') {
        $ui[$b].IsEnabled = -not $on
    }
    if (-not $on) { Update-PackageButtons }
}

function Complete-UiTask {
    $t = $script:Task
    $item = $null
    while ($t.Queue.TryDequeue([ref]$item)) { Add-LogLine $item[0] $item[1] }
    $result = $null; $err = $null
    try { $result = @($t.PS.EndInvoke($t.Handle)) }
    catch { $err = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message } }
    foreach ($e in $t.PS.Streams.Error) { Write-UiLog $e.ToString() 'Warning' }
    $t.PS.Dispose(); $t.Runspace.Dispose()
    $script:Task = $null
    Set-Busy ''
    if ($err) { Write-UiLog "$($t.Title) failed: $err" 'Error' }
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
        if ($script:Task.Handle.IsCompleted) { Complete-UiTask }
    }
    if ($script:Tick % 15 -eq 0) { Update-SandboxState }
})

function Update-SandboxState {
    $ui.TxtSandboxState.Text = if (Test-MsixSandboxRunning) { 'Sandbox running' } else { 'Sandbox idle' }
}

function Update-ConnectionStatus {
    $c = Get-MsixIntuneContext
    if ($c -and $c.Account) {
        $ui.TxtConnectionStatus.Text = "Connected as $($c.Account)"
        $ui.TxtConnectionStatus.Foreground = ConvertTo-Brush '#86EFAC'
        $ui.TxtTenant.Text = "Tenant: $($c.TenantId)"
    }
    else {
        $ui.TxtConnectionStatus.Text = 'Not signed in to Intune'
        $ui.TxtConnectionStatus.Foreground = ConvertTo-Brush '#FCA5A5'
        $ui.TxtTenant.Text = 'Tenant: -'
    }
    # Only the button that applies is enabled (as in the MFA tool)
    $ui.BtnIntuneSignIn.IsEnabled = -not ($c -and $c.Account)
    $ui.BtnIntuneSignInMenu.IsEnabled = $ui.BtnIntuneSignIn.IsEnabled
    $ui.BtnIntuneSignOut.IsEnabled = [bool]($c -and $c.Account)
}

# ---------------------------------------------------------------- navigation + help
$pages = @('Dashboard', 'Recipes', 'Packages', 'Certificate', 'Win32Apps', 'Win32Builds', 'Intune', 'Settings')
$script:CurrentPage = 'Dashboard'
function Show-Page([string]$Name) {
    $script:CurrentPage = $Name
    foreach ($p in $pages) { $ui["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
    $ui["Nav$Name"].IsChecked = $true
    switch ($Name) {
        'Dashboard'   { Update-Dashboard }
        'Recipes'     { Update-RecipeList }
        'Packages'    { Update-PackageList }
        'Certificate' { Update-CertificateView }
        'Intune'      { Update-IntuneView }
        'Settings'    { Update-SettingsView }
        'Win32Apps'   { Update-Win32AppList }
        'Win32Builds' { Update-Win32BuildList }
    }
    if ($ui.HelpPanel.Visibility -eq 'Visible') { Show-Help }
}
foreach ($p in $pages) {
    $ui["Nav$p"].Add_Checked({
        param($src)
        $name = $src.Name -replace '^Nav', ''
        if ($ui["Page$name"].Visibility -ne 'Visible') { Show-Page $name }
    })
}

$script:HelpTexts = @{
    Dashboard   = @(
        @('What it does', 'MSIX Sandbox Studio turns installers into signed MSIX packages. Every run uses a fresh Windows Sandbox, so the capture is clean and nothing stays on this computer.'),
        @('Record installation', 'Opens the MSIX Recorder in a sandbox. It installs the MSIX Packaging Tool by itself. Click Start recording, install and configure the app, click Stop recording. Every click is documented with a screenshot and the screen is recorded.'),
        @('Recipes', 'For installers with a silent mode: one recipe per app, packaged unattended.'),
        @('Readiness', 'All tiles should be green before the first run. The toolchain downloads automatically when needed.'))
    Recipes     = @(
        @('Silent', 'The installer runs unattended with the silent arguments. The framework is detected when you choose the installer (Inno Setup, NSIS, WiX, InstallShield ...).'),
        @('Manual', 'Opens the MSIX Recorder: you install the app yourself while it records.'),
        @('Identity', 'Package name and version identify the app on devices. Each new version needs a higher version number.'))
    Packages    = @(
        @('Test', 'Installs the package in a clean sandbox without network, starts every app, takes screenshots and uninstalls it.'),
        @('Update', 'Restores this package in a sandbox (files, registry, Start menu entries) when the recording starts. Then run the app''s updater or the new setup; the new package contains everything.'),
        @('Documentation', 'HTML report next to the package: how it was made, every click with screenshot, the screen recording, the test result and the full file list.'))
    Certificate = @(
        @('Publisher', 'The certificate subject (e.g. CN=Contoso Packaging) is the publisher of every package; it must match exactly, otherwise signing fails.'),
        @('Trust', 'Devices must trust the certificate. With a self-signed one, click Trust via Intune once and assign the profile to the same devices as the apps.'))
    Intune      = @(
        @('Sign in', 'Sign in (top right) opens the Microsoft sign-in in front of this window. Needed rights: manage Intune apps and device configurations, read groups.'),
        @('Assignment', 'Choose a group and the intent before publishing; without a group the app is only uploaded.'))
    Win32Apps   = @(
        @('Design', 'Choose the installer: install, uninstall and detection scripts are generated from it and can be edited here. The update routine (Update.ps1) runs at the start of the installation, e.g. to remove an old version.'),
        @('Detection', 'Script: Detect.ps1 writes output and exits with 0 when the app is installed. Or use the MSI product code, a file/folder (optionally with minimum version) or a registry value.'),
        @('Test in sandbox', 'Opens the Win32 Test Lab: Install, Detect, Uninstall, Detect with one click each, as SYSTEM like Intune. Check the app in between, fix scripts in the sandbox (they come back into the project), then report success or failure.'),
        @('Test update', 'Choose a previous build: the lab installs it first, then the new version over it, so the update path is tested exactly.'))
    Win32Builds = @(
        @('Build', 'Each build contains the .intunewin, the parameter file intune-app.json (all Intune settings) and the documentation with the test protocol.'),
        @('Publish', 'The wizard uploads the app, sets the previous version it supersedes (Update: install over it; Replace: uninstall it first) and the assignment.'))
    Settings    = @(
        @('Toolchain', 'MSIX Packaging Tool, its driver and the Windows SDK signing tools are cached on this computer and mapped read-only into every sandbox.'),
        @('Network', 'Packaging and recording sandboxes get network access when enabled (web installers). Test sandboxes never have network.'))
}
function Show-Help {
    $ui.HelpTitle.Text = "Help: $script:CurrentPage"
    $ui.HelpBody.Children.Clear()
    foreach ($entry in $script:HelpTexts[$script:CurrentPage]) {
        $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $entry[0]; $l.Style = $window.FindResource('HelpLabel')
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = $entry[1]; $t.Style = $window.FindResource('HelpText')
        [void]$ui.HelpBody.Children.Add($l); [void]$ui.HelpBody.Children.Add($t)
    }
    $ui.HelpPanel.Visibility = 'Visible'
}
Add-Click $ui.BtnHelp { if ($ui.HelpPanel.Visibility -eq 'Visible') { $ui.HelpPanel.Visibility = 'Collapsed' } else { Show-Help } }
Add-Click $ui.BtnHelpClose { $ui.HelpPanel.Visibility = 'Collapsed' }
Add-Click $ui.BtnHeaderSettings { Show-Page 'Settings' }

# ---------------------------------------------------------------- dashboard
function New-ReadinessCard {
    param([string]$Glyph, [string]$Title, [ValidateSet('ok', 'warn', 'bad')][string]$State, [string]$Text, [string]$ActionText, [scriptblock]$Action)
    # One compact row: icon | title + state text | action button | state dot
    $color = @{ ok = Get-Brush 'Success'; warn = ConvertTo-Brush '#B45309'; bad = Get-Brush 'Danger' }[$State]
    $border = New-Object System.Windows.Controls.Border
    $border.BorderBrush = ConvertTo-Brush '#EEF1F4'; $border.BorderThickness = '0,0,0,1'; $border.Padding = '0,7'
    $row = New-Object System.Windows.Controls.DockPanel
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 10; $dot.Height = 10; $dot.Fill = $color; $dot.VerticalAlignment = 'Center'; $dot.Margin = '10,0,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($dot, 'Right')
    [void]$row.Children.Add($dot)
    if ($ActionText) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $ActionText; $b.Style = $window.FindResource('SmallButton')
        [System.Windows.Controls.DockPanel]::SetDock($b, 'Right')
        Add-Click $b $Action
        [void]$row.Children.Add($b)
    }
    $ico = New-Object System.Windows.Controls.TextBlock
    $ico.Text = $Glyph; $ico.Style = $window.FindResource('Glyph'); $ico.Foreground = Get-Brush 'Primary'; $ico.VerticalAlignment = 'Center'
    [void]$row.Children.Add($ico)
    $sp = New-Object System.Windows.Controls.StackPanel
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Title; $t.FontWeight = 'SemiBold'
    $d = New-Object System.Windows.Controls.TextBlock
    $d.Text = $Text; $d.Style = $window.FindResource('Hint'); $d.TextWrapping = 'NoWrap'; $d.TextTrimming = 'CharacterEllipsis'; $d.ToolTip = $Text
    [void]$sp.Children.Add($t); [void]$sp.Children.Add($d)
    [void]$row.Children.Add($sp)
    $border.Child = $row
    $border
}

function Update-Dashboard {
    $s = Get-MsixHostStatus
    $c = Get-MsixIntuneContext
    $ui.ReadinessGrid.Children.Clear()
    $cards = @(
        @{ Glyph = [char]0xE7F4; Title = 'Windows Sandbox'
           State = $(if ($s.SandboxEnabled) { 'ok' } else { 'bad' })
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
           State = $(if ($s.CertificateReady) { 'ok' } else { 'warn' })
           Text = $(if ($s.CertificateReady) { "$($s.Certificate.Subject), valid until $($s.Certificate.NotAfter.ToString('d'))" } elseif ($s.Certificate -and $s.Certificate.IsExpired) { 'Expired' } else { 'None configured' })
           ActionText = $(if (-not $s.CertificateReady) { 'Set up' })
           Action = { Show-Page 'Certificate' } }
        @{ Glyph = [char]0xE753; Title = 'Microsoft Graph'
           State = $(if ($s.GraphModule) { 'ok' } else { 'warn' })
           Text = $(if ($s.GraphModule) { 'Module installed, Intune publishing available' } else { 'Install Microsoft.Graph.Authentication for Intune' }) }
        @{ Glyph = [char]0xE77B; Title = 'Intune session'
           State = $(if ($c -and $c.Account) { 'ok' } else { 'warn' })
           Text = $(if ($c -and $c.Account) { $c.Account } else { 'Not signed in' })
           ActionText = $(if (-not ($c -and $c.Account)) { 'Sign in' })
           Action = { Connect-Intune } }
    )
    if ($script:Mode -eq 'Win32') { $cards = @($cards | Where-Object { $_.Title -notin 'Toolchain', 'Signing certificate' }) }
    foreach ($card in $cards) { [void]$ui.ReadinessGrid.Children.Add((New-ReadinessCard @card)) }
    $ui.ReadinessGrid.Children[$ui.ReadinessGrid.Children.Count - 1].BorderThickness = '0'
    if ($script:Mode -eq 'Win32') {
        $ui.StatLabel1.Text = 'Win32 apps'; $ui.StatRecipes.Text = @(Get-Win32AppProject).Count
        $ui.StatLabel2.Text = 'Built .intunewin packages'; $ui.StatPackages.Text = @(Get-Win32AppBuild).Count
    }
    else {
        $ui.StatLabel1.Text = 'Recipes'; $ui.StatRecipes.Text = @(Get-MsixRecipe).Count
        $ui.StatLabel2.Text = 'Packages in output'; $ui.StatPackages.Text = @(Get-ChildItem (Get-MsixWorkspace).Output -Filter '*.msix' -ErrorAction SilentlyContinue).Count
    }
    Update-SandboxState
    Update-ConnectionStatus
}

function Invoke-ToolchainUpdate([bool]$Force) {
    Start-UiTask -Title 'Updating toolchain' -Arguments @{ Force = $Force } -Work {
        param($Force) Update-MsixToolchain -Force:$Force | Out-Null
    } -OnDone { Update-SettingsView }
}

function Assert-ReadyForSandbox {
    if (-not (Get-MsixCertificate)) { throw 'Set up a signing certificate first (Certificate tab).' }
    if (Test-MsixSandboxRunning) { throw 'A Windows Sandbox is already open; close it first (Windows runs one at a time).' }
}

function Start-Recording {
    # Opens the MSIX Recorder; afterwards the package (and its documentation) is shown on the Packages tab.
    param([hashtable]$Parameters, [string]$Title)
    Start-UiTask -Title $Title -Arguments @{ P = $Parameters } -Work {
        param($P) Start-MsixRecording @P
    } -OnDone {
        param($result, $err)
        Update-RecipeList
        if ($err -or -not $result) { return }
        $r = $result[-1]
        if ($r.PackagePath) { Show-Page 'Packages'; Select-Package $r.PackagePath }
    }
}

function Show-RecordDialog {
    <#
    Asked before every recording: starting point (clean, existing MSIX, existing Win32 app) and the installer
    that runs during the recording. Returns the parameters for Start-MsixRecording, or $null when cancelled.
    #>
    param([string]$BasePackage)
    [xml]$x = Get-Content (Join-Path $PSScriptRoot 'UI\RecordWindow.xaml') -Raw -Encoding UTF8
    $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
    $dlg.Owner = $window
    $d = @{}
    foreach ($n in 'RbBaseNone', 'RbBaseMsix', 'RbBaseWin32', 'PanelBaseMsix', 'PanelBaseWin32', 'TxtBaseMsix', 'TxtBaseWin32', 'TxtBaseWin32Command',
            'TxtBaseWin32Hint', 'BtnBaseMsixBrowse', 'BtnBaseWin32Browse', 'TxtInstallerHeader', 'TxtInstaller', 'BtnInstallerBrowse', 'BtnInstallerClear',
            'ChkAutoStart', 'TxtInstallerHint', 'BtnRecordStart', 'BtnRecordCancel') { $d[$n] = $dlg.FindName($n) }
    $script:RecordResult = $null

    $update = {
        $hasBase = -not $d.RbBaseNone.IsChecked
        $d.PanelBaseMsix.IsEnabled = [bool]$d.RbBaseMsix.IsChecked
        $d.PanelBaseWin32.IsEnabled = [bool]$d.RbBaseWin32.IsChecked
        $d.TxtInstallerHeader.Text = if ($hasBase) { '2. Update to install' } else { '2. Installer to record' }
        $d.TxtInstallerHint.Text = if ($hasBase) { "Leave empty to start the app's own updater in the sandbox, or download the new setup there." }
                                   else { 'Leave empty to download the installer in the sandbox or paste it from the host.' }
        $d.ChkAutoStart.IsEnabled = [bool]$d.TxtInstaller.Text
    }
    $pick = {
        param([string]$Title, [string]$Filter)
        $f = New-Object Microsoft.Win32.OpenFileDialog
        $f.Title = $Title; $f.Filter = $Filter
        if ($f.ShowDialog($dlg)) { $f.FileName }
    }
    foreach ($rb in $d.RbBaseNone, $d.RbBaseMsix, $d.RbBaseWin32) { $rb.Add_Checked({ & $update }) }
    $d.BtnBaseMsixBrowse.Add_Click({
        $file = & $pick 'Existing MSIX package (starting point)' 'MSIX packages (*.msix)|*.msix'
        if ($file) { $d.TxtBaseMsix.Text = $file }
    })
    $d.BtnBaseWin32Browse.Add_Click({
        $file = & $pick 'Existing Win32 app (starting point)' 'Win32 apps (*.intunewin)|*.intunewin'
        if (-not $file) { return }
        try {
            $info = Get-IntuneWinInstallInfo -Path $file
            $d.TxtBaseWin32.Text = $file
            $d.TxtBaseWin32Command.Text = $info.Command
            $d.TxtBaseWin32Hint.Text = if ($info.FromParameterFile) { "Command from intune-app.json ($($info.Name) $($info.Version))." }
                                       else { "Derived from the setup file $($info.SetupFile): check the arguments (silent install)." }
        }
        catch { Show-Error $_.Exception.Message }
    })
    $d.BtnInstallerBrowse.Add_Click({
        $file = & $pick 'Installer to run during the recording' 'Installers (*.msi;*.exe)|*.msi;*.exe|All files (*.*)|*.*'
        if ($file) { $d.TxtInstaller.Text = $file; & $update }
    })
    $d.BtnInstallerClear.Add_Click({ $d.TxtInstaller.Text = ''; & $update })
    $d.BtnRecordCancel.Add_Click({ $dlg.Close() })
    $d.BtnRecordStart.Add_Click({
        $p = @{ AutoStart = [bool]$d.ChkAutoStart.IsChecked }
        if ($d.RbBaseMsix.IsChecked) {
            if (-not $d.TxtBaseMsix.Text) { Show-Error 'Choose the MSIX package to start from.'; return }
            $p.BasePackage = $d.TxtBaseMsix.Text
        }
        if ($d.RbBaseWin32.IsChecked) {
            if (-not $d.TxtBaseWin32.Text) { Show-Error 'Choose the .intunewin to start from.'; return }
            if (-not $d.TxtBaseWin32Command.Text.Trim()) { Show-Error 'Enter the install command of the Win32 app.'; return }
            $p.BaseIntuneWin = $d.TxtBaseWin32.Text
            $p.BaseInstallCommand = $d.TxtBaseWin32Command.Text.Trim()
        }
        if ($d.TxtInstaller.Text) {
            $p.InstallerPath = $d.TxtInstaller.Text
            # Identity from the installer only for a new package (an MSIX base brings its own)
            if (-not $p.BasePackage) {
                $info = Get-MsixInstallerInfo -Path $p.InstallerPath
                if ($info.ProductName) {
                    $p.DisplayName = $info.ProductName
                    $p.PackageName = ConvertTo-MsixPackageName (($info.Manufacturer -split '\s')[0] + '.' + $info.ProductName)
                    $p.PublisherDisplayName = $info.Manufacturer
                }
                if ($info.Version) { $p.Version = $info.Version }
            }
        }
        $script:RecordResult = $p
        $dlg.Close()
    })

    if ($BasePackage) { $d.TxtBaseMsix.Text = $BasePackage; $d.RbBaseMsix.IsChecked = $true }
    & $update
    [void]$dlg.ShowDialog()
    $script:RecordResult
}

Add-Click $ui.BtnDashNewRecipe { Show-Page 'Recipes'; Clear-RecipeForm }
Add-Click $ui.BtnDashRecord {
    Assert-ReadyForSandbox
    $p = Show-RecordDialog
    if (-not $p) { return }
    $title = if ($p.BasePackage -or $p.BaseIntuneWin) { 'Recording an update: Start recording in the sandbox, the starting point is installed, then the update' }
             else { 'Recording: Start recording in the sandbox, install the app, Stop recording' }
    Start-Recording -Parameters $p -Title $title
}
Add-Click $ui.BtnDashSandbox {
    if (Test-MsixSandboxRunning) { throw 'A Windows Sandbox is already open; Windows runs one at a time.' }
    Start-UiTask -Title 'Starting interactive sandbox' -Work { Start-MsixSandbox | Out-Null }
}

# ---------------------------------------------------------------- recipes
$script:CurrentRecipe = $null

function New-ListItemContent([string]$Title, [string]$Sub, [string]$Badge, [ValidateSet('blue', 'green', 'yellow')][string]$BadgeColor = 'blue') {
    $colors = @{ blue = @('#DBEAFE', '#1E40AF'); green = @('#DCFCE7', '#166534'); yellow = @('#FEF3C7', '#92400E') }[$BadgeColor]
    $grid = New-Object System.Windows.Controls.DockPanel
    if ($Badge) {
        $bd = New-Object System.Windows.Controls.Border
        $bd.CornerRadius = 10; $bd.Padding = '9,2'; $bd.VerticalAlignment = 'Top'; $bd.Background = ConvertTo-Brush $colors[0]
        $bt = New-Object System.Windows.Controls.TextBlock; $bt.Text = $Badge; $bt.FontSize = 11; $bt.FontWeight = 'SemiBold'; $bt.Foreground = ConvertTo-Brush $colors[1]
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
        $manual = $r.InstallMode -eq 'Manual'
        $badge = if ($manual) { 'RECORDED' } else { [IO.Path]::GetExtension($r.Installer).TrimStart('.').ToUpper() }
        $item.Content = New-ListItemContent $r.DisplayName "$($r.PackageName)  $Dot  $($r.Version)" $badge $(if ($manual) { 'yellow' } else { 'blue' })
        $item.Tag = $r
        [void]$ui.RecipeList.Items.Add($item)
        if ($r.PackageName -eq $selected) { $item.IsSelected = $true }
    }
    Update-PublisherHint
}

function Update-PublisherHint {
    $cert = Get-MsixCertificate
    $ui.TxtPublisherHint.Text = if ($cert) { "Publisher: $($cert.Subject) (from the signing certificate)" } else { 'No signing certificate yet: set one up on the Certificate tab before building.' }
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
    if ($info.Type -eq 'EXE' -and -not $info.SuggestedArguments -and -not (Test-ManualMode)) {
        Write-UiLog 'Setup framework not recognized: enter the silent arguments yourself, or record the installation manually.' 'Warning'
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
    Assert-ReadyForSandbox
    $title = "$(@{ Package = 'Packaging'; Test = 'Packaging and testing'; All = 'Running full pipeline' }[$Mode]) $($form.DisplayName)"
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
        $item.Content = New-ListItemContent $p.DisplayName ("{0}  $Dot  {1}  $Dot  {2:N1} MB" -f $p.Version, $p.Architecture, ($p.SizeBytes / 1MB)) $badge $(if ($p.IsSigned) { 'green' } else { 'yellow' })
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
    $ui.BtnPkgUpdate.IsEnabled = $idle -and [bool]$p
    $ui.BtnPkgPublish.IsEnabled = $idle -and [bool]$p -and $p.IsSigned
    $ui.BtnPkgDoc.IsEnabled = [bool]($p -and (Get-MsixDocumentation -PackagePath $p.Path))
    if (-not $p) { $ui.PkgTitle.Text = 'Select a package'; $ui.PkgDetails.Text = ''; return }
    $ui.PkgTitle.Text = "$($p.DisplayName) $($p.Version)"
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
    $ui.TestIcon.Foreground = if ($ok) { Get-Brush 'Success' } else { Get-Brush 'Danger' }
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
    Start-UiTask -Title "Testing $($p.DisplayName)" -Arguments @{ Path = $p.Path } -Work {
        param($Path)
        $t = Test-MsixPackage -Path $Path
        # Documentation again with the test result (keeps the job of the original build if known)
        $doc = Get-MsixDocumentation -PackagePath $Path
        $jobPath = $null
        if ($doc) {
            $m = [regex]::Match((Get-Content $doc -Raw), 'job folder <code>([^<]+)</code>')
            if ($m.Success) { $jobPath = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) }
        }
        New-MsixDocumentation -PackagePath $Path -JobPath $jobPath -TestResult $t | Out-Null
        $t
    } -OnDone {
        param($result, $err)
        if (-not $err -and $result) { Show-TestResult $result[-1]; Update-PackageButtons }
    }
}
Add-Click $ui.BtnPkgUpdate {
    $p = $ui.PackageList.SelectedItem.Tag
    Assert-ReadyForSandbox
    $params = Show-RecordDialog -BasePackage $p.Path
    if (-not $params) { return }
    Start-Recording -Parameters $params -Title "Updating $($p.DisplayName): Start recording in the sandbox, run the updates, Stop recording"
}
Add-Click $ui.BtnPkgDoc {
    $doc = Get-MsixDocumentation -PackagePath $ui.PackageList.SelectedItem.Tag.Path
    if ($doc) { Start-Process $doc }
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

# ---------------------------------------------------------------- mode: MSIX or Win32
$script:Mode = 'MSIX'
function Set-AppMode([ValidateSet('MSIX', 'Win32')][string]$Mode) {
    $script:Mode = $Mode
    $msix = $Mode -eq 'MSIX'
    foreach ($n in 'NavRecipes', 'NavPackages', 'NavCertificate') { $ui[$n].Visibility = if ($msix) { 'Visible' } else { 'Collapsed' } }
    foreach ($n in 'NavWin32Apps', 'NavWin32Builds') { $ui[$n].Visibility = if ($msix) { 'Collapsed' } else { 'Visible' } }
    $ui.GrpStartMsix.Visibility = if ($msix) { 'Visible' } else { 'Collapsed' }
    $ui.GrpStartWin32.Visibility = if ($msix) { 'Collapsed' } else { 'Visible' }
    $ui.BtnMode.Content = if ($msix) { 'Mode: MSIX' } else { 'Mode: Win32' }
    $ui.FooterText.Text = if ($msix) { 'Packages are signed on this computer. Sandboxes only receive the public certificate.' } else { 'Win32 apps are tested in a fresh sandbox as SYSTEM, like the Intune Management Extension runs them.' }
    $hidden = @{ MSIX = 'Win32Apps', 'Win32Builds'; Win32 = 'Recipes', 'Packages', 'Certificate' }[$Mode]
    if ($script:CurrentPage -in $hidden) { Show-Page 'Dashboard' } elseif ($script:CurrentPage -eq 'Dashboard') { Update-Dashboard }
}

function Show-ModeDialog {
    # Start question (MSIX or Win32); the answer is remembered when "Do not ask again" is ticked.
    [xml]$x = Get-Content (Join-Path $PSScriptRoot 'UI\ModeWindow.xaml') -Raw -Encoding UTF8
    $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
    $dlg.Owner = $window
    $script:ModeChoice = $null
    $dlg.FindName('BtnChooseMsix').Add_Click({ $script:ModeChoice = 'MSIX'; $dlg.Close() })
    $dlg.FindName('BtnChooseWin32').Add_Click({ $script:ModeChoice = 'Win32'; $dlg.Close() })
    $remember = $dlg.FindName('ChkModeRemember')
    $remember.IsChecked = -not (Get-MsixSettings).AskModeOnStart
    [void]$dlg.ShowDialog()
    if ($script:ModeChoice) {
        Set-MsixSettings @{ Mode = $script:ModeChoice; AskModeOnStart = -not [bool]$remember.IsChecked } | Out-Null
        Set-AppMode $script:ModeChoice
    }
}
Add-Click $ui.BtnMode { Show-ModeDialog }

# ---------------------------------------------------------------- Win32 apps (designer)
$script:CurrentW32 = $null

function Update-Win32AppList {
    $selected = if ($script:CurrentW32) { $script:CurrentW32.Id } else { $null }
    $ui.Win32AppList.Items.Clear()
    foreach ($p in Get-Win32AppProject | Sort-Object DisplayName) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $test = if ($p.LastTest) { $p.LastTest.result } else { '' }
        $badge = switch ($test) { 'Passed' { 'TESTED' } 'Failed' { 'TEST FAILED' } default { $p.InstallerType.ToUpper() } }
        $color = switch ($test) { 'Passed' { 'green' } 'Failed' { 'yellow' } default { 'blue' } }
        $item.Content = New-ListItemContent $p.DisplayName "$($p.Publisher)  $Dot  $($p.Version)" $badge $color
        $item.Tag = $p
        [void]$ui.Win32AppList.Items.Add($item)
        if ($p.Id -eq $selected) { $item.IsSelected = $true }
    }
}

function Set-ComboText($Combo, [string]$Text) {
    foreach ($i in $Combo.Items) { if ($i.Content -eq $Text) { $Combo.SelectedItem = $i; return } }
    $Combo.SelectedIndex = 0
}

function Update-W32DetectionView {
    $ui.W32DetMsiPanel.Visibility = if ($ui.W32DetMsi.IsChecked) { 'Visible' } else { 'Collapsed' }
    $ui.W32DetFilePanel.Visibility = if ($ui.W32DetFile.IsChecked) { 'Visible' } else { 'Collapsed' }
    $ui.W32DetRegPanel.Visibility = if ($ui.W32DetReg.IsChecked) { 'Visible' } else { 'Collapsed' }
}
foreach ($n in 'W32DetScript', 'W32DetMsi', 'W32DetFile', 'W32DetReg') { $ui[$n].Add_Checked({ Update-W32DetectionView }) }

function Clear-Win32Form {
    $script:CurrentW32 = $null
    $ui.Win32AppList.SelectedItem = $null
    foreach ($n in 'TxtW32Name', 'TxtW32Publisher', 'TxtW32Description', 'TxtW32Installer', 'TxtW32Args', 'TxtW32DetectName',
        'TxtW32Install', 'TxtW32Detect', 'TxtW32Uninstall', 'TxtW32UpdateScript', 'TxtW32ProductCode', 'TxtW32ProductVersion',
        'TxtW32FilePath', 'TxtW32FileName', 'TxtW32FileVersion', 'TxtW32RegKey', 'TxtW32RegValue', 'TxtW32RegData') { $ui[$n].Text = '' }
    $ui.TxtW32Version.Text = '1.0.0'
    $ui.W32Title.Text = 'New Win32 app'
    $ui.W32DetScript.IsChecked = $true
    $ui.ChkW32Update.IsChecked = $false
    foreach ($c in 'CmbW32RunAs', 'CmbW32Restart', 'CmbW32Arch', 'CmbW32MinOS') { $ui[$c].SelectedIndex = 0 }
    $ui.TxtW32LastTest.Text = 'Not tested yet. Save, then "Test in sandbox".'
    $ui.BtnW32Delete.IsEnabled = $false
    Update-W32DetectionView
}

function Show-Win32App($p) {
    $script:CurrentW32 = $p
    $ui.W32Title.Text = "$($p.DisplayName) $($p.Version)"
    $ui.TxtW32Name.Text = $p.DisplayName
    $ui.TxtW32Publisher.Text = $p.Publisher
    $ui.TxtW32Version.Text = $p.Version
    $ui.TxtW32Description.Text = $p.Description
    $ui.TxtW32Installer.Text = if ($p.InstallerFile) { Join-Path $p.SourcePath $p.InstallerFile } else { '' }
    $ui.TxtW32Args.Text = $p.InstallArguments
    $ui.TxtW32DetectName.Text = $p.DetectionName
    $s = Get-Win32AppScript -Project $p
    $ui.TxtW32Install.Text = $s['Install.ps1']
    $ui.TxtW32Detect.Text = $s['Detect.ps1']
    $ui.TxtW32Uninstall.Text = $s['Uninstall.ps1']
    $ui.TxtW32UpdateScript.Text = $s['Update.ps1']
    $ui.ChkW32Update.IsChecked = [bool]$s['Update.ps1']
    $d = $p.Detection
    switch ($d.Type) {
        'MsiProductCode' { $ui.W32DetMsi.IsChecked = $true }
        'File'           { $ui.W32DetFile.IsChecked = $true }
        'Registry'       { $ui.W32DetReg.IsChecked = $true }
        default          { $ui.W32DetScript.IsChecked = $true }
    }
    $ui.TxtW32ProductCode.Text = if ($d.ProductCode) { $d.ProductCode } else { $p.ProductCode }
    $ui.TxtW32ProductVersion.Text = $d.ProductVersion
    $ui.TxtW32FilePath.Text = $d.Path; $ui.TxtW32FileName.Text = $d.FileOrFolder; $ui.TxtW32FileVersion.Text = $d.FileVersion
    $ui.TxtW32RegKey.Text = $d.KeyPath; $ui.TxtW32RegValue.Text = $d.ValueName; $ui.TxtW32RegData.Text = $d.RegistryValue
    Set-ComboText $ui.CmbW32RunAs $p.RunAs
    Set-ComboText $ui.CmbW32Restart $p.Restart
    Set-ComboText $ui.CmbW32Arch $p.Architecture
    Set-ComboText $ui.CmbW32MinOS $p.MinimumWindows
    $t = $p.LastTest
    $ui.TxtW32LastTest.Text = if ($t) {
        "Last test: $($t.result) ($($t.scenario), $(([datetime]$t.date).ToString('g'))). $($t.message)" + $(if ($t.notes) { " Notes: $($t.notes)" }) + $(if ($t.changed) { " Scripts taken over from the sandbox: $($t.changed -join ', ')." })
    } else { 'Not tested yet. Save, then "Test in sandbox".' }
    $ui.W32LastTestBox.Background = if ($t -and $t.result -eq 'Passed') { ConvertTo-Brush '#DCFCE7' } elseif ($t) { ConvertTo-Brush '#FEE2E2' } else { Get-Brush 'InfoBackground' }
    $ui.BtnW32Delete.IsEnabled = $true
    Update-W32DetectionView
}

function Get-Win32Form {
    if (-not $ui.TxtW32Name.Text.Trim()) { throw 'Display name is required.' }
    if ($ui.TxtW32Version.Text -notmatch '^\d+(\.\d+){0,3}$') { throw 'Version must look like 1.2.3 or 1.2.3.4.' }
    $installer = $ui.TxtW32Installer.Text.Trim()
    if ($installer -and -not (Test-Path -LiteralPath $installer)) { throw 'The installer file does not exist.' }
    $det = if ($ui.W32DetMsi.IsChecked) {
        if (-not $ui.TxtW32ProductCode.Text.Trim()) { throw 'Enter the MSI product code.' }
        $v = $ui.TxtW32ProductVersion.Text.Trim()
        New-Win32Detection -Type MsiProductCode -ProductCode $ui.TxtW32ProductCode.Text.Trim() -ProductVersion $v -ProductVersionOperator $(if ($v) { 'greaterThanOrEqual' } else { 'notConfigured' })
    }
    elseif ($ui.W32DetFile.IsChecked) {
        if (-not $ui.TxtW32FilePath.Text.Trim() -or -not $ui.TxtW32FileName.Text.Trim()) { throw 'Enter folder and file name for the detection.' }
        $v = $ui.TxtW32FileVersion.Text.Trim()
        New-Win32Detection -Type File -Path $ui.TxtW32FilePath.Text.Trim() -FileOrFolder $ui.TxtW32FileName.Text.Trim() -FileOperation $(if ($v) { 'version' } else { 'exists' }) -FileVersion $v
    }
    elseif ($ui.W32DetReg.IsChecked) {
        if (-not $ui.TxtW32RegKey.Text.Trim()) { throw 'Enter the registry key for the detection.' }
        $data = $ui.TxtW32RegData.Text.Trim()
        New-Win32Detection -Type Registry -KeyPath $ui.TxtW32RegKey.Text.Trim() -ValueName $ui.TxtW32RegValue.Text.Trim() -RegistryOperation $(if ($data) { 'string' } else { 'exists' }) -RegistryValue $data
    }
    else { New-Win32Detection -Type Script }
    $form = @{
        DisplayName      = $ui.TxtW32Name.Text.Trim()
        Publisher        = $ui.TxtW32Publisher.Text.Trim()
        Version          = $ui.TxtW32Version.Text.Trim()
        Description      = $ui.TxtW32Description.Text.Trim()
        InstallArguments = $ui.TxtW32Args.Text.Trim()
        DetectionName    = $ui.TxtW32DetectName.Text.Trim()
        Detection        = $det
        RunAs            = $ui.CmbW32RunAs.SelectedItem.Content
        Restart          = $ui.CmbW32Restart.SelectedItem.Content
        Architecture     = $ui.CmbW32Arch.SelectedItem.Content
        MinimumWindows   = $ui.CmbW32MinOS.SelectedItem.Content
    }
    if ($script:CurrentW32) { $form.Id = $script:CurrentW32.Id }
    # A new installer (outside the project's source folder) is copied in on save
    if ($installer -and -not ($script:CurrentW32 -and $installer -eq (Join-Path $script:CurrentW32.SourcePath $script:CurrentW32.InstallerFile))) { $form.InstallerPath = $installer }
    # Script editors: only when they have content (an empty editor gets the template)
    $scripts = @{}
    foreach ($pair in @(@('Install.ps1', 'TxtW32Install'), @('Detect.ps1', 'TxtW32Detect'), @('Uninstall.ps1', 'TxtW32Uninstall'))) {
        if ($ui[$pair[1]].Text.Trim()) { $scripts[$pair[0]] = $ui[$pair[1]].Text }
    }
    $scripts['Update.ps1'] = if ($ui.ChkW32Update.IsChecked) { $ui.TxtW32UpdateScript.Text } else { '' }
    if ($ui.ChkW32Update.IsChecked -and -not $ui.TxtW32UpdateScript.Text.Trim()) { $scripts.Remove('Update.ps1'); $form.WithUpdateScript = $true }
    $form.Scripts = $scripts
    $form
}

function Save-Win32Form {
    $form = Get-Win32Form
    $window.Cursor = 'Wait'
    try { $p = Save-Win32AppProject @form } finally { $window.Cursor = $null }
    Show-Win32App $p
    Update-Win32AppList
    $p
}

$ui.Win32AppList.Add_SelectionChanged({ if ($ui.Win32AppList.SelectedItem) { Show-Win32App $ui.Win32AppList.SelectedItem.Tag } })
Add-Click $ui.BtnW32New { Clear-Win32Form }
Add-Click $ui.BtnDashWin32New { Show-Page 'Win32Apps'; Clear-Win32Form }
Add-Click $ui.BtnDashWin32Builds { Show-Page 'Win32Builds' }
Add-Click $ui.BtnW32Refresh { Update-Win32AppList }
Add-Click $ui.BtnW32Browse {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'Installers (*.msi;*.exe)|*.msi;*.exe|All files (*.*)|*.*'
    if (-not $dlg.ShowDialog($window)) { return }
    $info = Get-MsixInstallerInfo -Path $dlg.FileName
    $ui.TxtW32Installer.Text = $info.Path
    if (-not $ui.TxtW32Name.Text) { $ui.TxtW32Name.Text = $info.ProductName }
    if (-not $ui.TxtW32Publisher.Text) { $ui.TxtW32Publisher.Text = $info.Manufacturer }
    if (-not $script:CurrentW32 -or $ui.TxtW32Version.Text -eq '1.0.0') { $ui.TxtW32Version.Text = $info.Version }
    if (-not $ui.TxtW32Args.Text) { $ui.TxtW32Args.Text = $info.SuggestedArguments }
    if (-not $ui.TxtW32DetectName.Text) { $ui.TxtW32DetectName.Text = $info.ProductName }
    if ($info.Type -eq 'MSI') {
        try { $ui.TxtW32ProductCode.Text = (& (Get-Module MsixSandboxStudio) { param($f) (Get-MsiProperty -Path $f -Names 'ProductCode').ProductCode } $info.Path) } catch { }
    }
    Write-UiLog "Installer: $($info.Type), $($info.Framework). Save to copy it into the project; empty script editors are filled from the templates." 'Info'
}
Add-Click $ui.BtnW32Save { Save-Win32Form | Out-Null; Write-UiLog 'Win32 app saved.' 'Success' }
Add-Click $ui.BtnW32Generate {
    if ($script:CurrentW32) {
        $answer = [System.Windows.MessageBox]::Show($window, 'Replace all scripts with freshly generated ones from the templates? Your changes to the scripts are lost.', 'Generate scripts', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    $form = Get-Win32Form
    $form.Remove('Scripts')
    $form.RegenerateScripts = $true
    if ($ui.ChkW32Update.IsChecked) { $form.WithUpdateScript = $true }
    $p = Save-Win32AppProject @form
    if (-not $ui.ChkW32Update.IsChecked) { Remove-Item (Join-Path $p.SourcePath 'Update.ps1') -Force -ErrorAction SilentlyContinue }
    Show-Win32App (Get-Win32AppProject -Id $p.Id)
    Update-Win32AppList
    Write-UiLog 'Scripts generated from the templates. Check the TODO places for EXE installers.' 'Success'
}
$ui.ChkW32Update.Add_Checked({
    if (-not $ui.TxtW32UpdateScript.Text.Trim() -and $script:CurrentW32) {
        $ui.TxtW32UpdateScript.Text = (Get-Win32ScriptTemplate -Project $script:CurrentW32)['Update.ps1']
    }
})
Add-Click $ui.BtnW32Delete {
    if (-not $script:CurrentW32) { return }
    $answer = [System.Windows.MessageBox]::Show($window, "Delete the Win32 app '$($script:CurrentW32.DisplayName)' with its scripts and installer copy? Builds stay.", 'Delete', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }
    Remove-Win32AppProject -Id $script:CurrentW32.Id
    Clear-Win32Form
    Update-Win32AppList
}

function Start-Win32Lab([string]$BaseBuild) {
    if (Test-MsixSandboxRunning) { throw 'A Windows Sandbox is already open; close it first (Windows runs one at a time).' }
    $p = Save-Win32Form
    $title = if ($BaseBuild) { "Test lab: update of $($p.DisplayName). Run the steps in the sandbox, then report the result" } else { "Test lab: $($p.DisplayName). Run Install, Detect, Uninstall in the sandbox, then report the result" }
    Start-UiTask -Title $title -Arguments @{ Id = $p.Id; BaseBuild = $BaseBuild } -Work {
        param($Id, $BaseBuild)
        if ($BaseBuild) { Start-Win32TestLab -Id $Id -BaseBuild $BaseBuild } else { Start-Win32TestLab -Id $Id }
    } -OnDone {
        param($result, $err)
        if ($script:CurrentW32) { Show-Win32App (Get-Win32AppProject -Id $script:CurrentW32.Id) }
        Update-Win32AppList
        if ($err -or -not $result) { return }
        $r = $result[-1]
        $icon = if ($r.Verdict -eq 'Passed') { 'Information' } else { 'Warning' }
        $text = "Test lab: $($r.Verdict).`n$($r.Message)" + $(if ($r.ChangedScripts) { "`n`nScripts changed in the sandbox were taken into the project: $($r.ChangedScripts -join ', ')." })
        [void][System.Windows.MessageBox]::Show($window, $text, 'Win32 Test Lab', 'OK', $icon)
    }
}
Add-Click $ui.BtnW32Test { Start-Win32Lab '' }
Add-Click $ui.BtnW32TestUpdate {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Previous build to install first (its intune-app.json or .intunewin)'
    $dlg.Filter = 'Win32 build (intune-app.json;*.intunewin)|intune-app.json;*.intunewin'
    $dlg.InitialDirectory = (Get-MsixWorkspace).Win32Output
    if ($dlg.ShowDialog($window)) { Start-Win32Lab (Split-Path $dlg.FileName -Parent) }
}
Add-Click $ui.BtnW32Build {
    $p = Save-Win32Form
    if (-not $p.LastTest -or $p.LastTest.result -ne 'Passed') {
        $answer = [System.Windows.MessageBox]::Show($window, "$($p.DisplayName) has no passed test in the Win32 Test Lab. Build anyway?", 'Build .intunewin', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    Start-UiTask -Title "Building $($p.DisplayName) $($p.Version).intunewin" -Arguments @{ Id = $p.Id } -Work { param($Id) New-Win32AppPackage -Id $Id } -OnDone {
        param($result, $err)
        if ($err -or -not $result) { return }
        Show-Page 'Win32Builds'
        Select-Win32Build $result[-1].BuildPath
    }
}

# ---------------------------------------------------------------- Win32 builds + publish wizard
function Update-Win32BuildList {
    $selected = if ($ui.Win32BuildList.SelectedItem) { $ui.Win32BuildList.SelectedItem.Tag.Path } else { $null }
    $ui.Win32BuildList.Items.Clear()
    foreach ($b in Get-Win32AppBuild) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $published = [bool]$b.Definition.published
        $badge = if ($published) { 'PUBLISHED' } elseif ($b.Tested -eq 'Passed') { 'TESTED' } elseif ($b.Tested) { 'TEST FAILED' } else { 'NOT TESTED' }
        $color = if ($published -or $b.Tested -eq 'Passed') { 'green' } elseif ($b.Tested) { 'yellow' } else { 'blue' }
        $item.Content = New-ListItemContent $b.DisplayName "$($b.Version)  $Dot  $($b.Built.ToString('g'))" $badge $color
        $item.Tag = $b
        [void]$ui.Win32BuildList.Items.Add($item)
        if ($b.Path -eq $selected) { $item.IsSelected = $true }
    }
    Update-Win32BuildView
}

function Select-Win32Build([string]$Path) {
    Update-Win32BuildList
    foreach ($item in $ui.Win32BuildList.Items) { if ($item.Tag.Path -eq $Path) { $item.IsSelected = $true } }
}

function Update-Win32BuildView {
    $b = if ($ui.Win32BuildList.SelectedItem) { $ui.Win32BuildList.SelectedItem.Tag } else { $null }
    foreach ($n in 'BtnW32Publish', 'BtnW32BuildParams', 'BtnW32BuildOpen') { $ui[$n].IsEnabled = [bool]$b -and -not ($n -eq 'BtnW32Publish' -and $script:Task) }
    $ui.BtnW32BuildDoc.IsEnabled = [bool]($b -and $b.Documentation)
    if (-not $b) { $ui.W32BuildTitle.Text = 'Select a build'; $ui.W32BuildDetails.Text = ''; return }
    $d = $b.Definition
    $ui.W32BuildTitle.Text = "$($d.displayName) $($d.displayVersion)"
    $pub = if ($d.published) { "$($d.published.appId) ($(([datetime]$d.published.date).ToString('g')))" + $(if ($d.published.supersedes) { ", supersedes $($d.published.supersedes) ($($d.published.supersedenceType))" }) } else { 'not yet' }
    $ui.W32BuildDetails.Text = (@(
        "Package     $($d.fileName)"
        "Install     $($d.installCommandLine)"
        "Uninstall   $($d.uninstallCommandLine)"
        "Detection   $((& (Get-Module MsixSandboxStudio) { param($x) Format-Win32Detection $x } $d.detection))"
        "Run as      $($d.runAsAccount), restart $($d.deviceRestartBehavior), $($d.applicableArchitectures), Windows $($d.minimumSupportedWindowsRelease)+"
        "Test        $(if ($d.test) { "$($d.test.result) ($($d.test.scenario))" } else { 'not tested' })"
        "Published   $pub"
        "Folder      $($b.Path)"
    ) -join "`n")
}

$ui.Win32BuildList.Add_SelectionChanged({ Update-Win32BuildView })
Add-Click $ui.BtnW32BuildsRefresh { Update-Win32BuildList }
Add-Click $ui.BtnW32BuildsFolder { Start-Process explorer.exe (Get-MsixWorkspace).Win32Output }
Add-Click $ui.BtnW32BuildDoc { Start-Process $ui.Win32BuildList.SelectedItem.Tag.Documentation }
Add-Click $ui.BtnW32BuildParams { Start-Process notepad.exe -ArgumentList "`"$($ui.Win32BuildList.SelectedItem.Tag.Parameters)`"" }
Add-Click $ui.BtnW32BuildOpen { Start-Process explorer.exe $ui.Win32BuildList.SelectedItem.Tag.Path }

function Show-PublishWizard($Build) {
    # Collects app details, the app to supersede and the assignment; returns the choices or $null.
    [xml]$x = Get-Content (Join-Path $PSScriptRoot 'UI\PublishWin32Window.xaml') -Raw -Encoding UTF8
    $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($x))
    $dlg.Owner = $window
    $w = @{}
    foreach ($node in $x.SelectNodes("//*[@*[local-name()='Name']]")) {
        $n = ($node.Attributes | Where-Object LocalName -eq 'Name').Value
        $w[$n] = $dlg.FindName($n)
    }
    $d = $Build.Definition
    $w.WizSubtitle.Text = "$($d.displayName) $($d.displayVersion)  $Dot  $($d.fileName)"
    $w.WizName.Text = $d.displayName; $w.WizPublisher.Text = $d.publisher; $w.WizDescription.Text = $d.description
    $w.WizTestText.Text = if ($d.test -and $d.test.result -eq 'Passed') { "Tested in the Win32 Test Lab: passed ($($d.test.scenario), $(([datetime]$d.test.date).ToString('g')))." } else { 'Warning: this build has no passed test in the Win32 Test Lab.' }
    $w.WizTestBox.Background = if ($d.test -and $d.test.result -eq 'Passed') { ConvertTo-Brush '#DCFCE7' } else { ConvertTo-Brush '#FEF3C7' }
    $state = @{ Page = 1; Supersede = $null; Group = $null; Result = $null }

    $showPage = {
        foreach ($i in 1..4) {
            $w["WizPage$i"].Visibility = if ($i -eq $state.Page) { 'Visible' } else { 'Collapsed' }
            $w["WizDot$i"].Background = if ($i -le $state.Page) { Get-Brush 'Primary' } else { ConvertTo-Brush '#E2E8F0' }
            ($w["WizDot$i"].Child).Foreground = if ($i -le $state.Page) { [System.Windows.Media.Brushes]::White } else { ConvertTo-Brush '#475569' }
        }
        $w.WizBack.IsEnabled = $state.Page -gt 1
        $w.WizNext.Visibility = if ($state.Page -lt 4) { 'Visible' } else { 'Collapsed' }
        $w.WizPublish.Visibility = if ($state.Page -eq 4) { 'Visible' } else { 'Collapsed' }
        if ($state.Page -eq 4) {
            $sup = if ($state.Supersede) { "$($state.Supersede.DisplayName) $($state.Supersede.Version) ($(if ($w.WizTypeReplace.IsChecked) { 'replace: uninstall old first' } else { 'update: install over it' }))" } else { 'none' }
            $grp = if ($state.Group) { "$($state.Group.DisplayName) ($(if ($w.WizIntentAvailable.IsChecked) { 'available' } else { 'required' }))" } else { 'none (upload only)' }
            $w.WizSummary.Text = (@(
                "App          $($w.WizName.Text) $($d.displayVersion)"
                "Publisher    $($w.WizPublisher.Text)"
                "Package      $($d.fileName)"
                "Install      $($d.installCommandLine)"
                "Uninstall    $($d.uninstallCommandLine)"
                "Supersedes   $sup"
                "Assignment   $grp"
                "Tenant       $((Get-MsixIntuneContext).TenantId)"
            ) -join "`n")
        }
    }
    $w.WizNext.Add_Click({
        if ($state.Page -eq 1 -and -not $w.WizName.Text.Trim()) { [void][System.Windows.MessageBox]::Show($dlg, 'Display name is required.'); return }
        $state.Page++; & $showPage
    })
    $w.WizBack.Add_Click({ $state.Page--; & $showPage })
    $w.WizCancel.Add_Click({ $dlg.Close() })
    $w.WizSearchApps.Add_Click({
        try {
            $w.WizAppList.Items.Clear()
            foreach ($a in Find-IntuneWin32App -Search $w.WizAppSearch.Text.Trim()) {
                $item = New-Object System.Windows.Controls.ListBoxItem
                $item.Content = New-ListItemContent $a.DisplayName "$($a.Version)  $Dot  $($a.Publisher)" ''
                $item.Tag = $a
                [void]$w.WizAppList.Items.Add($item)
            }
            if (-not $w.WizAppList.Items.Count) { [void][System.Windows.MessageBox]::Show($dlg, 'No Win32 app found.') }
        }
        catch { [void][System.Windows.MessageBox]::Show($dlg, $_.Exception.Message, 'Search', 'OK', 'Error') }
    })
    $w.WizAppList.Add_SelectionChanged({
        if ($w.WizAppList.SelectedItem) { $state.Supersede = $w.WizAppList.SelectedItem.Tag; $w.WizSupersedeText.Text = "$($state.Supersede.DisplayName) $($state.Supersede.Version)" }
    })
    $w.WizSupersedeClear.Add_Click({ $state.Supersede = $null; $w.WizSupersedeText.Text = 'none'; $w.WizAppList.SelectedItem = $null })
    $w.WizSearchGroups.Add_Click({
        try {
            if (-not $w.WizGroupSearch.Text.Trim()) { [void][System.Windows.MessageBox]::Show($dlg, 'Enter the beginning of a group name.'); return }
            $w.WizGroupList.Items.Clear()
            foreach ($g in Find-MsixIntuneGroup -Search $w.WizGroupSearch.Text.Trim()) {
                $item = New-Object System.Windows.Controls.ListBoxItem
                $item.Content = New-ListItemContent $g.DisplayName $g.Id ''
                $item.Tag = $g
                [void]$w.WizGroupList.Items.Add($item)
            }
        }
        catch { [void][System.Windows.MessageBox]::Show($dlg, $_.Exception.Message, 'Search', 'OK', 'Error') }
    })
    $w.WizGroupList.Add_SelectionChanged({
        if ($w.WizGroupList.SelectedItem) { $state.Group = $w.WizGroupList.SelectedItem.Tag; $w.WizGroupText.Text = $state.Group.DisplayName }
    })
    $w.WizGroupClear.Add_Click({ $state.Group = $null; $w.WizGroupText.Text = 'none'; $w.WizGroupList.SelectedItem = $null })
    $w.WizPublish.Add_Click({
        $state.Result = @{
            BuildPath        = $Build.Path
            DisplayName      = $w.WizName.Text.Trim()
            Publisher        = $w.WizPublisher.Text.Trim()
            Description      = $w.WizDescription.Text.Trim()
            SupersedeAppId   = $(if ($state.Supersede) { $state.Supersede.Id } else { '' })
            SupersedenceType = $(if ($w.WizTypeReplace.IsChecked) { 'replace' } else { 'update' })
            GroupId          = $(if ($state.Group) { $state.Group.Id } else { '' })
            Intent           = $(if ($w.WizIntentAvailable.IsChecked) { 'available' } else { 'required' })
        }
        $dlg.Close()
    })
    & $showPage
    [void]$dlg.ShowDialog()
    $state.Result
}

Add-Click $ui.BtnW32Publish {
    $b = $ui.Win32BuildList.SelectedItem.Tag
    if (-not (Get-MsixIntuneContext)) { Connect-Intune }
    if (-not (Get-MsixIntuneContext)) { return }
    $choice = Show-PublishWizard $b
    if (-not $choice) { return }
    Start-UiTask -Title "Publishing $($choice.DisplayName) $($b.Version) to Intune" -NeedsGraph -Arguments @{ C = $choice } -Work {
        param($C) Publish-Win32AppToIntune @C
    } -OnDone {
        param($result, $err)
        Update-Win32BuildList
        if (-not $err -and $result) { [void][System.Windows.MessageBox]::Show($window, "Published: $($result[-1].DisplayName) $($result[-1].Version)`nIntune app ID: $($result[-1].AppId)", 'Publish to Intune', 'OK', 'Information') }
    }
}

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
    # Connect-AzAccount may need an interactive sign-in: in front of the tool, like the Graph sign-in.
    $window.Cursor = 'Wait'
    try { Invoke-InteractiveSignIn { Import-MsixCertificateFromKeyVault -VaultName $ui.TxtKvVault.Text -CertificateName $ui.TxtKvCert.Text -Password $ui.PwdKv.SecurePassword | Out-Null } }
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

function Connect-Intune {
    param([ValidateSet('Windows', 'Keevault')][string]$Method = 'Windows')
    $tenant = $ui.TxtTenantId.Text.Trim()
    $window.Cursor = 'Wait'
    try {
        if ($Method -eq 'Keevault') {
            # Keevault and the embedded sign-in window take the foreground; the tool keeps painting meanwhile
            # but takes no clicks.
            $window.IsEnabled = $false
            $pump = { $window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background) }
            Connect-MsixIntuneWithKeevault -TenantId $tenant -Owner $window -OnWait $pump | Out-Null
        }
        else { Invoke-InteractiveSignIn { Connect-MsixIntune -TenantId $tenant | Out-Null } }
    }
    finally { $window.IsEnabled = $true; $window.Cursor = $null; [void]$window.Activate() }
    Update-ConnectionStatus
    Update-IntuneView
    Update-Dashboard
}

function Show-SignInMenu($Target) {
    # Options of the split button next to Sign in
    $kv = Find-KeevaultMcp
    $menu = New-Object System.Windows.Controls.ContextMenu
    $items = @(
        @{ Glyph = [char]0xE77B; Header = 'Sign in with Microsoft account'; Text = 'Windows sign-in dialog (Web Account Manager), as before.'; Method = 'Windows'; Enabled = $true }
        @{ Glyph = [char]0xE72E; Header = 'Sign in with Keevault'; Method = 'Keevault'; Enabled = ($kv.Installed -and $kv.McpEnabled)
           Text = $(if (-not $kv.Installed) { 'Keevault is not installed.' }
                    elseif (-not $kv.McpEnabled) { 'Switch on AI agents (MCP) in Keevault first.' }
                    elseif (-not $kv.Running) { 'Start and unlock Keevault first. You pick the account in Keevault; user name, password and one-time code are filled in.' }
                    else { 'You pick the account in Keevault; user name, password and one-time code are filled in.' }) }
    )
    foreach ($i in $items) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $i.Header; $mi.Tag = [string]$i.Glyph; $mi.ToolTip = $i.Text; $mi.IsEnabled = $i.Enabled
        # The menu shows the text below the title; no extra tooltip popup
        [System.Windows.Controls.ToolTipService]::SetIsEnabled($mi, $false)
        $script:SignInMenuMethods[$mi] = $i.Method
        $mi.Add_Click({
            param($src)
            try { Connect-Intune -Method $script:SignInMenuMethods[$src] } catch { Show-Error $_.Exception.Message }
        })
        [void]$menu.Items.Add($mi)
    }
    $menu.PlacementTarget = $Target
    $menu.Placement = 'Bottom'
    # Right edge of the menu below the right edge of the arrow (its shadow margin is 8 px)
    $menu.Add_Opened({ param($m) $m.HorizontalOffset = $m.PlacementTarget.ActualWidth - $m.ActualWidth + 8 })
    $menu.IsOpen = $true
}
$script:SignInMenuMethods = @{}

function Update-IntuneView {
    $c = Get-MsixIntuneContext
    $ui.IntuneAccount.Text = if ($c -and $c.Account) { $c.Account } else { 'Not signed in' }
    $ui.IntuneTenant.Text = if ($c -and $c.Account) { "Tenant $($c.TenantId)" } else { 'Sign in to publish apps and the certificate profile.' }
    $ui.BtnIntunePageSignIn.IsEnabled = -not ($c -and $c.Account)
    $ui.BtnIntunePageSignInMenu.IsEnabled = $ui.BtnIntunePageSignIn.IsEnabled
    Update-ConnectionStatus
}
Add-Click $ui.BtnIntuneSignIn { Connect-Intune }
Add-Click $ui.BtnIntunePageSignIn { Connect-Intune }
Add-Click $ui.BtnIntuneSignInMenu { Show-SignInMenu $ui.BtnIntuneSignInMenu }
Add-Click $ui.BtnIntunePageSignInMenu { Show-SignInMenu $ui.BtnIntunePageSignInMenu }
Add-Click $ui.BtnIntuneSignOut { Disconnect-MsixIntune; Update-IntuneView; Update-Dashboard }
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
    if (-not $ui.GroupList.Items.Count) { Write-UiLog 'No group found.' 'Warning' }
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
    Write-UiLog 'Settings saved.' 'Success'
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

Write-UiLog "MSIX Sandbox Studio $script:Version started. Workspace: $((Get-MsixWorkspace).Root)"
Show-Page 'Dashboard'
Clear-RecipeForm
Clear-Win32Form
$startSettings = Get-MsixSettings
Set-AppMode $(if ($startSettings.Mode) { $startSettings.Mode } else { 'MSIX' })
# Start question "MSIX or Win32?" once the window is visible (not in the off-screen test mode)
if (-not $env:MSIXSTUDIO_SMOKE -and ($startSettings.AskModeOnStart -or -not $startSettings.Mode)) {
    $script:ModeAsked = $false
    $window.Add_ContentRendered({ if (-not $script:ModeAsked) { $script:ModeAsked = $true; Show-ModeDialog } })
}
$timer.Start()
# Test hook: MSIXSTUDIO_SMOKE names a script that drives the window off-screen and renders every page.
if ($env:MSIXSTUDIO_SMOKE) { . $env:MSIXSTUDIO_SMOKE }
$window.Show()
[void]$window.Activate()
[void][System.Windows.Application]::Current.Run()
