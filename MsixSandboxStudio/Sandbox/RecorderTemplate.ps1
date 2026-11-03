# Conversion template for a recording, built inside the sandbox from what the user entered in the recorder.
# Same structure as New-MsixConversionTemplate in the module (kept separate: the sandbox has no module).

function New-RecorderTemplate {
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$PublisherName,
        [Parameter(Mandatory)][string]$PublisherDisplayName,
        [Parameter(Mandatory)][string]$Version,
        [string]$Description,
        [Parameter(Mandatory)][string]$InstallerPath,
        [string]$InstallerArguments,
        [Parameter(Mandatory)][string]$PackagePath
    )
    $ns = 'http://schemas.microsoft.com/appx/msixpackagingtool/template/2018'
    $nsV4 = 'http://schemas.microsoft.com/msix/msixpackagingtool/template/1910'
    $xml = New-Object System.Xml.XmlDocument
    $root = $xml.CreateElement('MsixPackagingToolTemplate', $ns)
    $root.SetAttribute('xmlns:V4', $nsV4)
    [void]$xml.AppendChild($root)

    $settings = $xml.CreateElement('Settings', $ns)
    $settings.SetAttribute('AllowTelemetry', 'false')
    $settings.SetAttribute('ApplyAllPrepareComputerFixes', 'true')
    $settings.SetAttribute('GenerateCommandLineFile', 'false')
    $settings.SetAttribute('AllowPromptForPassword', 'false')
    $settings.SetAttribute('EnforceMicrosoftStoreVersioningRequirements', 'false')
    [void]$root.AppendChild($settings)

    $save = $xml.CreateElement('SaveLocation', $ns)
    $save.SetAttribute('PackagePath', $PackagePath)
    [void]$root.AppendChild($save)

    $inst = $xml.CreateElement('Installer', $ns)
    $inst.SetAttribute('Path', $InstallerPath)
    if ($InstallerArguments) { $inst.SetAttribute('Arguments', $InstallerArguments) }
    [void]$root.AppendChild($inst)

    $pi = $xml.CreateElement('PackageInformation', $ns)
    $pi.SetAttribute('PackageName', $PackageName)
    $pi.SetAttribute('PackageDisplayName', $DisplayName)
    $pi.SetAttribute('PublisherName', $PublisherName)
    $pi.SetAttribute('PublisherDisplayName', $PublisherDisplayName)
    $pi.SetAttribute('Version', $Version)
    if ($Description) { [void]$pi.SetAttribute('PackageDescription', $nsV4, $Description) }
    [void]$root.AppendChild($pi)

    $ws = New-Object System.Xml.XmlWriterSettings
    $ws.OmitXmlDeclaration = $true
    $ws.Indent = $true
    $sw = New-Object IO.StringWriter
    $xw = [System.Xml.XmlWriter]::Create($sw, $ws)
    $xml.Save($xw)
    $xw.Dispose()
    $sw.ToString()
}

function New-RecorderEvent {
    # Named event shared by Recorder.ps1 and RecordingHold.ps1. Global: the Packaging Tool may start the
    # installer outside the recorder's session namespace. Local as fallback without SeCreateGlobalPrivilege.
    param([string]$Name)
    $mode = [System.Threading.EventResetMode]::ManualReset
    try { New-Object System.Threading.EventWaitHandle($false, $mode, "Global\$Name") }
    catch { New-Object System.Threading.EventWaitHandle($false, $mode, "Local\$Name") }
}

function ConvertTo-RecorderVersion {
    # 1-4 numeric parts -> x.x.x.x; $null if invalid
    param([string]$Version)
    if ($Version -notmatch '^\d{1,5}(\.\d{1,5}){0,3}$') { return $null }
    $parts = @($Version.Split('.') | ForEach-Object { [int]$_ })
    if ($parts | Where-Object { $_ -gt 65535 }) { return $null }
    while ($parts.Count -lt 4) { $parts += 0 }
    $parts -join '.'
}

# ---------------------------------------------------------------- update: restore an existing package natively
# An update recording starts with the content of the base .msix laid down as if it were installed classically
# (files to their real locations, registry imported, Start menu shortcuts per app). This happens inside the
# capture, so the new package contains the old content plus everything the update changes.

function Get-MsixVfsMap {
    # VFS folder names used in MSIX packages -> real locations
    [ordered]@{
        'ProgramFilesX64'       = $env:ProgramFiles
        'ProgramFilesX86'       = ${env:ProgramFiles(x86)}
        'ProgramFilesCommonX64' = $env:CommonProgramFiles
        'ProgramFilesCommonX86' = ${env:CommonProgramFiles(x86)}
        'SystemX64'             = Join-Path $env:SystemRoot 'System32'
        'SystemX86'             = Join-Path $env:SystemRoot 'SysWOW64'
        'Windows'               = $env:SystemRoot
        'Fonts'                 = Join-Path $env:SystemRoot 'Fonts'
        'Common AppData'        = $env:ProgramData
        'AppData'               = $env:APPDATA
        'Local AppData'         = $env:LOCALAPPDATA
        'LocalAppDataLow'       = Join-Path $env:USERPROFILE 'AppData\LocalLow'
        'Common Desktop'        = Join-Path $env:PUBLIC 'Desktop'
        'Common Programs'       = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
        'AppVPackageDrive'      = $env:SystemDrive + '\'
    }
}

