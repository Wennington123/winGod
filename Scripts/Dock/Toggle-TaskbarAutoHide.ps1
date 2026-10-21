<#
    .SYNOPSIS
    Toggles Windows taskbar auto-hide for the winGod dock (CLI).

    .DESCRIPTION
    Thin CLI on top of Set-TaskbarAutoHide.ps1 (the library). Edits the
    auto-hide flag inside the HKCU StuckRects3 'Settings' binary value and
    restarts Explorer to apply it.

    Modes:
      -Enable   turn auto-hide on
      -Disable  turn auto-hide off
      -Status   report current state only, no changes

    .EXAMPLE
    .\Toggle-TaskbarAutoHide.ps1 -Status
#>
[CmdletBinding(DefaultParameterSetName = 'Enable')]
param(
    [Parameter(ParameterSetName = 'Enable')]
    [switch]$Enable,

    [Parameter(ParameterSetName = 'Disable')]
    [switch]$Disable,

    [Parameter(ParameterSetName = 'Status')]
    [switch]$Status
)

. (Join-Path $PSScriptRoot 'Set-TaskbarAutoHide.ps1')

if ($Status) {
    Invoke-WinGodTaskbarAutoHide -Status
    return
}

if ($Disable) {
    $result = Invoke-WinGodTaskbarAutoHide -Disable
    exit $result
}

$result = Invoke-WinGodTaskbarAutoHide -Enable
exit $result
