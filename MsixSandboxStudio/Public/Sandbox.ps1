# Windows Sandbox orchestration. Every run gets a job folder on the host that is mapped into the
# sandbox; Sandbox\Bootstrap.ps1 reads job.json there, does the work and reports back via status.json.

$script:SandboxRoot = 'C:\MsixStudio'        # mapped host folders inside the sandbox
$script:SandboxLocal = 'C:\MsixStudioLocal'  # local working copy inside the sandbox

function Test-MsixSandboxAvailable {
    <# True if the Windows Sandbox feature is enabled on this host. #>
    Test-Path (Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe')
}

function Test-MsixSandboxRunning {
    <# Windows Sandbox runs one instance at a time; this tells whether one is open. #>
    [bool](Get-Process -Name 'WindowsSandboxRemoteSession', 'WindowsSandboxClient' -ErrorAction SilentlyContinue)
}

function Get-MsixHostStatus {
    <#
    .SYNOPSIS
    Readiness check of the host: sandbox feature, virtualization, toolchain, certificate, Graph module.
    #>
    [CmdletBinding()]
    param()
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $toolchain = Get-MsixToolchain
    $cert = Get-MsixCertificate
    [pscustomobject]@{
        OsCaption          = if ($os) { $os.Caption } else { '' }
        OsBuild            = [Environment]::OSVersion.Version.Build
        EditionSupported   = -not ($os -and $os.Caption -match 'Home')
        HypervisorPresent  = [bool]($cs -and $cs.HypervisorPresent)
        SandboxEnabled     = Test-MsixSandboxAvailable
        SandboxRunning     = Test-MsixSandboxRunning
        Toolchain          = $toolchain
        ToolchainReady     = [bool]($toolchain -and $toolchain.IsComplete)
        Certificate        = $cert
        CertificateReady   = [bool]($cert -and $cert.HasPassword -and -not $cert.IsExpired)
        GraphModule        = [bool](Get-Module -ListAvailable Microsoft.Graph.Authentication)
    }
}

function Enable-MsixSandboxFeature {
    <# Enables Windows Sandbox (elevated, needs a reboot afterwards). #>
    [CmdletBinding()]
    param()
    $cmd = 'Enable-WindowsOptionalFeature -FeatureName Containers-DisposableClientVM -All -Online -NoRestart'
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command', $cmd
    Write-MsixLog 'Windows Sandbox feature enabled. Restart the computer to use it.' -Level Warning
}

function New-MsixSandboxConfig {
    <# Writes the .wsb file for a job: mapped folders, logon command, resources. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JobPath,
        [bool]$Networking = $true,
        [int]$MemoryMB = 4096,
        [bool]$VGpu = $true,
        [switch]$MapShared
    )
    $ws = Get-MsixWorkspace
    $maps = @(
        @{ Host = $JobPath;                                    Sandbox = "$script:SandboxRoot\Job";       ReadOnly = $false }
        @{ Host = $ws.Toolchain;                               Sandbox = "$script:SandboxRoot\Toolchain"; ReadOnly = $true }
        @{ Host = (Join-Path $script:ModuleRoot 'Sandbox');    Sandbox = "$script:SandboxRoot\Tools";     ReadOnly = $true }
    )
    if ($MapShared) { $maps += @{ Host = $ws.Shared; Sandbox = "$script:SandboxRoot\Shared"; ReadOnly = $false } }

    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    $folders = ($maps | ForEach-Object {
        "    <MappedFolder>`r`n      <HostFolder>$(& $esc $_.Host)</HostFolder>`r`n      <SandboxFolder>$(& $esc $_.Sandbox)</SandboxFolder>`r`n      <ReadOnly>$($_.ReadOnly.ToString().ToLower())</ReadOnly>`r`n    </MappedFolder>"
    }) -join "`r`n"
    $logon = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:SandboxRoot\Tools\Bootstrap.ps1"
    $wsb = @"
<Configuration>
  <vGPU>$(if ($VGpu) { 'Enable' } else { 'Disable' })</vGPU>
  <Networking>$(if ($Networking) { 'Enable' } else { 'Disable' })</Networking>
  <MemoryInMB>$MemoryMB</MemoryInMB>
  <ClipboardRedirection>Enable</ClipboardRedirection>
  <MappedFolders>
$folders
  </MappedFolders>
  <LogonCommand>
    <Command>$(& $esc $logon)</Command>
  </LogonCommand>
</Configuration>
"@
    $path = Join-Path $JobPath 'sandbox.wsb'
    Set-Content -Path $path -Value $wsb -Encoding UTF8
    $path
}

