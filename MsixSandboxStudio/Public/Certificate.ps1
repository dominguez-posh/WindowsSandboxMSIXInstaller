# Signing certificate, kept on the host only. The PFX password is stored DPAPI-encrypted
# (readable only by the same Windows user on the same machine) so signing can run unattended.

function Get-MsixCertificate {
    <#
    .SYNOPSIS
    Returns the configured signing certificate (subject, thumbprint, expiry, file paths) or $null.
    #>
    [CmdletBinding()]
    param()
    $pfx = (Get-MsixSettings).CertificatePath
    if (-not $pfx -or -not (Test-Path $pfx)) { return $null }
    $cer = [IO.Path]::ChangeExtension($pfx, '.cer')
    $pwdFile = [IO.Path]::ChangeExtension($pfx, '.pwd')
    $info = $null
    if (Test-Path $cer) {
        $info = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $cer
    }
    [pscustomobject]@{
        Subject     = if ($info) { $info.Subject } else { $null }
        Thumbprint  = if ($info) { $info.Thumbprint } else { $null }
        NotAfter    = if ($info) { $info.NotAfter } else { $null }
        IsExpired   = if ($info) { $info.NotAfter -lt (Get-Date) } else { $null }
        PfxPath     = $pfx
        CerPath     = $cer
        HasPassword = Test-Path $pwdFile
    }
}

function Get-MsixCertificatePassword {
    <# Reads the DPAPI-protected PFX password as SecureString, or $null. #>
    $cert = Get-MsixCertificate
    if (-not $cert -or -not $cert.HasPassword) { return $null }
    (Get-Content ([IO.Path]::ChangeExtension($cert.PfxPath, '.pwd')) -Raw).Trim() | ConvertTo-SecureString
}

function ConvertTo-MsixPlainText {
    param([Parameter(Mandatory)][Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Register-MsixCertificateFiles {
    # Copies/exports pfx + cer into the workspace, stores the password, makes it the active certificate.
    param(
        [Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][byte[]]$PfxBytes,
        [Parameter(Mandatory)][Security.SecureString]$Password
    )
    $name = ($Certificate.GetNameInfo('SimpleName', $false) -replace '[^\w\.-]', '_') + '_' + $Certificate.Thumbprint.Substring(0, 8)
    $dir = (Get-MsixWorkspace).Certificates
    $pfxPath = Join-Path $dir "$name.pfx"
    [IO.File]::WriteAllBytes($pfxPath, $PfxBytes)
    [IO.File]::WriteAllBytes([IO.Path]::ChangeExtension($pfxPath, '.cer'), $Certificate.Export('Cert'))
    ConvertFrom-SecureString $Password | Set-Content ([IO.Path]::ChangeExtension($pfxPath, '.pwd'))
    Set-MsixSettings @{ CertificatePath = $pfxPath } | Out-Null
    Write-MsixLog "Signing certificate active: $($Certificate.Subject) ($($Certificate.Thumbprint))" -Level Success
    Get-MsixCertificate
}

function New-MsixCertificate {
    <#
    .SYNOPSIS
    Creates a self-signed code-signing certificate and makes it the active signing certificate.
    .PARAMETER Subject
    Becomes the Publisher of every package (e.g. "CN=Contoso Packaging").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^CN=')][string]$Subject,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [ValidateRange(1, 30)][int]$Years = 5
    )
    $cert = New-SelfSignedCertificate -Type Custom -Subject $Subject -KeyUsage DigitalSignature `
        -FriendlyName "MSIX Sandbox Studio - $Subject" -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}') `
        -KeyExportPolicy Exportable -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddYears($Years)
    try {
        $bytes = $cert.Export('Pfx', (ConvertTo-MsixPlainText $Password))
        $public = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $cert.Export('Cert'))
        Register-MsixCertificateFiles -Certificate $public -PfxBytes $bytes -Password $Password
    }
    finally {
        # The private key lives in the PFX only, not in the user's certificate store.
        Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -DeleteKey -ErrorAction SilentlyContinue
    }
}

function Import-MsixCertificate {
    <#
    .SYNOPSIS
    Uses an existing PFX (internal CA, public CA or an earlier self-signed one) as signing certificate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PfxPath,
        [Parameter(Mandatory)][Security.SecureString]$Password
    )
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path $PfxPath))
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $bytes, $Password
    if (-not $cert.HasPrivateKey) { throw 'The PFX contains no private key.' }
    $eku = $cert.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] }
    if ($eku -and -not ($eku.EnhancedKeyUsages | Where-Object Value -eq '1.3.6.1.5.5.7.3.3')) {
        Write-MsixLog 'The certificate has no Code Signing usage; signing will probably fail.' -Level Warning
    }
    Register-MsixCertificateFiles -Certificate $cert -PfxBytes $bytes -Password $Password
}

function Import-MsixCertificateFromKeyVault {
    <#
    .SYNOPSIS
    Downloads a certificate (with private key) from Azure Key Vault and makes it the signing certificate.
    Needs the Az.KeyVault module and a signed-in Az session (Connect-AzAccount).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$CertificateName,
        [Parameter(Mandatory)][Security.SecureString]$Password
    )
    if (-not (Get-Module -ListAvailable Az.KeyVault)) { throw 'Module Az.KeyVault is not installed (Install-Module Az.KeyVault).' }
    Import-Module Az.KeyVault -ErrorAction Stop
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) { Connect-AzAccount -ErrorAction Stop | Out-Null }
    # A Key Vault certificate's private key is exposed as a secret with the same name (PFX, base64, no password).
    $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $CertificateName -AsPlainText -ErrorAction Stop
    $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList ([Convert]::FromBase64String($secret)), '', $flags
    $bytes = $cert.Export('Pfx', (ConvertTo-MsixPlainText $Password))
    Set-MsixSettings @{ KeyVaultName = $VaultName; KeyVaultCertName = $CertificateName } | Out-Null
    Register-MsixCertificateFiles -Certificate $cert -PfxBytes $bytes -Password $Password
}
