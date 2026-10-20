BeforeAll {
    . (Join-Path $PSScriptRoot '..\Scripts\Performance\Logging.ps1')

    function Get-WinGodLogRecords {
        param(
            [string]$Path
        )

        $records = @()
        foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $records += ($line | ConvertFrom-Json)
            }
        }
        return $records
    }
}

Describe 'Protect-WinGodLogText' {
    It 'replaces a user profile path' {
        Protect-WinGodLogText -Text 'C:\Users\Alice\Documents\file.txt' |
            Should -BeLike 'C:\Users\%USERNAME%\*'
    }

    It 'replaces MAC addresses' {
        Protect-WinGodLogText -Text 'adapter aa-bb-cc-dd-ee-ff up' |
            Should -BeLike '*%MAC%*'
    }

    It 'keeps unrelated text intact' {
        Protect-WinGodLogText -Text 'service DiagTrack disabled' |
            Should -Be 'service DiagTrack disabled'
    }

    It 'returns null for null input' {
        Protect-WinGodLogText -Text $null | Should -BeNullOrEmpty
    }
}

Describe 'Protect-WinGodLogObject' {
    It 'walks nested dictionaries' {
        $value = @{ outer = @{ inner = 'C:\Users\Alice\x' } }
        $result = Protect-WinGodLogObject -Value $value

        $result['outer']['inner'] | Should -BeLike 'C:\Users\%USERNAME%\*'
    }

    It 'stops at the depth limit' {
        $value = [ordered]@{ a = [ordered]@{ b = [ordered]@{ c = [ordered]@{ d = [ordered]@{ e = 'x' } } } } }
        $result = Protect-WinGodLogObject -Value $value -MaxDepth 2

        $result['a']['b'] | Should -Be '<redacted-depth>'
    }
}

Describe 'New-WinGodLog' {
    AfterEach {
        Close-WinGodLog
    }

    It 'creates the run files' {
        $dir = New-WinGodLog -Path (Join-Path $TestDrive 'logs') -NoConsole

        Test-Path (Join-Path $dir 'run.jsonl') | Should -BeTrue
        Test-Path (Join-Path $dir 'run.log') | Should -BeTrue
        Test-Path (Join-Path $dir 'run.meta.json') | Should -BeTrue
    }

    It 'writes a run.started record' {
        $dir = New-WinGodLog -Path (Join-Path $TestDrive 'started') -NoConsole
        $records = Get-WinGodLogRecords -Path (Join-Path $dir 'run.jsonl')

        $records[0].evt | Should -Be 'run.started'
        $records[0].lvl | Should -Be 'Info'
        $records[0].run | Should -Not -BeNullOrEmpty
    }

    It 'replaces an already open log' {
        $first = New-WinGodLog -Path (Join-Path $TestDrive 'first') -NoConsole
        $second = New-WinGodLog -Path (Join-Path $TestDrive 'second') -NoConsole

        $first | Should -Not -Be $second
        (Get-WinGodLogPath) | Should -Be $second
    }
}

