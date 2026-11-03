# Recipes: one JSON file per app with everything needed to repackage it unattended
# (installer, silent arguments, package identity). Turned into a Packaging Tool conversion template per run.

function ConvertTo-MsixVersion {
    <# Normalizes any version string to the 4-part form MSIX requires (each part 0-65535). #>
    param([string]$Version)
    $parts = @([regex]::Matches("$Version", '\d+') | Select-Object -First 4 | ForEach-Object { [Math]::Min([int64]$_.Value, 65535) })
    while ($parts.Count -lt 4) { $parts += 0 }
    $parts -join '.'
}

function ConvertTo-MsixPackageName {
    <# Package identity names allow letters, digits, dots and dashes (3-50 characters). #>
    param([string]$Name)
    $clean = ($Name -replace '[^A-Za-z0-9\.\-]', '').Trim('.', '-')
    if ($clean.Length -lt 3) { $clean = "App$clean" }
    if ($clean.Length -gt 50) { $clean = $clean.Substring(0, 50) }
    $clean
}

function Get-MsiProperty {
    param([string]$Path, [string[]]$Names)
    $result = @{}
    $installer = New-Object -ComObject WindowsInstaller.Installer
    try {
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        foreach ($n in $Names) {
            $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$n'"))
            $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
            $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($rec) { $result[$n] = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) }
            $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
        }
    }
    finally { [Runtime.InteropServices.Marshal]::ReleaseComObject($installer) | Out-Null }
    $result
}

function Get-MsixInstallerInfo {
    <#
    .SYNOPSIS
    Inspects an installer: product name, vendor, version and the silent arguments for its setup framework.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    $info = [ordered]@{
        Path               = $file.FullName
        Type               = $file.Extension.TrimStart('.').ToUpperInvariant()
        Framework          = 'Unknown'
        SuggestedArguments = ''
        ProductName        = $file.BaseName
        Manufacturer       = ''
        Version            = '1.0.0.0'
    }
    if ($info.Type -eq 'MSI') {
        $info.Framework = 'Windows Installer'
        try {
            $p = Get-MsiProperty -Path $file.FullName -Names 'ProductName', 'Manufacturer', 'ProductVersion'
            if ($p.ProductName) { $info.ProductName = $p.ProductName }
            if ($p.Manufacturer) { $info.Manufacturer = $p.Manufacturer }
            if ($p.ProductVersion) { $info.Version = ConvertTo-MsixVersion $p.ProductVersion }
        }
        catch { Write-MsixLog "MSI properties could not be read: $($_.Exception.Message)" -Level Warning }
        # The Packaging Tool runs MSI silently on its own.
    }
    elseif ($info.Type -eq 'EXE') {
        $vi = $file.VersionInfo
        if ($vi.ProductName) { $info.ProductName = $vi.ProductName.Trim() }
        if ($vi.CompanyName) { $info.Manufacturer = $vi.CompanyName.Trim() }
        if ($vi.ProductVersion) { $info.Version = ConvertTo-MsixVersion $vi.ProductVersion }
        elseif ($vi.FileVersion) { $info.Version = ConvertTo-MsixVersion $vi.FileVersion }

        # Setup frameworks leave recognizable strings in the stub; the first 8 MB are enough.
        $stream = [IO.File]::OpenRead($file.FullName)
        try {
            $buffer = New-Object byte[] ([Math]::Min($stream.Length, 8MB))
            [void]$stream.Read($buffer, 0, $buffer.Length)
        }
        finally { $stream.Dispose() }
        $text = [Text.Encoding]::ASCII.GetString($buffer)
        $known = @(
            @{ Pattern = 'Inno Setup';                 Name = 'Inno Setup';       Args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
            @{ Pattern = 'Nullsoft|NSIS';              Name = 'NSIS';             Args = '/S' }
            @{ Pattern = 'WixBundle|WiX Toolset|\.wixburn'; Name = 'WiX Burn';    Args = '/quiet /norestart' }
            @{ Pattern = 'InstallShield';              Name = 'InstallShield';    Args = '/s /v"/qn /norestart"' }
            @{ Pattern = 'Advanced Installer';         Name = 'Advanced Installer'; Args = '/exenoui /qn /norestart' }
            @{ Pattern = 'Squirrel';                   Name = 'Squirrel';         Args = '--silent' }
        )
        foreach ($k in $known) {
            if ($text -match $k.Pattern) { $info.Framework = $k.Name; $info.SuggestedArguments = $k.Args; break }
        }
    }
    [pscustomobject]$info
}

function Get-MsixRecipe {
    [CmdletBinding()]
    param([string]$Name)
    $dir = (Get-MsixWorkspace).Recipes
    $files = Get-ChildItem $dir -Filter '*.json' -ErrorAction SilentlyContinue
    if ($Name) { $files = $files | Where-Object BaseName -eq $Name }
    foreach ($f in $files) {
        $r = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $r | Add-Member -NotePropertyName RecipePath -NotePropertyValue $f.FullName -Force
        $r
    }
}

function Save-MsixRecipe {
    <#
    .SYNOPSIS
    Creates or updates a recipe. The installer is copied into the workspace so the recipe stays reproducible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$PublisherDisplayName = '',
        [string]$Version = '1.0.0.0',
        [string]$Arguments = '',
        [string]$Description = '',
        [string]$InstallLocation = ''
    )
    $PackageName = ConvertTo-MsixPackageName $PackageName
    $dir = Join-Path (Get-MsixWorkspace).Recipes $PackageName
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $source = (Resolve-Path -LiteralPath $InstallerPath).Path
    $target = Join-Path $dir (Split-Path $source -Leaf)
    if ($source -ne $target) { Copy-Item -LiteralPath $source -Destination $target -Force }

    $recipe = [ordered]@{
        PackageName          = $PackageName
        DisplayName          = $DisplayName
        PublisherDisplayName = $(if ($PublisherDisplayName) { $PublisherDisplayName } else { $DisplayName })
        Version              = ConvertTo-MsixVersion $Version
        Description          = $Description
        Installer            = $target
        Arguments            = $Arguments
        InstallLocation      = $InstallLocation
        Modified             = (Get-Date).ToString('o')
    }
    $path = Join-Path (Get-MsixWorkspace).Recipes "$PackageName.json"
    $recipe | ConvertTo-Json | Set-Content $path -Encoding UTF8
    Write-MsixLog "Recipe saved: $PackageName $($recipe.Version)" -Level Success
    Get-MsixRecipe -Name $PackageName
}

