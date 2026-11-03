# The "installer" of a recording conversion template. The MSIX Packaging Tool captures every change
# made while this process runs:
#   1. update recordings: restore the base package's content natively (-Restore), signal "restored"
#   2. optionally start the real installer (-Launch)
#   3. wait for the recorder: Stop recording -> exit 0 (package is built), Cancel -> exit 1602
param(
    [string]$Launch,
    [string]$Restore,
    [string]$InstallRoot
)

. (Join-Path $PSScriptRoot 'RecorderTemplate.ps1')
$stop = New-RecorderEvent 'MsixStudioStopRecording'
$cancel = New-RecorderEvent 'MsixStudioCancelRecording'
$restored = New-RecorderEvent 'MsixStudioRestored'
$restoreFailed = New-RecorderEvent 'MsixStudioRestoreFailed'

if ($Restore) {
    # Log in %TEMP% (excluded from the capture); the recorder copies it to the job folder afterwards.
    $log = Join-Path $env:TEMP 'msixstudio\restore.log'
    try {
        Restore-MsixPackageContent -Path $Restore -InstallRoot $InstallRoot -Log $log | Out-Null
    }
    catch {
        Add-Content $log "restore failed: $($_.Exception.Message)"
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