function Get-MsixRestorePlan {
    # Maps every entry of an .msix to where it goes on a classic install. Kind: File, MachineHive, UserHive, Skip.
    # Package parts are percent-encoded in the zip ("Common%20AppData"); files outside VFS go to InstallRoot.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$InstallRoot)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $map = Get-MsixVfsMap
    $metadata = @('AppxManifest.xml', 'AppxBlockMap.xml', 'AppxSignature.p7x', '[Content_Types].xml', 'resources.pri')
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }   # folder entry
            $name = [uri]::UnescapeDataString($e.FullName)
            $parts = @($name -split '/')
            $kind = 'File'; $target = $null
            if ($parts.Count -eq 1 -and $metadata -contains $name) { $kind = 'Skip' }
            elseif ($parts[0] -eq 'AppxMetadata' -or $parts[0] -eq 'Assets') { $kind = 'Skip' }
            elseif ($parts.Count -eq 1 -and $name -eq 'Registry.dat') { $kind = 'MachineHive' }
            elseif ($parts.Count -eq 1 -and ($name -eq 'User.dat' -or $name -eq 'UserClasses.dat')) { $kind = 'UserHive' }
            elseif ($parts[0] -eq 'VFS' -and $parts.Count -gt 2) {
                if ($map.Contains($parts[1])) { $target = Join-Path $map[$parts[1]] ($parts[2..($parts.Count - 1)] -join '\') }
                else { $kind = 'Skip' }   # unknown VFS root
            }
            else { $target = Join-Path $InstallRoot ($parts -join '\') }
            [pscustomobject]@{ Entry = $e.FullName; Name = $name; Kind = $kind; Target = $target; Size = $e.Length }
        }
    }
    finally { $zip.Dispose() }
}

function Import-MsixHive {
    # Loads a package hive under HKU (not captured) and copies its keys to HKLM / HKCU with reg.exe.
    param([Parameter(Mandatory)][string]$HiveFile, [string]$Log)
    $mount = 'HKU\MsixStudioRestore'
    & reg.exe load $mount $HiveFile 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load failed for $HiveFile" }
    try {
        $hku = 'HKEY_USERS\MsixStudioRestore'
        $subkeys = { param($key) @(& reg.exe query $key 2>$null | Where-Object { $_ -like "$key\*" }) }
        foreach ($k in (& $subkeys "$hku\REGISTRY\MACHINE")) {
            $leaf = Split-Path $k -Leaf
            & reg.exe copy $k "HKLM\$leaf" /s /f 2>&1 | Out-Null
            if ($Log) { Add-Content $Log "registry: $k -> HKLM\$leaf (exit $LASTEXITCODE)" }
        }
        foreach ($sid in (& $subkeys "$hku\REGISTRY\USER")) {
            foreach ($k in (& $subkeys $sid)) {
                $leaf = Split-Path $k -Leaf
                & reg.exe copy $k "HKCU\$leaf" /s /f 2>&1 | Out-Null
                if ($Log) { Add-Content $Log "registry: $k -> HKCU\$leaf (exit $LASTEXITCODE)" }
            }
        }
    }
    finally {
        [GC]::Collect()
        & reg.exe unload $mount 2>&1 | Out-Null
    }
}

function Restore-MsixPackageContent {
    # Lays down the content of an .msix classically. Returns a summary (files, hives, shortcuts).
    # Temporary files go to %TEMP% (excluded from captures).
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$Log
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $plan = @(Get-MsixRestorePlan -Path $Path -InstallRoot $InstallRoot)
    $temp = Join-Path $env:TEMP 'msixstudio\restore'
    New-Item -ItemType Directory $temp -Force | Out-Null
    $files = 0; $hives = 0
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($p in $plan) {
            if ($p.Kind -eq 'Skip') { continue }
            $entry = $zip.GetEntry($p.Entry)
            if ($p.Kind -eq 'File') {
                $dir = Split-Path $p.Target -Parent
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $p.Target, $true)
                $files++
            }
            else {
                $hive = Join-Path $temp $p.Name
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $hive, $true)
                Import-MsixHive -HiveFile $hive -Log $Log
                $hives++
            }
        }
        $reader = New-Object IO.StreamReader($zip.GetEntry('AppxManifest.xml').Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }

    # Start menu shortcuts per application, so the new capture detects the same entry points
    $shortcuts = 0
    $programs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $shell = New-Object -ComObject WScript.Shell
    foreach ($app in @($manifest.Package.Applications.Application)) {
        $exe = [uri]::UnescapeDataString($app.Executable) -replace '/', '\'
        $target = ($plan | Where-Object { $_.Kind -eq 'File' -and ($_.Name -replace '/', '\') -eq $exe } | Select-Object -First 1).Target
        if (-not $target) { continue }
        $name = $app.VisualElements.DisplayName
        if (-not $name -or $name -like 'ms-resource:*') { $name = [IO.Path]::GetFileNameWithoutExtension($target) }
        $lnk = $shell.CreateShortcut((Join-Path $programs (($name -replace '[\\/:*?"<>|]', '') + '.lnk')))
        $lnk.TargetPath = $target
        $lnk.WorkingDirectory = Split-Path $target -Parent
        $lnk.Save()
        $shortcuts++
    }
    if ($Log) { Add-Content $Log "restored: $files files, $hives hives, $shortcuts shortcuts" }
    [pscustomobject]@{ Files = $files; Hives = $hives; Shortcuts = $shortcuts }
}
