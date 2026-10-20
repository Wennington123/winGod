BeforeAll {
    . (Join-Path $PSScriptRoot '..\Scripts\Performance\Logging.ps1')
    . (Join-Path $PSScriptRoot '..\Scripts\Performance\Audit-System.ps1')

    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        function Get-CimInstance {
            param($ClassName, $Filter, $ErrorAction)
        }
    }
}

Describe 'ConvertTo-WinGodMB' {
    It 'converts bytes to megabytes' {
        ConvertTo-WinGodMB -Bytes 1048576 | Should -Be 1
    }

    It 'rounds to one decimal' {
        ConvertTo-WinGodMB -Bytes 1572864 | Should -Be 1.5
    }

    It 'handles zero' {
        ConvertTo-WinGodMB -Bytes 0 | Should -Be 0
    }
}

Describe 'Test-WinGodTelemetryTaskPath' {
    It 'matches an Application Experience task' {
        Test-WinGodTelemetryTaskPath -Path '\Microsoft\Windows\Application Experience\' | Should -BeTrue
    }

    It 'matches case-insensitively' {
        Test-WinGodTelemetryTaskPath -Path '\microsoft\windows\feedback\siuf\' | Should -BeTrue
    }

    It 'matches the Windows Error Reporting folder' {
        Test-WinGodTelemetryTaskPath -Path '\Microsoft\Windows\Windows Error Reporting\' | Should -BeTrue
    }

    It 'rejects an unrelated folder' {
        Test-WinGodTelemetryTaskPath -Path '\Microsoft\Windows\Defrag\' | Should -BeFalse
    }

    It 'rejects an empty path' {
        Test-WinGodTelemetryTaskPath -Path '' | Should -BeFalse
    }
}

Describe 'Invoke-WinGodSafeCollector' {
    BeforeEach {
        Mock Write-WinGodLog {}
    }

    It 'returns the collected value' {
        $result = Invoke-WinGodSafeCollector -Name 'unit' -ScriptBlock { 42 }

        $result.ok | Should -BeTrue
        $result.value | Should -Be 42
        $result.error | Should -BeNullOrEmpty
    }

    It 'fails open and keeps the message' {
        $result = Invoke-WinGodSafeCollector -Name 'unit' -ScriptBlock { throw 'collector exploded' }

        $result.ok | Should -BeFalse
        $result.value | Should -BeNullOrEmpty
        $result.error | Should -Match 'collector exploded'
    }

    It 'records a duration' {
        $result = Invoke-WinGodSafeCollector -Name 'unit' -ScriptBlock { 1 }

        $result.duration_ms | Should -BeGreaterOrEqual 0
    }
}

Describe 'Get-WinGodServiceInventory' {
    BeforeEach {
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{
                    Name = 'AutoRunning'; DisplayName = 'Auto Running'; State = 'Running'
                    StartMode = 'Auto'; StartName = 'LocalSystem'; ProcessId = 100
                }
                [pscustomobject]@{
                    Name = 'AutoStopped'; DisplayName = 'Auto Stopped'; State = 'Stopped'
                    StartMode = 'Auto'; StartName = 'LocalSystem'; ProcessId = 0
                }
                [pscustomobject]@{
                    Name = 'Manual'; DisplayName = 'Manual'; State = 'Stopped'
                    StartMode = 'Manual'; StartName = 'LocalService'; ProcessId = 0
                }
                [pscustomobject]@{
                    Name = 'Off'; DisplayName = 'Off'; State = 'Stopped'
                    StartMode = 'Disabled'; StartName = 'LocalSystem'; ProcessId = 0
                }
            )
        }
    }

    It 'counts states and start modes' {
        $inventory = Get-WinGodServiceInventory

        $inventory.total | Should -Be 4
        $inventory.running | Should -Be 1
        $inventory.auto | Should -Be 2
        $inventory.auto_running | Should -Be 1
        $inventory.manual | Should -Be 1
        $inventory.disabled | Should -Be 1
    }

    It 'keeps every service row' {
        $inventory = Get-WinGodServiceInventory

        @($inventory.services).Count | Should -Be 4
        $inventory.services[0].name | Should -Be 'AutoRunning'
    }
}

