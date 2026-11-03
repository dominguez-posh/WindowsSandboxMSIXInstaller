# Pester 5 tests for the host-side logic. Offline: no downloads, no sandbox, no tenant.
#   Invoke-Pester .\Tests

BeforeAll {
    $script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("msixstudio-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $script:TestRoot | Out-Null
    $env:MSIXSTUDIO_SETTINGS = Join-Path $script:TestRoot 'settings.json'
    Import-Module (Join-Path $PSScriptRoot '..\MsixSandboxStudio\MsixSandboxStudio.psd1') -Force
    Set-MsixLogSink { param($l, $v) }
    Set-MsixSettings @{ WorkspacePath = (Join-Path $script:TestRoot 'ws') } | Out-Null
}

AfterAll {
    Remove-Module MsixSandboxStudio -ErrorAction SilentlyContinue
    Remove-Item Env:\MSIXSTUDIO_SETTINGS -ErrorAction SilentlyContinue
    Remove-Item $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Naming and versions' {
    It 'normalizes <In> to <Out>' -ForEach @(
        @{ In = '3'; Out = '3.0.0.0' }
        @{ In = '1.2.3'; Out = '1.2.3.0' }
        @{ In = 'v24.1.2 build 7'; Out = '24.1.2.7' }
        @{ In = '1.2.3.4.5'; Out = '1.2.3.4' }
        @{ In = '99999.1'; Out = '65535.1.0.0' }
    ) {
        ConvertTo-MsixVersion $In | Should -Be $Out
    }
    It 'cleans package names' {
        ConvertTo-MsixPackageName 'My App (x64)!' | Should -Be 'MyAppx64'
        ConvertTo-MsixPackageName 'ab' | Should -Be 'Appab'
        (ConvertTo-MsixPackageName ('x' * 80)).Length | Should -Be 50
    }
    It 'computes the publisher hash of Microsoft packages' {
        Get-MsixPublisherHash 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' | Should -Be '8wekyb3d8bbwe'
    }
}

Describe 'Settings' {
    It 'stores and reads values' {
        Set-MsixSettings @{ SandboxMemoryMB = 6144 } | Out-Null
        (Get-MsixSettings).SandboxMemoryMB | Should -Be 6144
    }
    It 'rejects unknown keys' {
        { Set-MsixSettings @{ Nope = 1 } } | Should -Throw
    }
}

Describe 'Conversion template' {
    BeforeAll {
        $recipe = [pscustomobject]@{ PackageName = 'Contoso.App'; DisplayName = 'Contoso & App'; PublisherDisplayName = 'Contoso'; Version = '2.1'; Description = 'Desc'; Arguments = '/S'; InstallLocation = '' }
        $script:Xml = [xml](New-MsixConversionTemplate -Recipe $recipe -Publisher 'CN=Contoso' -InstallerPath 'C:\in\setup.exe' -PackagePath 'C:\out\a.msix')
        $script:Ns = @{ t = 'http://schemas.microsoft.com/appx/msixpackagingtool/template/2018' }
    }
    It 'has package identity, publisher and a 4-part version' {
        $pi = (Select-Xml -Xml $script:Xml -XPath '//t:PackageInformation' -Namespace $script:Ns).Node
        $pi.PackageName | Should -Be 'Contoso.App'
        $pi.PublisherName | Should -Be 'CN=Contoso'
        $pi.Version | Should -Be '2.1.0.0'
        $pi.PackageDisplayName | Should -Be 'Contoso & App'
    }
    It 'passes installer path and arguments' {
        $inst = (Select-Xml -Xml $script:Xml -XPath '//t:Installer' -Namespace $script:Ns).Node
        $inst.Path | Should -Be 'C:\in\setup.exe'
        $inst.Arguments | Should -Be '/S'
    }
    It 'puts the description in the V4 namespace' {
        $script:Xml.OuterXml | Should -Match 'V4:PackageDescription="Desc"'
    }
    It 'lets manual recording replace the installer arguments' {
        $r = [pscustomobject]@{ PackageName = 'A.B'; DisplayName = 'A'; PublisherDisplayName = 'A'; Version = '1'; Arguments = '/S' }
        $x = [xml](New-MsixConversionTemplate -Recipe $r -Publisher 'CN=A' -InstallerPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -InstallerArguments '-File C:\MsixStudio\Tools\ManualCapture.ps1' -PackagePath 'y')
        $inst = (Select-Xml -Xml $x -XPath '//t:Installer' -Namespace $script:Ns).Node
        $inst.Path | Should -Match 'powershell\.exe$'
        $inst.Arguments | Should -Be '-File C:\MsixStudio\Tools\ManualCapture.ps1'
    }
    It 'has no XML declaration (the file is written as UTF-8)' {
        (New-MsixConversionTemplate -Recipe ([pscustomobject]@{ PackageName = 'A.B'; DisplayName = 'A'; PublisherDisplayName = 'A'; Version = '1' }) -Publisher 'CN=A' -InstallerPath 'x' -PackagePath 'y') |
            Should -Not -Match '<\?xml'
    }
}

Describe 'Sandbox configuration' {
    It 'maps job (writable), toolchain and tools (read-only) and runs the bootstrap' {
        $job = Join-Path $script:TestRoot 'job'
        New-Item -ItemType Directory $job -Force | Out-Null
        [xml]$wsb = Get-Content (New-MsixSandboxConfig -JobPath $job -Networking $false -MemoryMB 3072 -VGpu $false) -Raw
        $wsb.Configuration.Networking | Should -Be 'Disable'
        $wsb.Configuration.MemoryInMB | Should -Be '3072'
        $maps = @($wsb.Configuration.MappedFolders.MappedFolder)
        ($maps | Where-Object SandboxFolder -eq 'C:\MsixStudio\Job').ReadOnly | Should -Be 'false'
        ($maps | Where-Object SandboxFolder -eq 'C:\MsixStudio\Toolchain').ReadOnly | Should -Be 'true'
        ($maps | Where-Object SandboxFolder -eq 'C:\MsixStudio\Tools').ReadOnly | Should -Be 'true'
        $wsb.Configuration.LogonCommand.Command | Should -Match 'Bootstrap\.ps1'
    }
}

Describe 'Recipes' {
    It 'saves, lists and removes a recipe with a copy of the installer' {
        $r = Save-MsixRecipe -InstallerPath "$env:SystemRoot\System32\whoami.exe" -PackageName 'Test App' -DisplayName 'Test App' -Version '1.5'
        $r.PackageName | Should -Be 'TestApp'
        $r.Version | Should -Be '1.5.0.0'
        Test-Path $r.Installer | Should -BeTrue
        (Get-MsixRecipe -Name 'TestApp').DisplayName | Should -Be 'Test App'
        Remove-MsixRecipe -Name 'TestApp'
        Get-MsixRecipe -Name 'TestApp' | Should -BeNullOrEmpty
    }
    It 'saves a manual recipe without installer' {
        $r = Save-MsixRecipe -PackageName 'Manual.App' -DisplayName 'Manual App' -Version '2' -InstallMode Manual
        $r.InstallMode | Should -Be 'Manual'
        $r.Installer | Should -BeNullOrEmpty
        Remove-MsixRecipe -Name 'Manual.App'
    }
    It 'refuses a silent recipe without installer' {
        { Save-MsixRecipe -PackageName 'Silent.App' -DisplayName 'Silent App' } | Should -Throw
    }
    It 'reads product name and version from an EXE' {
        $info = Get-MsixInstallerInfo "$env:SystemRoot\System32\notepad.exe"
        $info.Type | Should -Be 'EXE'
        $info.Manufacturer | Should -Match 'Microsoft'
        $info.Version | Should -Match '^\d+\.\d+\.\d+\.\d+$'
    }
}

Describe 'Certificate' {
    It 'creates a self-signed certificate without leaving it in the user store' {
        $pw = ConvertTo-SecureString 'P@ss-Test-1' -AsPlainText -Force
        $c = New-MsixCertificate -Subject 'CN=MSIX Studio Pester' -Password $pw -Years 1
        $c.Subject | Should -Be 'CN=MSIX Studio Pester'
        $c.HasPassword | Should -BeTrue
        Test-Path $c.PfxPath | Should -BeTrue
        Test-Path $c.CerPath | Should -BeTrue
        Get-ChildItem Cert:\CurrentUser\My | Where-Object Thumbprint -eq $c.Thumbprint | Should -BeNullOrEmpty
    }
}

Describe 'Recorder (sandbox side)' {
    BeforeAll {
        $script:SandboxDir = Join-Path $PSScriptRoot '..\MsixSandboxStudio\Sandbox'
        . (Join-Path $script:SandboxDir 'RecorderTemplate.ps1')
    }
    It 'normalizes versions like the module' -ForEach @(
        @{ In = '3'; Out = '3.0.0.0' }
        @{ In = '1.2.3.4'; Out = '1.2.3.4' }
        @{ In = '1.2.x'; Out = $null }
        @{ In = '70000'; Out = $null }
    ) {
        ConvertTo-RecorderVersion $In | Should -Be $Out
    }
    It 'builds a template whose installer is the recording hold' {
        $x = [xml](New-RecorderTemplate -PackageName 'Contoso.Notes' -DisplayName 'Contoso Notes' -PublisherName 'CN=Contoso' `
            -PublisherDisplayName 'Contoso' -Version '3.2.0.0' -InstallerPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -InstallerArguments '-File RecordingHold.ps1' -PackagePath 'C:\MsixStudio\Job\out\Contoso.Notes_3.2.0.0.msix')
        $ns = @{ t = 'http://schemas.microsoft.com/appx/msixpackagingtool/template/2018' }
        (Select-Xml -Xml $x -XPath '//t:Installer' -Namespace $ns).Node.Arguments | Should -Be '-File RecordingHold.ps1'
        (Select-Xml -Xml $x -XPath '//t:PackageInformation' -Namespace $ns).Node.PublisherName | Should -Be 'CN=Contoso'
        (Select-Xml -Xml $x -XPath '//t:SaveLocation' -Namespace $ns).Node.PackagePath | Should -Match 'Contoso\.Notes_3\.2\.0\.0\.msix$'
    }
    It 'ends the hold process with <Code> on <Signal>' -ForEach @(
        @{ Signal = 'Stop'; Code = 0 }
        @{ Signal = 'Cancel'; Code = 1602 }
    ) {
        $stop = New-RecorderEvent 'MsixStudioStopRecording'
        $cancel = New-RecorderEvent 'MsixStudioCancelRecording'
        [void]$stop.Reset(); [void]$cancel.Reset()
        $p = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:SandboxDir 'RecordingHold.ps1') -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 3
        $p.HasExited | Should -BeFalse   # waits while "recording"
        if ($Signal -eq 'Stop') { [void]$stop.Set() } else { [void]$cancel.Set() }
        $p.WaitForExit(15000) | Should -BeTrue
        $p.ExitCode | Should -Be $Code
        [void]$stop.Reset(); [void]$cancel.Reset()
        $stop.Dispose(); $cancel.Dispose()
    }
}

Describe 'Intune content encryption' {
    It 'produces HMAC + IV + ciphertext that decrypts to the original' {
        $src = Join-Path $script:TestRoot 'plain.bin'
        $dst = Join-Path $script:TestRoot 'enc.bin'
        $data = New-Object byte[] 100000
        (New-Object Random 42).NextBytes($data)
        [IO.File]::WriteAllBytes($src, $data)
        $info = & (Get-Module MsixSandboxStudio) { param($s, $d) Protect-MsixIntuneFile -Source $s -Target $d } $src $dst
        $bytes = [IO.File]::ReadAllBytes($dst)

        $hmac = New-Object Security.Cryptography.HMACSHA256 (, [Convert]::FromBase64String($info.macKey))
        [Convert]::ToBase64String($hmac.ComputeHash($bytes, 32, $bytes.Length - 32)) | Should -Be $info.mac
        [Convert]::ToBase64String($bytes[0..31]) | Should -Be $info.mac

        $aes = [Security.Cryptography.Aes]::Create()
        $aes.Key = [Convert]::FromBase64String($info.encryptionKey)
        $aes.IV = $bytes[32..47]
        $plain = $aes.CreateDecryptor().TransformFinalBlock($bytes, 48, $bytes.Length - 48)
        [Convert]::ToBase64String($plain) | Should -Be ([Convert]::ToBase64String($data))
        $info.profileIdentifier | Should -Be 'ProfileVersion1'
    }
}
