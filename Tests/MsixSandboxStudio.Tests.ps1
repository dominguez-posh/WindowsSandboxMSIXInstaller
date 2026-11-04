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

Describe 'Update and documentation' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\MsixSandboxStudio\Sandbox\RecorderTemplate.ps1')
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        # A minimal .msix-like zip: manifest, VFS files (percent-encoded like real packages), root file, hive
        $script:Pkg = Join-Path $script:TestRoot 'Contoso.Notes_3.2.0.0.msix'
        $zip = [IO.Compression.ZipFile]::Open($script:Pkg, 'Create')
        $manifest = @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10" xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10" xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities">
  <Identity Name="Contoso.Notes" Publisher="CN=Contoso" Version="3.2.0.0" ProcessorArchitecture="x64"/>
  <Properties><DisplayName>Contoso Notes</DisplayName><PublisherDisplayName>Contoso</PublisherDisplayName><Logo>Assets\logo.png</Logo></Properties>
  <Capabilities><rescap:Capability Name="runFullTrust"/></Capabilities>
  <Applications><Application Id="NOTES" Executable="VFS\ProgramFilesX64\Contoso Notes\notes.exe" EntryPoint="Windows.FullTrustApplication">
    <uap:VisualElements DisplayName="Contoso Notes" Description="Notes" BackgroundColor="transparent" Square150x150Logo="Assets\logo.png" Square44x44Logo="Assets\logo.png"/>
  </Application></Applications>
</Package>
'@
        $entries = [ordered]@{
            'AppxManifest.xml'                              = $manifest
            'AppxBlockMap.xml'                              = '<x/>'
            'Assets/logo.png'                               = 'png'
            'Registry.dat'                                  = 'hive'
            'VFS/ProgramFilesX64/Contoso%20Notes/notes.exe' = 'exe'
            'VFS/Common%20AppData/Contoso/notes.ini'        = 'ini'
            'VFS/UnknownRoot/x.txt'                         = 'x'
            'readme.txt'                                    = 'root file'
        }
        foreach ($k in $entries.Keys) {
            $w = New-Object IO.StreamWriter(($zip.CreateEntry($k)).Open())
            $w.Write($entries[$k]); $w.Dispose()
        }
        $zip.Dispose()
    }
    It 'maps package entries to classic install locations' {
        $plan = @(Get-MsixRestorePlan -Path $script:Pkg -InstallRoot 'C:\Program Files\Contoso.Notes')
        ($plan | Where-Object Name -eq 'VFS/ProgramFilesX64/Contoso Notes/notes.exe').Target | Should -Be (Join-Path $env:ProgramFiles 'Contoso Notes\notes.exe')
        ($plan | Where-Object Name -eq 'VFS/Common AppData/Contoso/notes.ini').Target | Should -Be (Join-Path $env:ProgramData 'Contoso\notes.ini')
        ($plan | Where-Object Name -eq 'readme.txt').Target | Should -Be 'C:\Program Files\Contoso.Notes\readme.txt'
        ($plan | Where-Object Name -eq 'Registry.dat').Kind | Should -Be 'MachineHive'
        foreach ($skip in 'AppxManifest.xml', 'AppxBlockMap.xml', 'Assets/logo.png', 'VFS/UnknownRoot/x.txt') {
            ($plan | Where-Object Name -eq $skip).Kind | Should -Be 'Skip'
        }
    }
    It 'lists the package content by area' {
        $content = @(Get-MsixPackageContent -Path $script:Pkg)
        ($content | Where-Object Path -eq 'VFS\ProgramFilesX64\Contoso Notes\notes.exe').Area | Should -Be 'VFS\ProgramFilesX64'
        $content.Path | Should -Not -Contain 'AppxBlockMap.xml'
    }
    It 'writes the documentation with every documented click' {
        $job = Join-Path $script:TestRoot 'job-record'
        New-Item -ItemType Directory "$job\input", "$job\out\doc\steps", "$job\out\doc\frames" -Force | Out-Null
        @{ Id = 'job-record'; Mode = 'Record'; DisplayName = 'Contoso Notes' } | ConvertTo-Json | Set-Content "$job\job.json"
        "[Running] Installing MSIX Packaging Tool`n[Running] Ready" | Set-Content "$job\out\bootstrap.log"
        'img' | Set-Content "$job\out\doc\steps\step-001.jpg"
        'img' | Set-Content "$job\out\doc\frames\frame-00001.jpg"
        @(@{ Index = 1; Seconds = 4.5; Time = '10:00:04'; Button = 'Left'; X = 1; Y = 2; Window = 'Setup <Contoso>'; Process = 'setup'; Element = 'Next'; ElementType = 'button'; Image = 'steps/step-001.jpg' }) |
            ConvertTo-Json | Set-Content "$job\out\doc\steps.json"
        @(@{ Seconds = 1; Image = 'frames/frame-00001.jpg' }) | ConvertTo-Json | Set-Content "$job\out\doc\frames.json"
        @{ Started = '2026-11-04T10:00:00'; Stopped = '2026-11-04T10:01:00'; Clicks = 1; Frames = 1; AutoStarted = $true; Screen = '1920x1080'; RestoreLog = @() } |
            ConvertTo-Json | Set-Content "$job\out\doc\session.json"
        $index = New-MsixDocumentation -PackagePath $script:Pkg -JobPath $job
        $html = Get-Content $index -Raw
        $html | Should -Match 'Recorded manual installation'
        $html | Should -Match 'button <b>&ldquo;Next&rdquo;</b>'
        $html | Should -Match 'Setup &lt;Contoso&gt;'          # window titles are HTML-encoded
        $html | Should -Match 'notes\.exe'                      # file list
        Test-Path (Join-Path (Split-Path $index) 'steps\step-001.jpg') | Should -BeTrue
        Get-MsixDocumentation -PackagePath $script:Pkg | Should -Be $index
    }
    It 'compiles the click recorder' {
        { Add-Type -Path (Join-Path $PSScriptRoot '..\MsixSandboxStudio\Sandbox\ClickRecorder.cs') -ReferencedAssemblies System.Drawing, System.Windows.Forms, UIAutomationClient, UIAutomationTypes, WindowsBase } |
            Should -Not -Throw
    }
}