function New-MsixJob {
    # Creates a job folder with job.json; returns its path.
    param([Parameter(Mandatory)][ValidateSet('Interactive', 'Package', 'Record', 'Test')][string]$Mode, [string]$Name = 'sandbox', [hashtable]$Data = @{})
    $id = '{0:yyyyMMdd-HHmmss}-{1}-{2}' -f (Get-Date), $Mode.ToLower(), ($Name -replace '[^\w\.-]', '_')
    $path = Join-Path (Get-MsixWorkspace).Jobs $id
    New-Item -ItemType Directory -Path (Join-Path $path 'input'), (Join-Path $path 'out') -Force | Out-Null
    $job = [ordered]@{ Id = $id; Mode = $Mode; Created = (Get-Date).ToString('o') }
    foreach ($k in $Data.Keys) { $job[$k] = $Data[$k] }
    $job | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $path 'job.json') -Encoding UTF8
    $path
}

function Start-MsixSandboxProcess {
    param([Parameter(Mandatory)][string]$WsbPath)
    if (-not (Test-MsixSandboxAvailable)) { throw 'Windows Sandbox is not enabled on this computer (see Enable-MsixSandboxFeature).' }
    if (Test-MsixSandboxRunning) { throw 'A Windows Sandbox is already open. Windows runs only one at a time; close it first.' }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe') -ArgumentList "`"$WsbPath`""
}

function Wait-MsixJob {
    <# Waits until the sandbox reports Succeeded/Failed in status.json; logs each new step. #>
    param([Parameter(Mandatory)][string]$JobPath, [int]$TimeoutMinutes = 45)
    $statusPath = Join-Path $JobPath 'status.json'
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $started = Get-Date
    $lastStep = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $status = $null
        if (Test-Path $statusPath) {
            try { $status = Get-Content $statusPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { }
        }
        if ($status) {
            if ($status.Step -and $status.Step -ne $lastStep) {
                $lastStep = $status.Step
                Write-MsixLog "  [sandbox] $($status.Step)"
            }
            if ($status.State -in 'Succeeded', 'Failed') { return $status }
        }
        # Sandbox closed without a final status (user closed it, crash): give it 90 s to boot first.
        if (((Get-Date) - $started).TotalSeconds -gt 90 -and -not (Test-MsixSandboxRunning)) {
            return [pscustomobject]@{ State = 'Failed'; Step = $lastStep; Message = 'The sandbox was closed before the job finished.' }
        }
    }
    [pscustomobject]@{ State = 'Failed'; Step = $lastStep; Message = "Timeout after $TimeoutMinutes minutes." }
}

function Start-MsixSandbox {
    <#
    .SYNOPSIS
    Opens an interactive sandbox with the MSIX Packaging Tool installed and the signing certificate trusted.
    Workspace\Shared is mapped to C:\MsixStudio\Shared; anything saved there survives the sandbox.
    #>
    [CmdletBinding()]
    param([Nullable[bool]]$Networking)
    $settings = Get-MsixSettings
    $toolchain = Get-MsixToolchain
    if (-not ($toolchain -and $toolchain.IsComplete)) { $toolchain = Update-MsixToolchain }
    if ($null -eq $Networking) { $Networking = $true }
    $cert = Get-MsixCertificate
    $job = New-MsixJob -Mode Interactive -Data @{ AutoClose = $false; Publisher = $(if ($cert) { $cert.Subject } else { '' }) }
    if ($cert -and (Test-Path $cert.CerPath)) { Copy-Item $cert.CerPath (Join-Path $job 'input\signing.cer') }
    $wsb = New-MsixSandboxConfig -JobPath $job -Networking $Networking -MemoryMB $settings.SandboxMemoryMB -VGpu $settings.SandboxVGpu -MapShared
    Start-MsixSandboxProcess -WsbPath $wsb
    Write-MsixLog "Interactive sandbox started. Shared folder: $((Get-MsixWorkspace).Shared)" -Level Success
    [pscustomobject]@{ JobPath = $job; Wsb = $wsb }
}

