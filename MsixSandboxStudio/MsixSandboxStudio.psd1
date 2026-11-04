@{
    RootModule        = 'MsixSandboxStudio.psm1'
    ModuleVersion     = '2.3.0'
    GUID              = '5d0f4f3e-8a51-4d55-9b0e-2f6c1b7a9e41'
    Author            = 'Lucas Dominguez'
    Description       = 'MSIX packages and Win32 apps (.intunewin) for Intune: repackage, record, test and document in disposable Windows Sandboxes, publish to Intune.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        # Host and settings
        'Get-MsixHostStatus', 'Enable-MsixSandboxFeature', 'Get-MsixSettings', 'Set-MsixSettings', 'Get-MsixWorkspace', 'Set-MsixLogSink', 'Write-MsixLog'
        # Toolchain
        'Get-MsixToolchain', 'Get-MsixToolchainSource', 'Update-MsixToolchain'
        # Certificate
        'Get-MsixCertificate', 'New-MsixCertificate', 'Import-MsixCertificate', 'Import-MsixCertificateFromKeyVault'
        # Recipes
        'Get-MsixInstallerInfo', 'Get-MsixRecipe', 'Save-MsixRecipe', 'Remove-MsixRecipe', 'New-MsixConversionTemplate', 'ConvertTo-MsixVersion', 'ConvertTo-MsixPackageName'
        # Sandbox
        'Test-MsixSandboxAvailable', 'Test-MsixSandboxRunning', 'New-MsixSandboxConfig', 'Start-MsixSandbox', 'Start-MsixRecording', 'Invoke-MsixPackaging', 'Test-MsixPackage', 'Invoke-MsixPipeline'
        # Signing
        'Get-MsixPackageInfo', 'Invoke-MsixSigning'
        # Documentation
        'New-MsixDocumentation', 'Get-MsixDocumentation', 'Get-MsixPackageContent'
        # Intune
        'Connect-MsixIntune', 'Disconnect-MsixIntune', 'Get-MsixIntuneContext', 'Publish-MsixToIntune', 'Set-MsixIntuneAssignment', 'Find-MsixIntuneGroup', 'Publish-MsixCertificateToIntune', 'Get-MsixPublisherHash', 'Update-MsixIntuneToken'
        # Intune sign-in with Keevault (MCP)
        'Connect-MsixIntuneWithKeevault', 'Find-KeevaultMcp', 'Connect-KeevaultMcp', 'Invoke-KeevaultMcpTool', 'Close-KeevaultMcp', 'Invoke-MsixBrowserSignIn', 'Get-MsixWebView2'
        # Win32 apps (.intunewin)
        'Get-Win32AppProject', 'Save-Win32AppProject', 'Remove-Win32AppProject', 'Get-Win32AppScript', 'Get-Win32ScriptTemplate', 'New-Win32Detection'
        'New-IntuneWinPackage', 'Get-IntuneWinInfo', 'Expand-IntuneWinPackage', 'Get-IntuneWinInstallInfo', 'New-Win32AppPackage', 'Get-Win32AppBuild', 'ConvertTo-IntuneWin32Rule'
        'Start-Win32TestLab', 'New-Win32AppDocumentation', 'Publish-Win32AppToIntune', 'Find-IntuneWin32App'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('MSIX', 'WindowsSandbox', 'Intune', 'Packaging')
            ProjectUri = 'https://github.com/dominguez-posh/WindowsSandboxMSIXInstaller'
        }
    }
}
