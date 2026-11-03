# Runs INSIDE Windows Sandbox as logon command. Reads C:\MsixStudio\Job\job.json, does the job
# and reports progress/results to status.json in the same (host-mapped) folder.
#   Interactive: install the MSIX Packaging Tool, trust the signing certificate, open the tool
#   Package:     install the tool, run the conversion template unattended, close the sandbox
#   Record:      open the MSIX Recorder (Recorder.ps1), install the tool while it shows progress, then hand
#                over: the user starts/stops the recording there and the recorder closes the sandbox
#   Test:        trust the certificate, install the package, start each app, screenshot, uninstall, close
#   Win32Lab:    open the Win32 Test Lab (Win32Lab.ps1) for an .intunewin's content; it closes the sandbox

$ErrorActionPreference = 'Stop'
$JobDir       = 'C:\MsixStudio\Job'
$ToolchainDir = 'C:\MsixStudio\Toolchain'
$OutDir       = Join-Path $JobDir 'out'
$ToolFamily   = 'Microsoft.MSIXPackagingTool_8wekyb3d8bbwe'
# Windows services (deployment, MSIX Packaging Tool) cannot use the mapped host folders ("Access denied"):
# the sandbox works on local copies; only results go back to the job folder.
$LocalDir     = 'C:\MsixStudioLocal'
$LocalInput   = Join-Path $LocalDir 'input'
$LocalOut     = Join-Path $LocalDir 'out'

# Logs go to %TEMP% while the sandbox works: the Packaging Tool excludes that folder from captures,
# a log file in the job folder could otherwise end up in the package. Copied to out\ at the end.
$TempLog = Join-Path $env:TEMP 'msixstudio'
New-Item -ItemType Directory $TempLog -Force | Out-Null
Start-Transcript -Path (Join-Path $TempLog 'bootstrap.log') -Force | Out-Null
$Host.UI.RawUI.WindowTitle = 'MSIX Sandbox Studio'
$job = Get-Content (Join-Path $JobDir 'job.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Set-JobStatus {
    param([string]$State, [string]$Step, [string]$Message = '', $Result = $null)
    Write-Host "[$State] $Step $Message" -ForegroundColor Cyan
    $status = [ordered]@{ State = $State; Step = $Step; Message = $Message; Result = $Result; Updated = (Get-Date).ToString('o') }
    # Write to a temp file first so the host never reads a half-written status.
    $tmp = Join-Path $JobDir 'status.tmp'
    $status | ConvertTo-Json -Depth 6 | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp (Join-Path $JobDir 'status.json') -Force
}

function Copy-JobInput {
    # Local copy of the job input (installers, base package, package to test), before any capture starts.
    New-Item -ItemType Directory $LocalInput, $LocalOut -Force | Out-Null
    Copy-Item (Join-Path $JobDir 'input\*') $LocalInput -Recurse -Force
}

function Install-PackagingTool {
    Set-JobStatus Running 'Installing MSIX Packaging Tool driver'
    # DISM wants a local .cab with the right extension.
    New-Item -ItemType Directory C:\Temp -Force | Out-Null
    $cab = 'C:\Temp\Msix-PackagingTool-Driver-Package.cab'
    Copy-Item (Join-Path $ToolchainDir 'Msix-PackagingTool-Driver-Package.cab') $cab -Force
    Add-WindowsPackage -Online -PackagePath $cab -NoRestart | Out-Null

    Set-JobStatus Running 'Installing MSIX Packaging Tool'
    # Local copies: the deployment service cannot read from the mapped (host) folder ("Access denied").
    $bundle = 'C:\Temp\MSIXPackagingTool.msixbundle'
    $license = 'C:\Temp\MSIXPackagingTool.License.xml'
    Copy-Item (Join-Path $ToolchainDir 'MSIXPackagingTool.msixbundle') $bundle -Force
    Copy-Item (Join-Path $ToolchainDir 'MSIXPackagingTool.License.xml') $license -Force
    Add-AppxProvisionedPackage -Online -PackagePath $bundle -LicensePath $license | Out-Null
    # Provisioned packages register at the next logon; register for the already logged-on user now.
    try { Add-AppxPackage -RegisterByFamilyName -MainPackage $ToolFamily }
    catch { Add-AppxPackage -Path $bundle }
    Get-AppxPackage -Name 'Microsoft.MSIXPackagingTool'
}

function Import-SigningCertificate {
    $cer = Join-Path $JobDir 'input\signing.cer'
    if (Test-Path $cer) {
        Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
        Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Write-Host 'Signing certificate trusted.'
    }
}

