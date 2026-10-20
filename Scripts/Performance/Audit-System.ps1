<#
    .SYNOPSIS
        Read-only system audit for winGod.

    .DESCRIPTION
        Collects what the machine is doing before any change: processes,
        services, scheduled tasks, startup entries, Appx packages, network
        connections and an idle sample.

        Nothing here writes to the system. Every collector fails open: a broken
        collector is logged as a warning and the audit continues without it.

        Counters are read through CIM raw perf classes on purpose. Get-Counter
        needs English counter names, which breaks on localized Windows.
#>

if (-not (Get-Variable -Name WinGodVersion -Scope Script -ErrorAction SilentlyContinue)) {
    $script:WinGodVersion = '0.1.0'
}

$script:WinGodTelemetryTaskPrefixes = @(
    '\Microsoft\Windows\Application Experience\',
    '\Microsoft\Windows\Customer Experience Improvement Program\',
    '\Microsoft\Windows\Feedback\',
    '\Microsoft\Windows\Windows Error Reporting\',
    '\Microsoft\Windows\PI\',
    '\Microsoft\Windows\DiskDiagnostic\',
    '\Microsoft\Windows\DiskFootprint\',
    '\Microsoft\Windows\Device Information\',
    '\Microsoft\Windows\Power Efficiency Diagnostics\',
    '\Microsoft\Windows\WDI\',
    '\Microsoft\Windows\Autochk\'
)

function Get-WinGodAverage {
    <#
        .SYNOPSIS
            Mean of the non-null values, or $null when nothing is left.

        .DESCRIPTION
            Works on values pulled out of dictionaries, which is what the idle
            sampler produces. Measure-Object cannot read dictionary keys as
            properties, so it cannot be used here.
    #>
    param(
        [AllowNull()]
        $Values
    )

    $sum = 0.0
    $count = 0

    foreach ($value in @($Values)) {
        if ($null -ne $value) {
            $sum += [double]$value
            $count++
        }
    }

    if ($count -eq 0) {
        return $null
    }

    return $sum / $count
}

function Get-WinGodMaximum {
    <#
        .SYNOPSIS
            Largest non-null value, or $null when nothing is left.
    #>
    param(
        [AllowNull()]
        $Values
    )

    $max = $null

    foreach ($value in @($Values)) {
        if ($null -ne $value) {
            if ($null -eq $max -or [double]$value -gt $max) {
                $max = [double]$value
            }
        }
    }

    return $max
}

function ConvertTo-WinGodMB {
    <#
        .SYNOPSIS
            Converts bytes to megabytes, rounded to one decimal.
    #>
    param(
        [double]$Bytes
    )

    return [math]::Round($Bytes / 1MB, 1)
}

