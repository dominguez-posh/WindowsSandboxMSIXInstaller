# Win32 apps for Intune (.intunewin): projects with install / uninstall / detection / update scripts,
# a test lab in Windows Sandbox (Install, Detect, Uninstall, update from the previous version), the
# .intunewin package itself and the parameter file (intune-app.json) with every Intune setting.
#
# Project folder: Workspace\Win32Apps\<Id>\project.json + source\ (installer files and the scripts)
# Build folder:   Workspace\Output\Win32\<Id>_<Version>\ (.intunewin, intune-app.json, scripts\, documentation\)

$script:Win32InstallCommand   = '"%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File ".\Install.ps1"'
$script:Win32UninstallCommand = '"%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File ".\Uninstall.ps1"'

# ---------------------------------------------------------------- projects

function ConvertTo-Win32AppId {
    param([string]$Name)
    $id = ($Name -replace '[^A-Za-z0-9\.\-_]', '').Trim('.', '-')
    if (-not $id) { $id = 'Win32App' }
    $id
}

function Get-Win32AppProject {
    <# Returns Win32 app projects (all, or one by Id). #>
    [CmdletBinding()]
    param([string]$Id)
    $root = (Get-MsixWorkspace).Win32Apps
    $dirs = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue
    if ($Id) { $dirs = $dirs | Where-Object Name -eq $Id }
    foreach ($d in $dirs) {
        $file = Join-Path $d.FullName 'project.json'
        if (-not (Test-Path $file)) { continue }
        $p = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
        $p | Add-Member -NotePropertyName ProjectPath -NotePropertyValue $d.FullName -Force
        $p | Add-Member -NotePropertyName SourcePath -NotePropertyValue (Join-Path $d.FullName 'source') -Force
        $p
    }
}

function New-Win32Detection {
    <# A detection rule object (Type: Script, MsiProductCode, File, Registry) with all fields present. #>
    param(
        [ValidateSet('Script', 'MsiProductCode', 'File', 'Registry')][string]$Type = 'Script',
        [string]$ProductCode = '', [string]$ProductVersion = '', [string]$ProductVersionOperator = 'notConfigured',
        [string]$Path = '', [string]$FileOrFolder = '', [ValidateSet('exists', 'version')][string]$FileOperation = 'exists',
        [string]$FileOperator = 'greaterThanOrEqual', [string]$FileVersion = '',
        [string]$KeyPath = '', [string]$ValueName = '', [ValidateSet('exists', 'string', 'version')][string]$RegistryOperation = 'exists',
        [string]$RegistryOperator = 'equal', [string]$RegistryValue = ''
    )
    [ordered]@{
        Type = $Type; ProductCode = $ProductCode; ProductVersion = $ProductVersion; ProductVersionOperator = $ProductVersionOperator
        Path = $Path; FileOrFolder = $FileOrFolder; FileOperation = $FileOperation; FileOperator = $FileOperator; FileVersion = $FileVersion
        KeyPath = $KeyPath; ValueName = $ValueName; RegistryOperation = $RegistryOperation; RegistryOperator = $RegistryOperator; RegistryValue = $RegistryValue
    }
}

