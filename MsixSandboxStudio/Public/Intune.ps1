# Intune via Microsoft Graph: upload an .msix as line-of-business app (windowsUniversalAppX),
# deploy the signing certificate as trusted root profile, assign both to groups.
# Needs Microsoft.Graph.Authentication; all requests go through Invoke-MgGraphRequest.

$script:GraphScopes = @(
    'DeviceManagementApps.ReadWrite.All'
    'DeviceManagementConfiguration.ReadWrite.All'
    'Group.Read.All'
)

function Connect-MsixIntune {
    [CmdletBinding()]
    param([string]$TenantId)
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        throw 'Module Microsoft.Graph.Authentication is not installed (Install-Module Microsoft.Graph.Authentication -Scope CurrentUser).'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $p = @{ Scopes = $script:GraphScopes; NoWelcome = $true }
    if ($TenantId) { $p.TenantId = $TenantId }
    Connect-MgGraph @p -ErrorAction Stop
    $ctx = Get-MgContext
    Write-MsixLog "Signed in to Microsoft Graph as $($ctx.Account) (tenant $($ctx.TenantId))." -Level Success
    $ctx
}

function Disconnect-MsixIntune {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Write-MsixLog 'Signed out of Microsoft Graph.'
}

function Get-MsixIntuneContext {
    if (-not (Get-Command Get-MgContext -ErrorAction SilentlyContinue)) { return $null }
    Get-MgContext
}

function Invoke-MsixGraph {
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Uri, $Body)
    $p = @{ Method = $Method; Uri = "https://graph.microsoft.com/v1.0/$Uri"; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10); $p.ContentType = 'application/json' }
    Invoke-MgGraphRequest @p
}

function Get-MsixPublisherHash {
    <#
    .SYNOPSIS
    Computes the 13-character publisher ID of a package family name from the publisher string
    (SHA256 over UTF-16LE, first 64 bits, Crockford-style base32).
    #>
    param([Parameter(Mandatory)][string]$Publisher)
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::Unicode.GetBytes($Publisher))
    $bits = ($hash[0..7] | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    $bits += '0'   # 64 bits -> 65 = 13 groups of 5
    $alphabet = '0123456789abcdefghjkmnpqrstvwxyz'
    -join (0..12 | ForEach-Object { $alphabet[[Convert]::ToInt32($bits.Substring($_ * 5, 5), 2)] })
}

function Protect-MsixIntuneFile {
    <#
    Encrypts a file the way Intune expects LOB content: AES-256-CBC, output = HMAC(32) + IV(16) + ciphertext,
    HMAC-SHA256 over IV + ciphertext. Returns the encryption info for the commit call.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target)
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256
    $aes.GenerateKey(); $aes.GenerateIV()
    $hmacKey = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($hmacKey)

    $out = [IO.File]::Open($Target, 'Create', 'ReadWrite')
    try {
        $out.Write((New-Object byte[] 32), 0, 32)
        $out.Write($aes.IV, 0, $aes.IV.Length)
        $in = [IO.File]::OpenRead($Source)
        $crypto = New-Object Security.Cryptography.CryptoStream($out, $aes.CreateEncryptor(), 'Write')
        $in.CopyTo($crypto)
        $crypto.FlushFinalBlock()
        $in.Dispose()

        $out.Seek(32, 'Begin') | Out-Null
        $hmac = New-Object Security.Cryptography.HMACSHA256 (, $hmacKey)
        $mac = $hmac.ComputeHash($out)
        $out.Seek(0, 'Begin') | Out-Null
        $out.Write($mac, 0, $mac.Length)
    }
    finally { $out.Dispose() }

    $digest = [Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($Source))
    [ordered]@{
        encryptionKey        = [Convert]::ToBase64String($aes.Key)
        macKey               = [Convert]::ToBase64String($hmacKey)
        initializationVector = [Convert]::ToBase64String($aes.IV)
        mac                  = [Convert]::ToBase64String($mac)
        profileIdentifier    = 'ProfileVersion1'
        fileDigest           = [Convert]::ToBase64String($digest)
        fileDigestAlgorithm  = 'SHA256'
    }
}

function Wait-MsixContentFile {
    param([string]$FileUri, [string]$State)
    for ($i = 0; $i -lt 120; $i++) {
        $f = Invoke-MsixGraph -Uri $FileUri
        if ($f.uploadState -eq $State) { return $f }
        if ($f.uploadState -match 'Failed|TimedOut') { throw "Intune upload state: $($f.uploadState)" }
        Start-Sleep -Seconds 2
    }
    throw "Intune did not reach '$State' in time."
}

