# MSIX Sandbox Studio

Repackage classic installers (MSI/EXE) into **signed, tested MSIX packages**, using a fresh
**Windows Sandbox** for every run, and publish them to **Microsoft Intune**. Comes as a
PowerShell module plus a desktop GUI.

![Dashboard](docs/images/dashboard.png)

## Why a sandbox?

The MSIX Packaging Tool records everything that changes on the machine while an installer runs.
On your own workstation that capture picks up noise, and the installed app stays behind afterwards.
Windows Sandbox gives you a clean Windows image that is thrown away when it closes, so every capture
starts from the same state and nothing is left on the host.

## Features

| Step | What happens |
|------|--------------|
| **Toolchain** | Downloads the MSIX Packaging Tool (offline bundle + license), its driver and the Windows SDK signing tools **once** to the host, with SHA256 hashes. Mapped read-only into every sandbox: no download per run, and it works without network. Checks Microsoft Learn for newer versions. |
| **Recipes** | One JSON recipe per app: installer, silent arguments, package identity. Detects MSI properties and common EXE setup frameworks (Inno Setup, NSIS, WiX Burn, InstallShield, Advanced Installer, Squirrel) and suggests silent arguments. |
| **Package** | Generates a Packaging Tool conversion template and runs the conversion **unattended** in a new sandbox, which closes itself when done. Logs land in the job folder. |
| **Record** | For installers without silent mode, or apps that need setup clicks: the **MSIX Recorder** opens in a sandbox and installs everything by itself. You click **Start recording** (your installer starts automatically), install and configure the app, click **Stop recording**. The package is built, copied back, signed and optionally tested like any other. |
| **Sign** | Signs on the **host** with signtool (SHA256 + RFC 3161 timestamp). The private key never enters a sandbox. |
| **Test** | Installs the package in a second fresh sandbox (certificate trusted, network off), starts every app, takes screenshots and uninstalls it again. |
| **Intune** | Uploads the package as a line-of-business app via Microsoft Graph (new app or new version of an existing one) and assigns it to a group. It can also create the trusted-certificate profile, so devices trust your packages. |
| **Interactive** | Opens a sandbox with the Packaging Tool installed and a shared folder, for apps that need manual steps. |

## Requirements

- Windows 10/11 Pro, Enterprise or Education with virtualization enabled
- Windows Sandbox feature enabled (the dashboard can do this for you; needs a reboot)
- Windows PowerShell 5.1 (included in Windows) or PowerShell 7
- For Intune: `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`, an account allowed to manage Intune apps
- Optional, for certificates from Azure Key Vault: `Install-Module Az.KeyVault -Scope CurrentUser`

## Quick start (GUI)

1. Double-click **`Start.cmd`**.
2. **Dashboard**: fix anything that is not green. The toolchain downloads on first use (about 60 MB).
3. **Certificate**: create a self-signed code-signing certificate, or import a PFX from your CA or Key Vault.
   Its subject (for example `CN=Contoso Packaging`) becomes the publisher of every package.