function Test-WinGodTelemetryTaskPath {
    <#
        .SYNOPSIS
            True when a scheduled task path belongs to a telemetry task folder.
    #>
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    foreach ($prefix in $script:WinGodTelemetryTaskPrefixes) {
        if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-WinGodIsElevated {
    <#
        .SYNOPSIS
            True when the current process runs with administrator rights.
    #>
    param()

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Invoke-WinGodSafeCollector {
    <#
        .SYNOPSIS
            Runs a collector and returns a section object, never throwing.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $value = & $ScriptBlock
        $stopwatch.Stop()
        Write-WinGodLog -Module 'audit' -Event "collector.$Name" -Level 'Debug' -Message 'ok' -DurationMs $stopwatch.Elapsed.TotalMilliseconds
        return [ordered]@{
            ok = $true
            error = $null
            duration_ms = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
            value = $value
        }
    }
    catch {
        $stopwatch.Stop()
        Write-WinGodLog -Module 'audit' -Event "collector.$Name" -Level 'Warn' -Message 'failed' -DurationMs $stopwatch.Elapsed.TotalMilliseconds -ErrorRecord $_
        return [ordered]@{
            ok = $false
            error = $_.Exception.Message
            duration_ms = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
            value = $null
        }
    }
}

function Get-WinGodSystemInfo {
    <#
        .SYNOPSIS
            OS build, hardware and memory totals.
    #>
    param()

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue

    $totalMb = [math]::Round(([double]$os.TotalVisibleMemorySize) / 1024, 1)
    $freeMb = [math]::Round(([double]$os.FreePhysicalMemory) / 1024, 1)
    $uptimeHours = 0
    if ($os.LastBootUpTime) {
        $uptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 2)
    }

    $usedPct = $null
    if ($totalMb -gt 0) {
        $usedPct = [math]::Round((($totalMb - $freeMb) / $totalMb) * 100, 1)
    }

    $biosVersion = $null
    if ($bios) {
        $biosVersion = $bios.SMBIOSBIOSVersion
    }

    return [ordered]@{
        caption = $os.Caption
        version = $os.Version
        build = $os.BuildNumber
        architecture = $os.OSArchitecture
        installed = $os.InstallDate
        last_boot = $os.LastBootUpTime
        uptime_hours = $uptimeHours
        manufacturer = $cs.Manufacturer
        model = $cs.Model
        domain_joined = [bool]$cs.PartOfDomain
        logical_cpus = $cs.NumberOfLogicalProcessors
        total_ram_mb = $totalMb
        free_ram_mb = $freeMb
        used_ram_mb = [math]::Round($totalMb - $freeMb, 1)
        used_ram_pct = $usedPct
        bios_version = $biosVersion
        elevated = (Get-WinGodIsElevated)
    }
}

function Get-WinGodProcessInventory {
    <#
        .SYNOPSIS
            Process totals and the heaviest processes by private memory.
    #>
    param(
        [int]$Top = 30
    )

    $all = @(Get-Process -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) {
        throw 'Get-Process returned no processes'
    }

    $totalPrivate = 0
    $totalWorking = 0
    $totalHandles = 0
    foreach ($process in $all) {
        $totalPrivate += $process.PrivateMemorySize64
        $totalWorking += $process.WorkingSet64
        $totalHandles += $process.HandleCount
    }

    $rows = @($all |
        Sort-Object -Property PrivateMemorySize64 -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            [ordered]@{
                name = $_.ProcessName
                pid = $_.Id
                private_mb = (ConvertTo-WinGodMB -Bytes $_.PrivateMemorySize64)
                working_set_mb = (ConvertTo-WinGodMB -Bytes $_.WorkingSet64)
                handles = $_.HandleCount
                threads = $_.Threads.Count
                started = $_.StartTime
            }
        })

    return [ordered]@{
        count = $all.Count
        total_private_mb = (ConvertTo-WinGodMB -Bytes $totalPrivate)
        total_working_set_mb = (ConvertTo-WinGodMB -Bytes $totalWorking)
        total_handles = $totalHandles
        top = $rows
    }
}

function Get-WinGodServiceInventory {
    <#
        .SYNOPSIS
            Every service with its state and start mode.
    #>
    param()

    $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)

    $rows = @($services | ForEach-Object {
        [ordered]@{
            name = $_.Name
            display_name = $_.DisplayName
            state = $_.State
            start_mode = $_.StartMode
            account = $_.StartName
            pid = $_.ProcessId
        }
    })

    $running = @($rows | Where-Object { $_.state -eq 'Running' })
    $auto = @($rows | Where-Object { $_.start_mode -eq 'Auto' })
    $autoRunning = @($rows | Where-Object { $_.start_mode -eq 'Auto' -and $_.state -eq 'Running' })

    return [ordered]@{
        total = $rows.Count
        running = $running.Count
        auto = $auto.Count
        auto_running = $autoRunning.Count
        manual = @($rows | Where-Object { $_.start_mode -eq 'Manual' }).Count
        disabled = @($rows | Where-Object { $_.start_mode -eq 'Disabled' }).Count
        services = $rows
    }
}

