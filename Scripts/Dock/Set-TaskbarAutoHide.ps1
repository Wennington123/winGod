<#
    .SYNOPSIS
    Library for the Windows taskbar auto-hide switch used by the winGod dock.
#>
$stuckRects3Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
$settingsValueName = 'Settings'

function Convert-WinGodStuckRectsSettings {
    <#
        .SYNOPSIS
        Pure helper: returns a new StuckRects3 byte array with the auto-hide
        flag at byte offset 8 set or cleared.

        .OUTPUTS
        byte[] with the flag updated, or $null when the layout is not
        recognised (caller must then fail without writing the registry).
    #>
    param(
        [AllowNull()]
        [byte[]]$Bytes,
        [Parameter(Mandatory)]
        [bool]$AutoHide
    )

    if (-not $Bytes -or $Bytes.Length -lt 9) {
        return $null
    }

    # Flag layouts for StuckRects3 byte 8:
    # - modern (Win10 1903+): 0x02 = hide off, 0x03 = auto-hide on
    # - legacy:               0x78 = hide off, 0x79 = auto-hide on
    $flagLowModern = 0x02
    $flagHighModern = 0x03
    $flagLowLegacy = 0x78
    $flagHighLegacy = 0x79

    $offValues = @($flagLowModern, $flagLowLegacy)
    $onValues = @($flagHighModern, $flagHighLegacy)

    if (($Bytes[8] -notin $offValues) -and ($Bytes[8] -notin $onValues)) {
        return $null
    }

    $result = [byte[]]::new($Bytes.Length)
    $Bytes.CopyTo($result, 0)
    if (($Bytes[8] -eq $flagHighLegacy) -or ($Bytes[8] -eq $flagLowLegacy)) {
        $result[8] = if ($AutoHide) { $flagHighLegacy } else { $flagLowLegacy }
    }
    else {
        $result[8] = if ($AutoHide) { $flagHighModern } else { $flagLowModern }
    }
    return $result
}

function Get-WinGodTaskbarAutoHideState {
    <#
        .SYNOPSIS
        Reads the current auto-hide flag from StuckRects3.

        .OUTPUTS
        [bool] auto-hide on, or $null when unknown (missing/unknown layout).
    #>
    try {
        $settings = (Get-ItemProperty -Path $stuckRects3Path -Name $settingsValueName -ErrorAction Stop).Settings
    }
    catch {
        return $null
    }

    if (-not $settings -or $settings.Length -lt 9) {
        return $null
    }

    switch ($settings[8]) {
        0x78 { return $false }
        0x79 { return $true }
        0x02 { return $false }
        0x03 { return $true }
        default { return $null }
    }
}

# ---------- Main (skipped when dot-sourced, e.g. by the test suite) ----------
function Invoke-WinGodTaskbarAutoHide {
    <#
        .SYNOPSIS
        Compiled-and-script entrypoint used by the dock, the CLI script and
        the bundled exe.

        .PARAMETER Enable
        Turns auto-hide on.

        .PARAMETER Disable
        Turns auto-hide off.

        .PARAMETER Status
        Reports the current state.

        .OUTPUTS
        Exit code 0/1 for Enable and Disable, $null for Status queries
        (the state is printed to the host).
    #>
    param(
        [Parameter(ParameterSetName = 'Enable')]
        [switch]$Enable,

        [Parameter(ParameterSetName = 'Disable')]
        [switch]$Disable,

        [Parameter(ParameterSetName = 'Status')]
        [switch]$Status
    )

    if ($Status) {
        $state = Get-WinGodTaskbarAutoHideState
        if ($null -eq $state) {
            Write-Host 'Estado desconhecido: StuckRects3 ausente ou formato inesperado' -ForegroundColor Yellow
            return $null
        }
        Write-Host ("Auto-hide da taskbar: {0}" -f ($(if ($state) { 'ATIVO' } else { 'INATIVO' })))
        return $null
    }

    $desired = -not $Disable

    try {
        $current = (Get-ItemProperty -Path $stuckRects3Path -Name $settingsValueName -ErrorAction Stop).Settings
    }
    catch {
        Write-Warning "StuckRects3 não encontrado: $($_.Exception.Message)"
        Write-Host 'Ativa manualmente: Settings > Personalização > Barra de tarefas > Ocultar barra de tarefas automaticamente' -ForegroundColor Yellow
        return 1
    }

    $isAutoHide = $null
    if ($current -and $current.Length -ge 9) {
        switch ($current[8]) {
            0x78 { $isAutoHide = $false }
            0x79 { $isAutoHide = $true }
            0x02 { $isAutoHide = $false }
            0x03 { $isAutoHide = $true }
        }
    }

    if ($isAutoHide -eq $desired) {
        Write-Host ("Auto-hide da taskbar já está {0}, nada a fazer." -f ($(if ($desired) { 'ATIVO' } else { 'INATIVO' })))
        return 0
    }

    $updated = Convert-WinGodStuckRectsSettings -Bytes $current -AutoHide $desired

    if (-not $updated) {
        Write-Warning 'Formato de StuckRects3 não reconhecido; valor deixado intacto.'
        Write-Host 'Ativa manualmente: Settings > Personalização > Barra de tarefas > Ocultar barra de tarefas automaticamente' -ForegroundColor Yellow
        return 1
    }

    # Write ownership guard: never truncate the value, keep original length
    if ($updated.Length -ne $current.Length) {
        Write-Warning 'Tamanho inesperado após atualização; nada escrito.'
        return 1
    }

    try {
        Set-ItemProperty -Path $stuckRects3Path -Name $settingsValueName -Value $updated -Type Binary -ErrorAction Stop
    }
    catch {
        Write-Warning "Falha ao escrever StuckRects3: $($_.Exception.Message)"
        return 1
    }

    Write-Host ("Auto-hide da taskbar {0}." -f ($(if ($desired) { 'ATIVADO' } else { 'DESATIVADO' })))
    Write-Host "A reiniciar o Windows Explorer para aplicar a mudança..." -ForegroundColor DarkGray

    if ([Environment]::Is64BitProcess -eq [Environment]::Is64BitOperatingSystem) {
        Stop-Process -ProcessName Explorer -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host 'Não foi possível reiniciar o Explorer a partir de um processo 32-bit; reinicie-o manualmente.' -ForegroundColor Yellow
    }

    return 0
}

# ---------- Library (no top-level param; the CLI lives in
# Toggle-TaskbarAutoHide.ps1) ----------