function Invoke-MsixPackaging {
    <#
    .SYNOPSIS
    Repackages a recipe in a fresh sandbox and signs the result on the host.
    .DESCRIPTION
    InstallMode Silent: the installer runs unattended with the recipe's arguments.
    InstallMode Manual: opens the MSIX Recorder (see Start-MsixRecording).
    .OUTPUTS
    Object with State, PackagePath (signed .msix in Workspace\Output) and JobPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecipeName,
        [switch]$SkipSigning
    )
    $settings = Get-MsixSettings
    $recipe = Get-MsixRecipe -Name $RecipeName
    if (-not $recipe) { throw "Recipe not found: $RecipeName" }
    if ($recipe.InstallMode -eq 'Manual') { return Start-MsixRecording -RecipeName $RecipeName -SkipSigning:$SkipSigning }
    if (-not $recipe.Installer) { throw 'Silent packaging needs an installer; choose one or switch the recipe to manual recording.' }
    if (-not (Test-Path $recipe.Installer)) { throw "Installer missing: $($recipe.Installer)" }
    $cert = Get-MsixCertificate
    if (-not $cert -and -not $SkipSigning) { throw 'No signing certificate configured (New-MsixCertificate or Import-MsixCertificate).' }
    $toolchain = Get-MsixToolchain
    if (-not ($toolchain -and $toolchain.IsComplete)) { $toolchain = Update-MsixToolchain }

    # Publisher must match the certificate subject exactly, otherwise signing fails.
    $publisher = if ($cert) { $cert.Subject } else { 'CN=Unsigned' }
    $installerName = Split-Path $recipe.Installer -Leaf
    $msixName = '{0}_{1}.msix' -f $recipe.PackageName, $recipe.Version
    $job = New-MsixJob -Mode Package -Name $recipe.PackageName -Data @{
        AutoClose   = $true
        PackageName = $recipe.PackageName
        Installer   = $installerName
        PackageFile = $msixName
    }
    Copy-Item -LiteralPath $recipe.Installer -Destination (Join-Path $job "input\$installerName")
    # Paths in the sandbox's local copy (Bootstrap.ps1 copies input there; the tool cannot use mapped folders)
    $template = New-MsixConversionTemplate -Recipe $recipe -Publisher $publisher `
        -InstallerPath "$script:SandboxLocal\input\$installerName" `
        -PackagePath "$script:SandboxLocal\out\$msixName" `
        -TemplatePath "$script:SandboxLocal\out\template.xml"
    [IO.File]::WriteAllText((Join-Path $job 'template.xml'), $template, (New-Object Text.UTF8Encoding $false))

    Write-MsixLog "Packaging $($recipe.DisplayName) $($recipe.Version) in a fresh sandbox ..."
    $wsb = New-MsixSandboxConfig -JobPath $job -Networking ([bool]$settings.PackageNetworking) -MemoryMB $settings.SandboxMemoryMB -VGpu $settings.SandboxVGpu
    Start-MsixSandboxProcess -WsbPath $wsb
    $status = Wait-MsixJob -JobPath $job -TimeoutMinutes $settings.JobTimeoutMinutes

    $raw = Join-Path $job "out\$msixName"
    if ($status.State -ne 'Succeeded' -or -not (Test-Path $raw)) {
        Write-MsixLog "Packaging failed: $($status.Message) (logs: $job)" -Level Error
        return [pscustomobject]@{ State = 'Failed'; Message = $status.Message; PackagePath = $null; JobPath = $job }
    }
    $target = Join-Path (Get-MsixWorkspace).Output $msixName
    Copy-Item $raw $target -Force
    if (-not $SkipSigning) { Invoke-MsixSigning -Path $target | Out-Null }
    $doc = New-MsixDocumentation -PackagePath $target -JobPath $job
    Write-MsixLog "Package ready: $target" -Level Success
    [pscustomobject]@{ State = 'Succeeded'; Message = $status.Message; PackagePath = $target; JobPath = $job; Documentation = $doc }
}

function Start-MsixRecording {
    <#
    .SYNOPSIS
    Records a manual installation: opens a sandbox with the MSIX Recorder, where everything is installed
    automatically. You click "Start recording", install the app (the installer starts by itself),
    click "Stop recording"; the package comes back to the host and is signed.
    .DESCRIPTION
    Package details (name, version, publisher display name) are prefilled from the recipe or the parameters
    and can still be changed in the recorder. The values used are saved as a manual recipe afterwards.
    Every click is documented with a screenshot and the screen is recorded; the HTML documentation is
    written next to the package.
    .PARAMETER BasePackage
    Update an existing package: its content is restored in the sandbox (files, registry, shortcuts) when the
    recording starts, then you run the updates. Identity is taken from it, the version is raised by one.
    .OUTPUTS
    Object with State, PackagePath, JobPath, Recipe and Documentation.
    #>
    [CmdletBinding()]
    param(
        [string]$RecipeName,
        [string]$InstallerPath,
        [string]$BasePackage,
        [string]$DisplayName = '',
        [string]$PackageName = '',
        [string]$Version = '1.0.0.0',
        [string]$PublisherDisplayName = '',
        [switch]$SkipSigning
    )
    $settings = Get-MsixSettings
    $base = $null
    if ($BasePackage) {
        $base = Get-MsixPackageInfo -Path $BasePackage
        if (-not $DisplayName) { $DisplayName = $base.DisplayName }
        if (-not $PackageName) { $PackageName = $base.Name }
        if (-not $PublisherDisplayName) { $PublisherDisplayName = $base.PublisherDisplayName }
        if ($Version -eq '1.0.0.0') {
            # Next version: last part + 1 (an update must have a higher version)
            $v = [version]$base.Version
            $Version = '{0}.{1}.{2}.{3}' -f $v.Major, $v.Minor, $v.Build, [Math]::Min(65535, $v.Revision + 1)
        }
    }
    $recipe = $null
    if ($RecipeName) {
        $recipe = Get-MsixRecipe -Name $RecipeName
        if (-not $recipe) { throw "Recipe not found: $RecipeName" }
        if (-not $InstallerPath) { $InstallerPath = $recipe.Installer }
        if (-not $DisplayName) { $DisplayName = $recipe.DisplayName }
        if (-not $PackageName) { $PackageName = $recipe.PackageName }
        if ($Version -eq '1.0.0.0') { $Version = $recipe.Version }
        if (-not $PublisherDisplayName) { $PublisherDisplayName = $recipe.PublisherDisplayName }
    }
    if ($InstallerPath -and -not (Test-Path -LiteralPath $InstallerPath)) { throw "Installer missing: $InstallerPath" }
    $cert = Get-MsixCertificate
    if (-not $cert -and -not $SkipSigning) { throw 'No signing certificate configured (New-MsixCertificate or Import-MsixCertificate).' }
    $toolchain = Get-MsixToolchain
    if (-not ($toolchain -and $toolchain.IsComplete)) { $toolchain = Update-MsixToolchain }

    $publisher = if ($cert) { $cert.Subject } else { 'CN=Unsigned' }
    if ($base -and $base.Publisher -ne $publisher) {
        Write-MsixLog "The base package was published by '$($base.Publisher)'; the update gets '$publisher'. Devices treat it as a different app." -Level Warning
    }
    $data = @{
        AutoClose            = $false   # the recorder closes the sandbox
        DisplayName          = $DisplayName
        PackageName          = $PackageName
        Version              = ConvertTo-MsixVersion $Version
        PublisherDisplayName = $PublisherDisplayName
        Publisher            = $publisher
        InstallLocation      = $(if ($recipe -and $recipe.InstallLocation) { $recipe.InstallLocation } else { '' })
    }
    if ($base) {
        $data.BasePackage = Split-Path $base.Path -Leaf
        $data.BaseDisplayName = $base.DisplayName
        $data.BaseVersion = $base.Version
    }
    $job = New-MsixJob -Mode Record -Name $(if ($PackageName) { $PackageName } else { 'recording' }) -Data $data
    if ($InstallerPath) { Copy-Item -LiteralPath $InstallerPath -Destination (Join-Path $job 'input') }
    if ($base) {
        New-Item -ItemType Directory (Join-Path $job 'input\base') -Force | Out-Null
        Copy-Item -LiteralPath $base.Path -Destination (Join-Path $job 'input\base')
    }
    if ($cert -and (Test-Path $cert.CerPath)) { Copy-Item $cert.CerPath (Join-Path $job 'input\signing.cer') }

    if ($base) { Write-MsixLog "Opening the MSIX Recorder for an update of $($base.DisplayName) $($base.Version) -> $($data.Version)." }
    else { Write-MsixLog 'Opening the MSIX Recorder. In the sandbox: Start recording, install the app, Stop recording.' }
    $wsb = New-MsixSandboxConfig -JobPath $job -Networking ([bool]$settings.PackageNetworking) -MemoryMB $settings.SandboxMemoryMB -VGpu $settings.SandboxVGpu
    Start-MsixSandboxProcess -WsbPath $wsb
    # Manual installs take as long as they take.
    $status = Wait-MsixJob -JobPath $job -TimeoutMinutes ([Math]::Max(480, [int]$settings.JobTimeoutMinutes))

    $r = $status.Result
    $raw = if ($r -and $r.PackageFile) { Join-Path $job "out\$($r.PackageFile)" } else { $null }
    if ($status.State -ne 'Succeeded' -or -not $raw -or -not (Test-Path $raw)) {
        Write-MsixLog "Recording failed: $($status.Message) (logs: $job)" -Level Error
        return [pscustomobject]@{ State = 'Failed'; Message = $status.Message; PackagePath = $null; JobPath = $job; Recipe = $null }
    }
    $target = Join-Path (Get-MsixWorkspace).Output $r.PackageFile
    Copy-Item $raw $target -Force
    if (-not $SkipSigning) { Invoke-MsixSigning -Path $target | Out-Null }

    # Keep what was entered in the recorder as a manual recipe, ready for the next version.
    $saved = Save-MsixRecipe -InstallMode Manual -InstallerPath $(if ($InstallerPath) { $InstallerPath } else { '' }) `
        -PackageName $r.PackageName -DisplayName $r.DisplayName -PublisherDisplayName $r.PublisherDisplayName -Version $r.Version
    $doc = New-MsixDocumentation -PackagePath $target -JobPath $job
    Write-MsixLog "Package ready: $target" -Level Success
    [pscustomobject]@{ State = 'Succeeded'; Message = $status.Message; PackagePath = $target; JobPath = $job; Recipe = $saved; Documentation = $doc }
}