Describe 'Get-WinGodProcessInventory' {
    BeforeEach {
        Mock Get-Process {
            @(
                [pscustomobject]@{
                    ProcessName = 'heavy'; Id = 10; PrivateMemorySize64 = 104857600
                    WorkingSet64 = 209715200; HandleCount = 500; Threads = @(1, 2); StartTime = (Get-Date)
                }
                [pscustomobject]@{
                    ProcessName = 'light'; Id = 11; PrivateMemorySize64 = 10485760
                    WorkingSet64 = 20971520; HandleCount = 50; Threads = @(1); StartTime = (Get-Date)
                }
            )
        }
    }

    It 'reports totals and sorts by private memory' {
        $inventory = Get-WinGodProcessInventory -Top 5

        $inventory.count | Should -Be 2
        $inventory.total_private_mb | Should -Be 110
        $inventory.total_handles | Should -Be 550
        $inventory.top[0].name | Should -Be 'heavy'
        $inventory.top[0].private_mb | Should -Be 100
    }

    It 'truncates the top list' {
        $inventory = Get-WinGodProcessInventory -Top 1

        @($inventory.top).Count | Should -Be 1
    }
}

Describe 'Get-WinGodAuditReport' {
    BeforeEach {
        Mock Write-WinGodLog {}
        Mock Get-WinGodIsElevated { $false }
    }

    It 'records every collector failure and still returns a report' {
        Mock Get-WinGodSystemInfo { throw 'system' }
        Mock Get-WinGodProcessInventory { throw 'processes' }
        Mock Get-WinGodServiceInventory { throw 'services' }
        Mock Get-WinGodScheduledTaskInventory { throw 'tasks' }
        Mock Get-WinGodStartupInventory { throw 'startup' }
        Mock Get-WinGodNetworkInventory { throw 'network' }

        $report = Get-WinGodAuditReport

        $report.sections.Count | Should -Be 6
        $report.sections.system.ok | Should -BeFalse
        $report.sections.system.error | Should -Be 'system'
        @($report.meta.failures).Count | Should -Be 6
    }

    It 'adds the appx section only when requested' {
        Mock Get-WinGodSystemInfo { [ordered]@{ caption = 'x' } }
        Mock Get-WinGodProcessInventory { [ordered]@{ count = 0 } }
        Mock Get-WinGodServiceInventory { [ordered]@{ total = 0 } }
        Mock Get-WinGodScheduledTaskInventory { [ordered]@{ total = 0 } }
        Mock Get-WinGodStartupInventory { [ordered]@{ total = 0 } }
        Mock Get-WinGodNetworkInventory { [ordered]@{ established_total = 0 } }
        Mock Get-WinGodAppxInventory { [ordered]@{ installed_total = 0 } }

        $without = Get-WinGodAuditReport
        $with = Get-WinGodAuditReport -IncludeApps

        $without.sections.Contains('appx') | Should -BeFalse
        $with.sections.Contains('appx') | Should -BeTrue
    }
}

Describe 'Export-WinGodAuditReport' {
    BeforeEach {
        Mock Write-WinGodLog {}
    }

    It 'writes audit.json and summary.md' {
        $report = [ordered]@{
            meta = [ordered]@{
                generated = '2026-01-01T00:00:00Z'
                host = 'TESTHOST'
                elevated = $false
                duration_seconds = 1
                failures = @()
            }
            sections = [ordered]@{}
        }

        $paths = Export-WinGodAuditReport -Report $report -Path (Join-Path $TestDrive 'audit')

        Test-Path -LiteralPath $paths.json | Should -BeTrue
        Test-Path -LiteralPath $paths.summary | Should -BeTrue
        (Get-Content -LiteralPath $paths.summary -Raw) | Should -Match 'winGod audit'
        (Get-Content -LiteralPath $paths.json -Raw | ConvertFrom-Json).meta.host | Should -Be 'TESTHOST'
    }

    It 'lists failed collectors in the summary' {
        $report = [ordered]@{
            meta = [ordered]@{
                generated = '2026-01-01T00:00:00Z'
                host = 'TESTHOST'
                elevated = $false
                duration_seconds = 1
                failures = @(@{ section = 'network'; error = 'denied' })
            }
            sections = [ordered]@{}
        }

        $paths = Export-WinGodAuditReport -Report $report -Path (Join-Path $TestDrive 'audit-fail')

        (Get-Content -LiteralPath $paths.summary -Raw) | Should -Match 'network.*denied'
    }
}
