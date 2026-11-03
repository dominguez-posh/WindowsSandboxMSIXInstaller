@echo off
rem Starts MSIX Sandbox Studio by double-click (Windows PowerShell 5.1).
rem -ExecutionPolicy Bypass applies to this process only and changes no system setting.
rem The console starts minimized; it stays because the Microsoft sign-in dialog belongs to it.
start "" /min powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start-MsixSandboxStudio.ps1"