function Remove-MsixRecipe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $ws = (Get-MsixWorkspace).Recipes
    Remove-Item (Join-Path $ws "$Name.json") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $ws $Name) -Recurse -Force -ErrorAction SilentlyContinue
    Write-MsixLog "Recipe removed: $Name"
}

function New-MsixConversionTemplate {
    <#
    .SYNOPSIS
    Builds the MSIX Packaging Tool conversion template (XML) for a recipe, with paths as seen inside the sandbox.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Recipe,
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$PackagePath,
        [string]$TemplatePath
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
    $settings.SetAttribute('GenerateCommandLineFile', 'true')
    $settings.SetAttribute('AllowPromptForPassword', 'false')
    $settings.SetAttribute('EnforceMicrosoftStoreVersioningRequirements', 'false')
    [void]$root.AppendChild($settings)

    $save = $xml.CreateElement('SaveLocation', $ns)
    $save.SetAttribute('PackagePath', $PackagePath)
    if ($TemplatePath) { $save.SetAttribute('TemplatePath', $TemplatePath) }
    [void]$root.AppendChild($save)

    $inst = $xml.CreateElement('Installer', $ns)
    $inst.SetAttribute('Path', $InstallerPath)
    if ($Recipe.Arguments) { $inst.SetAttribute('Arguments', $Recipe.Arguments) }
    if ($Recipe.InstallLocation) { $inst.SetAttribute('InstallLocation', $Recipe.InstallLocation) }
    [void]$root.AppendChild($inst)

    $pi = $xml.CreateElement('PackageInformation', $ns)
    $pi.SetAttribute('PackageName', $Recipe.PackageName)
    $pi.SetAttribute('PackageDisplayName', $Recipe.DisplayName)
    $pi.SetAttribute('PublisherName', $Publisher)
    $pi.SetAttribute('PublisherDisplayName', $Recipe.PublisherDisplayName)
    $pi.SetAttribute('Version', (ConvertTo-MsixVersion $Recipe.Version))
    if ($Recipe.Description) { $pi.SetAttribute('PackageDescription', $nsV4, $Recipe.Description) | Out-Null }
    [void]$root.AppendChild($pi)

    # No XML declaration: a StringWriter would declare utf-16, but the file is written as UTF-8.
    $ws = New-Object System.Xml.XmlWriterSettings
    $ws.OmitXmlDeclaration = $true
    $ws.Indent = $true
    $sw = New-Object IO.StringWriter
    $xw = [System.Xml.XmlWriter]::Create($sw, $ws)
    $xml.Save($xw)
    $xw.Dispose()
    $sw.ToString()
}
