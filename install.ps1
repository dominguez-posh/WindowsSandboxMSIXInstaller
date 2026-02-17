#MSIX Builder in Windows Sandbox

#Enable-WindowsOptionalFeature -FeatureName "Containers-DisposableClientVM" -All -Online



##Download MSIPackagingTool

$sourceUrl = "https://download.microsoft.com/download/e/2/e/e2e923b2-7a3a-4730-969d-ab37001fbb5e/MSIXPackagingtoolv1.2024.405.0.msixbundle"
$destinationPath = "C:\Temp\MSIXPackagingtool.msixbundle"

try {
    if (-not [Uri]::IsWellFormedUriString($sourceUrl, [UriKind]::Absolute)) {
        throw "Invalid URL format: $sourceUrl"
    }

    $destDir = Split-Path $destinationPath -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($sourceUrl, $destinationPath)

    Write-Host "Download completed successfully: $destinationPath" -ForegroundColor Green
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

$msixbundle = $destinationPath


##Download MSIPackagingTool License

$sourceUrl = "https://download.microsoft.com/download/e/2/e/e2e923b2-7a3a-4730-969d-ab37001fbb5e/MSIXPackagingtoolv1.2024.405.0.License.xml"
$destinationPath = "C:\Temp\MSIXPackagingtoolv1.2024.405.0.License.xml"

try {
    if (-not [Uri]::IsWellFormedUriString($sourceUrl, [UriKind]::Absolute)) {
        throw "Invalid URL format: $sourceUrl"
    }

    $destDir = Split-Path $destinationPath -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($sourceUrl, $destinationPath)

    Write-Host "Download completed successfully: $destinationPath" -ForegroundColor Green
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}

$Licensefile = $destinationPath

##Download MSIPackagingTool CAB FILE for Windows

$sourceUrl = "https://download.microsoft.com/download/6/c/7/6c7d654b-580b-40d4-8502-f8d435ca125a/Msix-PackagingTool-Driver-Package%7E31bf3856ad364e35%7Eamd64%7E%7E1.cab"
$destinationPath = "C:\Temp\Msix-PackagingTool-Driver-Package%7E31bf3856ad364e35%7Eamd64%7E%7E1.cab"

try {
    if (-not [Uri]::IsWellFormedUriString($sourceUrl, [UriKind]::Absolute)) {
        throw "Invalid URL format: $sourceUrl"
    }

    $destDir = Split-Path $destinationPath -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($sourceUrl, $destinationPath)

    Write-Host "Download completed successfully: $destinationPath" -ForegroundColor Green
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
}



#Install Driver for MSIX Packaging tool
Add-WindowsPackage -Online -PackagePath $destinationPath

#Install MSIX Packaging Tool with Offline License

Add-AppxProvisionedPackage -Online -PackagePath $msixbundle -LicensePath $Licensefile




###Zertifikat für MSIX Package Installieren

$cert = New-SelfSignedCertificate -Type Custom `
  -Subject "CN=unique-projects" `
  -KeyUsage DigitalSignature `
  -FriendlyName "MSIX-Installer-Zertifikat-up-LuDo" `
  -CertStoreLocation "Cert:\CurrentUser\My" `
  -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}") `
  -NotAfter (Get-Date).AddYears(100)



$password = ConvertTo-SecureString -String "!P4sswort123!" -Force -AsPlainText
Export-PfxCertificate -cert $cert -FilePath "C:\Temp\MSIXCert.pfx" -Password $password

CLS
write-host ""
Write-Host "You Can now use The Tool 'MSIX Packaging Tool'... yay "
Write-Host "Use The Certificate unter C Temp MSIXCert.pfx with the Password: !P4sswort123!"
