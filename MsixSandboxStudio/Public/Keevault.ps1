# Intune sign-in with an account stored in Keevault (the user's password manager), through Keevault's MCP interface.
# Keevault comes to the front, the user picks the Microsoft account and Keevault hands over user name, password and
# the current one-time code (tool request_microsoft_login). An embedded browser (WebView2) runs the normal Microsoft
# sign-in and fills these in step by step; the user can type or choose another method at any time.
# The authorization code is redeemed here (public client with PKCE, same app as Connect-MgGraph).

$script:GraphClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'   # Microsoft Graph Command Line Tools
$script:SignInRedirect = 'http://localhost'
$script:SignInHosts = @('login.microsoftonline.com', 'login.microsoft.com', 'login.live.com')

# ---------------------------------------------------------------- Keevault MCP client (JSON-RPC over stdio)
function Find-KeevaultMcp {
    <# Where Keevault and its MCP host script are, and whether it is installed, MCP is switched on and the app runs. #>
    $running = Get-Process Keevault -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
    $exe = if ($running) { $running.Path } else { Join-Path $env:LOCALAPPDATA 'Programs\Keevault\Keevault.exe' }
    $script = Join-Path $env:APPDATA 'KeyVault PwSafe\mcp\keevault-mcp.cjs'
    [pscustomobject]@{
        Exe        = $exe
        Script     = $script
        Installed  = (Test-Path $exe)
        McpEnabled = (Test-Path $script)
        Running    = [bool]$running
    }
}

function Connect-KeevaultMcp {
    <# Starts Keevault's MCP host (Keevault.exe as Node) and runs the MCP handshake. $OnWait runs while waiting. #>
    param([scriptblock]$OnWait)
    $kv = Find-KeevaultMcp
    if (-not $kv.Installed) { throw 'Keevault is not installed on this computer.' }
    if (-not $kv.McpEnabled) { throw 'AI agents (MCP) are switched off in Keevault: Keevault > Settings > AI agents (MCP) > switch on and save.' }
    if (-not $kv.Running) { throw 'Keevault is not running. Start and unlock Keevault, then sign in again.' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $kv.Exe
    $psi.Arguments = '"{0}"' -f $kv.Script
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'
    $process = [System.Diagnostics.Process]::Start($psi)
    [void]$process.StandardError.ReadToEndAsync()   # drained so the host never blocks on a full pipe

    $client = [pscustomobject]@{ Process = $process; NextId = 0; Pending = $null }
    $version = $MyInvocation.MyCommand.Module.Version.ToString()
    try {
        [void](Invoke-KeevaultMcpRequest -Client $client -Method 'initialize' -TimeoutSeconds 20 -OnWait $OnWait -Params @{
            protocolVersion = '2025-06-18'
            capabilities    = @{}
            clientInfo      = @{ name = 'MSIX Sandbox Studio'; version = $version }
        })
        Send-KeevaultMcpMessage -Client $client -Message @{ jsonrpc = '2.0'; method = 'notifications/initialized' }
    }
    catch { Close-KeevaultMcp $client; throw }
    $client
}

function Send-KeevaultMcpMessage {
    param([Parameter(Mandatory)]$Client, [Parameter(Mandatory)][hashtable]$Message)
    # UTF-8 without BOM, one JSON object per line (.NET Framework has no StandardInputEncoding)
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes(($Message | ConvertTo-Json -Depth 10 -Compress) + "`n")
    $stream = $Client.Process.StandardInput.BaseStream
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Invoke-KeevaultMcpRequest {
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSeconds = 300,
        [scriptblock]$OnWait
    )
    $Client.NextId++
    $id = $Client.NextId
    Send-KeevaultMcpMessage -Client $Client -Message @{ jsonrpc = '2.0'; id = $id; method = $Method; params = $Params }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if (-not $Client.Pending) { $Client.Pending = $Client.Process.StandardOutput.ReadLineAsync() }
        while (-not $Client.Pending.Wait(50)) {
            if ($OnWait) { & $OnWait }
            if ($Client.Process.HasExited) { throw 'The connection to Keevault ended unexpectedly.' }
            if ((Get-Date) -gt $deadline) { throw "Keevault did not answer within $TimeoutSeconds seconds." }
        }
        $line = $Client.Pending.Result
        $Client.Pending = $null
        if ($null -eq $line) { throw 'The connection to Keevault ended unexpectedly.' }
        if (-not $line.Trim()) { continue }
        $msg = $line | ConvertFrom-Json
        if ($msg.id -ne $id) { continue }   # notifications or other replies
        if ($msg.error) { throw "Keevault: $($msg.error.message)" }
        return $msg.result
    }
}

