<#
    .SYNOPSIS
        Structured logging for winGod.

    .DESCRIPTION
        Three sinks per run, all optional except the JSONL one:

        - run.jsonl   one JSON object per line, machine readable, never rewritten
        - run.log     human readable, same events, aligned for reading in a terminal
        - console     same as run.log, with color, unless -NoConsole is used

        Every record carries: ts, lvl, evt, mod, msg, dur_ms, run, host, pid,
        ctx (inherited context) and optionally data and err.

        Logging never throws. A broken sink must not break the caller, so every
        write is wrapped and failures are swallowed after a single console warning.
#>

if (-not (Get-Variable -Name WinGodVersion -Scope Script -ErrorAction SilentlyContinue)) {
    $script:WinGodVersion = '0.1.0'
}

$script:WinGodLog = $null
$script:WinGodLogWarningShown = $false

function Get-WinGodLogLevelValue {
    <#
        .SYNOPSIS
            Maps a level name to its numeric severity.
    #>
    param(
        [string]$Level
    )

    switch ($Level) {
        'Trace' { return 0 }
        'Debug' { return 1 }
        'Info' { return 2 }
        'Warn' { return 3 }
        'Error' { return 4 }
        'Fatal' { return 5 }
        default { return 2 }
    }
}

function Protect-WinGodLogText {
    <#
        .SYNOPSIS
            Removes identifying values from a string before it reaches a sink.

        .DESCRIPTION
            Replaces the user profile path, the user name, the computer name and
            MAC addresses with placeholders. Paths keep their shape, so the log
            stays useful after redaction.
    #>
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $result = $Text

    if ($env:USERPROFILE) {
        $result = $result -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%'
    }

    if ($env:HOME -and $env:HOME -ne $env:USERPROFILE) {
        $result = $result -replace [regex]::Escape($env:HOME), '%HOME%'
    }

    if ($env:USERNAME) {
        $result = $result -replace [regex]::Escape($env:USERNAME), '%USERNAME%'
    }

    $result = $result -replace '(?i)\b([0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b', '%MAC%'
    $result = $result -replace '(?i)\bC:\\Users\\[^\\\s"'']+', 'C:\Users\%USERNAME%'

    return $result
}

function Protect-WinGodLogObject {
    <#
        .SYNOPSIS
            Applies redaction through a nested structure.

        .DESCRIPTION
            Walks dictionaries and arrays up to MaxDepth levels. Deeper values
            are replaced by the string '<redacted-depth>'. Non-string scalars are
            returned unchanged.
    #>
    param(
        [AllowNull()]
        $Value,
        [int]$Depth = 0,
        [int]$MaxDepth = 4
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        return (Protect-WinGodLogText -Text $Value)
    }

    if ($Depth -ge $MaxDepth) {
        return '<redacted-depth>'
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $copy[$key] = Protect-WinGodLogObject -Value $Value[$key] -Depth ($Depth + 1) -MaxDepth $MaxDepth
        }
        return $copy
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$items.Add((Protect-WinGodLogObject -Value $item -Depth ($Depth + 1) -MaxDepth $MaxDepth))
        }
        return @($items)
    }

    return $Value
}

function New-WinGodLog {
    <#
        .SYNOPSIS
            Starts a run log and returns its directory.

        .PARAMETER Path
            Parent directory. A per-run subdirectory is created inside it.

        .PARAMETER Level
            Minimum level written to any sink. One of Trace, Debug, Info, Warn,
            Error, Fatal.

        .PARAMETER Redact
            Strip user profile, user name, computer name and MAC addresses.

        .PARAMETER NoConsole
            Write files only.

        .PARAMETER MaxFileBytes
            Rotate run.jsonl and run.log once they exceed this size.
    #>
    param(
        [string]$Path = (Join-Path (Join-Path $env:LOCALAPPDATA 'winGod') 'logs'),
        [ValidateSet('Trace', 'Debug', 'Info', 'Warn', 'Error', 'Fatal')]
        [string]$Level = 'Info',
        [switch]$Redact,
        [switch]$NoConsole,
        [int]$MaxFileBytes = 52428800,
        [string]$Name
    )

    if ($script:WinGodLog) {
        Close-WinGodLog
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $runId = '{0}-{1}' -f $stamp, ([guid]::NewGuid().ToString('N').Substring(0, 6))

    if (-not $Name) {
        $Name = $runId
    }

    $dir = Join-Path $Path $Name
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $jsonlPath = Join-Path $dir 'run.jsonl'
    $textPath = Join-Path $dir 'run.log'
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $writer = New-Object System.IO.StreamWriter($jsonlPath, $true, $utf8)
    $writer.AutoFlush = $true
    $textWriter = New-Object System.IO.StreamWriter($textPath, $true, $utf8)
    $textWriter.AutoFlush = $true

    $script:WinGodLog = @{
        RunId = $runId
        Dir = $dir
        JsonlPath = $jsonlPath
        TextPath = $textPath
        Writer = $writer
        TextWriter = $textWriter
        Level = $Level
        LevelValue = (Get-WinGodLogLevelValue -Level $Level)
        Redact = [bool]$Redact
        NoConsole = [bool]$NoConsole
        MaxFileBytes = $MaxFileBytes
        Rotations = 0
        Events = 0
        Started = (Get-Date)
        Context = [ordered]@{}
        Warnings = 0
    }

    $meta = [ordered]@{
        tool = 'winGod'
        version = $script:WinGodVersion
        run = $runId
        started = (Get-Date).ToString('o')
        level = $Level
        redact = [bool]$Redact
        host = $env:COMPUTERNAME
        user = $env:USERNAME
        pid = $PID
        psversion = $PSVersionTable.PSVersion.ToString()
        edition = $PSVersionTable.PSEdition
    }

    try {
        $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'run.meta.json') -Encoding UTF8
    }
    catch {
        $script:WinGodLog.Warnings++
    }

    Write-WinGodLog -Module 'log' -Event 'run.started' -Message "run $runId" -Data @{ path = $dir }

    return $dir
}

