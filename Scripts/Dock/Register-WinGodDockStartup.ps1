<#
    .SYNOPSIS
    Adds or removes the winGod dock auto-start Run key for the current user.

    .DESCRIPTION
    HKCU\Software\Microsoft\Windows\CurrentVersion\Run value "winGodDock".
    Uses -NoRunKey on the dock entrypoint so the running dock does not try to
    re-register itself on every launch.

    Modes:
      -Register   write the Run key (idempotent)
      -Unregister remove the Run key

    .EXAMPLE
    .\Register-WinGodDockStartup.ps1 -Register
#>
[CmdletBinding()]
param(
    [switch]$Register,
    [switch]$Unregister
)

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'winGodDock'

function Get-WinGodDockRunCommand {
    <#
        .SYNOPSIS
        Returns the exact command line the Run key should carry.
    #>
    $scriptPath = Join-Path $PSScriptRoot 'Invoke-WinGodDock.ps1'
    $command = "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`" -NoRunKey"
    return $command
}

if ($Unregister) {
    $existing = (Get-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue)
    if ($null -eq $existing) {
        Write-Host 'Run key do winGodDock não existe, nada a fazer.'
        exit 0
    }

    try {
        Remove-ItemProperty -Path $runKey -Name $runValueName -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Falha ao remover a Run key: $($_.Exception.Message)"
        exit 1
    }

    Write-Host 'Run key do winGodDock removida.' -ForegroundColor Green
    exit 0
}

$command = Get-WinGodDockRunCommand
$scriptPath = Join-Path $PSScriptRoot 'Invoke-WinGodDock.ps1'

if (-not (Test-Path $scriptPath)) {
    Write-Warning "Script de dock não encontrado: $scriptPath"
    exit 1
}

$existing = (Get-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue)

if ($existing -and $existing.$runValueName -eq $command) {
    Write-Host 'Run key do winGodDock já configurada, nada a fazer.'
    exit 0
}

try {
    Set-ItemProperty -Path $runKey -Name $runValueName -Value $command -Type String -Force -ErrorAction Stop
}
catch {
    Write-Warning "Falha ao escrever a Run key: $($_.Exception.Message)"
    exit 1
}

Write-Host 'Run key do winGodDock registada: o dock arranca com o login.' -ForegroundColor Green
exit 0