function Invoke-KeevaultMcpTool {
    <# Calls a Keevault tool and returns its result object; a tool error (e.g. declined) becomes an exception. #>
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments = @{},
        [int]$TimeoutSeconds = 300,
        [scriptblock]$OnWait
    )
    $r = Invoke-KeevaultMcpRequest -Client $Client -Method 'tools/call' -Params @{ name = $Name; arguments = $Arguments } -TimeoutSeconds $TimeoutSeconds -OnWait $OnWait
    $text = @($r.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n"
    if ($r.isError) { throw "Keevault: $text" }
    if ($r.structuredContent) { return $r.structuredContent }
    $text | ConvertFrom-Json
}

function Close-KeevaultMcp {
    param($Client)
    if (-not $Client -or -not $Client.Process) { return }
    try { $Client.Process.StandardInput.Close() } catch { }
    if (-not $Client.Process.WaitForExit(2000)) { try { $Client.Process.Kill() } catch { } }
    $Client.Process.Dispose()
}

# ---------------------------------------------------------------- embedded browser (WebView2)
function Get-MsixWebView2 {
    <#
    Loads the WebView2 SDK (Core + WPF) for the embedded sign-in window. Downloaded once from NuGet into
    Workspace\Toolchain\WebView2; the DLLs must carry a valid Microsoft signature. Needs the WebView2 runtime
    (part of Windows 11, otherwise installed with Edge).
    #>
    $dir = Join-Path (Get-MsixWorkspace).Toolchain 'WebView2'
    $core = Join-Path $dir 'Microsoft.Web.WebView2.Core.dll'
    $wpf = Join-Path $dir 'Microsoft.Web.WebView2.Wpf.dll'
    $loader = Join-Path $dir 'WebView2Loader.dll'
    if (-not ((Test-Path $core) -and (Test-Path $wpf) -and (Test-Path $loader))) {
        $index = Invoke-RestMethod 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json' -TimeoutSec 20
        $version = @($index.versions | Where-Object { $_ -notmatch '-' })[-1]
        Write-MsixLog "Downloading the WebView2 SDK $version for the embedded sign-in ..."
        $nupkg = Join-Path ([IO.Path]::GetTempPath()) "webview2-$version.zip"
        Invoke-MsixDownload -Uri "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg" -Destination $nupkg
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
        try {
            $wanted = @{
                'lib/net462/Microsoft.Web.WebView2.Core.dll' = $core
                'lib/net462/Microsoft.Web.WebView2.Wpf.dll'  = $wpf
                'runtimes/win-x64/native/WebView2Loader.dll' = $loader
            }
            foreach ($e in $zip.Entries) {
                if ($wanted.ContainsKey($e.FullName)) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $wanted[$e.FullName], $true) }
            }
        }
        finally { $zip.Dispose(); Remove-Item $nupkg -Force -ErrorAction SilentlyContinue }
        foreach ($f in $core, $wpf, $loader) {
            $sig = if (Test-Path $f) { Get-AuthenticodeSignature -FilePath $f }
            if (-not $sig -or $sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
                Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
                throw "The WebView2 SDK file $(Split-Path $f -Leaf) is missing or not signed by Microsoft."
            }
        }
    }
    if (-not ('Microsoft.Web.WebView2.Wpf.WebView2' -as [type])) {
        Add-Type -Path $core
        Add-Type -Path $wpf
        [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath($dir)
    }
    try { [void][Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString() }
    catch { throw 'The Microsoft Edge WebView2 runtime is not installed (https://go.microsoft.com/fwlink/p/?LinkId=2124703).' }
    $dir
}

function ConvertTo-MsixBase64Url([byte[]]$Bytes) {
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# Watches the Microsoft sign-in page and reports the current step to the host; the host answers with
# __msixFill / __msixClick. Runs after every navigation (the page switches steps without navigating).
$script:SignInPageScript = @'
(() => {
  if (window.__msixSignIn) return;
  window.__msixSignIn = true;
  const q = (s) => document.querySelector(s);
  const shown = (el) => !!el && !el.disabled && el.offsetParent !== null;
  const empty = (s) => shown(q(s)) && !q(s).value;
  // Passkey page ("Face, fingerprint, PIN or security key"): the link back to the password, or in the
  // credential picker the tile "Password" (tiles are divs, so the "Forgot my password" link does not match)
  const toPassword = () => q('#idA_PWD_SwitchToPassword') || q('#idA_PWD_SwitchToCredPicker')
    || [...document.querySelectorAll('a,button')].find((el) => shown(el) && /password instead|kennwort verwenden|other ways to sign in|andere möglichkeiten/i.test(el.innerText || ''))
    || [...document.querySelectorAll('div[role="button"],div[role="listitem"],div.table')].find((el) => shown(el) && (el.innerText || '').length < 60 && /passwor|kennwort/i.test(el.innerText || ''));
  let last = '';
  setInterval(() => {
    let step = '';
    if (empty('input[name="otc"]')) step = 'otp';
    else if (empty('input[name="passwd"]')) step = 'password';
    else if (empty('input[name="loginfmt"]')) step = 'username';
    else if (shown(q('#KmsiCheckboxField')) && shown(q('#idBtn_Back'))) step = 'kmsi';
    else if (shown(q('[data-value="PhoneAppOTP"]'))) step = 'choose-otp';
    else if (shown(q('#signInAnotherWay'))) step = 'another-way';
    else if (toPassword()) step = 'passkey';
    if (step !== last) { last = step; if (step) window.chrome.webview.postMessage(step); }
  }, 400);
  window.__msixToPassword = () => { const el = toPassword(); if (el) el.click(); };
  window.__msixFill = (selector, value, submit) => {
    const el = q(selector);
    if (!el) return;
    el.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    setTimeout(() => {
      const b = q(submit) || [...document.querySelectorAll('input[type="submit"],button[type="submit"]')].find(shown);
      if (b) b.click();
    }, 300);
  };
  window.__msixClick = (selector) => { const el = q(selector); if (el) el.click(); };
})();
'@

function Invoke-MsixBrowserSignIn {
    <#
    Runs the Microsoft sign-in (authorization code + PKCE) in an embedded browser window and returns the token
    response (access_token, refresh_token, expires_in). $Fill gets the step ('username', 'password', 'otp') and
    returns the value to fill in, or $null to leave it to the user. Each value is filled in once (the one-time
    code twice at most), so a rejected password is not retried. Cookies live in a temporary profile only.
    #>
    param(
        [string]$Tenant,
        [string]$LoginHint,
        [scriptblock]$Fill,
        [switch]$HasOtp,
        [string]$Title = 'Sign in to Microsoft Intune',
        [string]$Hint,
        [System.Windows.Window]$Owner,
        # Tests: gets ($win, $wv) before the window opens (e.g. to render it off-screen)
        [scriptblock]$Configure
    )
    if (-not $Tenant) { $Tenant = 'organizations' }
    [void](Get-MsixWebView2)
    Add-Type -AssemblyName System.Web

    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes); $verifier = ConvertTo-MsixBase64Url $bytes
    $rng.GetBytes($bytes); $state = ConvertTo-MsixBase64Url $bytes
    $sha = [Security.Cryptography.SHA256]::Create()
    $challenge = ConvertTo-MsixBase64Url $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))
    $scope = (@($script:GraphScopes | ForEach-Object { "https://graph.microsoft.com/$_" }) + 'offline_access', 'openid', 'profile') -join ' '
    $query = [ordered]@{
        client_id             = $script:GraphClientId
        response_type         = 'code'
        redirect_uri          = $script:SignInRedirect
        response_mode         = 'query'
        scope                 = $scope
        state                 = $state
        code_challenge        = $challenge
        code_challenge_method = 'S256'
        prompt                = 'login'
    }
    if ($LoginHint) { $query.login_hint = $LoginHint }
    $url = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/authorize?" + (($query.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, [Uri]::EscapeDataString($_.Value) }) -join '&')

    # Window in the shared look: slate header with the hint, browser below
    $win = New-Object System.Windows.Window
    $win.Title = $Title
    $win.Width = 500; $win.Height = 700
    $win.ResizeMode = 'CanResize'
    $win.ShowInTaskbar = $true
    if ($Owner) { $win.Owner = $Owner; $win.WindowStartupLocation = 'CenterOwner' } else { $win.WindowStartupLocation = 'CenterScreen' }
    $grid = New-Object System.Windows.Controls.DockPanel
    $head = New-Object System.Windows.Controls.Border
    $head.Background = (New-Object System.Windows.Media.BrushConverter).ConvertFrom('#0F172A')
    $head.Padding = '16,10'
    [System.Windows.Controls.DockPanel]::SetDock($head, 'Top')
    $text = New-Object System.Windows.Controls.TextBlock
    $text.Text = if ($Hint) { $Hint } else { 'Sign in with your Microsoft account.' }
    $text.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFrom('#CBD5E1')
    $text.TextWrapping = 'Wrap'; $text.FontFamily = 'Segoe UI'; $text.FontSize = 12
    $head.Child = $text
    [void]$grid.Children.Add($head)

    $userData = Join-Path ([IO.Path]::GetTempPath()) ('MsixStudioSignIn-' + [guid]::NewGuid().ToString('N'))
    $wv = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $props = New-Object Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties
    $props.UserDataFolder = $userData
    # No WebAuthn in this browser: with it, Microsoft jumps straight to the passkey (Windows Hello dialog)
    # for accounts that have one, and that dialog cannot be filled in. Without it the password is asked.
    if ($Fill) { $props.AdditionalBrowserArguments = '--disable-blink-features=WebAuth' }
    $wv.CreationProperties = $props
    [void]$grid.Children.Add($wv)
    $win.Content = $grid

    $ctx = @{ Redirect = $null; Done = @{}; Otp = 0; Passkey = 0; Error = $null }
    $wv.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) { $ctx.Error = "The embedded browser could not start: $($e.InitializationException.Message)"; $win.Close(); return }
        $s.CoreWebView2.Settings.AreDevToolsEnabled = $false
        $s.CoreWebView2.Settings.IsStatusBarEnabled = $false
    })
    $wv.Add_NavigationStarting({
        param($s, $e)
        if ($e.Uri.StartsWith($script:SignInRedirect, [StringComparison]::OrdinalIgnoreCase)) {
            $e.Cancel = $true
            $ctx.Redirect = $e.Uri
            $win.Close()
        }
    })
    $wv.Add_NavigationCompleted({ param($s, $e) [void]$s.ExecuteScriptAsync($script:SignInPageScript) })
    $wv.Add_WebMessageReceived({
        param($s, $e)
        # Values only go to Microsoft's sign-in pages
        $origin = try { ([Uri]$e.Source).Host } catch { '' }
        if ($origin -notin $script:SignInHosts) { return }
        $step = $e.TryGetWebMessageAsString()
        $js = { param($f, [string[]]$a) [void]$s.ExecuteScriptAsync("window.$f(" + (($a | ForEach-Object { ConvertTo-Json $_ -Compress }) -join ',') + ')') }
        switch ($step) {
            'username' {
                if ($ctx.Done.username -or -not $Fill) { return }
                $ctx.Done.username = $true
                $v = & $Fill 'username'
                if ($v) { & $js '__msixFill' 'input[name="loginfmt"]', $v, '#idSIButton9' }
            }
            'password' {
                if ($ctx.Done.password -or -not $Fill) { return }
                $ctx.Done.password = $true
                $v = & $Fill 'password'
                if ($v) { & $js '__msixFill' 'input[name="passwd"]', $v, '#idSIButton9' }
            }
            'otp' {
                if ($ctx.Otp -ge 2 -or -not $Fill) { return }
                $ctx.Otp++
                $v = & $Fill 'otp'
                if ($v) { & $js '__msixFill' 'input[name="otc"]', $v, '#idSubmit_SAOTCC_Continue' }
            }
            'kmsi' { & $js '__msixClick' '#idBtn_Back' }   # "Stay signed in?" -> No (the profile is temporary anyway)
            'choose-otp' {
                if (-not $HasOtp -or $ctx.Done.chooseOtp) { return }
                $ctx.Done.chooseOtp = $true
                & $js '__msixClick' '[data-value="PhoneAppOTP"]'
            }
            'another-way' {
                if (-not $HasOtp -or $ctx.Done.anotherWay) { return }
                $ctx.Done.anotherWay = $true
                & $js '__msixClick' '#signInAnotherWay'
            }
            'passkey' {
                # Account prefers a passkey: back to the password we have (at most twice: link, then picker tile)
                if (-not $Fill -or $ctx.Passkey -ge 2) { return }
                $ctx.Passkey++
                [void]$s.ExecuteScriptAsync('window.__msixToPassword()')
            }
        }
    })
    # Come to the front even if another app (Keevault) has the focus right now
    $win.Add_ContentRendered({ if ($win.ShowActivated) { $win.Topmost = $true; [void]$win.Activate(); $win.Topmost = $false } })
    if ($Configure) { & $Configure $win $wv }
    $wv.Source = [Uri]$url
    try { [void]$win.ShowDialog() }
    finally {
        $wv.Dispose()
        Start-Sleep -Milliseconds 300
        Remove-Item $userData -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($ctx.Error) { throw $ctx.Error }
    if (-not $ctx.Redirect) { throw 'Sign-in cancelled.' }
    $result = [System.Web.HttpUtility]::ParseQueryString(([Uri]$ctx.Redirect).Query)
    if ($result['error']) { throw "Sign-in failed: $($result['error_description'])" }
    if ($result['state'] -ne $state) { throw 'Sign-in failed: the answer does not belong to this sign-in.' }
    Request-MsixIntuneToken -Tenant $Tenant -Body @{
        grant_type    = 'authorization_code'
        code          = $result['code']
        redirect_uri  = $script:SignInRedirect
        code_verifier = $verifier
    }
}

