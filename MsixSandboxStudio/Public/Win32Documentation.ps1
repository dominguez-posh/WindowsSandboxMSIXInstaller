# Documentation of a Win32 app build: Intune settings, detection, scripts, the test lab session
# (every step with result, output and screenshot, documented clicks) and the package content.

function Format-Win32Detection {
    # Detection rule in words, e.g. "File C:\Program Files\App\app.exe version >= 2.1"
    param($Detection)
    $op = @{ equal = '='; notEqual = '<>'; greaterThan = '>'; greaterThanOrEqual = '>='; lessThan = '<'; lessThanOrEqual = '<='; notConfigured = '' }
    switch ($Detection.Type) {
        'MsiProductCode' { "MSI product code $($Detection.ProductCode)" + $(if ($Detection.ProductVersion -and $Detection.ProductVersionOperator -ne 'notConfigured') { ", version $($op[$Detection.ProductVersionOperator]) $($Detection.ProductVersion)" }) }
        'File' { "File or folder $(Join-Path $Detection.Path $Detection.FileOrFolder)" + $(if ($Detection.FileOperation -eq 'version') { " version $($op[$Detection.FileOperator]) $($Detection.FileVersion)" } else { ' exists' }) }
        'Registry' { "Registry $($Detection.KeyPath)" + $(if ($Detection.ValueName) { "\$($Detection.ValueName)" }) + $(switch ($Detection.RegistryOperation) { 'string' { " = $($Detection.RegistryValue)" } 'version' { " version $($op[$Detection.RegistryOperator]) $($Detection.RegistryValue)" } default { ' exists' } }) }
        default { 'Script Detect.ps1 (detected = exit code 0 and output on STDOUT)' }
    }
}

