# Package inspection and signing on the host (the private key never enters a sandbox).

function Get-MsixPackageInfo {
    <#
    .SYNOPSIS
    Reads identity, display name and applications from the AppxManifest.xml inside an .msix.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $entry = $zip.GetEntry('AppxManifest.xml')
        if (-not $entry) { throw 'AppxManifest.xml not found - is this an .msix package (not a bundle)?' }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $signed = [bool]$zip.GetEntry('AppxSignature.p7x')
    }
    finally { $zip.Dispose() }

    $id = $manifest.Package.Identity
    [pscustomobject]@{
        Path                 = (Resolve-Path -LiteralPath $Path).Path
        Name                 = $id.Name
        Publisher            = $id.Publisher
        Version              = $id.Version
        Architecture         = $(if ($id.ProcessorArchitecture) { $id.ProcessorArchitecture } else { 'neutral' })
        DisplayName          = $manifest.Package.Properties.DisplayName
        PublisherDisplayName = $manifest.Package.Properties.PublisherDisplayName
        Description          = $manifest.Package.Properties.Description
        Applications         = @($manifest.Package.Applications.Application | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Executable = $_.Executable } })
        IsSigned             = $signed
        SizeBytes            = (Get-Item -LiteralPath $Path).Length
    }
}

function Invoke-MsixSigning {
    <#
    .SYNOPSIS
    Signs an .msix with the configured certificate (signtool from the toolchain, SHA256, RFC 3161 timestamp).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $toolchain = Get-MsixToolchain
    if (-not ($toolchain -and (Test-Path $toolchain.SignTool))) { throw 'signtool not found - run Update-MsixToolchain first.' }
    $cert = Get-MsixCertificate
    if (-not $cert) { throw 'No signing certificate configured.' }
    $password = Get-MsixCertificatePassword
    if (-not $password) { throw 'The certificate password is not stored; import the certificate again.' }

    $pkg = Get-MsixPackageInfo -Path $Path
    if ($pkg.Publisher -ne $cert.Subject) {
        throw "Publisher mismatch: package says '$($pkg.Publisher)', certificate is '$($cert.Subject)'. Repackage with the current certificate."
    }

    $plain = ConvertTo-MsixPlainText $password
    $base = @('sign', '/fd', 'SHA256', '/f', $cert.PfxPath, '/p', $plain)
    $timestamp = (Get-MsixSettings).TimestampUrl
    $attempts = @()
    if ($timestamp) { $attempts += , @('/tr', $timestamp, '/td', 'SHA256') }
    $attempts += , @()   # without timestamp as fallback (offline)

    foreach ($extra in $attempts) {
        $out = & $toolchain.SignTool @($base + $extra + @($pkg.Path)) 2>&1
        if ($LASTEXITCODE -eq 0) {
            if (-not $extra) { Write-MsixLog 'Signed WITHOUT timestamp (timestamp server not reachable): the signature expires with the certificate.' -Level Warning }
            Write-MsixLog "Signed: $(Split-Path $pkg.Path -Leaf)" -Level Success
            return Get-MsixPackageInfo -Path $pkg.Path
        }
        $msg = ($out | Out-String).Replace($plain, '***').Trim()
        Write-MsixLog "signtool: $msg" -Level Warning
    }
    throw 'Signing failed, see the signtool output above.'
}