Describe 'Win32 apps' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\MsixSandboxStudio\Sandbox\Win32Shared.ps1')
        $script:W32 = Save-Win32AppProject -DisplayName 'Contoso Tool' -Publisher 'Contoso' -Version '2.4.1' -InstallerPath "$env:SystemRoot\System32\whoami.exe" -InstallArguments '/S' -WithUpdateScript
    }
    It 'creates a project with all four scripts that parse' {
        foreach ($name in 'Install.ps1', 'Uninstall.ps1', 'Detect.ps1', 'Update.ps1') {
            $file = Join-Path $script:W32.SourcePath $name
            Test-Path $file | Should -BeTrue
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors) | Out-Null
            $errors.Count | Should -Be 0 -Because "$name must be valid PowerShell"
        }
        $script:W32.InstallerType | Should -Be 'EXE'
        $script:W32.InstallCommand | Should -Match 'sysnative.*Install\.ps1'
    }
    It 'keeps edited scripts on save and regenerates on request' {
        $p = Save-Win32AppProject -Id $script:W32.Id -DisplayName 'Contoso Tool' -Version '2.4.1' -Scripts @{ 'Install.ps1' = '# custom'; 'Update.ps1' = '' }
        Get-Content (Join-Path $p.SourcePath 'Install.ps1') -Raw | Should -Match '# custom'
        Test-Path (Join-Path $p.SourcePath 'Update.ps1') | Should -BeFalse
        $p = Save-Win32AppProject -Id $script:W32.Id -DisplayName 'Contoso Tool' -Version '2.4.1' -RegenerateScripts
        Get-Content (Join-Path $p.SourcePath 'Install.ps1') -Raw | Should -Match 'Start-Process -FilePath'
    }
    It 'reports "not installed" from the generated detection script' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:W32.SourcePath 'Detect.ps1')
        $LASTEXITCODE | Should -Be 1
        $out | Should -BeNullOrEmpty
    }
    It 'takes the install command of a build from its intune-app.json (starting point of a recording)' {
        $b = New-Win32AppPackage -Id $script:W32.Id
        $i = Get-IntuneWinInstallInfo -Path $b.IntuneWin
        $i.FromParameterFile | Should -BeTrue
        $i.Command | Should -Match 'Install\.ps1'
        $i.Name | Should -Be $script:W32.DisplayName
    }
    It 'derives the install command from the setup file <Setup> without parameter file' -ForEach @(
        @{ Setup = 'setup.msi'; Pattern = '^msiexec\.exe /i "setup\.msi" /qn' }
        @{ Setup = 'Install.ps1'; Pattern = 'sysnative.*-File "\.\\Install\.ps1"$' }
        @{ Setup = 'setup.exe'; Pattern = '^"setup\.exe"$' }
    ) {
        $src = Join-Path $script:TestRoot "plain-$Setup"
        New-Item -ItemType Directory $src -Force | Out-Null
        Set-Content (Join-Path $src $Setup) 'x'
        $file = Join-Path $script:TestRoot "plain-$Setup.intunewin"
        New-IntuneWinPackage -SourceFolder $src -SetupFile $Setup -OutputFile $file | Out-Null
        $i = Get-IntuneWinInstallInfo -Path $file
        $i.FromParameterFile | Should -BeFalse
        $i.Command | Should -Match $Pattern
    }
    It 'builds an .intunewin whose content decrypts back to the source' {
        $b = New-Win32AppPackage -Id $script:W32.Id
        $info = Get-IntuneWinInfo -Path $b.IntuneWin
        $info.SetupFile | Should -Be 'Install.ps1'
        $info.EncryptionInfo.profileIdentifier | Should -Be 'ProfileVersion1'
        $x = Join-Path $script:TestRoot 'expanded'
        Expand-IntuneWinPackage -Path $b.IntuneWin -Destination $x | Out-Null
        foreach ($f in Get-ChildItem $script:W32.SourcePath -File) {
            (Get-FileHash (Join-Path $x $f.Name)).Hash | Should -Be (Get-FileHash $f.FullName).Hash
        }
        $def = Get-Content $b.Parameters -Raw | ConvertFrom-Json
        $def.detectionRule.'@odata.type' | Should -Be '#microsoft.graph.win32LobAppPowerShellScriptRule'
        $def.returnCodes.returnCode | Should -Contain 3010
        Test-Path $b.Documentation | Should -BeTrue
        (Get-Win32AppBuild -Id $script:W32.Id).Version | Should -Contain '2.4.1'
    }
    It 'maps detection rules to Graph rules' -ForEach @(
        @{ D = @{ Type = 'MsiProductCode'; ProductCode = '{A}'; ProductVersion = '1.2'; ProductVersionOperator = 'greaterThanOrEqual' }; T = '#microsoft.graph.win32LobAppProductCodeRule' }
        @{ D = @{ Type = 'File'; Path = '%ProgramFiles%\C'; FileOrFolder = 'c.exe'; FileOperation = 'version'; FileOperator = 'greaterThanOrEqual'; FileVersion = '2.0' }; T = '#microsoft.graph.win32LobAppFileSystemRule' }
        @{ D = @{ Type = 'Registry'; KeyPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\C'; ValueName = 'V'; RegistryOperation = 'string'; RegistryOperator = 'equal'; RegistryValue = '1' }; T = '#microsoft.graph.win32LobAppRegistryRule' }
    ) {
        $rule = ConvertTo-IntuneWin32Rule -Project ([pscustomobject]@{ Detection = [pscustomobject]$D; SourcePath = $script:W32.SourcePath })
        $rule.'@odata.type' | Should -Be $T
        $rule.ruleType | Should -Be 'detection'
    }
    It 'runs a command line like the Intune Management Extension (cmd syntax, sysnative, working folder)' {
        $wd = Join-Path $script:TestRoot 'lab content'
        New-Item -ItemType Directory $wd -Force | Out-Null
        'Write-Output "in $PWD"; exit 3010' | Set-Content (Join-Path $wd 'Install.ps1')
        $h = Start-LabCommand -CommandLine '"%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File ".\Install.ps1"' -WorkingDirectory $wd -Root (Join-Path $script:TestRoot 'labruns')
        $r = $null
        for ($i = 0; $i -lt 60 -and -not $r; $i++) { Start-Sleep -Milliseconds 500; $r = Get-LabCommandResult $h }
        $r.ExitCode | Should -Be 3010
        $r.Output | Should -Match 'lab content'
        Test-LabSuccessCode $r.ExitCode | Should -BeTrue
        Test-LabSuccessCode 1603 | Should -BeFalse
    }
    It 'evaluates file, registry and MSI detection rules' {
        (Test-LabDetection ([pscustomobject]@{ Type = 'File'; Path = '%SystemRoot%\System32'; FileOrFolder = 'notepad.exe'; FileOperation = 'exists' })).Detected | Should -BeTrue
        (Test-LabDetection ([pscustomobject]@{ Type = 'File'; Path = '%SystemRoot%\System32'; FileOrFolder = 'notepad.exe'; FileOperation = 'version'; FileOperator = 'greaterThanOrEqual'; FileVersion = '999.0' })).Detected | Should -BeFalse
        (Test-LabDetection ([pscustomobject]@{ Type = 'Registry'; KeyPath = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; ValueName = 'ProductName'; RegistryOperation = 'exists' })).Detected | Should -BeTrue
        (Test-LabDetection ([pscustomobject]@{ Type = 'MsiProductCode'; ProductCode = '{00000000-0000-0000-0000-000000000000}' })).Detected | Should -BeFalse
    }
    It 'documents a test lab session' {
        $job = Join-Path $script:TestRoot 'lab-job'
        New-Item -ItemType Directory "$job\out\lab\shots" -Force | Out-Null
        'png' | Set-Content "$job\out\lab\shots\step-1.png"
        @{ Scenario = 'New installation'; AsSystem = $true; Verdict = 'Passed'; Notes = 'ok'
           Steps = @(@{ Index = 1; Kind = 'Install'; Title = 'Install 2.4.1'; Expect = 'Exit code is a success code'; State = 'Passed'; ExitCode = 0; Detail = 'Exit code 0'; Output = 'done'; Seconds = 3; Screenshot = 'shots/step-1.png' }) } |
            ConvertTo-Json -Depth 5 | Set-Content "$job\out\lab\results.json"
        $file = Join-Path $script:W32.ProjectPath 'project.json'
        $json = Get-Content $file -Raw | ConvertFrom-Json
        $json | Add-Member -NotePropertyName LastTest -NotePropertyValue ([pscustomobject]@{ result = 'Passed'; date = (Get-Date).ToString('o'); scenario = 'new installation'; message = 'ok'; notes = 'Looks good'; job = $job; changed = @() }) -Force
        $json | ConvertTo-Json -Depth 8 | Set-Content $file
        $b = New-Win32AppPackage -Id $script:W32.Id
        $html = Get-Content $b.Documentation -Raw
        $html | Should -Match 'tested in the Win32 Test Lab: passed'
        $html | Should -Match 'Install 2\.4\.1'
        $html | Should -Match 'Looks good'
        Test-Path (Join-Path (Split-Path $b.Documentation) 'lab-step-1.png') | Should -BeTrue
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

Describe 'Keevault MCP client' {
    BeforeAll {
        # Stand-in for Keevault's MCP host: JSON-RPC over stdio, sends a notification before every reply
        $script:FakeServer = Join-Path $script:TestRoot 'fake-mcp.ps1'
        Set-Content $script:FakeServer -Encoding UTF8 -Value @'
# Raw streams: setting [Console]::InputEncoding would drop input that already arrived
$utf8 = New-Object Text.UTF8Encoding $false
$in = New-Object IO.StreamReader ([Console]::OpenStandardInput()), $utf8
$out = New-Object IO.StreamWriter ([Console]::OpenStandardOutput()), $utf8
while ($null -ne ($line = $in.ReadLine())) {
    $m = $line | ConvertFrom-Json
    if ($null -eq $m.id) { continue }
    $r = switch ($m.method) {
        'initialize' { @{ protocolVersion = '2025-06-18'; serverInfo = @{ name = 'fake' } } }
        'tools/call' {
            if ($m.params.name -eq 'fail') { @{ content = @(@{ type = 'text'; text = 'Vom Benutzer abgelehnt' }); isError = $true } }
            else { @{ content = @(@{ type = 'text'; text = '{}' }); structuredContent = @{ tool = $m.params.name; purpose = $m.params.arguments.purpose } } }
        }
    }
    $out.WriteLine((@{ jsonrpc = '2.0'; method = 'notifications/message' } | ConvertTo-Json -Compress))
    $out.WriteLine((@{ jsonrpc = '2.0'; id = $m.id; result = $r } | ConvertTo-Json -Depth 6 -Compress))
    $out.Flush()
}
'@
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script:FakeServer
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
        $script:Mcp = [pscustomobject]@{ Process = [System.Diagnostics.Process]::Start($psi); NextId = 0; Pending = $null }
    }
    AfterAll { Close-KeevaultMcp $script:Mcp }

    It 'answers requests by id and skips notifications' {
        $r = & (Get-Module MsixSandboxStudio) { param($c) Invoke-KeevaultMcpRequest -Client $c -Method 'initialize' -TimeoutSeconds 30 } $script:Mcp
        $r.serverInfo.name | Should -Be 'fake'
    }
    It 'returns the structured result of a tool, UTF-8 intact' {
        $r = Invoke-KeevaultMcpTool -Client $script:Mcp -Name 'request_microsoft_login' -Arguments @{ purpose = 'Prüfung für Intune' } -TimeoutSeconds 30
        $r.tool | Should -Be 'request_microsoft_login'
        $r.purpose | Should -Be 'Prüfung für Intune'
    }
    It 'turns a tool error into an exception' {
        { Invoke-KeevaultMcpTool -Client $script:Mcp -Name 'fail' -TimeoutSeconds 30 } | Should -Throw '*abgelehnt*'
    }
}
