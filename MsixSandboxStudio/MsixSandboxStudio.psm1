# MSIX Sandbox Studio: repackage installers to MSIX in disposable Windows Sandboxes,
# sign on the host, test in a clean sandbox and publish to Intune.

foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem (Join-Path $PSScriptRoot $folder) -Filter '*.ps1') {
        . $file.FullName
    }
}