function Send-MsixBlob {
    # Uploads to the Azure Storage SAS URI in 4 MB blocks, then commits the block list.
    param([string]$SasUri, [string]$Path)
    $blockSize = 4MB
    $ids = @()
    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] $blockSize
        $n = 0
        while (($read = $stream.Read($buffer, 0, $blockSize)) -gt 0) {
            $id = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($n.ToString('0000')))
            $chunk = if ($read -eq $blockSize) { $buffer } else { $buffer[0..($read - 1)] }
            Invoke-WebRequest -Method Put -Uri "$SasUri&comp=block&blockid=$([uri]::EscapeDataString($id))" `
                -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -Body ([byte[]]$chunk) -UseBasicParsing | Out-Null
            $ids += $id
            $n++
        }
    }
    finally { $stream.Dispose() }
    $xml = '<?xml version="1.0" encoding="utf-8"?><BlockList>' + (($ids | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
    Invoke-WebRequest -Method Put -Uri "$SasUri&comp=blocklist" -Body $xml -ContentType 'application/xml' -UseBasicParsing | Out-Null
}

function Publish-MsixToIntune {
    <#
    .SYNOPSIS
    Uploads a signed .msix to Intune as line-of-business app. An existing app with the same identity
    name gets the new version; otherwise a new app is created. Optionally assigns it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$GroupId,
        [ValidateSet('required', 'available', 'uninstall')][string]$Intent = 'required'
    )
    if (-not (Get-MsixIntuneContext)) { Connect-MsixIntune | Out-Null }
    $pkg = Get-MsixPackageInfo -Path $Path
    if (-not $pkg.IsSigned) { throw 'The package is not signed; Intune would reject it on the devices.' }

    $arch = switch ($pkg.Architecture) { 'x64' { 'x64' } 'x86' { 'x86' } 'arm64' { 'arm64' } 'arm' { 'arm' } default { 'neutral' } }
    $appBody = [ordered]@{
        '@odata.type'                    = '#microsoft.graph.windowsUniversalAppX'
        displayName                      = $pkg.DisplayName
        description                      = $(if ($pkg.Description) { $pkg.Description } else { $pkg.DisplayName })
        publisher                        = $pkg.PublisherDisplayName
        fileName                         = Split-Path $Path -Leaf
        applicableArchitectures          = $arch
        applicableDeviceTypes            = 'desktop'
        identityName                     = $pkg.Name
        identityPublisherHash            = Get-MsixPublisherHash -Publisher $pkg.Publisher
        identityVersion                  = $pkg.Version
        isBundle                         = $false
        minimumSupportedOperatingSystem  = @{ v10_0 = $true }
    }

    $existing = (Invoke-MsixGraph -Uri "deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.windowsUniversalAppX')").value |
        Where-Object { $_.identityName -eq $pkg.Name } | Select-Object -First 1
    if ($existing) {
        Write-MsixLog "Updating Intune app '$($existing.displayName)' to $($pkg.Version) ..."
        $appId = $existing.id
    }
    else {
        Write-MsixLog "Creating Intune app '$($pkg.DisplayName)' ..."
        $appId = (Invoke-MsixGraph -Method POST -Uri 'deviceAppManagement/mobileApps' -Body $appBody).id
    }
    $base = "deviceAppManagement/mobileApps/$appId/microsoft.graph.windowsUniversalAppX"
    $cv = (Invoke-MsixGraph -Method POST -Uri "$base/contentVersions" -Body @{}).id

    $encrypted = Join-Path ([IO.Path]::GetTempPath()) ("{0}.enc" -f [guid]::NewGuid())
    try {
        Write-MsixLog 'Encrypting package for upload ...'
        $encInfo = Protect-MsixIntuneFile -Source $pkg.Path -Target $encrypted
        $fileBody = [ordered]@{
            '@odata.type' = '#microsoft.graph.mobileAppContentFile'
            name          = Split-Path $Path -Leaf
            size          = $pkg.SizeBytes
            sizeEncrypted = (Get-Item $encrypted).Length
            manifest      = $null
            isDependency  = $false
        }
        $fileId = (Invoke-MsixGraph -Method POST -Uri "$base/contentVersions/$cv/files" -Body $fileBody).id
        $fileUri = "$base/contentVersions/$cv/files/$fileId"
        $file = Wait-MsixContentFile -FileUri $fileUri -State 'azureStorageUriRequestSuccess'

        Write-MsixLog "Uploading $([math]::Round($fileBody.sizeEncrypted / 1MB, 1)) MB ..."
        Send-MsixBlob -SasUri $file.azureStorageUri -Path $encrypted
        Invoke-MsixGraph -Method POST -Uri "$fileUri/commit" -Body @{ fileEncryptionInfo = $encInfo } | Out-Null
        Wait-MsixContentFile -FileUri $fileUri -State 'commitFileSuccess' | Out-Null
    }
    finally { Remove-Item $encrypted -Force -ErrorAction SilentlyContinue }

    $patch = [ordered]@{ '@odata.type' = '#microsoft.graph.windowsUniversalAppX'; committedContentVersion = $cv }
    if ($existing) { $patch.identityVersion = $pkg.Version; $patch.fileName = $appBody.fileName }
    Invoke-MsixGraph -Method PATCH -Uri "deviceAppManagement/mobileApps/$appId" -Body $patch | Out-Null
    Write-MsixLog "Intune app ready: $($pkg.DisplayName) $($pkg.Version)" -Level Success

    if ($GroupId) { Set-MsixIntuneAssignment -AppId $appId -GroupId $GroupId -Intent $Intent }
    [pscustomobject]@{ AppId = $appId; DisplayName = $pkg.DisplayName; Version = $pkg.Version; Updated = [bool]$existing }
}

function Set-MsixIntuneAssignment {
    <# Assigns an Intune app to a group (replaces the app's existing assignments). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$GroupId,
        [ValidateSet('required', 'available', 'uninstall')][string]$Intent = 'required'
    )
    $body = @{ mobileAppAssignments = @(@{
        '@odata.type' = '#microsoft.graph.mobileAppAssignment'
        intent        = $Intent
        target        = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $GroupId }
    }) }
    Invoke-MsixGraph -Method POST -Uri "deviceAppManagement/mobileApps/$AppId/assign" -Body $body | Out-Null
    Write-MsixLog "Assigned ($Intent) to group $GroupId." -Level Success
}

function Find-MsixIntuneGroup {
    <# Searches Entra groups by display name (for the group picker). #>
    param([Parameter(Mandatory)][string]$Search)
    $s = $Search.Replace("'", "''")
    (Invoke-MsixGraph -Uri "groups?`$filter=startswith(displayName,'$s')&`$select=id,displayName&`$top=25").value |
        ForEach-Object { [pscustomobject]@{ Id = $_.id; DisplayName = $_.displayName } }
}