function New-Win32AppDocumentation {
    <#
    .SYNOPSIS
    Writes documentation\index.html into a Win32 build folder, including the last test lab session.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BuildPath)
    $def = Get-Content (Join-Path $BuildPath 'intune-app.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $docDir = Join-Path $BuildPath 'documentation'
    if (Test-Path $docDir) { Remove-Item $docDir -Recurse -Force }
    New-Item -ItemType Directory $docDir | Out-Null
    $h = { param($t) ConvertTo-MsixHtml $t }
    $rows = { param($pairs) ($pairs | ForEach-Object { "<tr><th>$(& $h $_[0])</th><td>$($_[1])</td></tr>" }) -join "`n" }

    $codes = ($def.returnCodes | ForEach-Object { "<span class='chip'>$($_.returnCode) $(& $h $_.type)</span>" }) -join ' '
    $settings = & $rows @(
        @('Display name', (& $h $def.displayName)),
        @('Version', (& $h $def.displayVersion)),
        @('Publisher', (& $h $def.publisher)),
        @('Description', (& $h $def.description)),
        @('Package file', "<code>$(& $h $def.fileName)</code><br><span class='muted'>SHA256 <code>$($def.intunewin.sha256)</code>, content $('{0:N1}' -f ($def.intunewin.unencryptedContentSize / 1MB)) MB</span>"),
        @('Setup file', "<code>$(& $h $def.setupFilePath)</code>"),
        @('Install command', "<code>$(& $h $def.installCommandLine)</code>"),
        @('Uninstall command', "<code>$(& $h $def.uninstallCommandLine)</code>"),
        @('Detection', (& $h (Format-Win32Detection $def.detection))),
        @('Install behavior', "Run as $(& $h $def.runAsAccount), restart: $(& $h $def.deviceRestartBehavior)"),
        @('Requirements', "Architecture $(& $h $def.applicableArchitectures), Windows $(& $h $def.minimumSupportedWindowsRelease) or later"),
        @('Return codes', $codes),
        @('Installer', $(if ($def.installer.file) { "$(& $h $def.installer.file) ($(& $h $def.installer.type))" + $(if ($def.installer.arguments) { ", arguments <code>$(& $h $def.installer.arguments)</code>" }) + $(if ($def.installer.productCode) { ", product code <code>$($def.installer.productCode)</code>" }) } else { '<span class="muted">script only</span>' })),
        @('Update routine', $(if ($def.hasUpdateScript) { 'Update.ps1 runs at the start of the installation' } else { '<span class="muted">none</span>' })),
        @('Published to Intune', $(if ($def.published) { "App ID <code>$($def.published.appId)</code>, $(& $h ([datetime]$def.published.date).ToString('g'))" + $(if ($def.published.supersedes) { "<br>Supersedes <code>$($def.published.supersedes)</code> ($(& $h $def.published.supersedenceType))" }) + $(if ($def.published.groupId) { "<br>Assigned ($(& $h $def.published.intent)) to group <code>$($def.published.groupId)</code>" }) } else { '<span class="muted">not yet</span>' }))
    )

    # ---- test lab session
    $testHtml = '<p class="muted">Not tested in the Win32 Test Lab yet.</p>'
    $t = $def.test
    if ($t) {
        $cls = if ($t.result -eq 'Passed') { 'passed' } else { 'failed' }
        $testHtml = "<p><span class='result $cls'>$(& $h $t.result)</span> &nbsp;$(& $h $t.scenario) &middot; $(& $h ([datetime]$t.date).ToString('g'))</p>"
        if ($t.notes) { $testHtml += "<p><b>Notes:</b> $(& $h $t.notes)</p>" }
        if ($t.changed) { $testHtml += "<p class='muted'>Scripts changed during the test and taken into the project: $(& $h ($t.changed -join ', '))</p>" }
        $lab = if ($t.job) { Join-Path $t.job 'out\lab' } else { $null }
        if ($lab -and (Test-Path (Join-Path $lab 'results.json'))) {
            $res = Get-Content (Join-Path $lab 'results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            $testHtml += "<p class='muted'>Commands ran as $(if ($res.AsSystem) { 'SYSTEM (like Intune)' } else { 'the sandbox user' }).</p>"
            $stepRows = ''
            foreach ($s in @($res.Steps)) {
                $c = switch ($s.State) { 'Passed' { 'passed' } 'Failed' { 'failed' } default { 'pending' } }
                $value = if ($s.Kind -eq 'Detect') { if ($s.Detected) { 'detected' } else { 'not detected' } } elseif ($null -ne $s.ExitCode) { "exit code $($s.ExitCode)" } else { '' }
                $shot = ''
                if ($s.Screenshot -and (Test-Path (Join-Path $lab $s.Screenshot))) {
                    $name = 'lab-' + (Split-Path $s.Screenshot -Leaf)
                    Copy-Item (Join-Path $lab $s.Screenshot) (Join-Path $docDir $name) -Force
                    $shot = "<a href='$name' target='_blank'><img loading='lazy' src='$name' alt='Screenshot after $(& $h $s.Title)' style='max-width:360px'></a>"
                }
                $output = if ($s.Output) { "<details><summary>Output</summary><pre>$(& $h $s.Output)</pre></details>" } else { '' }
                $stepRows += "<tr><td>$($s.Index)</td><td><b>$(& $h $s.Title)</b><br><span class='muted'>$(& $h $s.Expect)</span>$output</td><td><span class='result $c'>$(& $h $s.State)</span></td><td>$(& $h $value)<br><span class='muted'>$(& $h $s.Detail)</span></td><td>$(if ($s.Seconds) { "$($s.Seconds) s" })</td><td>$shot</td></tr>"
            }
            $testHtml += "<table class='grid'><tr><th>#</th><th>Step</th><th>Result</th><th>Details</th><th>Time</th><th>Screen after the step</th></tr>$stepRows</table>"
            # Clicks documented during the session (same recorder as for MSIX recordings)
            $clickFile = Join-Path $lab 'doc\steps.json'
            if (Test-Path $clickFile) {
                $clicks = @((Get-Content $clickFile -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
                if ($clicks) {
                    Copy-Item (Join-Path $lab 'doc\steps') (Join-Path $docDir 'steps') -Recurse -Force -ErrorAction SilentlyContinue
                    $testHtml += "<h2 style='margin-top:18px'>Documented clicks ($($clicks.Count))</h2>"
                    foreach ($c in $clicks) {
                        $what = if ($c.Element) { "$(& $h $c.ElementType) <b>&ldquo;$(& $h $c.Element)&rdquo;</b>" } else { "position $($c.X), $($c.Y)" }
                        $img = if ($c.Image) { "<a href='$($c.Image)' target='_blank'><img loading='lazy' src='$($c.Image)' alt='Click $($c.Index)'></a>" } else { '' }
                        $testHtml += "<div class='step'><div class='step-head'><span class='num'>$($c.Index)</span><div><div>$(& $h $c.Button) click on $what in <b>&ldquo;$(& $h $c.Window)&rdquo;</b> <span class='muted'>($(& $h $c.Process))</span></div><div class='muted'>$($c.Time)</div></div></div>$img</div>"
                    }
                }
            }
        }
    }

    # ---- scripts and content
    $scriptsHtml = ''
    foreach ($f in Get-ChildItem (Join-Path $BuildPath 'scripts') -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object { @{ 'Install.ps1' = 1; 'Detect.ps1' = 2; 'Uninstall.ps1' = 3; 'Update.ps1' = 4 }[$_.Name] }) {
        $scriptsHtml += "<details$(if ($f.Name -eq 'Install.ps1') { ' open' })><summary><b>$(& $h $f.Name)</b></summary><pre>$(& $h ([IO.File]::ReadAllText($f.FullName)))</pre></details>"
    }
    $contentHtml = ''
    $iw = Join-Path $BuildPath $def.fileName
    if (Test-Path $iw) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('iwdoc-' + [guid]::NewGuid().ToString('N'))
        try {
            Expand-IntuneWinPackage -Path $iw -Destination $tmp | Out-Null
            $files = Get-ChildItem $tmp -Recurse -File | ForEach-Object { "<tr><td>$(& $h $_.FullName.Substring($tmp.Length + 1))</td><td class='num'>$('{0:N0}' -f $_.Length)</td></tr>" }
            $contentHtml = "<table class='files'>$($files -join '')</table>"
        }
        catch { $contentHtml = "<p class='bad'>$(& $h $_.Exception.Message)</p>" }
        finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $paramJson = Get-Content (Join-Path $BuildPath 'intune-app.json') -Raw -Encoding UTF8

    $badge = if ($t -and $t.result -eq 'Passed') { 'tested in the Win32 Test Lab: passed' } elseif ($t) { 'test lab: FAILED' } else { 'not tested' }
    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(& $h $def.displayName) $(& $h $def.displayVersion) - Win32 app documentation</title>
<style>
$(Get-MsixReportStyle)
</style></head><body>
<header><h1>$(& $h $def.displayName) $(& $h $def.displayVersion)</h1><div class="sub">Win32 app for Intune (.intunewin) &middot; $(& $h $badge)</div>
<div class="meta">built $(& $h ([datetime]$def.built).ToString('yyyy-MM-dd HH:mm')) &middot; generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by MSIX Sandbox Studio</div></header>
<main>
<section class="card"><h2>Intune app settings</h2><table class="summary">$settings</table></section>
<section class="card"><h2>Test in Windows Sandbox</h2>$testHtml</section>
<section class="card"><h2>Scripts</h2>$scriptsHtml</section>
<section class="card"><h2>Package content</h2>$contentHtml</section>
<section class="card"><h2>Parameter file (intune-app.json)</h2><details><summary>Show</summary><pre>$(& $h $paramJson)</pre></details></section>
</main><footer>MSIX Sandbox Studio</footer></body></html>
"@
    $index = Join-Path $docDir 'index.html'
    [IO.File]::WriteAllText($index, $html, (New-Object Text.UTF8Encoding $false))
    Write-MsixLog "Documentation: $index" -Level Success
    $index
}