function Get-WinGodScheduledTaskInventory {
    <#
        .SYNOPSIS
            Scheduled tasks, with telemetry-related tasks called out.
    #>
    param()

    Import-Module ScheduledTasks -ErrorAction Stop
    $tasks = @(Get-ScheduledTask -ErrorAction Stop)

    $rows = @($tasks | ForEach-Object {
        [ordered]@{
            path = $_.TaskPath
            name = $_.TaskName
            state = [string]$_.State
        }
    })

    $telemetry = @($rows | Where-Object { Test-WinGodTelemetryTaskPath -Path $_.path })
    $telemetryEnabled = @($telemetry | Where-Object { $_.state -notin @('Disabled', 'Unknown') })

    return [ordered]@{
        total = $rows.Count
        ready = @($rows | Where-Object { $_.state -eq 'Ready' }).Count
        running = @($rows | Where-Object { $_.state -eq 'Running' }).Count
        disabled = @($rows | Where-Object { $_.state -eq 'Disabled' }).Count
        telemetry_total = $telemetry.Count
        telemetry_enabled = $telemetryEnabled.Count
        telemetry_tasks = $telemetry
        tasks = $rows
    }
}

function Get-WinGodStartupInventory {
    <#
        .SYNOPSIS
            Startup entries from Win32_StartupCommand and Run keys.
    #>
    param()

    $rows = New-Object System.Collections.ArrayList

    $commands = @(Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        [void]$rows.Add([ordered]@{
            source = 'Win32_StartupCommand'
            location = $command.Location
            name = $command.Name
            command = $command.Command
            user = $command.User
        })
    }

    $runKeys = @(
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; View = '64' }
        @{ Hive = 'HKLM'; Path = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; View = '32' }
        @{ Hive = 'HKCU'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; View = '64' }
        @{ Hive = 'HKCU'; Path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'; View = '64' }
    )

    foreach ($key in $runKeys) {
        $providerPath = '{0}:\{1}' -f $key.Hive, $key.Path
        if (-not (Test-Path -LiteralPath $providerPath)) {
            continue
        }

        try {
            $item = Get-Item -LiteralPath $providerPath -ErrorAction Stop
            $userValue = 'SYSTEM'
            if ($key.Hive -eq 'HKCU') {
                $userValue = $env:USERNAME
            }

            foreach ($valueName in $item.GetValueNames()) {
                [void]$rows.Add([ordered]@{
                    source = 'Registry'
                    location = $providerPath
                    name = $valueName
                    command = $item.GetValue($valueName)
                    user = $userValue
                })
            }
        }
        catch {
            Write-WinGodLog -Module 'audit' -Event 'startup.registry' -Level 'Warn' -Message "could not read $providerPath" -ErrorRecord $_
        }
    }

    return [ordered]@{
        total = $rows.Count
        entries = @($rows)
    }
}

function Get-WinGodAppxInventory {
    <#
        .SYNOPSIS
            Installed and provisioned Appx packages.
    #>
    param()

    $installed = $null
    $scope = 'current-user'

    try {
        $installed = @(Get-AppxPackage -AllUsers -ErrorAction Stop)
        $scope = 'all-users'
    }
    catch {
        Write-WinGodLog -Module 'audit' -Event 'appx.allusers' -Level 'Warn' -Message 'Get-AppxPackage -AllUsers failed, falling back to current user' -ErrorRecord $_
        $installed = @(Get-AppxPackage -ErrorAction Stop)
    }

    $installedRows = @($installed | ForEach-Object {
        [ordered]@{
            name = $_.Name
            full_name = $_.PackageFullName
            version = $_.Version.ToString()
            publisher = $_.Publisher
            is_framework = [bool]$_.IsFramework
            status = [string]$_.Status
        }
    })

    $provisionedRows = @()
    try {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
        $provisionedRows = @($provisioned | ForEach-Object {
            [ordered]@{
                name = $_.DisplayName
                version = $_.Version
            }
        })
    }
    catch {
        Write-WinGodLog -Module 'audit' -Event 'appx.provisioned' -Level 'Warn' -Message 'Get-AppxProvisionedPackage failed' -ErrorRecord $_
    }

    return [ordered]@{
        scope = $scope
        installed_total = $installedRows.Count
        installed_non_framework = @($installedRows | Where-Object { -not $_.is_framework }).Count
        provisioned_total = $provisionedRows.Count
        installed = $installedRows
        provisioned = $provisionedRows
    }
}