function Publish-MsixCertificateToIntune {
    <#
    .SYNOPSIS
    Creates a Windows "Trusted certificate" profile with the signing certificate, so devices trust the packages.
    #>
    [CmdletBinding()]
    param([string]$GroupId)
    if (-not (Get-MsixIntuneContext)) { Connect-MsixIntune | Out-Null }
    $cert = Get-MsixCertificate
    if (-not $cert) { throw 'No signing certificate configured.' }
    $name = "MSIX signing certificate - $($cert.Subject -replace '^CN=', '')"
    $existing = (Invoke-MsixGraph -Uri 'deviceManagement/deviceConfigurations').value |
        Where-Object { $_.displayName -eq $name } | Select-Object -First 1
    if ($existing) {
        Write-MsixLog "Profile '$name' already exists." -Level Warning
        $id = $existing.id
    }
    else {
        $body = [ordered]@{
            '@odata.type'          = '#microsoft.graph.windows81TrustedRootCertificate'
            displayName            = $name
            description            = "Trusts MSIX packages signed by $($cert.Subject) (thumbprint $($cert.Thumbprint))."
            trustedRootCertificate = [Convert]::ToBase64String([IO.File]::ReadAllBytes($cert.CerPath))
            certFileName           = Split-Path $cert.CerPath -Leaf
            destinationStore       = 'computerCertStoreRoot'
        }
        $id = (Invoke-MsixGraph -Method POST -Uri 'deviceManagement/deviceConfigurations' -Body $body).id
        Write-MsixLog "Created profile '$name'." -Level Success
    }
    if ($GroupId) {
        $assign = @{ assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $GroupId } }) }
        Invoke-MsixGraph -Method POST -Uri "deviceManagement/deviceConfigurations/$id/assign" -Body $assign | Out-Null
        Write-MsixLog "Profile assigned to group $GroupId." -Level Success
    }
    [pscustomobject]@{ ProfileId = $id; DisplayName = $name }
}
