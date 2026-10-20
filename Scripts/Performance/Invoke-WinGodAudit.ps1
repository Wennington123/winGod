<#
    .SYNOPSIS
        Runs the winGod audit on the current machine.

    .DESCRIPTION
        Read-only. Collects system, process, service, task, startup, network and
        optionally Appx data, plus an idle sample, and writes:

        <OutputPath>/<run-id>/audit.json
        <OutputPath>/<run-id>/summary.md
        <OutputPath>/logs/<run-id>/run.jsonl
        <OutputPath>/logs/<run-id>/run.log

        Run from an elevated PowerShell for complete Appx data. Without
        elevation the audit still runs and logs the fallback.

    .PARAMETER OutputPath
        Base directory for reports and logs.

    .PARAMETER Level
        Log level: Trace, Debug, Info, Warn, Error, Fatal.

    .PARAMETER Redact
        Remove user profile, user name, computer name and MAC addresses from
        every record. Use this when sharing the log.

    .PARAMETER IncludeApps
        Also collect installed and provisioned Appx packages. Slower.

    .PARAMETER IdleSeconds
        Length of the idle sampling window. 0 disables sampling.

    .PARAMETER TopProcesses
        How many processes to keep in the report, sorted by private memory.

    .EXAMPLE
        .\Invoke-WinGodAudit.ps1 -IdleSeconds 60 -IncludeApps

    .EXAMPLE
        .\Invoke-WinGodAudit.ps1 -Quick -Redact
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [ValidateSet('Trace', 'Debug', 'Info', 'Warn', 'Error', 'Fatal')]
    [string]$Level = 'Info',
    [switch]$Redact,
    [switch]$IncludeApps,
    [int]$IdleSeconds = 0,
    [int]$TopProcesses = 30,
    [int]$MaxLogBytes = 52428800,
    [switch]$NoConsole,
    [switch]$Quick
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/Logging.ps1"
. "$PSScriptRoot/Audit-System.ps1"

if (-not $OutputPath) {
    if ($env:LOCALAPPDATA) {
        $OutputPath = Join-Path (Join-Path $env:LOCALAPPDATA 'winGod') 'audit'
    }
    else {
        $OutputPath = Join-Path (Join-Path $PSScriptRoot '..\..\out') 'audit'
    }
}

$logRoot = Join-Path $OutputPath 'logs'
$logDir = New-WinGodLog -Path $logRoot -Level $Level -Redact:$Redact -NoConsole:$NoConsole -MaxFileBytes $MaxLogBytes

Add-WinGodLogContext -Data @{ phase = 'audit' }

Write-WinGodLog -Module 'audit' -Event 'audit.invoked' -Message 'starting audit' -Data @{
    output = $OutputPath
    include_apps = [bool]$IncludeApps
    idle_seconds = $IdleSeconds
    top_processes = $TopProcesses
    quick = [bool]$Quick
}

if (-not (Get-WinGodIsElevated)) {
    Write-WinGodLog -Module 'audit' -Event 'audit.elevation' -Level 'Warn' -Message 'not elevated: Appx all-users data will fall back to current user'
}

$report = $null
$paths = $null
$exitCode = 0

try {
    if ($Quick) {
        $IncludeApps = $false
        if ($IdleSeconds -eq 0) {
            $IdleSeconds = 15
        }
        if ($TopProcesses -eq 30) {
            $TopProcesses = 15
        }
    }

    $report = Get-WinGodAuditReport -IncludeApps:$IncludeApps -IdleSeconds $IdleSeconds -TopProcesses $TopProcesses

    $runPath = Join-Path $OutputPath $report['meta']['run']
    $paths = Export-WinGodAuditReport -Report $report -Path $runPath

    $failureCount = @($report['meta']['failures']).Count
    if ($failureCount -gt 0) {
        Write-WinGodLog -Module 'audit' -Event 'audit.partial' -Level 'Warn' -Message "$failureCount collector(s) failed"
    }

    Write-WinGodLog -Module 'audit' -Event 'audit.finished' -Message 'audit complete' -Data @{
        json = $paths['json']
        summary = $paths['summary']
        seconds = $report['meta']['duration_seconds']
        failures = $failureCount
    }
}
catch {
    $exitCode = 1
    Write-WinGodLog -Module 'audit' -Event 'audit.failed' -Level 'Fatal' -Message 'audit aborted' -ErrorRecord $_
}
finally {
    Close-WinGodLog
}

if ($paths) {
    Write-Host ''
    Write-Host 'winGod audit complete' -ForegroundColor Green
    Write-Host ("  summary : {0}" -f $paths['summary'])
    Write-Host ("  report  : {0}" -f $paths['json'])
    Write-Host ("  log     : {0}" -f (Join-Path $logDir 'run.jsonl'))
}

exit $exitCode