function Get-WinGodNetworkInventory {
    <#
        .SYNOPSIS
            Established TCP connections grouped by owning process.
    #>
    param()

    $connections = @(Get-NetTCPConnection -State Established -ErrorAction Stop)
    $processes = @{}
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        $processes[[int]$process.Id] = $process.ProcessName
    }

    $groups = @($connections |
        Group-Object -Property OwningProcess |
        ForEach-Object {
            $processId = [int]$_.Name
            $name = $processes[$processId]
            if (-not $name) {
                $name = 'unknown'
            }
            [ordered]@{
                process = $name
                pid = $processId
                connections = $_.Count
                remote = @($_.Group | ForEach-Object { '{0}:{1}' -f $_.RemoteAddress, $_.RemotePort } | Select-Object -Unique)
            }
        } |
        Sort-Object -Property connections -Descending)

    return [ordered]@{
        established_total = $connections.Count
        by_process = $groups
    }
}

function Measure-WinGodIdle {
    <#
        .SYNOPSIS
            Samples idle cost for a fixed window.

        .DESCRIPTION
            Reads CIM raw performance classes and computes deltas, so the result
            does not depend on the OS display language.

            cpu_pct is the mean busy time across logical processors. Memory is
            total physical minus free. Disk writes are physical disk bytes per
            second on the _Total instance.
    #>
    param(
        [int]$Seconds = 60,
        [int]$Interval = 2
    )

    if ($Seconds -lt 1) {
        throw 'Seconds must be at least 1'
    }

    if ($Interval -lt 1) {
        $Interval = 1
    }

    if ($Interval -gt $Seconds) {
        $Interval = $Seconds
    }

    $samples = New-Object System.Collections.ArrayList
    $deadline = (Get-Date).AddSeconds($Seconds)

    $previousCpu = @{}
    $previousDisk = $null
    $previousTimestamp = $null

    while ((Get-Date) -lt $deadline) {
        $cpuInstances = @(Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Processor -ErrorAction Stop)
        $disk = Get-CimInstance -ClassName Win32_PerfRawData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop

        $timestamp = $null
        foreach ($instance in $cpuInstances) {
            $timestamp = [double]$instance.Timestamp_Sys100NS
            break
        }

        $cpuPct = $null
        if ($null -ne $previousTimestamp -and $null -ne $timestamp -and $timestamp -gt $previousTimestamp) {
            $deltaTime = $timestamp - $previousTimestamp
            $sum = 0.0
            $counted = 0

            foreach ($instance in $cpuInstances) {
                if ([string]$instance.Name -eq '_Total') {
                    continue
                }

                $key = [string]$instance.Name
                if ($previousCpu.ContainsKey($key)) {
                    $delta = [double]$instance.PercentProcessorTime - [double]$previousCpu[$key]
                    if ($delta -lt 0) {
                        $delta = 0
                    }
                    $sum += ($delta / $deltaTime) * 100
                    $counted++
                }
            }

            if ($counted -gt 0) {
                $cpuPct = $sum / $counted
            }
        }

        $diskWrite = $null
        if ($null -ne $disk -and $null -ne $previousDisk) {
            $deltaTime = ([double]$disk.Timestamp_Sys100NS - $previousDisk.time) / 10000000
            if ($deltaTime -gt 0) {
                $deltaBytes = [double]$disk.DiskWriteBytesPerSec - $previousDisk.bytes
                if ($deltaBytes -ge 0) {
                    $diskWrite = $deltaBytes / $deltaTime
                }
            }
        }

        $previousCpu = @{}
        foreach ($instance in $cpuInstances) {
            if ([string]$instance.Name -ne '_Total') {
                $previousCpu[[string]$instance.Name] = $instance.PercentProcessorTime
            }
        }
        $previousTimestamp = $timestamp
        if ($null -ne $disk) {
            $previousDisk = @{
                time = [double]$disk.Timestamp_Sys100NS
                bytes = [double]$disk.DiskWriteBytesPerSec
            }
        }

        $totalMb = ([double]$os.TotalVisibleMemorySize) / 1024
        $freeMb = ([double]$os.FreePhysicalMemory) / 1024
        $usedMb = $totalMb - $freeMb

        $processList = @(Get-Process -ErrorAction SilentlyContinue)
        $handles = 0
        foreach ($process in $processList) {
            $handles += $process.HandleCount
        }

        $cpuValue = $null
        if ($null -ne $cpuPct) {
            $cpuValue = [math]::Round($cpuPct, 2)
        }

        $diskValue = $null
        if ($null -ne $diskWrite) {
            $diskValue = [math]::Round($diskWrite, 1)
        }

        [void]$samples.Add([ordered]@{
            at = (Get-Date).ToString('o')
            cpu_pct = $cpuValue
            used_ram_mb = [math]::Round($usedMb, 1)
            used_ram_pct = [math]::Round(($usedMb / $totalMb) * 100, 1)
            disk_write_bytes = $diskValue
            processes = $processList.Count
            handles = $handles
        })

        $remaining = ($deadline - (Get-Date)).TotalSeconds
        if ($remaining -gt 0) {
            $sleep = [math]::Min($Interval, [math]::Ceiling($remaining))
            Start-Sleep -Seconds $sleep
        }
    }

    $cpuValues = New-Object System.Collections.ArrayList
    $ramValues = New-Object System.Collections.ArrayList
    $ramPctValues = New-Object System.Collections.ArrayList
    $diskValues = New-Object System.Collections.ArrayList
    $processValues = New-Object System.Collections.ArrayList
    $handleValues = New-Object System.Collections.ArrayList

    foreach ($sample in $samples) {
        if ($null -ne $sample['cpu_pct']) { [void]$cpuValues.Add($sample['cpu_pct']) }
        if ($null -ne $sample['used_ram_mb']) { [void]$ramValues.Add($sample['used_ram_mb']) }
        if ($null -ne $sample['used_ram_pct']) { [void]$ramPctValues.Add($sample['used_ram_pct']) }
        if ($null -ne $sample['disk_write_bytes']) { [void]$diskValues.Add($sample['disk_write_bytes']) }
        if ($null -ne $sample['processes']) { [void]$processValues.Add($sample['processes']) }
        if ($null -ne $sample['handles']) { [void]$handleValues.Add($sample['handles']) }
    }

    $cpuAverage = Get-WinGodAverage -Values $cpuValues
    $cpuMaximum = Get-WinGodMaximum -Values $cpuValues
    $ramAverage = Get-WinGodAverage -Values $ramValues
    $ramPctAverage = Get-WinGodAverage -Values $ramPctValues
    $diskAverage = Get-WinGodAverage -Values $diskValues
    $processAverage = Get-WinGodAverage -Values $processValues
    $handleAverage = Get-WinGodAverage -Values $handleValues

    if ($null -ne $cpuAverage) { $cpuAverage = [math]::Round($cpuAverage, 2) }
    if ($null -ne $cpuMaximum) { $cpuMaximum = [math]::Round($cpuMaximum, 2) }
    if ($null -ne $ramAverage) { $ramAverage = [math]::Round($ramAverage, 1) }
    if ($null -ne $ramPctAverage) { $ramPctAverage = [math]::Round($ramPctAverage, 1) }
    if ($null -ne $diskAverage) { $diskAverage = [math]::Round($diskAverage, 1) }
    if ($null -ne $processAverage) { $processAverage = [math]::Round($processAverage, 1) }
    if ($null -ne $handleAverage) { $handleAverage = [math]::Round($handleAverage, 1) }

    $summary = [ordered]@{
        cpu_pct_avg = $cpuAverage
        cpu_pct_max = $cpuMaximum
        used_ram_mb_avg = $ramAverage
        used_ram_pct_avg = $ramPctAverage
        disk_write_bytes_avg = $diskAverage
        processes_avg = $processAverage
        handles_avg = $handleAverage
    }

    return [ordered]@{
        seconds = $Seconds
        interval = $Interval
        sample_count = $samples.Count
        warmup_samples = @($samples | Where-Object { $null -eq $_.cpu_pct }).Count
        summary = $summary
        samples = @($samples)
    }
}

