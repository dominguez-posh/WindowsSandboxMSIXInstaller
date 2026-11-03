@{
    RootModule        = 'MsixSandboxStudio.psm1'
    ModuleVersion     = '2.0.0'
    GUID              = '5d0f4f3e-8a51-4d55-9b0e-2f6c1b7a9e41'
    Author            = 'Lucas Dominguez'
    Description       = 'Repackage installers to MSIX in disposable Windows Sandboxes, sign on the host, test in a clean sandbox and publish to Intune.'
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
        'Test-MsixSandboxAvailable', 'Test-MsixSandboxRunning', 'New-MsixSandboxConfig', 'Start-MsixSandbox', 'Invoke-MsixPackaging', 'Test-MsixPackage', 'Invoke-MsixPipeline'
        # Signing
        'Get-MsixPackageInfo', 'Invoke-MsixSigning'
        # Intune
        'Connect-MsixIntune', 'Disconnect-MsixIntune', 'Get-MsixIntuneContext', 'Publish-MsixToIntune', 'Set-MsixIntuneAssignment', 'Find-MsixIntuneGroup', 'Publish-MsixCertificateToIntune', 'Get-MsixPublisherHash'
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
