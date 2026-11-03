# Toolchain cache on the host: MSIX Packaging Tool (bundle + offline license), its driver (FOD cab)
# and the Windows SDK signing tools. Downloaded once, mapped read-only into every sandbox.

$script:LearnOfflinePage = 'https://learn.microsoft.com/en-us/windows/msix/packaging-tool/disconnected-environment'

# Used when the Learn page cannot be read or its layout changed.
$script:FallbackSource = [pscustomobject]@{
    Version    = '1.2024.405.0'
    BundleUrl  = 'https://download.microsoft.com/download/e/2/e/e2e923b2-7a3a-4730-969d-ab37001fbb5e/MSIXPackagingtoolv1.2024.405.0.msixbundle'
    LicenseUrl = 'https://download.microsoft.com/download/e/2/e/e2e923b2-7a3a-4730-969d-ab37001fbb5e/MSIXPackagingtoolv1.2024.405.0.License.xml'
    DriverUrl  = 'https://download.microsoft.com/download/6/c/7/6c7d654b-580b-40d4-8502-f8d435ca125a/Msix-PackagingTool-Driver-Package%7E31bf3856ad364e35%7Eamd64%7E%7E.cab'
}

function Get-MsixToolchainSource {
    <#
    .SYNOPSIS
    Finds the current offline download of the MSIX Packaging Tool on Microsoft Learn.
    Falls back to the last known version if the page cannot be parsed.
    #>
    [CmdletBinding()]
    param()
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $html = (Invoke-WebRequest -Uri $script:LearnOfflinePage -UseBasicParsing -TimeoutSec 20).Content
        $bundle  = [regex]::Match($html, 'https://download\.microsoft\.com/[^"''\s]+?MSIXPackagingtoolv([\d\.]+?)\.msixbundle', 'IgnoreCase')
        $license = [regex]::Match($html, 'https://download\.microsoft\.com/[^"''\s]+?\.License\.xml', 'IgnoreCase')
        # Windows 11 driver: <a href="...amd64...cab">Windows 11, version 21H2, x64</a>
        $driver  = [regex]::Match($html, 'href="(https://download\.microsoft\.com/[^"]+?amd64[^"]*?\.cab)"[^>]*>[^<]*Windows 11', 'IgnoreCase')
        if ($bundle.Success -and $license.Success -and $driver.Success) {
            return [pscustomobject]@{
                Version    = $bundle.Groups[1].Value.TrimEnd('.')
                BundleUrl  = $bundle.Value
                LicenseUrl = $license.Value
                DriverUrl  = $driver.Groups[1].Value
            }
        }
        Write-MsixLog 'Learn page layout not recognized, using the last known download links.' -Level Warning
    }
    catch {
        Write-MsixLog "Learn page not reachable ($($_.Exception.Message)), using the last known download links." -Level Warning
    }
    $script:FallbackSource
}

function Get-MsixToolchain {
    <#
    .SYNOPSIS
    Returns the cached toolchain (versions, file paths) or $null if nothing is cached yet.
    #>
    [CmdletBinding()]
    param([switch]$VerifyHash)
    $dir = (Get-MsixWorkspace).Toolchain
    $manifestPath = Join-Path $dir 'toolchain.json'
    if (-not (Test-Path $manifestPath)) { return $null }
    $m = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ok = $true
    foreach ($f in $m.Files) {
        $p = Join-Path $dir $f.Name
        if (-not (Test-Path $p)) { $ok = $false; continue }
        if ($VerifyHash -and (Get-MsixSha256 $p) -ne $f.Sha256) {
            Write-MsixLog "Hash mismatch: $($f.Name)" -Level Error
            $ok = $false
        }
    }
    $signtool = Join-Path $dir 'SdkTools\signtool.exe'
    [pscustomobject]@{
        Path            = $dir
        Version         = $m.Version
        SdkToolsVersion = $m.SdkToolsVersion
        Downloaded      = [datetime]$m.Downloaded
        Bundle          = Join-Path $dir 'MSIXPackagingTool.msixbundle'
        License         = Join-Path $dir 'MSIXPackagingTool.License.xml'
        Driver          = Join-Path $dir 'Msix-PackagingTool-Driver-Package.cab'
        SignTool        = $signtool
        IsComplete      = $ok -and (Test-Path $signtool)
        Files           = $m.Files
    }
}

function Update-MsixToolchain {
    <#
    .SYNOPSIS
    Downloads the MSIX Packaging Tool, license, driver and the SDK signing tools into the workspace.
    Skips the download if the cached version is already current, unless -Force.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    $dir = (Get-MsixWorkspace).Toolchain
    $source = Get-MsixToolchainSource
    $current = Get-MsixToolchain
    if (-not $Force -and $current -and $current.IsComplete -and $current.Version -eq $source.Version) {
        Write-MsixLog "Toolchain is current (MSIX Packaging Tool $($current.Version))." -Level Success
        return $current
    }

    $files = @(
        @{ Name = 'MSIXPackagingTool.msixbundle';          Url = $source.BundleUrl }
        @{ Name = 'MSIXPackagingTool.License.xml';         Url = $source.LicenseUrl }
        @{ Name = 'Msix-PackagingTool-Driver-Package.cab'; Url = $source.DriverUrl }
    )
    foreach ($f in $files) {
        Write-MsixLog "Downloading $($f.Name) ..."
        Invoke-MsixDownload -Uri $f.Url -Destination (Join-Path $dir $f.Name)
    }

    $sdkVersion = Update-MsixSdkTools -Destination (Join-Path $dir 'SdkTools')

    $manifest = [ordered]@{
        Version         = $source.Version
        SdkToolsVersion = $sdkVersion
        Downloaded      = (Get-Date).ToString('o')
        Files           = @($files | ForEach-Object {
            [ordered]@{ Name = $_.Name; Url = $_.Url; Sha256 = (Get-MsixSha256 (Join-Path $dir $_.Name)) }
        })
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $dir 'toolchain.json') -Encoding UTF8
    Write-MsixLog "Toolchain ready: MSIX Packaging Tool $($source.Version), SDK tools $sdkVersion." -Level Success
    Get-MsixToolchain
}

function Update-MsixSdkTools {
    <# Extracts signtool/makeappx (x64) from the Microsoft.Windows.SDK.BuildTools NuGet package. Returns its version. #>
    param([Parameter(Mandatory)][string]$Destination)
    $index = Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/index.json' -TimeoutSec 20
    $version = @($index.versions | Where-Object { $_ -notmatch '-' })[-1]
    Write-MsixLog "Downloading Windows SDK build tools $version (signtool, makeappx) ..."
    $nupkg = Join-Path ([IO.Path]::GetTempPath()) "sdkbuildtools-$version.zip"
    Invoke-MsixDownload -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.buildtools/$version/microsoft.windows.sdk.buildtools.$version.nupkg" -Destination $nupkg

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
    try {
        $entries = @($zip.Entries | Where-Object { $_.FullName -match '^bin/[\d\.]+/x64/' -and $_.Name })
        if (-not $entries) { throw 'The SDK build tools package contains no x64 tools.' }
        foreach ($e in $entries) {
            $rel = $e.FullName -replace '^bin/[\d\.]+/x64/', ''
            $target = Join-Path $Destination ($rel -replace '/', '\')
            $targetDir = Split-Path $target -Parent
            if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    }
    finally { $zip.Dispose(); Remove-Item $nupkg -Force -ErrorAction SilentlyContinue }
    $version
}