function Add-WinGodLogContext {
    <#
        .SYNOPSIS
            Merges keys into the inherited context of every following record.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Data
    )

    if (-not $script:WinGodLog) {
        return
    }

    foreach ($key in $Data.Keys) {
        $script:WinGodLog.Context[$key] = $Data[$key]
    }
}

function Remove-WinGodLogContext {
    <#
        .SYNOPSIS
            Removes keys from the inherited context.
    #>
    param(
        [string[]]$Key
    )

    if (-not $script:WinGodLog) {
        return
    }

    foreach ($item in $Key) {
        if ($script:WinGodLog.Context.Contains($item)) {
            $script:WinGodLog.Context.Remove($item)
        }
    }
}

function ConvertTo-WinGodLogError {
    <#
        .SYNOPSIS
            Flattens an ErrorRecord into a JSON-friendly shape.
    #>
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if (-not $ErrorRecord) {
        return $null
    }

    $line = $null
    if ($ErrorRecord.InvocationInfo) {
        $line = $ErrorRecord.InvocationInfo.ScriptLineNumber
    }

    $stack = $null
    if ($ErrorRecord.ScriptStackTrace) {
        $stack = $ErrorRecord.ScriptStackTrace
    }

    return [ordered]@{
        type = $ErrorRecord.Exception.GetType().Name
        message = $ErrorRecord.Exception.Message
        category = [string]$ErrorRecord.CategoryInfo.Category
        target = [string]$ErrorRecord.CategoryInfo.TargetName
        line = $line
        stack = $stack
    }
}

