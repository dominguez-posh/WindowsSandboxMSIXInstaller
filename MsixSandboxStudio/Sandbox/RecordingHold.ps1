# The "installer" of a recording conversion template. The MSIX Packaging Tool captures every change
# made while this process runs:
#   1. update recordings: put the starting point in place, signal "restored"
#      -Restore: restore the base MSIX package's content natively
#      -Win32Base: install the previous Win32 app (decrypted .intunewin) with the command in -Win32CommandFile
#   2. optionally start the real installer (-Launch), i.e. the update
#   3. wait for the recorder: Stop recording -> exit 0 (package is built), Cancel -> exit 1602
param(
    [string]$Launch,
    [string]$Restore,
    [string]$InstallRoot,
    [string]$Win32Base,
    [string]$Win32CommandFile
)

. (Join-Path $PSScriptRoot 'RecorderTemplate.ps1')
$stop = New-RecorderEvent 'MsixStudioStopRecording'
$cancel = New-RecorderEvent 'MsixStudioCancelRecording'
$restored = New-RecorderEvent 'MsixStudioRestored'
$restoreFailed = New-RecorderEvent 'MsixStudioRestoreFailed'
# Log in %TEMP% (excluded from the capture); the recorder copies it to the job folder afterwards.
$log = Join-Path $env:TEMP 'msixstudio\restore.log'

if ($Restore) {
    try {
        Restore-MsixPackageContent -Path $Restore -InstallRoot $InstallRoot -Log $log | Out-Null
    }
    catch {
        Add-Content $log "restore failed: $($_.Exception.Message)"
        [void]$restoreFailed.Set()
    }
    [void]$restored.Set()
}

if ($Win32Base) {
    try {
        # Intune commands use sysnative (32-bit IME); this process is 64-bit, where sysnative does not exist
        $command = ((Get-Content -LiteralPath $Win32CommandFile -Raw).Trim()) -replace '(?i)\\sysnative\\', '\System32\'
        Add-Content $log "installing the previous Win32 app in ${Win32Base}: $command"
        # /s: cmd strips only the outer quotes added here, the command keeps its own
        $p = Start-Process cmd.exe -ArgumentList "/s /c `"$command`"" -WorkingDirectory $Win32Base -WindowStyle Hidden -Wait -PassThru
        Add-Content $log "exit code $($p.ExitCode)"
        if ($p.ExitCode -notin 0, 1707, 3010, 1641) { [void]$restoreFailed.Set() }
    }
    catch {
        Add-Content $log "install failed: $($_.Exception.Message)"
        [void]$restoreFailed.Set()
    }
    [void]$restored.Set()
}

if ($Launch -and (Test-Path -LiteralPath $Launch)) {
    if ([IO.Path]::GetExtension($Launch) -eq '.msi') { Start-Process msiexec.exe -ArgumentList '/i', "`"$Launch`"" }
    else { Start-Process -FilePath $Launch }
}

$index = [System.Threading.WaitHandle]::WaitAny(@($stop, $cancel))
if ($index -eq 0) { exit 0 }
exit 1602