Describe 'Write-WinGodLog' {
    BeforeEach {
        $script:dir = New-WinGodLog -Path (Join-Path $TestDrive 'write') -NoConsole -Level 'Trace'
        $script:records = Join-Path $script:dir 'run.jsonl'
    }

    AfterEach {
        Close-WinGodLog
    }

    It 'writes one json line per event' {
        Write-WinGodLog -Module 'test' -Event 'unit.event' -Message 'hello'

        $records = Get-WinGodLogRecords -Path $script:records
        $record = $records | Where-Object { $_.evt -eq 'unit.event' }

        $record.msg | Should -Be 'hello'
        $record.mod | Should -Be 'test'
        $record.pid | Should -Be $PID
    }

    It 'drops events below the configured level' {
        $script:dir = New-WinGodLog -Path (Join-Path $TestDrive 'level') -NoConsole -Level 'Warn'
        $script:records = Join-Path $script:dir 'run.jsonl'

        Write-WinGodLog -Module 'test' -Event 'info.event' -Level 'Info'
        Write-WinGodLog -Module 'test' -Event 'warn.event' -Level 'Warn'

        $records = Get-WinGodLogRecords -Path $script:records
        @($records | Where-Object { $_.evt -eq 'info.event' }).Count | Should -Be 0
        @($records | Where-Object { $_.evt -eq 'warn.event' }).Count | Should -Be 1
    }

    It 'records the duration when one is given' {
        Write-WinGodLog -Module 'test' -Event 'timed.event' -DurationMs 12.5

        $records = Get-WinGodLogRecords -Path $script:records
        $record = $records | Where-Object { $_.evt -eq 'timed.event' }

        $record.dur_ms | Should -Be 12.5
    }

    It 'records the inherited context' {
        Add-WinGodLogContext -Data @{ phase = 'audit' }
        Write-WinGodLog -Module 'test' -Event 'ctx.event'

        $records = Get-WinGodLogRecords -Path $script:records
        $record = $records | Where-Object { $_.evt -eq 'ctx.event' }

        $record.ctx.phase | Should -Be 'audit'
    }

    It 'drops a context key on request' {
        Add-WinGodLogContext -Data @{ phase = 'audit'; section = 'services' }
        Remove-WinGodLogContext -Key 'phase'
        Write-WinGodLog -Module 'test' -Event 'ctx.remove'

        $records = Get-WinGodLogRecords -Path $script:records
        $record = $records | Where-Object { $_.evt -eq 'ctx.remove' }

        $record.ctx.section | Should -Be 'services'
        $record.ctx.PSObject.Properties.Name | Should -Not -Contain 'phase'
    }

    It 'serializes an error record' {
        try {
            throw 'boom'
        }
        catch {
            Write-WinGodLog -Module 'test' -Event 'error.event' -Level 'Error' -ErrorRecord $_
        }

        $records = Get-WinGodLogRecords -Path $script:records
        $record = $records | Where-Object { $_.evt -eq 'error.event' }

        $record.err.message | Should -Be 'boom'
        $record.err.type | Should -Not -BeNullOrEmpty
    }

    It 'redacts data and message when redaction is on' {
        $script:dir = New-WinGodLog -Path (Join-Path $TestDrive 'redact') -NoConsole -Redact
        $script:records = Join-Path $script:dir 'run.jsonl'

        Write-WinGodLog -Module 'test' -Event 'redacted.event' -Message 'C:\Users\Alice\x' -Data @{ path = 'C:\Users\Alice\y' }

        $records = Get-WinGodLogRecords -Path $script:records
        $record = $records | Where-Object { $_.evt -eq 'redacted.event' }

        $record.msg | Should -Not -Match 'Alice'
        $record.data.path | Should -Not -Match 'Alice'
    }

    It 'does not throw when no log is open' {
        Close-WinGodLog

        { Write-WinGodLog -Module 'test' -Event 'orphan.event' -WarningAction SilentlyContinue } |
            Should -Not -Throw
    }

    It 'rotates once the file exceeds the limit' {
        $script:dir = New-WinGodLog -Path (Join-Path $TestDrive 'rotate') -NoConsole -MaxFileBytes 400
        $script:records = Join-Path $script:dir 'run.jsonl'

        for ($i = 0; $i -lt 20; $i++) {
            Write-WinGodLog -Module 'test' -Event 'fill.event' -Message ('x' * 80)
        }

        @(Get-ChildItem -LiteralPath $script:dir -Filter 'run.jsonl*').Count | Should -BeGreaterThan 1
    }
}

Describe 'Measure-WinGodBlock' {
    BeforeEach {
        $script:dir = New-WinGodLog -Path (Join-Path $TestDrive 'measure') -NoConsole -Level 'Trace'
        $script:records = Join-Path $script:dir 'run.jsonl'
    }

    AfterEach {
        Close-WinGodLog
    }

    It 'returns the value of the block' {
        Measure-WinGodBlock -Event 'block.ok' -ScriptBlock { 7 } | Should -Be 7
    }

    It 'logs a failure and rethrows' {
        { Measure-WinGodBlock -Event 'block.fail' -ScriptBlock { throw 'nope' } } | Should -Throw

        $records = Get-WinGodLogRecords -Path $script:records
        $record = $records | Where-Object { $_.evt -eq 'block.fail' }

        $record.lvl | Should -Be 'Error'
        $record.err.message | Should -Be 'nope'
    }
}

Describe 'Close-WinGodLog' {
    It 'releases the log and stops writing' {
        $dir = New-WinGodLog -Path (Join-Path $TestDrive 'close') -NoConsole
        Close-WinGodLog

        Get-WinGodLogPath | Should -BeNullOrEmpty
        { Write-WinGodLog -Module 'test' -Event 'after.close' -WarningAction SilentlyContinue } | Should -Not -Throw

        $records = Get-WinGodLogRecords -Path (Join-Path $dir 'run.jsonl')
        @($records | Where-Object { $_.evt -eq 'after.close' }).Count | Should -Be 0
        @($records | Where-Object { $_.evt -eq 'run.closed' }).Count | Should -Be 1
    }
}
