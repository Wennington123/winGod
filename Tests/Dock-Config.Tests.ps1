BeforeAll {
    . (Join-Path $PSScriptRoot '..\Scripts\Dock\Invoke-WinGodDock.ps1')
}

Describe 'New-WinGodDockConfig' {
    It 'loads the shipped config with exact values' {
        $config = New-WinGodDockConfig -Path (Join-Path $PSScriptRoot '..\Config\Dock.json')

        $config.height | Should -Be 56.0
        $config.theme | Should -Be 'glass'
        $config.clock24h | Should -BeTrue
        $config.autoHideBar | Should -BeTrue
        $config.fullscreenHide | Should -BeTrue
        $config.widgets | Should -Contain 'clock'
        $config.widgets | Should -Contain 'stats'
        $config.widgets | Should -Contain 'appTiles'
        $config.pinnedApps.Count | Should -BeGreaterThan 0
        foreach ($app in $config.pinnedApps) {
            $app | Should -Not -BeNullOrEmpty
            $app.Path | Should -Not -BeNullOrEmpty
            $app.Name | Should -Not -BeNullOrEmpty
        }
    }

    It 'falls back to defaults for unknown values' {
        $configFile = Join-Path $TestDrive 'dock-bad.json'
        Set-Content -Path $configFile -Encoding UTF8 -Value (@{
                Height  = 'XX'
                Theme   = 'neon'
                Widgets = @('clock', 'bogusWidget')
            } | ConvertTo-Json)

        $config = New-WinGodDockConfig -Path $configFile

        $config.height | Should -Be 48.0
        $config.theme | Should -Be 'neon'
        $config.widgets | Should -Contain 'clock'
        $config.widgets | Should -Not -Contain 'bogusWidget'
        $config.widgets | Should -Not -Contain 'stats'
    }

    It 'uses dock defaults when the config file is missing' {
        $config = New-WinGodDockConfig -Path (Join-Path $TestDrive 'missing.json')

        $config.height | Should -Be 48.0
        $config.theme | Should -Be 'dark'
        $config.clock24h | Should -BeTrue
        $config.autoHideBar | Should -BeTrue
        $config.widgets | Should -Contain 'clock'
        $config.pinnedApps.Count | Should -Be 0
    }

    It 'respects the size map S/M/L' {
        foreach ($entry in @(@('S', 40.0), @('M', 48.0), @('L', 56.0))) {
            $configFile = Join-Path $TestDrive ('dock-' + $entry[0] + '.json')
            Set-Content -Path $configFile -Encoding UTF8 -Value (@{ Height = $entry[0] } | ConvertTo-Json)
            $config = New-WinGodDockConfig -Path $configFile

            $config.height | Should -Be $entry[1]
        }
    }

    It 'keeps custom pinned apps with arguments' {
        $configFile = Join-Path $TestDrive 'dock-pins.json'
        Set-Content -Path $configFile -Encoding UTF8 -Value (@{
                PinnedApps = @(
                    @{ Name = 'wt'; Path = '%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe'; Args = @('-w', '0') }
                )
            } | ConvertTo-Json -Depth 4)

        $config = New-WinGodDockConfig -Path $configFile

        $config.pinnedApps.Count | Should -Be 1
        $config.pinnedApps[0].Args | Should -Contain '-w'
    }
}