function Get-WinGodAuditReport {
    <#
        .SYNOPSIS
            Runs every collector and returns one report object.
    #>
    param(
        [switch]$IncludeApps,
        [int]$IdleSeconds = 0,
        [int]$TopProcesses = 30
    )

    $started = Get-Date
    $sections = [ordered]@{}
    $failures = New-Object System.Collections.ArrayList

    $collectors = [ordered]@{
        system = { Get-WinGodSystemInfo }
        processes = { Get-WinGodProcessInventory -Top $TopProcesses }
        services = { Get-WinGodServiceInventory }
        tasks = { Get-WinGodScheduledTaskInventory }
        startup = { Get-WinGodStartupInventory }
        network = { Get-WinGodNetworkInventory }
    }

    if ($IncludeApps) {
        $collectors['appx'] = { Get-WinGodAppxInventory }
    }

    if ($IdleSeconds -gt 0) {
        $interval = 2
        if ($IdleSeconds -le 10) {
            $interval = 1
        }

        $collectors['idle'] = { Measure-WinGodIdle -Seconds $IdleSeconds -Interval $interval }
    }

    foreach ($name in $collectors.Keys) {
        $section = Invoke-WinGodSafeCollector -Name $name -ScriptBlock $collectors[$name]
        $sections[$name] = $section
        if (-not $section.ok) {
            [void]$failures.Add([ordered]@{ section = $name; error = $section.error })
        }
    }

    $elapsed = ((Get-Date) - $started).TotalSeconds

    $runId = $null
    if ($script:WinGodLog) {
        $runId = $script:WinGodLog.RunId
    }

    return [ordered]@{
        meta = [ordered]@{
            tool = 'winGod'
            version = $script:WinGodVersion
            generated = (Get-Date).ToString('o')
            run = $runId
            host = $env:COMPUTERNAME
            user = $env:USERNAME
            elevated = (Get-WinGodIsElevated)
            duration_seconds = [math]::Round($elapsed, 1)
            failures = @($failures)
        }
        sections = $sections
    }
}