function Save-Win32AppProject {
    <#
    .SYNOPSIS
    Creates or updates a Win32 app project. A new installer is copied into the project's source folder;
    missing scripts are generated from templates (existing scripts are kept unless -RegenerateScripts).
    #>
    [CmdletBinding()]
    param(
        [string]$Id,
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$Publisher = '',
        [string]$Version = '1.0.0',
        [string]$Description = '',
        [string]$InstallerPath = '',
        [string]$InstallArguments = '',
        [string]$DetectionName = '',
        $Detection,
        [ValidateSet('system', 'user')][string]$RunAs = 'system',
        [ValidateSet('basedOnReturnCode', 'allow', 'suppress', 'force')][string]$Restart = 'basedOnReturnCode',
        [ValidateSet('x64', 'x86', 'x64,x86')][string]$Architecture = 'x64,x86',
        [string]$MinimumWindows = '1607',
        [switch]$WithUpdateScript,
        [switch]$RegenerateScripts,
        [hashtable]$Scripts
    )
    if (-not $Id) { $Id = ConvertTo-Win32AppId $DisplayName }
    $existing = Get-Win32AppProject -Id $Id
    $projectPath = Join-Path (Get-MsixWorkspace).Win32Apps $Id
    $source = Join-Path $projectPath 'source'
    New-Item -ItemType Directory $source -Force | Out-Null

    $installerFile = if ($existing) { $existing.InstallerFile } else { '' }
    $installerType = if ($existing) { $existing.InstallerType } else { 'Script' }
    $productCode = if ($existing) { $existing.ProductCode } else { '' }
    if ($InstallerPath) {
        $src = (Resolve-Path -LiteralPath $InstallerPath).Path
        $installerFile = Split-Path $src -Leaf
        $target = Join-Path $source $installerFile
        if ($src -ne $target) { Copy-Item -LiteralPath $src -Destination $target -Force }
        $info = Get-MsixInstallerInfo -Path $target
        $installerType = $info.Type
        if ($info.Type -eq 'MSI') {
            try { $productCode = (Get-MsiProperty -Path $target -Names 'ProductCode').ProductCode } catch { }
        }
        if (-not $InstallArguments -and $info.SuggestedArguments) { $InstallArguments = $info.SuggestedArguments }
    }
    if (-not $DetectionName) { $DetectionName = if ($existing -and $existing.DetectionName) { $existing.DetectionName } else { $DisplayName } }
    if (-not $Detection) {
        $Detection = if ($existing) { $existing.Detection } else { New-Win32Detection -Type Script }
    }

    $project = [ordered]@{
        Id               = $Id
        DisplayName      = $DisplayName
        Publisher        = $Publisher
        Version          = $Version
        Description      = $Description
        InstallerFile    = $installerFile
        InstallerType    = $installerType
        InstallArguments = $InstallArguments
        ProductCode      = $productCode
        DetectionName    = $DetectionName
        InstallCommand   = $script:Win32InstallCommand
        UninstallCommand = $script:Win32UninstallCommand
        Detection        = $Detection
        RunAs            = $RunAs
        Restart          = $Restart
        Architecture     = $Architecture
        MinimumWindows   = $MinimumWindows
        ReturnCodes      = @(
            [ordered]@{ Code = 0; Type = 'success' }, [ordered]@{ Code = 1707; Type = 'success' },
            [ordered]@{ Code = 3010; Type = 'softReboot' }, [ordered]@{ Code = 1641; Type = 'hardReboot' },
            [ordered]@{ Code = 1618; Type = 'retry' })
        LastTest         = $(if ($existing) { $existing.LastTest } else { $null })
        Modified         = (Get-Date).ToString('o')
    }
    $project | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $projectPath 'project.json') -Encoding UTF8
    $p = Get-Win32AppProject -Id $Id

    # Scripts: given content wins, then templates for missing files (or all with -RegenerateScripts)
    $templates = Get-Win32ScriptTemplate -Project $p
    foreach ($name in 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1') {
        $file = Join-Path $source $name
        if ($Scripts -and $Scripts.ContainsKey($name)) { [IO.File]::WriteAllText($file, $Scripts[$name], (New-Object Text.UTF8Encoding $true)) }
        elseif ($RegenerateScripts -or -not (Test-Path $file)) { [IO.File]::WriteAllText($file, $templates[$name], (New-Object Text.UTF8Encoding $true)) }
    }
    $update = Join-Path $source 'Update.ps1'
    if ($Scripts -and $Scripts.ContainsKey('Update.ps1')) {
        if ($Scripts['Update.ps1'].Trim()) { [IO.File]::WriteAllText($update, $Scripts['Update.ps1'], (New-Object Text.UTF8Encoding $true)) }
        else { Remove-Item $update -Force -ErrorAction SilentlyContinue }
    }
    elseif ($WithUpdateScript -and ($RegenerateScripts -or -not (Test-Path $update))) {
        [IO.File]::WriteAllText($update, $templates['Update.ps1'], (New-Object Text.UTF8Encoding $true))
    }
    Write-MsixLog "Win32 app saved: $DisplayName $Version" -Level Success
    $p
}

