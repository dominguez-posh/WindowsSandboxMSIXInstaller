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
