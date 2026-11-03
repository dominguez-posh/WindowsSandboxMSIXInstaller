# Shared helpers for the Win32 Test Lab (inside the sandbox) and the host tests:
# run an Intune command line like the Intune Management Extension does, and evaluate detection rules.

function ConvertTo-LabCommandLine {
    # Intune runs commands from a 32-bit process on 64-bit Windows, so packages use %SystemRoot%\sysnative
    # to reach 64-bit PowerShell. A 64-bit process has no sysnative folder: map it to System32 there.
    param([Parameter(Mandatory)][string]$CommandLine)
    $line = [Environment]::ExpandEnvironmentVariables($CommandLine)
    if ([Environment]::Is64BitProcess) { $line = $line -replace '(?i)\\sysnative\\', '\System32\' }
    $line
}

function Start-LabCommand {
    <#
    Starts a command line in the background (working directory = package content, as in Intune).
    -AsSystem runs it as SYSTEM through a scheduled task, like the Intune Management Extension.
    Returns a handle; Get-LabCommandResult returns $null while it runs, then ExitCode/Output/Seconds.
    #>
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [switch]$AsSystem,
        [string]$Root = (Join-Path $env:ProgramData 'MsixStudioLab')
    )
    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = Join-Path $Root $id
    New-Item -ItemType Directory $dir -Force | Out-Null
    $line = ConvertTo-LabCommandLine $CommandLine
    $wrapper = Join-Path $dir 'run.ps1'
    # The wrapper runs the command through cmd.exe (Intune command lines are cmd syntax) and records the result.
    @"
`$ErrorActionPreference = 'Continue'
`$started = Get-Date
Set-Location -LiteralPath '$($WorkingDirectory.Replace("'", "''"))'
`$p = Start-Process cmd.exe -ArgumentList '/c "$($line.Replace("'", "''"))"' -Wait -PassThru -NoNewWindow ``
    -RedirectStandardOutput '$dir\stdout.txt' -RedirectStandardError '$dir\stderr.txt'
@{ ExitCode = `$p.ExitCode; Seconds = [math]::Round(((Get-Date) - `$started).TotalSeconds, 1); User = [Environment]::UserName } |
    ConvertTo-Json | Set-Content '$dir\result.json' -Encoding UTF8
"@ | Set-Content $wrapper -Encoding UTF8

    $handle = [pscustomobject]@{ Id = $id; Dir = $dir; CommandLine = $line; AsSystem = [bool]$AsSystem; Task = $null; Process = $null; Started = Get-Date }
    if ($AsSystem) {
        $name = "MsixStudioLab_$id"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wrapper`""
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $name
        $handle.Task = $name
    }
    else {
        $handle.Process = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$wrapper`"" -PassThru
    }
    $handle
}

function Get-LabCommandResult {
    # $null while running; afterwards ExitCode, Output (stdout + stderr), Seconds, User. Cleans up the task.
    param([Parameter(Mandatory)]$Handle)
    $resultFile = Join-Path $Handle.Dir 'result.json'
    if (-not (Test-Path $resultFile)) {
        # The wrapper itself failed (e.g. task did not start): give up after the process/task is gone.
        $gone = if ($Handle.Process) { $Handle.Process.HasExited } else {
            $t = Get-ScheduledTask -TaskName $Handle.Task -ErrorAction SilentlyContinue
            $t -and $t.State -ne 'Running' -and ((Get-Date) - $Handle.Started).TotalSeconds -gt 10
        }
        if (-not $gone) { return $null }
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path $resultFile)) { return [pscustomobject]@{ ExitCode = -1; Output = 'The command could not be started.'; Seconds = 0; User = '' } }
    }
    $r = $null
    try { $r = Get-Content $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }   # still being written
    $out = @()
    foreach ($f in 'stdout.txt', 'stderr.txt') {
        $p = Join-Path $Handle.Dir $f
        if (Test-Path $p) { $out += Get-Content $p -Raw -ErrorAction SilentlyContinue }
    }
    if ($Handle.Task) { Unregister-ScheduledTask -TaskName $Handle.Task -Confirm:$false -ErrorAction SilentlyContinue }
    [pscustomobject]@{ ExitCode = [int]$r.ExitCode; Output = (($out | Where-Object { $_ }) -join "`n").Trim(); Seconds = $r.Seconds; User = $r.User }
}

function Test-LabSuccessCode {
    # Intune default return codes: 0 / 1707 success, 3010 soft reboot, 1641 hard reboot (all count as installed).
    param([int]$ExitCode, [int[]]$SuccessCodes = @(0, 1707, 3010, 1641))
    $SuccessCodes -contains $ExitCode
}

function Compare-LabVersion {
    param([string]$Actual, [string]$Operator, [string]$Expected)
    try { $a = [version]($Actual -replace '[^\d\.].*$', ''); $e = [version]($Expected -replace '[^\d\.].*$', '') } catch { return $false }
    switch ($Operator) {
        'equal'              { $a -eq $e }
        'notEqual'           { $a -ne $e }
        'greaterThan'        { $a -gt $e }
        'greaterThanOrEqual' { $a -ge $e }
        'lessThan'           { $a -lt $e }
        'lessThanOrEqual'    { $a -le $e }
        default              { $true }
    }
}

function Test-LabDetection {
    <#
    Evaluates a non-script detection rule (MsiProductCode, File, Registry) like Intune does.
    Script rules run through Start-LabCommand (detected = exit code 0 and output on STDOUT).
    Returns Detected and a human-readable Detail.
    #>
    param([Parameter(Mandatory)]$Detection)
    $d = $Detection
    switch ($d.Type) {
        'MsiProductCode' {
            $keys = foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') {
                Get-ItemProperty (Join-Path $root $d.ProductCode) -ErrorAction SilentlyContinue
            }
            $key = $keys | Select-Object -First 1
            if (-not $key) { return [pscustomobject]@{ Detected = $false; Detail = "Product code $($d.ProductCode) is not installed." } }
            if ($d.ProductVersion -and $d.ProductVersionOperator -and $d.ProductVersionOperator -ne 'notConfigured') {
                $ok = Compare-LabVersion $key.DisplayVersion $d.ProductVersionOperator $d.ProductVersion
                return [pscustomobject]@{ Detected = $ok; Detail = "Product code found, version $($key.DisplayVersion) ($($d.ProductVersionOperator) $($d.ProductVersion): $ok)." }
            }
            [pscustomobject]@{ Detected = $true; Detail = "Product code found: $($key.DisplayName) $($key.DisplayVersion)." }
        }
        'File' {
            $path = Join-Path ([Environment]::ExpandEnvironmentVariables($d.Path)) $d.FileOrFolder
            if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ Detected = $false; Detail = "$path does not exist." } }
            if ($d.FileOperation -eq 'version') {
                $v = (Get-Item -LiteralPath $path).VersionInfo.FileVersion
                $ok = Compare-LabVersion $v $d.FileOperator $d.FileVersion
                return [pscustomobject]@{ Detected = $ok; Detail = "$path version $v ($($d.FileOperator) $($d.FileVersion): $ok)." }
            }
            [pscustomobject]@{ Detected = $true; Detail = "$path exists." }
        }
        'Registry' {
            $key = $d.KeyPath -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' -replace '^HKLM\\', 'HKLM:\' -replace '^HKEY_CURRENT_USER', 'HKCU:' -replace '^HKCU\\', 'HKCU:\'
            if (-not (Test-Path $key)) { return [pscustomobject]@{ Detected = $false; Detail = "$($d.KeyPath) does not exist." } }
            if (-not $d.ValueName) { return [pscustomobject]@{ Detected = $true; Detail = "$($d.KeyPath) exists." } }
            $value = (Get-ItemProperty $key -Name $d.ValueName -ErrorAction SilentlyContinue).($d.ValueName)
            if ($null -eq $value) { return [pscustomobject]@{ Detected = $false; Detail = "Value $($d.ValueName) does not exist." } }
            switch ($d.RegistryOperation) {
                'version' { $ok = Compare-LabVersion "$value" $d.RegistryOperator $d.RegistryValue }
                'string'  { $ok = "$value" -eq $d.RegistryValue }
                default   { $ok = $true }
            }
            [pscustomobject]@{ Detected = [bool]$ok; Detail = "$($d.KeyPath)\$($d.ValueName) = $value." }
        }
        default { throw "Detection type '$($d.Type)' is evaluated by running the script." }
    }
}
