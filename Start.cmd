@echo off
rem Starts MSIX Sandbox Studio by double-click (Windows PowerShell 5.1), like the M365 MFA tool:
rem -ExecutionPolicy Bypass applies to this process only and changes no system setting.
rem -WindowStyle Hidden + -HideConsole: no console window; it is shown briefly, centered over the tool, only
rem during a sign-in (the Microsoft sign-in dialog belongs to it).
rem conhost.exe: classic console host, so that Windows Terminal does not take the window over.
rem PSModulePath is cleared so that Windows PowerShell uses its own module paths, also when started from PowerShell 7.
set "PSModulePath="
start "" conhost.exe powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Start-MsixSandboxStudio.ps1" -HideConsole
