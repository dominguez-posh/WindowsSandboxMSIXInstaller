# Package documentation: an HTML report next to every package that shows how it was made and what is in it
# (identity, signature, automatic steps, every documented click with screenshot, screen recording player,
# full file list, test result, logs). Same look as the GUI.

function ConvertTo-MsixHtml([string]$Text) { [System.Net.WebUtility]::HtmlEncode("$Text") }

function Format-MsixDuration([double]$Seconds) {
    $t = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds
}

function Get-MsixPackageContent {
    <# Lists the files inside an .msix (decoded paths, sizes), metadata parts excluded. #>
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }
            $name = [uri]::UnescapeDataString($e.FullName)
            if ($name -in 'AppxBlockMap.xml', 'AppxSignature.p7x', '[Content_Types].xml' -or $name -like 'AppxMetadata/*') { continue }
            $parts = $name -split '/'
            $area = if ($parts[0] -eq 'VFS' -and $parts.Count -gt 2) { "VFS\$($parts[1])" } elseif ($parts.Count -gt 1) { $parts[0] } else { '(package root)' }
            [pscustomobject]@{ Path = $name -replace '/', '\'; Area = $area; Size = $e.Length }
        }
    }
    finally { $zip.Dispose() }
}

function New-MsixDocumentation {
    <#
    .SYNOPSIS
    Writes the documentation of a package to <package>_documentation\index.html (next to the .msix).
    .PARAMETER JobPath
    The sandbox job that produced the package (job.json, logs, recorded clicks and frames).
    .PARAMETER TestResult
    Optional result of Test-MsixPackage, added with its screenshots.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [string]$JobPath,
        $TestResult
    )
    $pkg = Get-MsixPackageInfo -Path $PackagePath
    $base = [IO.Path]::GetFileNameWithoutExtension($PackagePath)
    $docDir = Join-Path (Split-Path $PackagePath -Parent) "$($base)_documentation"
    if (Test-Path $docDir) { Remove-Item $docDir -Recurse -Force }
    New-Item -ItemType Directory $docDir -Force | Out-Null
    $h = { param($t) ConvertTo-MsixHtml $t }

    # ---- data
    $job = $null; $steps = @(); $frames = @(); $session = $null; $prep = @(); $convLog = @()
    if ($JobPath -and (Test-Path $JobPath)) {
        $job = Get-Content (Join-Path $JobPath 'job.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $out = Join-Path $JobPath 'out'
        $rec = Join-Path $out 'doc'
        if (Test-Path (Join-Path $rec 'steps.json')) {
            # Windows PowerShell returns a JSON array as one object: unroll it explicitly.
            $steps = @((Get-Content (Join-Path $rec 'steps.json') -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
            $frames = @((Get-Content (Join-Path $rec 'frames.json') -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
            $session = Get-Content (Join-Path $rec 'session.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($sub in 'steps', 'frames') {
                if (Test-Path (Join-Path $rec $sub)) { Copy-Item (Join-Path $rec $sub) (Join-Path $docDir $sub) -Recurse -Force }
            }
        }
        $boot = Join-Path $out 'bootstrap.log'
        if (Test-Path $boot) { $prep = @(Get-Content $boot | Where-Object { $_ -match '^\[(Running|Succeeded|Failed)\] ' } | ForEach-Object { $_ -replace '^\[\w+\]\s*', '' } | Select-Object -Unique) }
        $conv = Join-Path $out 'conversion.log'
        if (Test-Path $conv) { $convLog = @(Get-Content $conv -Tail 80) }
    }
    $sig = Get-AuthenticodeSignature -FilePath $pkg.Path
    $content = @(Get-MsixPackageContent -Path $pkg.Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($pkg.Path)
    try {
        $reader = New-Object IO.StreamReader($zip.GetEntry('AppxManifest.xml').Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }
    $capabilities = @($manifest.Package.Capabilities.ChildNodes | ForEach-Object { $_.Name } | Where-Object { $_ })

    $method = 'Unattended conversion'
    if ($job -and $job.Mode -eq 'Record') { $method = if ($job.BasePackage) { "Recorded update of $($job.BaseDisplayName) $($job.BaseVersion)" } else { 'Recorded manual installation' } }
    $installer = $null
    if ($JobPath) {
        $inst = Get-ChildItem (Join-Path $JobPath 'input') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'signing.cer' -and $_.Extension -ne '.msix' } | Select-Object -First 1
        if ($inst) { $installer = [pscustomobject]@{ Name = $inst.Name; Sha256 = Get-MsixSha256 $inst.FullName; Size = $inst.Length } }
    }

    # ---- html parts
    $rows = { param($pairs) ($pairs | ForEach-Object { "<tr><th>$(& $h $_[0])</th><td>$($_[1])</td></tr>" }) -join "`n" }
    $summary = & $rows @(
        @('Display name', (& $h $pkg.DisplayName)),
        @('Package name', "<code>$(& $h $pkg.Name)</code>"),
        @('Version', (& $h $pkg.Version)),
        @('Publisher', "<code>$(& $h $pkg.Publisher)</code>"),
        @('Publisher display name', (& $h $pkg.PublisherDisplayName)),
        @('Architecture', (& $h $pkg.Architecture)),
        @('Applications', (($pkg.Applications | ForEach-Object { "<code>$(& $h $_.Id)</code> &rarr; $(& $h $_.Executable)" }) -join '<br>')),
        @('Capabilities', (($capabilities | ForEach-Object { "<span class='chip'>$(& $h $_)</span>" }) -join ' ')),
        @('Size', ('{0:N1} MB, {1} files' -f ($pkg.SizeBytes / 1MB), $content.Count)),
        @('How it was made', (& $h $method)),
        @('Installer', $(if ($installer) { "$(& $h $installer.Name) ({0:N1} MB)<br><span class='muted'>SHA256 <code>$($installer.Sha256)</code></span>" -f ($installer.Size / 1MB) } else { '<span class="muted">none (installed manually in the sandbox)</span>' })),
        @('Signature', $(if ($sig.SignerCertificate) { "$(& $h $sig.SignerCertificate.Subject)<br><span class='muted'>Thumbprint <code>$($sig.SignerCertificate.Thumbprint)</code>, timestamp: $(if ($sig.TimeStamperCertificate) { 'yes' } else { 'no' })</span>" } else { '<span class="bad">not signed</span>' })),
        @('Sandbox job', $(if ($job) { "<code>$(& $h $job.Id)</code>" } else { '-' }))
    )

    $prepHtml = if ($prep) { '<ol class="plain">' + (($prep | ForEach-Object { "<li>$(& $h $_)</li>" }) -join '') + '</ol>' } else { '<p class="muted">No automatic steps recorded.</p>' }

    $stepsHtml = ''
    if ($steps) {
        $stepsHtml = ($steps | ForEach-Object {
            $what = if ($_.Element) { "$(& $h $_.ElementType) <b>&ldquo;$(& $h $_.Element)&rdquo;</b>" } else { 'position ' + $_.X + ', ' + $_.Y }
            $where = if ($_.Window) { " in <b>&ldquo;$(& $h $_.Window)&rdquo;</b>" } else { '' }
            $proc = if ($_.Process) { " <span class='muted'>($(& $h $_.Process))</span>" } else { '' }
            $img = if ($_.Image) { "<a href='$($_.Image)' target='_blank'><img loading='lazy' src='$($_.Image)' alt='Step $($_.Index)'></a>" } else { '' }
            @"
<div class="step" id="step-$($_.Index)">
  <div class="step-head"><span class="num">$($_.Index)</span>
    <div><div>$(& $h $_.Button) click on $what$where$proc</div>
    <div class="muted">+$(Format-MsixDuration $_.Seconds) &middot; $($_.Time) &middot; <a href="#player" onclick="seek($($_.Seconds))">show in recording</a></div></div>
  </div>
  $img
</div>
"@
        }) -join "`n"
    }
    elseif ($job -and $job.Mode -eq 'Record') { $stepsHtml = '<p class="muted">Click documentation was switched off for this recording.</p>' }
    else { $stepsHtml = "<p>The installer ran unattended$(if ($job -and $job.Installer) { ': <code>' + (& $h $job.Installer) + '</code>' })$(if ($installer -and (Get-MsixRecipe -Name $pkg.Name).Arguments) { ' with <code>' + (& $h (Get-MsixRecipe -Name $pkg.Name).Arguments) + '</code>' }). No manual steps.</p>" }

    $playerHtml = ''
    if ($frames) {
        $framesJson = ($frames | ForEach-Object { '{"s":' + ([string]$_.Seconds).Replace(',', '.') + ',"i":"' + $_.Image + '"}' }) -join ','
        $clicksJson = ($steps | ForEach-Object { '{"s":' + ([string]$_.Seconds).Replace(',', '.') + ',"n":' + $_.Index + '}' }) -join ','
        $playerHtml = @"
<section class="card" id="player"><h2>Screen recording</h2>
<p class="muted">The whole recording as one frame per second. Red marks on the timeline are the documented clicks.</p>
<div class="player"><img id="frame" src="$($frames[0].Image)" alt="Screen recording">
<div class="controls"><button id="play" onclick="toggle()">&#9654; Play</button>
<select id="speed"><option value="1">1x</option><option value="2">2x</option><option value="4" selected>4x</option><option value="8">8x</option></select>
<div class="timeline" id="timeline" onclick="clickTimeline(event)"><div class="bar" id="bar"></div></div>
<span id="clock" class="mono">00:00:00</span></div></div></section>
<script>
const frames=[$framesJson], clicks=[$clicksJson];
let idx=0, timer=null; const total=frames.length?frames[frames.length-1].s:0;
const tl=document.getElementById('timeline');
clicks.forEach(c=>{const m=document.createElement('div');m.className='mark';m.style.left=(total?c.s/total*100:0)+'%';m.title='Step '+c.n;m.onclick=e=>{e.stopPropagation();location.hash='step-'+c.n;};tl.appendChild(m);});
function fmt(s){s=Math.floor(s);return [s/3600,s%3600/60,s%60].map(v=>String(Math.floor(v)).padStart(2,'0')).join(':');}
function show(i){idx=Math.max(0,Math.min(frames.length-1,i));document.getElementById('frame').src=frames[idx].i;document.getElementById('bar').style.width=(total?frames[idx].s/total*100:0)+'%';document.getElementById('clock').textContent=fmt(frames[idx].s);}
function seek(s){let i=frames.findIndex(f=>f.s>=s);show(i<0?frames.length-1:i);}
function toggle(){const b=document.getElementById('play');if(timer){clearInterval(timer);timer=null;b.innerHTML='&#9654; Play';return;}
b.innerHTML='&#10074;&#10074; Pause';timer=setInterval(()=>{if(idx>=frames.length-1){toggle();return;}show(idx+1);},1000/document.getElementById('speed').value);}
function clickTimeline(e){const r=tl.getBoundingClientRect();seek((e.clientX-r.left)/r.width*total);}
</script>
"@
    }

    $sessionHtml = ''
    if ($session) {
        $dur = ([datetime]$session.Stopped - [datetime]$session.Started).TotalSeconds
        $restore = if ($session.RestoreLog) { '<br><span class="muted">' + (($session.RestoreLog | ForEach-Object { & $h $_ }) -join '<br>') + '</span>' } else { '' }
        $sessionHtml = "<p>Recording from $(& $h ([datetime]$session.Started).ToString('g')) for $(Format-MsixDuration $dur), $($session.Clicks) clicks, screen $(& $h $session.Screen). Installer started automatically: $(if ($session.AutoStarted) { 'yes' } else { 'no' }).$restore</p>"
        if ($session.Error) { $sessionHtml += "<p class='bad'>Documentation note: $(& $h $session.Error)</p>" }
    }

    $testHtml = ''
    if ($TestResult) {
        $shots = ''
        $i = 0
        foreach ($s in @($TestResult.Screenshots)) {
            $i++
            $name = "test-$i.png"
            Copy-Item $s (Join-Path $docDir $name) -Force
            $shots += "<a href='$name' target='_blank'><img loading='lazy' src='$name' alt='Test screenshot $i'></a>"
        }
        $cls = if ($TestResult.State -eq 'Succeeded') { 'ok' } else { 'bad' }
        $testHtml = "<section class='card'><h2>Test in a clean sandbox</h2><p class='$cls'><b>$(& $h $TestResult.State)</b>: $(& $h $TestResult.Message)</p><div class='shots'>$shots</div></section>"
    }

    $areas = $content | Group-Object Area | Sort-Object Name
    $filesHtml = ($areas | ForEach-Object {
        $list = ($_.Group | Sort-Object Path | ForEach-Object { "<tr><td>$(& $h $_.Path)</td><td class='num'>$('{0:N0}' -f $_.Size)</td></tr>" }) -join ''
        "<details><summary><b>$(& $h $_.Name)</b> <span class='muted'>$($_.Count) files, $('{0:N1}' -f (($_.Group | Measure-Object Size -Sum).Sum / 1MB)) MB</span></summary><table class='files'>$list</table></details>"
    }) -join "`n"
    $registry = if ($content | Where-Object Path -in 'Registry.dat', 'User.dat', 'UserClasses.dat') { 'The package contains registry data (' + ((($content | Where-Object Path -in 'Registry.dat', 'User.dat', 'UserClasses.dat').Path) -join ', ') + ').' } else { 'The package contains no registry data.' }

    $logHtml = if ($convLog) { "<details><summary>MSIX Packaging Tool output (last lines)</summary><pre>$(& $h ($convLog -join "`n"))</pre></details>" } else { '' }

    $html = @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(& $h $pkg.DisplayName) $(& $h $pkg.Version) - package documentation</title>
<style>
:root{--bg:#F3F5F8;--header:#0F172A;--card:#fff;--line:#E1E5EA;--text:#242424;--muted:#64748B;--primary:#0067B8;--ok:#107C41;--bad:#C42B1C}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
header{background:var(--header);color:#fff;padding:22px 32px}header h1{margin:0;font-size:24px;font-weight:600}
header .sub{color:#94A3B8;font-size:13px}header .meta{color:#CBD5E1;font-size:12px;margin-top:6px}
main{max-width:1180px;margin:0 auto;padding:24px 16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:18px 22px;margin-bottom:16px}
h2{font-size:15px;margin:0 0 12px;font-weight:600}table{border-collapse:collapse;width:100%}
.summary th{text-align:left;color:var(--muted);font-weight:600;width:210px;vertical-align:top;padding:6px 12px 6px 0}
.summary td{padding:6px 0;border-bottom:1px solid #EEF1F4}code,.mono{font-family:Consolas,monospace;font-size:12.5px}
.muted{color:var(--muted);font-size:12.5px}.ok{color:var(--ok)}.bad{color:var(--bad)}
.chip{display:inline-block;background:#E0ECF8;color:#0F3D66;border-radius:10px;padding:1px 9px;font-size:12px;margin:2px 2px 2px 0}
.step{border-top:1px solid #EEF1F4;padding:14px 0}.step:first-of-type{border-top:0}
.step-head{display:flex;gap:12px;align-items:flex-start;margin-bottom:8px}
.num{flex:none;width:28px;height:28px;border-radius:14px;background:var(--bad);color:#fff;font-weight:700;display:flex;align-items:center;justify-content:center}
.step img,.shots img{max-width:100%;border:1px solid var(--line);border-radius:4px}.shots{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:10px}
.player{max-width:960px;margin:0 auto}.player img{width:100%;border:1px solid var(--line);border-radius:4px;background:#000}
.controls{display:flex;gap:10px;align-items:center;margin-top:8px}.controls button,.controls select{font:inherit;padding:6px 14px;border:0;border-radius:4px;background:var(--primary);color:#fff;cursor:pointer}
.controls select{background:#64748B}.timeline{flex:1;height:10px;background:#E2E8F0;border-radius:5px;position:relative;cursor:pointer}
.bar{height:100%;background:var(--primary);border-radius:5px;width:0}.mark{position:absolute;top:-3px;width:4px;height:16px;background:var(--bad);border-radius:2px;cursor:pointer}
details{margin:6px 0}summary{cursor:pointer;padding:4px 0}.files td{padding:2px 8px;border-bottom:1px solid #F1F5F9;font-family:Consolas,monospace;font-size:12px}
.files td.num{text-align:right;color:var(--muted);width:120px}pre{background:#0F172A;color:#E2E8F0;padding:12px;border-radius:4px;overflow:auto;font-size:12px}
ol.plain{margin:0;padding-left:20px}footer{text-align:center;color:var(--muted);font-size:12px;padding:10px 0 30px}
@media print{.controls,#player{display:none}header{-webkit-print-color-adjust:exact;print-color-adjust:exact}}
</style></head><body>
<header><h1>$(& $h $pkg.DisplayName) $(& $h $pkg.Version)</h1><div class="sub">MSIX package documentation</div>
<div class="meta">$(& $h $method) &middot; generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by MSIX Sandbox Studio</div></header>
<main>
<section class="card"><h2>Package</h2><table class="summary">$summary</table></section>
<section class="card"><h2>Automatic preparation in the sandbox</h2>$prepHtml</section>
<section class="card"><h2>Installation steps$(if ($steps) { " ($($steps.Count) clicks)" })</h2>$sessionHtml$stepsHtml</section>
$playerHtml
$testHtml
<section class="card"><h2>Package contents</h2><p class="muted">$(& $h $registry)</p>$filesHtml</section>
<section class="card"><h2>Logs</h2>$logHtml<p class="muted">Full logs: job folder $(if ($JobPath) { '<code>' + (& $h $JobPath) + '</code>' })</p></section>
</main><footer>MSIX Sandbox Studio</footer></body></html>
"@
    $index = Join-Path $docDir 'index.html'
    [IO.File]::WriteAllText($index, $html, (New-Object Text.UTF8Encoding $false))
    Write-MsixLog "Documentation: $index" -Level Success
    $index
}

function Get-MsixDocumentation {
    <# Path of a package's documentation (index.html) or $null. #>
    param([Parameter(Mandatory)][string]$PackagePath)
    $index = Join-Path (Split-Path $PackagePath -Parent) ("{0}_documentation\index.html" -f [IO.Path]::GetFileNameWithoutExtension($PackagePath))
    if (Test-Path $index) { $index } else { $null }
}
