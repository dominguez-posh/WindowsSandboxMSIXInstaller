# Windows Sandbox MSIX Installer

A PowerShell script that turns a fresh **Windows Sandbox** into a disposable
MSIX packaging workstation: it installs the **MSIX Packaging Tool** (offline,
with its license and driver) and optionally creates a self-signed
code-signing certificate for the packages you build.

Because Windows Sandbox is thrown away when it closes, every repackaging run
starts from a clean Windows image. That is exactly what the MSIX Packaging
Tool wants: a machine with nothing else installed, so that the captured
package contains only the application you are converting.

Typical use: convert classic installers (MSI/EXE) into MSIX packages and
distribute them with Microsoft Intune.

## Requirements

- Windows 10/11 Pro, Enterprise or Education (Windows Sandbox is not
  available on Home)
- Virtualization enabled in the BIOS/UEFI
- The Windows Sandbox feature enabled on the host (one-time, needs a reboot):

  ```powershell
  Enable-WindowsOptionalFeature -FeatureName "Containers-DisposableClientVM" -All -Online
  ```

- Internet access inside the sandbox (enabled by default)

## Usage

1. Start **Windows Sandbox** from the Start menu.
2. Copy `install.ps1` into the sandbox (copy and paste works between host and
   sandbox).
3. Open PowerShell **as Administrator** inside the sandbox and run:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\install.ps1
   ```

4. Answer the prompt `Create New Password? (Y)` with `Y` if you need a new
   signing certificate (see below). Any other answer skips that step.
5. Start the **MSIX Packaging Tool** from the Start menu and package your
   application.
6. **Before closing the sandbox**, copy everything you want to keep (the
   `.msix` package, the certificate files) back to the host. Everything left
   inside the sandbox is gone when it closes.

## What the script does

| Step | Action |
|------|--------|
| 1 | Downloads the MSIX Packaging Tool bundle (`v1.2024.405.0`) to `C:\Temp` |
| 2 | Downloads the matching offline license XML to `C:\Temp` |
| 3 | Downloads the MSIX Packaging Tool driver (Feature on Demand `.cab`) to `C:\Temp` |
| 4 | Installs the driver with `Add-WindowsPackage -Online` |
| 5 | Provisions the Packaging Tool with `Add-AppxProvisionedPackage` and the offline license, so no Microsoft Store is needed |
| 6 | Optional: creates a self-signed code-signing certificate and exports it to the Public Desktop |

All downloads come directly from `download.microsoft.com`.

## Code-signing certificate

MSIX packages must be signed, and the device installing them must trust the
signing certificate. If you answer `Y`, the script:

- creates a self-signed certificate in `Cert:\CurrentUser\My` with
  - Subject `CN=unique-projects`
  - Enhanced Key Usage *Code Signing* (`1.3.6.1.5.5.7.3.3`)
  - validity of 200 years
- asks for a password and exports
  - `NewCertificate.pfx` (private key, password protected) and
  - `NewCertificatePubKey.cer` (public key only)

  to `C:\Users\Public\Desktop` in the sandbox.

How to use the two files:

- **`.pfx`**: select it in the MSIX Packaging Tool under *Signing preference →
  Sign with a certificate (.pfx)* and enter the password. Keep it safe; anyone
  holding it can sign packages your devices will trust.
- **`.cer`**: deploy it to your devices so they trust the packages, e.g. in
  Intune via *Devices → Configuration → Create → Templates → Trusted
  certificate*, store *Computer certificate store – Root* (or
  *Trusted People*).
- The **Publisher** you enter in the MSIX Packaging Tool must match the
  certificate subject exactly (`CN=unique-projects`), otherwise signing fails.

To reuse an existing certificate in a new sandbox, skip the creation step and
point the Packaging Tool at your saved `.pfx`. A certificate from a public or
internal CA works the same way and needs no extra trust deployment if the CA
is already trusted.

## Repository contents

| File | Purpose |
|------|---------|
| `install.ps1` | The installer script described above |
| `NewCertificate.pfx` | Example certificate (private key) created by the script |
| `NewCertificatePubKey.cer` | Public key of that example certificate |

> **Security note:** the `.pfx` in this repository contains a private key and
> is public. Do not use it to sign packages for production devices and do not
> deploy its `.cer` as a trusted certificate. Create your own certificate with
> the script instead.

## Known limitations

- The Packaging Tool version and download URLs are pinned in the script.
  When Microsoft publishes a new version, the URLs must be updated.
- The script has to be run again in every new sandbox session.
- The download step continues even if a download fails; check the output for
  red error lines.
- The final message mentions `C:\Temp\MSIXCert.pfx`; the files are actually
  written to the Public Desktop.

## License

No license has been specified yet.
