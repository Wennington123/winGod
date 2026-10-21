<#
    .SYNOPSIS
        Downloads and launches the winGod build of Win11Debloat.

    .DESCRIPTION
        Fork-only launcher, modeled on the upstream Get.ps1. It fetches the
        master branch archive, extracts it under %TEMP%\winGod and starts
        Win11Debloat.ps1 with the arguments you pass through.

        This file is not part of the upstream pull request.

    .EXAMPLE
        & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/Wennington123/winGod/master/Get.ps1"))) -DisableTelemetry -WhatIf

    .EXAMPLE
        & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/Wennington123/winGod/master/Get.ps1"))) -DisableTelemetry -Silent
#>

$ErrorActionPreference = 'Stop'

$sourceUri = 'https://github.com/Wennington123/winGod/archive/refs/heads/master.zip'
$tempRoot = Join-Path $env:TEMP 'winGod'
$archivePath = Join-Path $env:TEMP 'wingod.zip'
$forwarded = @($args)

function Test-WinGodElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-WinGodArgument {
    param([string]$Value)

    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

Write-Host '-------------------------------------------------------------------------------------------'
Write-Host ' winGod (Win11Debloat fork)'
Write-Host '-------------------------------------------------------------------------------------------'

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host '> Launcher is running under PowerShell 7; the script will be started in Windows PowerShell 5.1.' -ForegroundColor DarkGray
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Host '> Downloading winGod...'
    if (Test-Path $tempRoot) {
        Get-ChildItem -Path $tempRoot -Exclude 'Config', 'Logs', 'Backups' -Force |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Invoke-RestMethod -Uri $sourceUri -OutFile $archivePath
}
catch {
    Write-Host "Unable to download winGod: $($_.Exception.Message)" -ForegroundColor Red
    $global:LASTEXITCODE = 1
    return
}

try {
    Write-Host '> Unpacking...'
    Expand-Archive -Path $archivePath -DestinationPath $tempRoot -Force
    Remove-Item -Path $archivePath -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Host "Unable to unpack winGod: $($_.Exception.Message)" -ForegroundColor Red
    $global:LASTEXITCODE = 1
    return
}

$scriptPath = (Get-ChildItem -Path $tempRoot -Recurse -Filter 'Win11Debloat.ps1' |
    Select-Object -First 1).FullName

if (-not $scriptPath) {
    Write-Host 'Win11Debloat.ps1 was not found in the downloaded archive.' -ForegroundColor Red
    $global:LASTEXITCODE = 1
    return
}

$parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Format-WinGodArgument $scriptPath))
foreach ($item in $forwarded) {
    $parts += (Format-WinGodArgument ([string]$item))
}
$argumentString = $parts -join ' '

Write-Host '> Launching Win11Debloat...'
Write-Host ''

$startParams = @{
    FilePath     = 'powershell.exe'
    ArgumentList = $argumentString
    PassThru     = $true
}

if (Test-WinGodElevated) {
    $startParams.NoNewWindow = $true
}
else {
    $startParams.Verb = 'RunAs'
}

try {
    $process = Start-Process @startParams
    $process.WaitForExit()
    $global:LASTEXITCODE = $process.ExitCode
}
catch {
    Write-Host "Unable to start Win11Debloat: $($_.Exception.Message)" -ForegroundColor Red
    $global:LASTEXITCODE = 1
}