4. **Recipes**: drop an `.msi` or `.exe` on the window, check the suggested values and click
   **Package + sign + test**.
   To install by hand instead, see [Recording an installation](#recording-an-installation).
5. **Packages**: see the test result and screenshots, then click **Publish to Intune**.

Devices must trust the signing certificate. With a self-signed one, click **Trust via Intune**
on the Certificate page once and assign the profile to the same devices.

## Recording an installation

For setups without silent mode, or when you want to click through the installer and configure the app:

1. Click **Record installation** on the dashboard and pick the installer (or cancel to download it in the
   sandbox). Alternatively, choose **Manual (record my installation)** in a recipe and click **Record + sign**.
2. A sandbox opens with the **MSIX Recorder**. It installs the Packaging Tool driver, the tool and your signing
   certificate by itself and shows the progress. Check the package details meanwhile.
3. Click **Start recording**. The recording starts and your installer launches automatically.
   The recorder shrinks to a small bar with a timer.
4. Install and configure the app. **Run** starts the installer again if needed.
5. Click **Stop recording**. The Packaging Tool builds the package, the sandbox closes, and the host signs it.
   The values you used are saved as a manual recipe for the next version.

| Ready | While recording |
|-------|-----------------|
| ![MSIX Recorder](docs/images/recorder.png) | ![Recording bar](docs/images/recorder-bar.png) |

Everything you change in the sandbox while recording goes into the package, so keep to the app.

## Quick start (PowerShell)

```powershell
Import-Module .\MsixSandboxStudio\MsixSandboxStudio.psd1

Update-MsixToolchain
New-MsixCertificate -Subject 'CN=Contoso Packaging' -Password (Read-Host -AsSecureString 'PFX password')

Get-MsixInstallerInfo C:\Installers\notes-setup.exe          # suggests name, version, silent arguments
Save-MsixRecipe -InstallerPath C:\Installers\notes-setup.exe -PackageName Contoso.Notes `
    -DisplayName 'Contoso Notes' -Version 3.2.0 -Arguments '/VERYSILENT /NORESTART'

# Package -> sign -> test -> publish, stops at the first failing step
Connect-MsixIntune
Invoke-MsixPipeline -RecipeName Contoso.Notes -Publish -GroupId <entra-group-id> -Intent required
```

Single steps: `Invoke-MsixPackaging`, `Start-MsixRecording` (MSIX Recorder), `Invoke-MsixSigning`, `Test-MsixPackage`, `Publish-MsixToIntune`,
`Publish-MsixCertificateToIntune`, `Start-MsixSandbox` (interactive). `Get-Help <command>` describes each.

## How it works

```
Host                                          Windows Sandbox (fresh every run)
--------------------------------------------  -------------------------------------------
Workspace\Jobs\<job>\  ──(mapped, writable)──▶ C:\MsixStudio\Job         job.json, template.xml,
                                                                         input\, out\, status.json
Workspace\Toolchain\   ──(mapped, read-only)─▶ C:\MsixStudio\Toolchain   Packaging Tool, driver
MsixSandboxStudio\Sandbox\ ─(read-only)──────▶ C:\MsixStudio\Tools       Bootstrap.ps1 (logon command)
```

1. The host writes a job folder (`job.json`, conversion template, installer copy) and a `.wsb` file.
2. Windows Sandbox starts and runs `Bootstrap.ps1` as logon command. It installs what the job needs,
   does the work and reports progress in `status.json`. For recordings, `Recorder.ps1` takes over once the
   tool is installed. On **Start recording** it runs the Packaging Tool with a template whose "installer"
   is `RecordingHold.ps1`. That process starts your setup and waits. **Stop recording** signals it through a
   named event, it exits, and the tool builds the package.
   Logs are kept in `%TEMP%` (excluded from captures) during the run and copied to `out\` at the end.
3. The host follows `status.json`, picks up the results from `out\` and continues
   (signing, the next test or upload). Package and test sandboxes shut themselves down.

Everything local lives in `Workspace\` (gitignored): `Toolchain`, `Certificates`, `Recipes`,
`Jobs` (one folder per run, with logs and screenshots), `Output` (signed packages) and `Shared`
(mapped into the interactive sandbox). Settings are stored in `settings.json`.

## Security notes

- The PFX and its password stay on the host. The password is stored with DPAPI
  (`*.pwd`, readable only by your Windows account on this computer). Sandboxes only receive the public `.cer`.
- `*.pfx`, `*.pwd` and the workspace are gitignored. Never commit signing keys.
- The certificate that was committed to this repository before version 2.0 is public.
  Do not trust it on any device; create your own instead.
- The test sandbox runs without network access.

## Limitations

- Windows runs only one sandbox at a time, so jobs run one after another.
- Manual recording captures everything changed in the sandbox while the recording window is open,
  so keep to the app (no browsing around or unrelated installs).
- Intune upload covers single `.msix` packages (no bundles or dependencies yet).
- Assigning an app replaces its existing assignments.

## Tests

```powershell
Invoke-Pester .\Tests      # Pester 5; offline, no sandbox or tenant needed
```

## Classic script

`install.ps1` is the original one-shot script. Run it inside a manually started sandbox to install
the Packaging Tool and optionally create a certificate. MSIX Sandbox Studio replaces it, but it is
kept so that existing links keep working.
