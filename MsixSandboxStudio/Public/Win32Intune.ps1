# Upload of Win32 apps (.intunewin) to Intune via Microsoft Graph, with supersedence and assignment.
# The .intunewin already holds the encrypted content and its keys (Detection.xml); the upload sends the
# encrypted file to Azure Storage and commits it with those keys.

function Get-MsixGraphPage {
    # Follows @odata.nextLink and returns all items of a Graph collection.
    param([Parameter(Mandatory)][string]$Uri)
    $next = "https://graph.microsoft.com/v1.0/$Uri"
    while ($next) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
        foreach ($v in $page.value) { $v }
        $next = $page.'@odata.nextLink'
    }
}

function Find-IntuneWin32App {
    <#
    .SYNOPSIS
    Lists Win32 apps in Intune whose name contains the search text (for choosing the app to supersede).
    #>
    [CmdletBinding()]
    param([string]$Search = '')
    $apps = Get-MsixGraphPage -Uri "deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')&`$select=id,displayName,displayVersion,publisher,createdDateTime"
    $apps | Where-Object { -not $Search -or $_.displayName -like "*$Search*" } | Sort-Object { $_.displayName } | ForEach-Object {
        [pscustomobject]@{ Id = $_.id; DisplayName = $_.displayName; Version = $_.displayVersion; Publisher = $_.publisher; Created = $_.createdDateTime }
    }
}

function Publish-Win32AppToIntune {
    <#
    .SYNOPSIS
    Uploads a Win32 build (folder with .intunewin and intune-app.json) to Intune as a new app.
    .PARAMETER SupersedeAppId
    Intune app that the new app supersedes (the previous version).
    .PARAMETER SupersedenceType
    update: the new app is installed over the old one. replace: the old app is uninstalled first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BuildPath,
        [string]$DisplayName,
        [string]$Description,
        [string]$Publisher,
        [string]$SupersedeAppId,
        [ValidateSet('update', 'replace')][string]$SupersedenceType = 'update',
        [string]$GroupId,
        [ValidateSet('required', 'available', 'uninstall')][string]$Intent = 'required'
    )
    if (-not (Get-MsixIntuneContext)) { Connect-MsixIntune | Out-Null }
    $def = Get-Content (Join-Path $BuildPath 'intune-app.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $file = Join-Path $BuildPath $def.fileName
    $iw = Get-IntuneWinInfo -Path $file
    if (-not $DisplayName) { $DisplayName = $def.displayName }
    if (-not $Description) { $Description = $def.description }
    if (-not $Publisher) { $Publisher = $def.publisher }
    if (-not $Publisher) { $Publisher = $DisplayName }   # required by Intune

    $rule = @{}
    foreach ($prop in $def.detectionRule.PSObject.Properties) { $rule[$prop.Name] = $prop.Value }
    $body = [ordered]@{
        '@odata.type'                   = '#microsoft.graph.win32LobApp'
        displayName                     = $DisplayName
        description                     = $Description
        publisher                       = $Publisher
        displayVersion                  = $def.displayVersion
        fileName                        = $def.fileName
        setupFilePath                   = $def.setupFilePath
        installCommandLine              = $def.installCommandLine
        uninstallCommandLine            = $def.uninstallCommandLine
        applicableArchitectures         = $def.applicableArchitectures
        minimumSupportedWindowsRelease  = $def.minimumSupportedWindowsRelease
        installExperience               = [ordered]@{ '@odata.type' = 'microsoft.graph.win32LobAppInstallExperience'; runAsAccount = $def.runAsAccount; deviceRestartBehavior = $def.deviceRestartBehavior }
        returnCodes                     = @($def.returnCodes | ForEach-Object { [ordered]@{ '@odata.type' = '#microsoft.graph.win32LobAppReturnCode'; returnCode = [int]$_.returnCode; type = $_.type } })
        rules                           = @($rule)
    }
    Write-MsixLog "Creating Intune Win32 app '$DisplayName' $($def.displayVersion) ..."
    $appId = (Invoke-MsixGraph -Method POST -Uri 'deviceAppManagement/mobileApps' -Body $body).id
    $base = "deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp"
    $cv = (Invoke-MsixGraph -Method POST -Uri "$base/contentVersions" -Body @{}).id

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("iwupload-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $temp | Out-Null
    try {
        # The encrypted inner file is uploaded as is; size = unencrypted content, sizeEncrypted = this file
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($iw.Path)
        $encrypted = Join-Path $temp 'IntunePackage.intunewin'
        try { [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry($iw.ContentEntry), $encrypted, $true) } finally { $zip.Dispose() }
        $fileBody = [ordered]@{
            '@odata.type' = '#microsoft.graph.mobileAppContentFile'
            name          = $def.fileName
            size          = $iw.UnencryptedContentSize
            sizeEncrypted = (Get-Item $encrypted).Length
            manifest      = $null
            isDependency  = $false
        }
        $fileId = (Invoke-MsixGraph -Method POST -Uri "$base/contentVersions/$cv/files" -Body $fileBody).id
        $fileUri = "$base/contentVersions/$cv/files/$fileId"
        $f = Wait-MsixContentFile -FileUri $fileUri -State 'azureStorageUriRequestSuccess'
        Write-MsixLog "Uploading $([math]::Round($fileBody.sizeEncrypted / 1MB, 1)) MB ..."
        Send-MsixBlob -SasUri $f.azureStorageUri -Path $encrypted
        Invoke-MsixGraph -Method POST -Uri "$fileUri/commit" -Body @{ fileEncryptionInfo = $iw.EncryptionInfo } | Out-Null
        Wait-MsixContentFile -FileUri $fileUri -State 'commitFileSuccess' | Out-Null
    }
    finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    Invoke-MsixGraph -Method PATCH -Uri "deviceAppManagement/mobileApps/$appId" -Body ([ordered]@{ '@odata.type' = '#microsoft.graph.win32LobApp'; committedContentVersion = $cv }) | Out-Null
    Write-MsixLog "Intune Win32 app ready: $DisplayName $($def.displayVersion)" -Level Success

    if ($SupersedeAppId) {
        $rel = @{ relationships = @(@{ '@odata.type' = '#microsoft.graph.mobileAppSupersedence'; targetId = $SupersedeAppId; supersedenceType = $SupersedenceType }) }
        Invoke-MsixGraph -Method POST -Uri "deviceAppManagement/mobileApps/$appId/updateRelationships" -Body $rel | Out-Null
        Write-MsixLog "Supersedence set ($SupersedenceType): the new app supersedes $SupersedeAppId." -Level Success
    }
    if ($GroupId) { Set-MsixIntuneAssignment -AppId $appId -GroupId $GroupId -Intent $Intent }

    # Remember where it went (shown in the documentation and the GUI)
    $published = [ordered]@{ appId = $appId; date = (Get-Date).ToString('o'); supersedes = $SupersedeAppId; supersedenceType = $(if ($SupersedeAppId) { $SupersedenceType }); groupId = $GroupId; intent = $(if ($GroupId) { $Intent }) }
    $paramFile = Join-Path $BuildPath 'intune-app.json'
    $json = Get-Content $paramFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $json | Add-Member -NotePropertyName published -NotePropertyValue ([pscustomobject]$published) -Force
    $json | ConvertTo-Json -Depth 8 | Set-Content $paramFile -Encoding UTF8
    [pscustomobject]@{ AppId = $appId; DisplayName = $DisplayName; Version = $def.displayVersion; Supersedes = $SupersedeAppId }
}