function Save-Screenshot {
    param([string]$Path)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

function Save-Logs {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
    Copy-Item (Join-Path $TempLog '*') $OutDir -Force -ErrorAction SilentlyContinue
}

function Close-Sandbox {
    Save-Logs
    if ($job.AutoClose) {
        Start-Sleep -Seconds 3
        shutdown.exe /s /t 0
    }
}

try {
    switch ($job.Mode) {
        'Interactive' {
            Import-SigningCertificate
            $tool = Install-PackagingTool
            $appId = (Get-AppxPackageManifest -Package $tool.PackageFullName).Package.Applications.Application.Id | Select-Object -First 1
            Start-Process "shell:AppsFolder\$($tool.PackageFamilyName)!$appId"
            Set-JobStatus Succeeded 'Ready' 'MSIX Packaging Tool is open. Save results to C:\MsixStudio\Shared.'
            Write-Host ''
            Write-Host "Publisher for packages: $($job.Publisher)" -ForegroundColor Yellow
            Write-Host 'Save packages to C:\MsixStudio\Shared - everything else is lost when the sandbox closes.' -ForegroundColor Yellow
        }

        'Package' {
            Copy-JobInput
            Install-PackagingTool | Out-Null
            # No status writes from here until the tool is done: the installer runs while the tool captures.
            Set-JobStatus Running "Converting $($job.Installer)"
            # App execution alias, created when the tool is registered for the user.
            $cli = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\MsixPackagingTool.exe'
            if (-not (Test-Path $cli)) { throw "MSIX Packaging Tool command line not found ($cli)." }
            # Windows PowerShell turns stderr lines of native tools into errors; with 'Stop' the first one would abort.
            $ErrorActionPreference = 'Continue'
            & $cli create-package --template (Join-Path $JobDir 'template.xml') -v 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath (Join-Path $TempLog 'conversion.log')
            $exit = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'

            # Keep the tool's own logs for troubleshooting.
            $logs = Join-Path $env:LOCALAPPDATA "Packages\$ToolFamily\LocalState\DiagOutputDir"
            if (Test-Path $logs) { Copy-Item $logs (Join-Path $OutDir 'PackagingToolLogs') -Recurse -Force -ErrorAction SilentlyContinue }

            # The template saves to the local folder; results go back to the job folder now.
            Copy-Item (Join-Path $LocalOut '*') $OutDir -Force -ErrorAction SilentlyContinue
            $msix = Join-Path $OutDir $job.PackageFile
            if (Test-Path $msix) {
                Set-JobStatus Succeeded 'Done' "Package created ($([math]::Round((Get-Item $msix).Length / 1MB, 1)) MB)."
            }
            else {
                Set-JobStatus Failed 'Conversion' "No package was created (exit code $exit). See conversion.log."
            }
        }

        'Record' {
            # The recorder shows the progress below (it reads status.json) and takes over once 'Ready'.
            Start-Process powershell.exe -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "$PSScriptRoot\Recorder.ps1"
            Set-JobStatus Running 'Copying installer'
            Copy-JobInput
            Import-SigningCertificate
            Install-PackagingTool | Out-Null
            # Logs first: once 'Ready' is out, the user may start recording and the job folder must stay untouched.
            Save-Logs
            Set-JobStatus Running 'Ready'
        }

        'Win32Lab' {
            # The lab panel shows the progress and takes over once 'Ready'; no Packaging Tool needed.
            Start-Process powershell.exe -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "$PSScriptRoot\Win32Lab.ps1"
            Set-JobStatus Running 'Copying the package content'
            Copy-JobInput
            Save-Logs
            Set-JobStatus Running 'Ready'
        }

        'Test' {
            Import-SigningCertificate
            Copy-JobInput
            $file = Join-Path $LocalInput $job.PackageFile
            Set-JobStatus Running 'Installing package'
            Add-AppxPackage -Path $file
            $pkg = Get-AppxPackage -Name $job.IdentityName | Select-Object -First 1
            if (-not $pkg) { throw 'The package was installed but cannot be found.' }

            $apps = @((Get-AppxPackageManifest -Package $pkg.PackageFullName).Package.Applications.Application)
            $results = @()
            $i = 0
            foreach ($app in $apps) {
                $i++
                Set-JobStatus Running "Starting app $i/$($apps.Count): $($app.Id)"
                $entry = [ordered]@{ Id = $app.Id; Executable = $app.Executable; Started = $false; Running = $false; Screenshot = '' }
                try {
                    Start-Process "shell:AppsFolder\$($pkg.PackageFamilyName)!$($app.Id)"
                    $entry.Started = $true
                    Start-Sleep -Seconds $job.DurationSeconds
                    $exe = [IO.Path]::GetFileNameWithoutExtension($app.Executable)
                    $entry.Running = [bool](Get-Process -Name $exe -ErrorAction SilentlyContinue)
                    $shot = Join-Path $OutDir ("{0:D2}-{1}.png" -f $i, $app.Id)
                    Save-Screenshot -Path $shot
                    $entry.Screenshot = Split-Path $shot -Leaf
                    Get-Process -Name $exe -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                }
                catch { $entry.Error = $_.Exception.Message }
                $results += [pscustomobject]$entry
            }

            Set-JobStatus Running 'Uninstalling package'
            $uninstalled = $true
            try { Remove-AppxPackage -Package $pkg.PackageFullName } catch { $uninstalled = $false }

            $result = [ordered]@{
                PackageFullName = $pkg.PackageFullName
                Installed       = $true
                Apps            = $results
                Uninstalled     = $uninstalled
            }
            $failed = @($results | Where-Object { -not $_.Running })
            if ($apps.Count -gt 0 -and $failed.Count -eq 0 -and $uninstalled) {
                Set-JobStatus Succeeded 'Done' "Installed, $($apps.Count) app(s) started and kept running, uninstalled cleanly." $result
            }
            else {
                $msg = "Installed. Apps not running after $($job.DurationSeconds) s: $(($failed | ForEach-Object Id) -join ', '). Uninstalled: $uninstalled."
                if ($apps.Count -eq 0) { $msg = 'Installed, but the package has no application entries.' }
                Set-JobStatus Failed 'Done' $msg $result
            }
        }
    }
}
catch {
    Set-JobStatus Failed 'Error' $_.Exception.Message
    if ($job.Mode -in 'Record', 'Win32Lab') { Save-Logs }
}
finally {
    # In Record mode the recorder owns the sandbox from 'Ready' on (no more writes here); it closes it itself.
    if ($job.Mode -notin 'Record', 'Win32Lab') { Close-Sandbox }
}
