# The "installer" of a recording conversion template. The MSIX Packaging Tool captures every change
# made while this process runs. It optionally starts the real installer, then waits for the recorder:
#   Stop recording   -> exit 0, the tool builds the package
#   Cancel recording -> exit 1602, the conversion fails
param([string]$Launch)

. (Join-Path $PSScriptRoot 'RecorderTemplate.ps1')
$stop = New-RecorderEvent 'MsixStudioStopRecording'
$cancel = New-RecorderEvent 'MsixStudioCancelRecording'

if ($Launch -and (Test-Path -LiteralPath $Launch)) {
    if ([IO.Path]::GetExtension($Launch) -eq '.msi') { Start-Process msiexec.exe -ArgumentList '/i', "`"$Launch`"" }
    else { Start-Process -FilePath $Launch }
}

$index = [System.Threading.WaitHandle]::WaitAny(@($stop, $cancel))
if ($index -eq 0) { exit 0 }
exit 1602
