# Shared helpers: workspace layout, settings, logging.

$script:ModuleRoot = Split-Path $PSScriptRoot -Parent
$script:RepoRoot   = Split-Path $script:ModuleRoot -Parent
$script:LogSink    = $null

function Set-MsixLogSink {
    <# Routes log lines to a scriptblock (the GUI uses this to show them live). $null = console. #>
    param([scriptblock]$Sink)
    $script:LogSink = $Sink
}

function Write-MsixLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info'
    )
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    if ($script:LogSink) {
        & $script:LogSink $line $Level
        return
    }
    $color = @{ Info = 'Gray'; Success = 'Green'; Warning = 'Yellow'; Error = 'Red' }[$Level]
    Write-Host $line -ForegroundColor $color
}

function Get-MsixWorkspace {
    <# Returns the workspace folders (created on first use). Location comes from settings, default <repo>\Workspace. #>
    $root = (Get-MsixSettings).WorkspacePath
    $ws = [ordered]@{
        Root         = $root
        Toolchain    = Join-Path $root 'Toolchain'
        Certificates = Join-Path $root 'Certificates'
        Recipes      = Join-Path $root 'Recipes'
        Jobs         = Join-Path $root 'Jobs'
        Output       = Join-Path $root 'Output'
        Shared       = Join-Path $root 'Shared'
    }
    foreach ($dir in $ws.Values) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    [pscustomobject]$ws
}

function Get-MsixSettingsPath {
    # MSIXSTUDIO_SETTINGS points to another settings file (used by the tests).
    if ($env:MSIXSTUDIO_SETTINGS) { return $env:MSIXSTUDIO_SETTINGS }
    Join-Path $script:RepoRoot 'settings.json'
}

function Get-MsixSettings {
    <# Settings are stored next to the module in settings.json (gitignored). Missing values get defaults. #>
    $defaults = [ordered]@{
        WorkspacePath        = Join-Path $script:RepoRoot 'Workspace'
        CertificatePath      = ''
        TimestampUrl         = 'http://timestamp.digicert.com'
        SandboxMemoryMB      = 4096
        SandboxVGpu          = $true
        PackageNetworking    = $true
        TestDurationSeconds  = 20
        JobTimeoutMinutes    = 45
        KeyVaultName         = ''
        KeyVaultCertName     = ''
    }
    $path = Get-MsixSettingsPath
    if (Test-Path $path) {
        try {
            $stored = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $stored.PSObject.Properties) {
                if ($defaults.Contains($p.Name)) { $defaults[$p.Name] = $p.Value }
            }
        }
        catch { Write-MsixLog "settings.json could not be read, using defaults: $($_.Exception.Message)" -Level Warning }
    }
    [pscustomobject]$defaults
}

function Set-MsixSettings {
    <# Merges the given values into settings.json. #>
    param([Parameter(Mandatory)][hashtable]$Values)
    $current = Get-MsixSettings
    foreach ($key in $Values.Keys) {
        if ($current.PSObject.Properties.Name -notcontains $key) { throw "Unknown setting: $key" }
        $current.$key = $Values[$key]
    }
    $current | ConvertTo-Json | Set-Content -Path (Get-MsixSettingsPath) -Encoding UTF8
    $current
}

function Invoke-MsixDownload {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Destination)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = "$Destination.part"
    $client = New-Object System.Net.WebClient
    try { $client.DownloadFile($Uri, $tmp) }
    finally { $client.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $Destination -Force
}