function Remove-Win32AppProject {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    Remove-Item (Join-Path (Get-MsixWorkspace).Win32Apps $Id) -Recurse -Force -ErrorAction SilentlyContinue
    Write-MsixLog "Win32 app removed: $Id"
}

function Get-Win32AppScript {
    <# The current scripts of a project as hashtable (name -> content; Update.ps1 empty if absent). #>
    param([Parameter(Mandatory)]$Project)
    $result = [ordered]@{}
    foreach ($name in 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'Update.ps1') {
        $file = Join-Path $Project.SourcePath $name
        $result[$name] = if (Test-Path $file) { [IO.File]::ReadAllText($file) } else { '' }
    }
    $result
}

# ---------------------------------------------------------------- script templates

function Get-Win32ScriptTemplate {
    <#
    .SYNOPSIS
    Generates Install.ps1, Uninstall.ps1, Detect.ps1 and Update.ps1 for a project (MSI, EXE or script only).
    Logs go to the Intune Management Extension log folder, so they are part of Intune diagnostics.
    #>
    param([Parameter(Mandatory)]$Project)
    $p = $Project
    $q = { param($s) "$s".Replace("'", "''") }
    $name = & $q $p.DisplayName
    $match = & $q $p.DetectionName
    $version = & $q $p.Version
    $file = & $q $p.InstallerFile
    $args_ = & $q $p.InstallArguments
    $header = @"
# {0} - $name $version
# Generated by MSIX Sandbox Studio. Runs as SYSTEM (Intune default) from the package content folder.
`$ErrorActionPreference = 'Stop'
`$AppName = '$name'
`$AppVersion = '$version'
`$LogDir = Join-Path `$env:ProgramData 'Microsoft\IntuneManagementExtension\Logs'
New-Item -ItemType Directory `$LogDir -Force | Out-Null
"@
    $findEntry = @"
function Get-InstalledEntry {
    # Uninstall entries of the app (64- and 32-bit registry views)
    `$roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    Get-ChildItem `$roots -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { `$_.DisplayName -like '$match*' }
}
"@
    $installCore = switch ($p.InstallerType) {
        'MSI' {
@"
    `$msiLog = Join-Path `$LogDir "`$AppName-MSI-Install.log"
    `$p = Start-Process msiexec.exe -ArgumentList "/i ```"`$PSScriptRoot\$file```" /qn /norestart /l*v ```"`$msiLog```" $args_" -Wait -PassThru
    `$code = `$p.ExitCode
"@ }
        'EXE' {
@"
    `$p = Start-Process -FilePath "`$PSScriptRoot\$file" -ArgumentList '$args_' -Wait -PassThru
    `$code = `$p.ExitCode
"@ }
        default {
@"
    # TODO: installation steps (no installer file selected)
    `$code = 0
"@ }
    }
    $install = ($header -f 'Install') + @"

Start-Transcript -Path (Join-Path `$LogDir "`$AppName-Install.log") -Append | Out-Null
`$code = 0
try {
    # Update routine: runs first when Update.ps1 is part of the package
    if (Test-Path "`$PSScriptRoot\Update.ps1") {
        Write-Output 'Running update routine (Update.ps1)'
        & "`$PSScriptRoot\Update.ps1"
    }
$installCore
    Write-Output "Installer exit code: `$code"
}
catch {
    Write-Output "Installation failed: `$(`$_.Exception.Message)"
    `$code = 1603
}
finally { Stop-Transcript | Out-Null }
exit `$code
"@

    $uninstallCore = if ($p.InstallerType -eq 'MSI' -and $p.ProductCode) {
@"
    `$p = Start-Process msiexec.exe -ArgumentList "/x $($p.ProductCode) /qn /norestart /l*v ```"`$LogDir\`$AppName-MSI-Uninstall.log```"" -Wait -PassThru
    `$code = `$p.ExitCode
"@ }
    else {
        $silent = switch -Regex ($p.InstallArguments) { 'VERYSILENT' { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' } '^/S$' { '/S' } default { '' } }
@"
    `$entry = Get-InstalledEntry | Select-Object -First 1
    if (-not `$entry) { Write-Output 'Not installed.'; `$code = 0 }
    else {
        # Quiet uninstall string if the setup registered one, otherwise the uninstall string with silent arguments
        `$command = if (`$entry.QuietUninstallString) { `$entry.QuietUninstallString } else { "`$(`$entry.UninstallString) $silent" }
        Write-Output "Uninstalling: `$command"
        `$p = Start-Process cmd.exe -ArgumentList "/c ```"`$command```"" -Wait -PassThru
        `$code = `$p.ExitCode
    }
"@ }
    $uninstall = ($header -f 'Uninstall') + @"

$findEntry
Start-Transcript -Path (Join-Path `$LogDir "`$AppName-Uninstall.log") -Append | Out-Null
`$code = 0
try {
$uninstallCore
    Write-Output "Uninstall exit code: `$code"
}
catch {
    Write-Output "Uninstall failed: `$(`$_.Exception.Message)"
    `$code = 1603
}
finally { Stop-Transcript | Out-Null }
exit `$code
"@

    $detectCore = if ($p.InstallerType -eq 'MSI' -and $p.ProductCode) {
@"
`$key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$($p.ProductCode)', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$($p.ProductCode)' |
    Where-Object { Test-Path `$_ } | Select-Object -First 1
if (`$key) { Write-Output "Detected `$AppName (product code $($p.ProductCode))"; exit 0 }
exit 1
"@ }
    else {
@"
`$entry = Get-InstalledEntry | Sort-Object { try { [version]`$_.DisplayVersion } catch { [version]'0.0' } } -Descending | Select-Object -First 1
if (`$entry) {
    `$installed = try { [version](`$entry.DisplayVersion -replace '[^\d\.].*$', '') } catch { [version]'0.0' }
    `$expected = try { [version](`$AppVersion -replace '[^\d\.].*$', '') } catch { [version]'0.0' }
    if (`$installed -ge `$expected) { Write-Output "Detected `$(`$entry.DisplayName) `$(`$entry.DisplayVersion)"; exit 0 }
}
exit 1
"@ }
    $detect = @"
# Detect - $name $version
# Generated by MSIX Sandbox Studio. Intune rule: detected = exit code 0 AND output on STDOUT.
`$AppVersion = '$version'
`$AppName = '$name'
$findEntry
$detectCore
"@

    $update = ($header -f 'Update routine') + @"

# Runs at the start of Install.ps1 when this file is part of the package.
# Typical tasks: remove a previous version that cannot be upgraded in place, back up or migrate settings.
$findEntry
`$previous = Get-InstalledEntry | Where-Object {
    try { [version](`$_.DisplayVersion -replace '[^\d\.].*$', '') -lt [version](`$AppVersion -replace '[^\d\.].*$', '') } catch { `$false }
}
foreach (`$old in `$previous) {
    Write-Output "Previous version found: `$(`$old.DisplayName) `$(`$old.DisplayVersion)"
    # Example: uninstall it first
    # `$command = if (`$old.QuietUninstallString) { `$old.QuietUninstallString } else { `$old.UninstallString }
    # Start-Process cmd.exe -ArgumentList "/c ```"`$command```"" -Wait
}
"@
    @{ 'Install.ps1' = $install; 'Uninstall.ps1' = $uninstall; 'Detect.ps1' = $detect; 'Update.ps1' = $update }
}

# ---------------------------------------------------------------- .intunewin

function New-IntuneWinPackage {
    <#
    .SYNOPSIS
    Builds an .intunewin from a folder, in the format of the Microsoft Win32 Content Prep Tool:
    zip of the folder, AES-256 encrypted (HMAC + IV + data), plus Metadata\Detection.xml with the keys.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$SetupFile,
        [Parameter(Mandatory)][string]$OutputFile
    )
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (-not (Test-Path (Join-Path $SourceFolder $SetupFile))) { throw "Setup file $SetupFile not found in $SourceFolder." }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("intunewin-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $temp | Out-Null
    try {
        $zipFile = Join-Path $temp 'content.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($SourceFolder, $zipFile, 'Optimal', $false)
        $encrypted = Join-Path $temp 'IntunePackage.intunewin'
        $info = Protect-MsixIntuneFile -Source $zipFile -Target $encrypted

        $detection = @"
<ApplicationInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ToolVersion="1.8.6">
  <Name>$([Security.SecurityElement]::Escape($SetupFile))</Name>
  <UnencryptedContentSize>$((Get-Item $zipFile).Length)</UnencryptedContentSize>
  <FileName>IntunePackage.intunewin</FileName>
  <SetupFile>$([Security.SecurityElement]::Escape($SetupFile))</SetupFile>
  <EncryptionInfo>
    <EncryptionKey>$($info.encryptionKey)</EncryptionKey>
    <MacKey>$($info.macKey)</MacKey>
    <InitializationVector>$($info.initializationVector)</InitializationVector>
    <Mac>$($info.mac)</Mac>
    <ProfileIdentifier>$($info.profileIdentifier)</ProfileIdentifier>
    <FileDigest>$($info.fileDigest)</FileDigest>
    <FileDigestAlgorithm>$($info.fileDigestAlgorithm)</FileDigestAlgorithm>
  </EncryptionInfo>
</ApplicationInfo>
"@
        if (Test-Path $OutputFile) { Remove-Item $OutputFile -Force }
        New-Item -ItemType Directory (Split-Path $OutputFile -Parent) -Force | Out-Null
        $zip = [IO.Compression.ZipFile]::Open($OutputFile, 'Create')
        try {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $encrypted, 'IntuneWinPackage/Contents/IntunePackage.intunewin', 'NoCompression')
            $w = New-Object IO.StreamWriter(($zip.CreateEntry('IntuneWinPackage/Metadata/Detection.xml')).Open(), (New-Object Text.UTF8Encoding $false))
            $w.Write($detection); $w.Dispose()
        }
        finally { $zip.Dispose() }
    }
    finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    Get-IntuneWinInfo -Path $OutputFile
}

function Get-IntuneWinInfo {
    <# Reads Metadata\Detection.xml of an .intunewin (setup file, sizes, encryption info). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $meta = $zip.Entries | Where-Object FullName -like '*Metadata/Detection.xml' | Select-Object -First 1
        $content = $zip.Entries | Where-Object FullName -like '*Contents/*.intunewin' | Select-Object -First 1
        if (-not $meta -or -not $content) { throw 'Not an .intunewin package (Detection.xml or content missing).' }
        $r = New-Object IO.StreamReader($meta.Open())
        try { [xml]$x = $r.ReadToEnd() } finally { $r.Dispose() }
        $e = $x.ApplicationInfo.EncryptionInfo
        [pscustomobject]@{
            Path                   = (Resolve-Path -LiteralPath $Path).Path
            SetupFile              = $x.ApplicationInfo.SetupFile
            UnencryptedContentSize = [int64]$x.ApplicationInfo.UnencryptedContentSize
            EncryptedSize          = $content.Length
            ContentEntry           = $content.FullName
            EncryptionInfo         = [ordered]@{
                encryptionKey = $e.EncryptionKey; macKey = $e.MacKey; initializationVector = $e.InitializationVector; mac = $e.Mac
                profileIdentifier = $e.ProfileIdentifier; fileDigest = $e.FileDigest; fileDigestAlgorithm = $e.FileDigestAlgorithm
            }
            MsiInfo                = $x.ApplicationInfo.MsiInfo
        }
    }
    finally { $zip.Dispose() }
}

function Expand-IntuneWinPackage {
    <#
    .SYNOPSIS
    Decrypts an .intunewin (MAC checked) and extracts its content to a folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $info = Get-IntuneWinInfo -Path $Path
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("intunewin-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $temp | Out-Null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($info.Path)
        $enc = Join-Path $temp 'content.bin'
        try { [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry($info.ContentEntry), $enc, $true) } finally { $zip.Dispose() }
        $bytes = [IO.File]::ReadAllBytes($enc)
        $hmac = New-Object Security.Cryptography.HMACSHA256 (, [Convert]::FromBase64String($info.EncryptionInfo.macKey))
        if ([Convert]::ToBase64String($hmac.ComputeHash($bytes, 32, $bytes.Length - 32)) -ne $info.EncryptionInfo.mac) { throw 'The package is damaged (MAC mismatch).' }
        $aes = [Security.Cryptography.Aes]::Create()
        $aes.Key = [Convert]::FromBase64String($info.EncryptionInfo.encryptionKey)
        $aes.IV = $bytes[32..47]
        $plain = $aes.CreateDecryptor().TransformFinalBlock($bytes, 48, $bytes.Length - 48)
        $zipFile = Join-Path $temp 'content.zip'
        [IO.File]::WriteAllBytes($zipFile, $plain)
        if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
        [IO.Compression.ZipFile]::ExtractToDirectory($zipFile, $Destination)
    }
    finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    Get-Item $Destination
}

# ---------------------------------------------------------------- build

function Get-Win32AppBuild {
    <# Built packages (all, or those of one app). Each has the .intunewin, its parameters and documentation. #>
    [CmdletBinding()]
    param([string]$Id)
    $root = (Get-MsixWorkspace).Win32Output
    foreach ($d in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) {
        $paramFile = Join-Path $d.FullName 'intune-app.json'
        if (-not (Test-Path $paramFile)) { continue }
        $p = Get-Content $paramFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Id -and $p.id -ne $Id) { continue }
        $doc = Join-Path $d.FullName 'documentation\index.html'
        [pscustomobject]@{
            Id            = $p.id
            DisplayName   = $p.displayName
            Version       = $p.displayVersion
            Path          = $d.FullName
            IntuneWin     = Join-Path $d.FullName $p.fileName
            Parameters    = $paramFile
            Definition    = $p
            Documentation = $(if (Test-Path $doc) { $doc } else { $null })
            Tested        = $p.test.result
            Built         = [datetime]$p.built
        }
    }
}

function ConvertTo-IntuneWin32Rule {
    <# Detection rule of a project as Microsoft Graph win32LobApp rule. #>
    param([Parameter(Mandatory)]$Project)
    $d = $Project.Detection
    switch ($d.Type) {
        'MsiProductCode' {
            [ordered]@{
                '@odata.type' = '#microsoft.graph.win32LobAppProductCodeRule'; ruleType = 'detection'
                productCode = $d.ProductCode
                productVersionOperator = $(if ($d.ProductVersion) { $d.ProductVersionOperator } else { 'notConfigured' })
                productVersion = $(if ($d.ProductVersion) { $d.ProductVersion } else { $null })
            }
        }
        'File' {
            [ordered]@{
                '@odata.type' = '#microsoft.graph.win32LobAppFileSystemRule'; ruleType = 'detection'
                path = $d.Path; fileOrFolderName = $d.FileOrFolder; check32BitOn64System = $false
                operationType = $d.FileOperation
                operator = $(if ($d.FileOperation -eq 'version') { $d.FileOperator } else { 'notConfigured' })
                comparisonValue = $(if ($d.FileOperation -eq 'version') { $d.FileVersion } else { $null })
            }
        }
        'Registry' {
            [ordered]@{
                '@odata.type' = '#microsoft.graph.win32LobAppRegistryRule'; ruleType = 'detection'
                keyPath = $d.KeyPath; valueName = $d.ValueName; check32BitOn64System = $false
                operationType = $d.RegistryOperation
                operator = $(if ($d.RegistryOperation -ne 'exists') { $d.RegistryOperator } else { 'notConfigured' })
                comparisonValue = $(if ($d.RegistryOperation -ne 'exists') { $d.RegistryValue } else { $null })
            }
        }
        default {
            $script = [IO.File]::ReadAllText((Join-Path $Project.SourcePath 'Detect.ps1'))
            [ordered]@{
                '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'; ruleType = 'detection'
                enforceSignatureCheck = $false; runAs32Bit = $false
                scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
                operationType = 'notConfigured'; operator = 'notConfigured'; comparisonValue = $null
            }
        }
    }
}

function New-Win32AppPackage {
    <#
    .SYNOPSIS
    Builds the .intunewin of a project plus intune-app.json (all Intune settings, the parameter file for the
    upload) and the HTML documentation, into Workspace\Output\Win32\<Id>_<Version>\.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $p = Get-Win32AppProject -Id $Id
    if (-not $p) { throw "Win32 app not found: $Id" }
    foreach ($s in 'Install.ps1', 'Uninstall.ps1') {
        if (-not (Test-Path (Join-Path $p.SourcePath $s))) { throw "$s is missing in the project." }
    }
    if ($p.Detection.Type -eq 'Script' -and -not (Test-Path (Join-Path $p.SourcePath 'Detect.ps1'))) { throw 'Detect.ps1 is missing in the project.' }
    $name = '{0}_{1}' -f $p.Id, $p.Version
    $buildDir = Join-Path (Get-MsixWorkspace).Win32Output $name
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
    New-Item -ItemType Directory $buildDir | Out-Null
    Write-MsixLog "Building $name.intunewin ..."
    $file = Join-Path $buildDir "$name.intunewin"
    $iw = New-IntuneWinPackage -SourceFolder $p.SourcePath -SetupFile 'Install.ps1' -OutputFile $file

    # Snapshot of the scripts (for documentation and later comparison)
    $scriptDir = Join-Path $buildDir 'scripts'
    New-Item -ItemType Directory $scriptDir | Out-Null
    Get-ChildItem $p.SourcePath -Filter '*.ps1' | Copy-Item -Destination $scriptDir

    $definition = [ordered]@{
        id                            = $p.Id
        displayName                   = $p.DisplayName
        displayVersion                = $p.Version
        description                   = $(if ($p.Description) { $p.Description } else { $p.DisplayName })
        publisher                     = $p.Publisher
        fileName                      = "$name.intunewin"
        setupFilePath                 = 'Install.ps1'
        installCommandLine            = $p.InstallCommand
        uninstallCommandLine          = $p.UninstallCommand
        runAsAccount                  = $p.RunAs
        deviceRestartBehavior         = $p.Restart
        applicableArchitectures       = $p.Architecture
        minimumSupportedWindowsRelease = $p.MinimumWindows
        returnCodes                   = @($p.ReturnCodes | ForEach-Object { [ordered]@{ returnCode = $_.Code; type = $_.Type } })
        detection                     = $p.Detection
        detectionRule                 = ConvertTo-IntuneWin32Rule -Project $p
        installer                     = [ordered]@{ file = $p.InstallerFile; type = $p.InstallerType; arguments = $p.InstallArguments; productCode = $p.ProductCode }
        hasUpdateScript               = Test-Path (Join-Path $p.SourcePath 'Update.ps1')
        intunewin                     = [ordered]@{ sha256 = Get-MsixSha256 $file; unencryptedContentSize = $iw.UnencryptedContentSize; encryptedSize = $iw.EncryptedSize }
        test                          = $p.LastTest
        built                         = (Get-Date).ToString('o')
    }
    $definition | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $buildDir 'intune-app.json') -Encoding UTF8
    $doc = New-Win32AppDocumentation -BuildPath $buildDir
    Write-MsixLog "Win32 package ready: $file" -Level Success
    [pscustomobject]@{ State = 'Succeeded'; BuildPath = $buildDir; IntuneWin = $file; Parameters = (Join-Path $buildDir 'intune-app.json'); Documentation = $doc }
}

# ---------------------------------------------------------------- test lab

function Start-Win32TestLab {
    <#
    .SYNOPSIS
    Opens the Win32 Test Lab in a fresh sandbox: Install, Detect, Uninstall (and for updates first the previous
    version from -BaseBuild) with one click each, as SYSTEM like Intune. You check everything by hand, then
    report Success or Failure there. Scripts edited in the sandbox come back into the project.
    .PARAMETER BaseBuild
    Build folder (or .intunewin with intune-app.json next to it) of the previous version, for update tests.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$BaseBuild
    )
    $settings = Get-MsixSettings
    $p = Get-Win32AppProject -Id $Id
    if (-not $p) { throw "Win32 app not found: $Id" }
    $base = $null
    if ($BaseBuild) {
        $dir = if ((Get-Item $BaseBuild).PSIsContainer) { $BaseBuild } else { Split-Path $BaseBuild -Parent }
        $paramFile = Join-Path $dir 'intune-app.json'
        if (-not (Test-Path $paramFile)) { throw "intune-app.json not found next to the base package ($dir)." }
        $base = Get-Content $paramFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $base | Add-Member -NotePropertyName IntuneWin -NotePropertyValue (Join-Path $dir $base.fileName) -Force
    }

    $job = New-MsixJob -Mode Win32Lab -Name $p.Id -Data @{
        AutoClose   = $false   # the lab closes the sandbox
        DisplayName = $p.DisplayName
        Version     = $p.Version
        BaseVersion = $(if ($base) { $base.displayVersion } else { '' })
    }
    $inputDir = Join-Path $job 'input'
    Copy-Item $p.SourcePath (Join-Path $inputDir 'source') -Recurse
    Copy-Item (Join-Path $p.ProjectPath 'project.json') $inputDir
    if ($base) {
        Write-MsixLog "Unpacking the previous version $($base.displayVersion) for the update test ..."
        New-Item -ItemType Directory (Join-Path $inputDir 'base') | Out-Null
        Expand-IntuneWinPackage -Path $base.IntuneWin -Destination (Join-Path $inputDir 'base\source') | Out-Null
        $base | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $inputDir 'base\intune-app.json') -Encoding UTF8
    }

    $scenario = if ($base) { "update from $($base.displayVersion)" } else { 'new installation' }
    Write-MsixLog "Opening the Win32 Test Lab for $($p.DisplayName) $($p.Version) ($scenario)."
    $wsb = New-MsixSandboxConfig -JobPath $job -Networking ([bool]$settings.PackageNetworking) -MemoryMB $settings.SandboxMemoryMB -VGpu $settings.SandboxVGpu
    Start-MsixSandboxProcess -WsbPath $wsb
    $status = Wait-MsixJob -JobPath $job -TimeoutMinutes ([Math]::Max(480, [int]$settings.JobTimeoutMinutes))

    # Scripts edited in the sandbox come back into the project
    $changed = @()
    $edited = Join-Path $job 'out\scripts'
    if (Test-Path $edited) {
        foreach ($f in Get-ChildItem $edited -Filter '*.ps1') {
            $target = Join-Path $p.SourcePath $f.Name
            if (-not (Test-Path $target) -or (Get-MsixSha256 $target) -ne (Get-MsixSha256 $f.FullName)) {
                Copy-Item $f.FullName $target -Force
                $changed += $f.Name
            }
        }
        if ($changed) { Write-MsixLog "Scripts changed in the test lab, taken into the project: $($changed -join ', ')" -Level Warning }
    }

    $verdict = if ($status.State -eq 'Succeeded') { 'Passed' } else { 'Failed' }
    $last = [ordered]@{
        result   = $verdict
        date     = (Get-Date).ToString('o')
        scenario = $scenario
        message  = $status.Message
        notes    = $(if ($status.Result) { $status.Result.Notes } else { '' })
        job      = $job
        changed  = $changed
    }
    $file = Join-Path $p.ProjectPath 'project.json'
    $json = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $json | Add-Member -NotePropertyName LastTest -NotePropertyValue ([pscustomobject]$last) -Force
    $json | ConvertTo-Json -Depth 8 | Set-Content $file -Encoding UTF8

    $level = if ($verdict -eq 'Passed') { 'Success' } else { 'Error' }
    Write-MsixLog "Test lab result: $verdict. $($status.Message)" -Level $level
    [pscustomobject]@{ State = $status.State; Verdict = $verdict; Message = $status.Message; Result = $status.Result; JobPath = $job; ChangedScripts = $changed }
}
