@echo off
rem Starts MSIX Sandbox Studio by double-click (Windows PowerShell 5.1).
rem -ExecutionPolicy Bypass applies to this process only and changes no system setting.
rem PSModulePath is cleared so that Windows PowerShell uses its own module paths, also when started from PowerShell 7.
rem The console starts minimized; it stays because the Microsoft sign-in dialog belongs to it.
set "PSModulePath="
start "" /min powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start-MsixSandboxStudio.ps1"