function Write-WinGodLog {
    <#
        .SYNOPSIS
            Writes one structured record to every sink.

        .PARAMETER Module
            Emitting module, for example 'audit' or 'services'.

        .PARAMETER Event
            Dotted event name, for example 'collector.completed'.

        .PARAMETER DurationMs
            Operation duration. Negative means "not measured".
    #>
    param(
        [string]$Module = 'core',
        [Parameter(Mandatory)]
        [string]$Event,
        [AllowEmptyString()]
        [string]$Message = '',
        [ValidateSet('Trace', 'Debug', 'Info', 'Warn', 'Error', 'Fatal')]
        [string]$Level = 'Info',
        [System.Collections.IDictionary]$Data,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [double]$DurationMs = -1
    )

    if (-not $script:WinGodLog) {
        if (-not $script:WinGodLogWarningShown) {
            $script:WinGodLogWarningShown = $true
            Write-Warning 'winGod: log not started, events are discarded.'
        }
        return
    }

    $value = Get-WinGodLogLevelValue -Level $Level
    if ($value -lt $script:WinGodLog.LevelValue) {
        return
    }

    try {
        $ts = (Get-Date).ToString('o')

        if ($script:WinGodLog.Redact) {
            $Message = Protect-WinGodLogText -Text $Message
            if ($Data) {
                $Data = Protect-WinGodLogObject -Value $Data
            }
        }

        $record = [ordered]@{
            ts = $ts
            lvl = $Level
            evt = $Event
            mod = $Module
            msg = $Message
            dur_ms = $null
            run = $script:WinGodLog.RunId
            host = $env:COMPUTERNAME
            pid = $PID
        }

        if ($DurationMs -ge 0) {
            $record.dur_ms = [math]::Round($DurationMs, 3)
        }

        if ($script:WinGodLog.Context.Count -gt 0) {
            $record.ctx = Protect-WinGodLogObject -Value $script:WinGodLog.Context
        }

        if ($Data -and $Data.Count -gt 0) {
            $record.data = $Data
        }

        if ($ErrorRecord) {
            $record.err = ConvertTo-WinGodLogError -ErrorRecord $ErrorRecord
        }

        $json = $record | ConvertTo-Json -Compress -Depth 8

        if ($script:WinGodLog.Writer) {
            $script:WinGodLog.Writer.WriteLine($json)
        }

        $dataText = ''
        if ($Data -and $Data.Count -gt 0) {
            $dataText = ' | ' + (($Data.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join ' ')
        }

        $durationText = ''
        if ($DurationMs -ge 0) {
            $durationText = ' ({0:0.0} ms)' -f $DurationMs
        }

        $line = '{0} [{1,-5}] {2}/{3} {4}{5}{6}' -f $ts, $Level.ToUpperInvariant(), $Module, $Event, $Message, $durationText, $dataText

        if ($script:WinGodLog.TextWriter) {
            $script:WinGodLog.TextWriter.WriteLine($line)
        }

        if (-not $script:WinGodLog.NoConsole) {
            $color = 'Gray'
            switch ($Level) {
                'Trace' { $color = 'DarkGray' }
                'Debug' { $color = 'Gray' }
                'Info' { $color = 'White' }
                'Warn' { $color = 'Yellow' }
                'Error' { $color = 'Red' }
                'Fatal' { $color = 'Magenta' }
            }
            Write-Host $line -ForegroundColor $color
        }

        $script:WinGodLog.Events++

        if ($script:WinGodLog.MaxFileBytes -gt 0 -and $script:WinGodLog.Writer) {
            if ($script:WinGodLog.Writer.BaseStream.Length -ge $script:WinGodLog.MaxFileBytes) {
                Invoke-WinGodLogRotation
            }
        }
    }
    catch {
        $script:WinGodLog.Warnings++
        if (-not $script:WinGodLog.NoConsole) {
            Write-Warning ("winGod: log write failed: {0}" -f $_.Exception.Message)
        }
    }
}

function Invoke-WinGodLogRotation {
    <#
        .SYNOPSIS
            Rotates the current run files and opens fresh ones.
    #>
    param()

    if (-not $script:WinGodLog) {
        return
    }

    try {
        $script:WinGodLog.Rotations++
        $index = $script:WinGodLog.Rotations

        $script:WinGodLog.Writer.Dispose()
        $script:WinGodLog.TextWriter.Dispose()

        $jsonl = $script:WinGodLog.JsonlPath
        $text = $script:WinGodLog.TextPath

        Move-Item -LiteralPath $jsonl -Destination ([System.IO.Path]::ChangeExtension($jsonl, "jsonl.$index")) -Force
        Move-Item -LiteralPath $text -Destination ([System.IO.Path]::ChangeExtension($text, "log.$index")) -Force

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $script:WinGodLog.Writer = New-Object System.IO.StreamWriter($jsonl, $true, $utf8)
        $script:WinGodLog.Writer.AutoFlush = $true
        $script:WinGodLog.TextWriter = New-Object System.IO.StreamWriter($text, $true, $utf8)
        $script:WinGodLog.TextWriter.AutoFlush = $true

        Write-WinGodLog -Module 'log' -Event 'run.rotated' -Level 'Warn' -Message "rotated to index $index"
    }
    catch {
        $script:WinGodLog.Warnings++
    }
}

function Measure-WinGodBlock {
    <#
        .SYNOPSIS
            Runs a block, logs its duration and outcome, and rethrows failures.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Event,
        [string]$Module = 'core',
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $value = & $ScriptBlock
        $stopwatch.Stop()
        Write-WinGodLog -Module $Module -Event $Event -Level 'Debug' -Message 'completed' -DurationMs $stopwatch.Elapsed.TotalMilliseconds
        return $value
    }
    catch {
        $stopwatch.Stop()
        Write-WinGodLog -Module $Module -Event $Event -Level 'Error' -Message 'failed' -DurationMs $stopwatch.Elapsed.TotalMilliseconds -ErrorRecord $_
        throw
    }
}

function Close-WinGodLog {
    <#
        .SYNOPSIS
            Writes the closing event and releases the file handles.
    #>
    param()

    if (-not $script:WinGodLog) {
        return
    }

    try {
        $elapsed = ((Get-Date) - $script:WinGodLog.Started).TotalSeconds
        Write-WinGodLog -Module 'log' -Event 'run.closed' -Message 'run finished' -Data @{
            events = $script:WinGodLog.Events
            warnings = $script:WinGodLog.Warnings
            rotations = $script:WinGodLog.Rotations
            seconds = [math]::Round($elapsed, 1)
        }

        if ($script:WinGodLog.Writer) {
            $script:WinGodLog.Writer.Dispose()
        }

        if ($script:WinGodLog.TextWriter) {
            $script:WinGodLog.TextWriter.Dispose()
        }
    }
    catch {
        Write-Warning ("winGod: failed to close log: {0}" -f $_.Exception.Message)
    }
    finally {
        $script:WinGodLog = $null
    }
}

function Get-WinGodLogPath {
    <#
        .SYNOPSIS
            Returns the current run directory, or $null when no log is open.
    #>
    param()

    if ($script:WinGodLog) {
        return $script:WinGodLog.Dir
    }

    return $null
}