function Test-MsixPackage {
    <#
    .SYNOPSIS
    Installs a package in a fresh sandbox (certificate trusted like on a managed client), starts each app,
    takes a screenshot, uninstalls and reports the result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$DurationSeconds
    )
    $settings = Get-MsixSettings
    if (-not $DurationSeconds) { $DurationSeconds = $settings.TestDurationSeconds }
    $pkg = Get-MsixPackageInfo -Path $Path
    $file = Split-Path $Path -Leaf
    $job = New-MsixJob -Mode Test -Name $pkg.Name -Data @{ AutoClose = $true; PackageFile = $file; IdentityName = $pkg.Name; DurationSeconds = $DurationSeconds }
    Copy-Item -LiteralPath $Path -Destination (Join-Path $job "input\$file")
    $cert = Get-MsixCertificate
    if ($cert -and (Test-Path $cert.CerPath)) { Copy-Item $cert.CerPath (Join-Path $job 'input\signing.cer') }

    Write-MsixLog "Testing $($pkg.Name) $($pkg.Version) in a fresh sandbox ..."
    # The test needs no toolchain download and no network: closer to a locked-down client.
    $wsb = New-MsixSandboxConfig -JobPath $job -Networking $false -MemoryMB $settings.SandboxMemoryMB -VGpu $settings.SandboxVGpu
    Start-MsixSandboxProcess -WsbPath $wsb
    $status = Wait-MsixJob -JobPath $job -TimeoutMinutes 15

    $shots = @(Get-ChildItem (Join-Path $job 'out') -Filter '*.png' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $level = if ($status.State -eq 'Succeeded') { 'Success' } else { 'Error' }
    Write-MsixLog "Test $($status.State): $($status.Message)" -Level $level
    [pscustomobject]@{
        State       = $status.State
        Message     = $status.Message
        Result      = $status.Result
        Screenshots = $shots
        JobPath     = $job
    }
}

function Invoke-MsixPipeline {
    <#
    .SYNOPSIS
    Package -> sign -> test -> (optional) publish to Intune, stopping at the first failing step.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RecipeName,
        [switch]$SkipTest,
        [switch]$Publish,
        [string]$GroupId,
        [ValidateSet('required', 'available', 'uninstall')][string]$Intent = 'required'
    )
    $built = Invoke-MsixPackaging -RecipeName $RecipeName
    if ($built.State -ne 'Succeeded') { return $built }
    $result = [ordered]@{ State = 'Succeeded'; PackagePath = $built.PackagePath; Test = $null; IntuneApp = $null; Documentation = $built.Documentation }
    if (-not $SkipTest) {
        $result.Test = Test-MsixPackage -Path $built.PackagePath
        # Documentation again, now with the test result and its screenshots
        $result.Documentation = New-MsixDocumentation -PackagePath $built.PackagePath -JobPath $built.JobPath -TestResult $result.Test
        if ($result.Test.State -ne 'Succeeded') { $result.State = 'Failed'; return [pscustomobject]$result }
    }
    if ($Publish) { $result.IntuneApp = Publish-MsixToIntune -Path $built.PackagePath -GroupId $GroupId -Intent $Intent }
    [pscustomobject]$result
}
