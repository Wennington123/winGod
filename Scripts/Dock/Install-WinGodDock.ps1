<#
    .SYNOPSIS
    One-click installer for the winGod dock.

    .DESCRIPTION
    Works with the bundled exe (build\winGod-dock.exe) or falls back to the
    repository scripts. Copies the program to %LOCALAPPDATA%\winGod, registers
    the auto-start Run key for the current user and starts the dock.

    .PARAMETER Uninstall
    Stops the dock, removes the Run key and deletes the installed file.

    .PARAMETER NoLaunch
    Install without starting the dock.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$repoExe = Join-Path $repositoryRoot 'build\winGod-dock.exe'
$installDir = Join-Path $env:LOCALAPPDATA 'winGod'
$installedExe = Join-Path $installDir 'winGod-dock.exe'

if ($Uninstall) {
    $dockScript = Join-Path $PSScriptRoot 'Invoke-WinGodDock.ps1'
    if (Test-Path $dockScript) {
        PowerShell -NoProfile -ExecutionPolicy Bypass -File $dockScript -Stop *> $null
    }
    & reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v winGodDock /f *> $null
    Remove-Item $installedExe -Force -ErrorAction SilentlyContinue
    Write-Host 'winGod dock desinstalado.' -ForegroundColor Green
    exit 0
}

if (Test-Path $repoExe) {
    New-Item -Path $installDir -ItemType Directory -Force | Out-Null
    Copy-Item $repoExe $installedExe -Force
    $program = $installedExe
    $mode = 'exe'
}
else {
    $program = Join-Path $PSScriptRoot 'Invoke-WinGodDock.ps1'
    $mode = 'script'
}

$existing = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name winGodDock -ErrorAction SilentlyContinue)
$command = if ($mode -eq 'exe') {
    "`"$program`" -NoRunKey"
}
else {
    "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$program`" -NoRunKey"
}

if ($existing) { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name winGodDock -Force -ErrorAction SilentlyContinue }
New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name winGodDock -Value $command -PropertyType String -Force | Out-Null

Write-Host 'winGod dock instalado.' -ForegroundColor Green
Write-Host "  programa : $program"
Write-Host "  modo     : $mode"
Write-Host '  auto-start: registrado (Run key winGodDock)'

if (-not $NoLaunch) {
    if ($mode -eq 'exe') {
        Start-Process $program -ArgumentList '-NoRunKey'
    }
    else {
        Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $program, '-NoRunKey')
    }
}
