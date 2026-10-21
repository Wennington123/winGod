@echo off
setlocal

:: winGod dock launcher. The dock is a hidden WPF window, so the PowerShell
:: host is launched detached and minimized.
set "SCRIPT_PATH=%~dp0Invoke-WinGodDock.ps1"
set "LOG_DIR=%LOCALAPPDATA%\winGod\dock\logs"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

echo Starting winGod dock...
start "" /min PowerShell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT_PATH%" >> "%LOG_DIR%\launch.log" 2>&1

echo Dock started. Stop it with: PowerShell -File "%~dp0Invoke-WinGodDock.ps1" -Stop