# ---------------------------------------------------------------- Keevault sign-in
function Connect-MsixIntuneWithKeevault {
    <#
    Signs in to Microsoft Graph with an account from Keevault. Keevault asks the user to approve and pick the
    account (only accounts released for AI agents); the embedded sign-in fills in user name, password and
    one-time code. A fresh one-time code is requested from Keevault when the first one has expired.
    #>
    [CmdletBinding()]
    param([string]$TenantId, [System.Windows.Window]$Owner, [scriptblock]$OnWait)
    $client = Connect-KeevaultMcp -OnWait $OnWait
    try {
        $request = @{ purpose = 'MSIX Sandbox Studio: sign in to Microsoft Intune (Graph)' }
        if ($TenantId -and $TenantId -match '\.' -and $TenantId -notmatch '^[0-9a-f-]{36}$') { $request.tenant = $TenantId }
        Write-MsixLog 'Keevault: choose the Microsoft account in Keevault ...'
        $login = Invoke-KeevaultMcpTool -Client $client -Name 'request_microsoft_login' -Arguments $request -OnWait $OnWait
        Write-MsixLog "Keevault: signing in as $($login.username) ($($login.title))."
        $creds = @{
            Username = [string]$login.username
            Password = [string]$login.password
            Otp      = [string]$login.totp
            OtpUntil = if ($login.totp) { (Get-Date).AddSeconds([int]$login.totpValidForSeconds - 3) } else { [datetime]::MinValue }
            Used     = $false
        }
        $fill = {
            param($step)
            switch ($step) {
                'username' { $creds.Username }
                'password' { $creds.Password }
                'otp' {
                    if (-not $creds.Otp) { return $null }
                    if ($creds.Used -or (Get-Date) -gt $creds.OtpUntil) {
                        try { $creds.Otp = [string](Invoke-KeevaultMcpTool -Client $client -Name 'get_totp' -Arguments @{ vaultId = $login.vaultId; entryId = $login.entryId } -TimeoutSeconds 120 -OnWait $OnWait).code }
                        catch { Write-MsixLog "Keevault: no new one-time code ($($_.Exception.Message))." -Level Warning; return $null }
                    }
                    $creds.Used = $true
                    $creds.Otp
                }
            }
        }
        $hint = "Keevault fills in the account $($login.username). You can type yourself or choose another sign-in method at any time."
        $token = Invoke-MsixBrowserSignIn -Tenant $TenantId -LoginHint $login.username -Fill $fill -HasOtp:([bool]$login.totp) -Hint $hint -Owner $Owner `
            -Title 'Sign in to Microsoft Intune with Keevault'
    }
    finally {
        if ($creds) { $creds.Password = $null; $creds.Otp = $null }
        Close-KeevaultMcp $client
    }
    Set-MsixIntuneToken -Token $token -Tenant $TenantId
    $ctx = Get-MgContext
    Write-MsixLog "Signed in to Microsoft Graph as $($ctx.Account) (tenant $($ctx.TenantId), via Keevault)." -Level Success
    $ctx
}
