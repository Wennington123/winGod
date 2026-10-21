BeforeAll {
    . (Join-Path $PSScriptRoot '..\Scripts\Dock\Set-TaskbarAutoHide.ps1')
}

Describe 'Convert-WinGodStuckRectsSettings' {
    It 'enables auto-hide from a modern flag-off StuckRects3 payload' {
        $bytes = [byte[]](0x30, 0x00, 0x00, 0x00, 0xFE, 0xFF, 0xFF, 0xFF, 0x02, 0x80)
        $result = Convert-WinGodStuckRectsSettings -Bytes $bytes -AutoHide $true

        $result[8] | Should -Be 0x03
        $result[9] | Should -Be 0x80
        $result[0] | Should -Be 0x30
    }

    It 'disables auto-hide from a modern flag-on StuckRects3 payload' {
        $bytes = [byte[]](0x30, 0x00, 0x00, 0x00, 0xFE, 0xFF, 0xFF, 0xFF, 0x03, 0x80)
        $result = Convert-WinGodStuckRectsSettings -Bytes $bytes -AutoHide $false

        $result[8] | Should -Be 0x02
    }

    It 'enables auto-hide from a legacy flag-off payload' {
        $bytes = [byte[]](0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x78, 0x05)
        $result = Convert-WinGodStuckRectsSettings -Bytes $bytes -AutoHide $true

        $result[8] | Should -Be 0x79
        $result[9] | Should -Be 0x05
    }

    It 'disables auto-hide from a legacy flag-on payload' {
        $bytes = [byte[]](0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x79, 0x05)
        $result = Convert-WinGodStuckRectsSettings -Bytes $bytes -AutoHide $false

        $result[8] | Should -Be 0x78
    }

    It 'is idempotent (modern)' {
        $bytes = [byte[]](0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x80)
        $result = Convert-WinGodStuckRectsSettings -Bytes $bytes -AutoHide $true

        $result[8] | Should -Be 0x03
    }

    It 'returns null for a too-short payload' {
        $bytes = [byte[]](0x00, 0x00, 0x00)
        Convert-WinGodStuckRectsSettings -Bytes $bytes -AutoHide $true | Should -BeNullOrEmpty
    }

    It 'returns null for an unrecognised flag byte' {
        $bytes = [byte[]](0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x70)
        Convert-WinGodStuckRectsSettings -Bytes $bytes -AutoHide $true | Should -BeNullOrEmpty
    }

    It 'keeps the payload length untouched' {
        $bytes = [byte[]](1, 2, 3, 4, 5, 6, 7, 8, 0x02, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20)
        $result = Convert-WinGodStuckRectsSettings -Bytes $bytes -AutoHide $true

        $result.Length | Should -Be $bytes.Length
    }
}