function Export-WinGodAuditReport {
    <#
        .SYNOPSIS
            Writes audit.json and summary.md next to each other.
    #>
    param(
        [Parameter(Mandatory)]
        $Report,
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }

    $jsonPath = Join-Path $Path 'audit.json'
    $summaryPath = Join-Path $Path 'summary.md'

    $Report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('# winGod audit')
    [void]$lines.Add('')
    [void]$lines.Add(('- generated: {0}' -f $Report['meta']['generated']))
    [void]$lines.Add(('- host: {0}' -f $Report['meta']['host']))
    [void]$lines.Add(('- elevated: {0}' -f $Report['meta']['elevated']))
    [void]$lines.Add(('- duration: {0}s' -f $Report['meta']['duration_seconds']))
    [void]$lines.Add('')

    if (@($Report['meta']['failures']).Count -gt 0) {
        [void]$lines.Add('## Failed collectors')
        [void]$lines.Add('')
        foreach ($failure in $Report['meta']['failures']) {
            [void]$lines.Add(('- **{0}**: {1}' -f $failure['section'], $failure['error']))
        }
        [void]$lines.Add('')
    }

    $system = $Report['sections']['system']
    if ($system -and $system['ok']) {
        $info = $system['value']
        [void]$lines.Add('## System')
        [void]$lines.Add('')
        [void]$lines.Add('| field | value |')
        [void]$lines.Add('|---|---|')
        [void]$lines.Add(('| OS | {0} |' -f $info['caption']))
        [void]$lines.Add(('| build | {0} |' -f $info['build']))
        [void]$lines.Add(('| CPUs | {0} |' -f $info['logical_cpus']))
        [void]$lines.Add(('| RAM total | {0} MB |' -f $info['total_ram_mb']))
        [void]$lines.Add(('| RAM used | {0} MB ({1}%) |' -f $info['used_ram_mb'], $info['used_ram_pct']))
        [void]$lines.Add('')
    }

    $idle = $Report['sections']['idle']
    if ($idle -and $idle['ok']) {
        $idleValue = $idle['value']
        $idleSummary = $idleValue['summary']
        [void]$lines.Add('## Idle sample')
        [void]$lines.Add('')
        [void]$lines.Add('| metric | value |')
        [void]$lines.Add('|---|---|')
        [void]$lines.Add(('| window | {0}s, {1}s interval |' -f $idleValue['seconds'], $idleValue['interval']))
        [void]$lines.Add(('| CPU avg | {0}% |' -f $idleSummary['cpu_pct_avg']))
        [void]$lines.Add(('| CPU max | {0}% |' -f $idleSummary['cpu_pct_max']))
        [void]$lines.Add(('| RAM used avg | {0} MB |' -f $idleSummary['used_ram_mb_avg']))
        [void]$lines.Add(('| disk write avg | {0} B/s |' -f $idleSummary['disk_write_bytes_avg']))
        [void]$lines.Add(('| processes avg | {0} |' -f $idleSummary['processes_avg']))
        [void]$lines.Add(('| handles avg | {0} |' -f $idleSummary['handles_avg']))
        [void]$lines.Add('')
    }

    $processes = $Report['sections']['processes']
    if ($processes -and $processes['ok']) {
        $procValue = $processes['value']
        [void]$lines.Add('## Processes')
        [void]$lines.Add('')
        [void]$lines.Add(('Total: {0} processes, {1} MB private, {2} handles' -f $procValue['count'], $procValue['total_private_mb'], $procValue['total_handles']))
        [void]$lines.Add('')
        [void]$lines.Add('| process | pid | private MB | working set MB | handles |')
        [void]$lines.Add('|---|---|---|---|---|')
        foreach ($row in $procValue['top']) {
            [void]$lines.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $row['name'], $row['pid'], $row['private_mb'], $row['working_set_mb'], $row['handles']))
        }
        [void]$lines.Add('')
    }

    $services = $Report['sections']['services']
    if ($services -and $services['ok']) {
        $serviceValue = $services['value']
        [void]$lines.Add('## Services')
        [void]$lines.Add('')
        [void]$lines.Add(('Total: {0} - running {1}, auto {2}, auto+running {3}, manual {4}, disabled {5}' -f $serviceValue['total'], $serviceValue['running'], $serviceValue['auto'], $serviceValue['auto_running'], $serviceValue['manual'], $serviceValue['disabled']))
        [void]$lines.Add('')
    }

    $tasks = $Report['sections']['tasks']
    if ($tasks -and $tasks['ok']) {
        $taskValue = $tasks['value']
        [void]$lines.Add('## Scheduled tasks')
        [void]$lines.Add('')
        [void]$lines.Add(('Total: {0} - ready {1}, running {2}, disabled {3}' -f $taskValue['total'], $taskValue['ready'], $taskValue['running'], $taskValue['disabled']))
        [void]$lines.Add(('Telemetry tasks: {0} total, {1} enabled' -f $taskValue['telemetry_total'], $taskValue['telemetry_enabled']))
        [void]$lines.Add('')
    }

    $startup = $Report['sections']['startup']
    if ($startup -and $startup['ok']) {
        [void]$lines.Add('## Startup entries')
        [void]$lines.Add('')
        [void]$lines.Add(('Total: {0}' -f $startup['value']['total']))
        [void]$lines.Add('')
    }

    $appx = $Report['sections']['appx']
    if ($appx -and $appx['ok']) {
        $appxValue = $appx['value']
        [void]$lines.Add('## Appx packages')
        [void]$lines.Add('')
        [void]$lines.Add(('Installed: {0} ({1} non-framework), provisioned: {2}, scope: {3}' -f $appxValue['installed_total'], $appxValue['installed_non_framework'], $appxValue['provisioned_total'], $appxValue['scope']))
        [void]$lines.Add('')
    }

    $network = $Report['sections']['network']
    if ($network -and $network['ok']) {
        [void]$lines.Add('## Network')
        [void]$lines.Add('')
        [void]$lines.Add(('Established connections: {0}' -f $network['value']['established_total']))
        [void]$lines.Add('')
    }

    Set-Content -LiteralPath $summaryPath -Value $lines -Encoding UTF8

    Write-WinGodLog -Module 'audit' -Event 'report.exported' -Message 'audit written' -Data @{
        json = $jsonPath
        summary = $summaryPath
    }

    return [ordered]@{
        json = $jsonPath
        summary = $summaryPath
    }
}
