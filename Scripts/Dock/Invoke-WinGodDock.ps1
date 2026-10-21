<#
    .SYNOPSIS
    winGod dock: a bottom-of-screen bar with clock, system stats and pinned
    app tiles, in the spirit of lumabar.

    .DESCRIPTION
    WPF app built entirely in PowerShell. Docks to the bottom of the primary
    screen, hides itself when a fullscreen window covers the monitor, and
    turns on Windows taskbar auto-hide while it runs (restores it on exit).

    Stop it with -Stop. The dock registers the HKCU Run key on every manual
    start unless -NoRunKey is passed. Run key startup itself runs hidden with
    -NoRunKey.

    .PARAMETER ConfigPath
    Path to the dock configuration file. Defaults to ..\..\Config\Dock.json.

    .PARAMETER Stop
    Stops a running dock instance and restores the Windows taskbar.

    .PARAMETER NoRunKey
    Skip Run key registration on start (used by the Run key itself).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Stop,
    [switch]$NoRunKey,
    [switch]$OpenPanel
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\Performance\Logging.ps1"
. (Join-Path $PSScriptRoot 'Set-TaskbarAutoHide.ps1')

$script:dockDataRoot = Join-Path $env:LOCALAPPDATA 'winGod\dock'
$script:dockRunFile = Join-Path $script:dockDataRoot 'run.json'

# State shared across WPF event handlers (same STA thread, script scope)
$script:dockWindow = $null
$script:dockScreen = $null
$script:dockConfig = $null
$script:dockCollapsed = $false
$script:dockFullscreen = $false
$script:dockMouseInside = $false
$script:dockClockTime = $null
$script:dockClockDate = $null
$script:dockClockFormat = 'HH:mm'
$script:dockStatsText = $null
$script:dockCpuCounter = $null

function New-WinGodDockConfig {
    <#
        .SYNOPSIS
        Loads the dock config file and returns a normalized hashtable with
        safe defaults for missing values.
    #>
    param([string]$Path)

    if (-not $Path) {
        $configInRepo = if ($PSScriptRoot) {
            Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Config\Dock.json'
        }
        else {
            Join-Path $script:dockDataRoot 'Dock.json'
        }
        $Path = $configInRepo
    }

    $configRaw = $null
    if (Test-Path $Path) {
        try {
            $configRaw = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Write-Warning "Dock.json inválido, a usar defaults: $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning "Dock.json não encontrado em '$Path', a usar defaults."
    }

    $heightMap = @{ S = 40.0; M = 48.0; L = 56.0 }
    $height = 48.0
    if ($configRaw -and $configRaw.Height -in @('S', 'M', 'L')) {
        $height = $heightMap[$configRaw.Height]
    }

    $widgets = [System.Collections.Generic.List[string]]::new()
    foreach ($known in @('clock', 'stats', 'appTiles', 'indicators', 'battery', 'network', 'uptime', 'dayProgress')) {
        if ((-not $configRaw -or -not $configRaw.Widgets) -and ($known -in @('clock', 'stats', 'appTiles', 'indicators'))) {
            $widgets.Add($known)
        }
    }
    if ($configRaw -and $configRaw.Widgets) {
        foreach ($requested in @($configRaw.Widgets)) {
            if ($requested -in @('clock', 'stats', 'appTiles', 'indicators', 'battery', 'network', 'uptime', 'dayProgress') -and -not $widgets.Contains($requested)) {
                $widgets.Add($requested)
            }
        }
    }

    $heightKey = 'M'
    if ($configRaw -and $configRaw.Height -in @('S', 'M', 'L')) {
        $heightKey = $configRaw.Height
    }

    return @{
        file           = $Path
        glassMode      = if ($configRaw -and $configRaw.GlassMode) { $configRaw.GlassMode } else { 'solid' }
        heightKey      = $heightKey
        height         = $height
        theme          = if ($configRaw -and $configRaw.Theme) { $configRaw.Theme } else { 'dark' }
        clock24h       = if ($configRaw -and $null -ne $configRaw.Clock24h) { [bool]$configRaw.Clock24h } else { $true }
        widgets        = $widgets
        autoHideBar    = if ($configRaw -and $null -ne $configRaw.AutoHideBar) { [bool]$configRaw.AutoHideBar } else { $true }
        fullscreenHide = if ($configRaw -and $null -ne $configRaw.FullscreenHideBar) { [bool]$configRaw.FullscreenHideBar } else { $true }
        pinnedApps     = @(if ($configRaw -and $configRaw.PinnedApps) { $configRaw.PinnedApps } else { @() })
    }
}

function Get-WinGodDockTheme {
    <#
        .SYNOPSIS
        Color set for the dock bar and widgets.
    #>
    param([string]$Name)

    switch ($Name) {
        'glass' {
            return @{
                barBackground   = '#E6101216'
                barBorder       = '#54707478'
                tileHover       = '#33FFFFFF'
                foreground      = '#FFEFF3F5'
                mutedForeground = '#B9DDE3E5'
            }
        }
        default {
            return @{
                barBackground   = '#FF1B1B1C'
                barBorder       = '#54555759'
                tileHover       = '#26FFFFFF'
                foreground      = '#FFECEEF0'
                mutedForeground = '#FFB8BDC2'
            }
        }
    }
}

function Set-WinGodShellTrayHidden {
    <#
        .SYNOPSIS
        Fully hides (or restores) the Windows taskbar window.

        .DESCRIPTION
        Auto-hide alone still slides the taskbar up when the pointer reaches
        the bottom edge, which fights the dock. Hiding Shell_TrayWnd removes
        it completely until the dock stops (or Explorer restarts, which the
        dock re-hides on its bus).
    #>
    param([bool]$Hidden)

    if (-not ('WinGodDockNative' -as [Type])) { Add-WinGodDockNative }
    $tray = [WinGodDockNative]::FindWindowW('Shell_TrayWnd', $null)
    if ($tray -eq [IntPtr]::Zero) { return }
    $cmd = if ($Hidden) { 0 } else { 5 } # SW_HIDE / SW_SHOW
    [void][WinGodDockNative]::ShowWindow($tray, $cmd)
}

function Save-WinGodDockConfig {
    <#
        .SYNOPSIS
        Writes the dock config JSON from a normalized config hashtable.
    #>
    param([hashtable]$Config)

    $apps = @()
    foreach ($app in $Config.pinnedApps) {
        if (-not $app -or -not $app.Path) { continue }
        $entry = [ordered]@{
            Name = [string]$app.Name
            Path = [string]$app.Path
        }
        if ($app.Args)      { $entry.Args = @($app.Args) }
        if ($app.IconPath)  { $entry.IconPath = [string]$app.IconPath }
        $apps += $entry
    }

    $payload = [ordered]@{
        Version           = '1.0'
        Height            = [string]$Config.heightKey
        Theme             = [string]$Config.theme
        Clock24h          = [bool]$Config.clock24h
        Widgets           = @($Config.widgets)
        AutoHideBar       = [bool]$Config.autoHideBar
        FullscreenHideBar = [bool]$Config.fullscreenHide
        PinnedApps        = $apps
    }

    ConvertTo-Json -InputObject $payload -Depth 4 | Set-Content -Path $Config.file -Encoding UTF8 -Force
}

function Move-WinGodDockTo {
    <#
        .SYNOPSIS
        Places the dock window at the edge in real physical pixels.
    #>
    param([bool]$Expanded)

    if (-not $script:dockWindow) { return }
    Add-WinGodDockNative

    $interop = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:dockWindow
    $handle = $interop.Handle
    if ($handle -eq [IntPtr]::Zero) { return }

    $rect = New-Object WinGodDockNative+RECT
    [void][WinGodDockNative]::GetWindowRect($handle, [ref]$rect)
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -le 0) { return }

    $dpi = [WinGodDockNative]::GetDpiForWindow($handle)
    $scale = $dpi / 96.0
    $physW = [int][System.Math]::Round([System.Windows.SystemParameters]::PrimaryScreenWidth * $scale)
    $physH = [int][System.Math]::Round([System.Windows.SystemParameters]::PrimaryScreenHeight * $scale)

    $x = [int][System.Math]::Round(($physW - $w) / 2.0)
    $y = if ($Expanded) {
        $physH - $h
    }
    else {
        $physH - [int][System.Math]::Round(8.0 * $scale)
    }

    $SWP_NOACTIVATE = 0x10
    [void][WinGodDockNative]::SetWindowPos(
        $handle,
        [IntPtr](-1),
        $x, $y, $w, $h,
        $SWP_NOACTIVATE)
    return $true
}

function Add-WinGodDockIconSource {
    <#
        .SYNOPSIS
        Builds a WPF ImageSource from an icon in any exe/dll/ico file,
        optionally by index inside the file.

        .OUTPUTS
        ImageSource, or $null when extraction fails.
    #>
    param(
        [string]$FilePath,
        [int]$Index = -1
    )

    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($FilePath)
        if (-not (Test-Path $expanded)) { return $null }

        if ($expanded -match '\.ico$') {
            return [System.Windows.Media.Imaging.BitmapFrame]::Create(
                [Uri]::new($expanded, [UriKind]::RelativeOrAbsolute))
        }

        if ($Index -ge 0) {
            $large = [IntPtr[]]::new(1)
            $small = [IntPtr[]]::new(1)
            [void][WinGodDockNative]::ExtractIconExW($expanded, $Index, $large, $small, 1)
            $handle = $small[0]
            if ($handle -eq [IntPtr]::Zero) { $handle = $large[0] }
            if ($handle -eq [IntPtr]::Zero) { return $null }
            $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $handle,
                [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            [void][WinGodDockNative]::DestroyIcon($handle)
            return $source
        }

        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($expanded)
        if (-not $icon) { return $null }
        $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $icon.Handle,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        return $source
    }
    catch {
        return $null
    }
}

function Add-WinGodDockNative {
    <#
        .SYNOPSIS
        Loads the Win32 helpers used by the dock.
    #>
    if (-not ('WinGodDockNative' -as [Type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class WinGodDockNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential, Pack = 8)]
    public class MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;

        public MEMORYSTATUSEX() { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)); }
    }

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string className, string windowName);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern uint ExtractIconExW(string file, int index, [Out] IntPtr[] largeIcons, [Out] IntPtr[] smallIcons, uint count);
    [DllImport("user32.dll")] public static extern int DestroyIcon(IntPtr hIcon);

    [DllImport("user32.dll")]
    public static extern bool SetWindowCompositionAttribute(IntPtr hWnd, ref WCA_DATA data);

    [StructLayout(LayoutKind.Sequential)]
    public struct WCA_DATA
    {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ACCENT_POLICY
    {
        public int AccentState;      // 4 = ACCENT_ENABLE_ACRYLICBLURBEHIND, 3 = BLURBEHIND, 0 = none
        public int AccentFlags;
        public uint GradientColor;   // AABBGGRR: alpha channel carries the tint strength
        public int AnimationId;
    }

    public static string ApplyGlass(IntPtr hWnd, uint tintColor)
    {
        var policy = new ACCENT_POLICY { AccentState = 4, AccentFlags = 2, GradientColor = tintColor, AnimationId = 0 };
        IntPtr policyPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(ACCENT_POLICY)));
        try {
            Marshal.StructureToPtr(policy, policyPtr, false);
            var data = new WCA_DATA { Attribute = 19, Data = policyPtr, SizeOfData = Marshal.SizeOf(typeof(ACCENT_POLICY)) };
            if (!SetWindowCompositionAttribute(hWnd, ref data)) {
                return "SetWindowCompositionAttribute error " + Marshal.GetLastWin32Error();
            }
            return "glass applied";
        }
        finally {
            Marshal.FreeHGlobal(policyPtr);
        }
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, [Out] StringBuilder className, int maxCount);
    [DllImport("user32.dll")] public static extern int GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr value);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int value);
    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int cx, int cy);
    [DllImport("user32.dll")]
    public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);
    [DllImport("kernel32.dll")] public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX buffer);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetDiskFreeSpaceExW(string directory, out long freeBytesAvailable, out long totalBytes, out long totalFreeBytes);
}
'@
    }
}

function Invoke-WinGodDockFullscreenCheck {
    <#
        .SYNOPSIS
        True when some other window covers the entire primary screen
        (fullscreen app/game running).
    #>
    param([IntPtr]$DockHandle)

    $foreground = [WinGodDockNative]::GetForegroundWindow()
    if ($foreground -eq [IntPtr]::Zero -or $foreground -eq $DockHandle) {
        return $false
    }

    # Shell windows cover the monitor without being "apps": never treat them as fullscreen.
    $className = New-Object System.Text.StringBuilder 256
    [void][WinGodDockNative]::GetClassNameW($foreground, $className, 256)
    if ($className.ToString() -in @('Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd')) {
        return $false
    }

    $rect = New-Object WinGodDockNative+RECT
    [void][WinGodDockNative]::GetWindowRect($foreground, [ref]$rect)

    $coversScreen = ($rect.Left -le $screen.Left -and
        $rect.Top -le $screen.Top -and
        $rect.Right -ge ($screen.Left + $screen.Width) -and
        $rect.Bottom -ge ($screen.Top + $screen.Height))
    if (-not $coversScreen) {
        return $false
    }

    # A maximized window also covers the monitor while staying framed;
    # only true fullscreen (borderless, not zoomed) should hide the dock.
    if ([WinGodDockNative]::IsZoomed($foreground)) {
        return $false
    }

    # Maximized windows overflow the monitor by the invisible resize border
    # while staying framed; real fullscreen windows are borderless.
    $style = $null
    if ([Environment]::Is64BitProcess) {
        $style = [Long][WinGodDockNative]::GetWindowLongPtr($foreground, -16) # GWL_STYLE
    }
    else {
        $style = [WinGodDockNative]::GetWindowLong($foreground.ToInt32(), -16)
    }

    $WS_CAPTION = 0x00C00000
    $WS_THICKFRAME = 0x00040000
    return (($style -band $WS_CAPTION) -eq 0 -and ($style -band $WS_THICKFRAME) -eq 0)
}

function Get-WinGodDockStatsText {
    <#
        .SYNOPSIS
        One-line system stats: CPU, RAM and primary drive free space.
    #>
    $memory = New-Object WinGodDockNative+MEMORYSTATUSEX
    [void][WinGodDockNative]::GlobalMemoryStatusEx($memory)
    $ramPct = [int]$memory.dwMemoryLoad

    $cpuPct = 0
    try {
        $cpuSample = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        $cpuPct = [int][System.Math]::Round([System.Math]::Max(0, [double]$cpuSample.PercentProcessorTime))
    }
    catch {
        $cpuPct = 0
    }

    $freeAvailable = [long]0
    $totalBytes = [long]0
    $totalFree = [long]0
    [void][WinGodDockNative]::GetDiskFreeSpaceExW($env:SystemDrive + '\', [ref]$freeAvailable, [ref]$totalBytes, [ref]$totalFree)
    $diskFreePct = 100.0
    if ($totalBytes -gt 0) {
        $diskFreePct = [double]$freeAvailable / [double]$totalBytes * 100.0
    }

    return ("CPU {0}%  RAM {1}%  Disco {2:0}%" -f $cpuPct, $ramPct, $diskFreePct)
}

function Invoke-WinGodDockAppLaunch {
    <#
        .SYNOPSIS
        Starts a pinned app tile target with environment-expanded paths.
    #>
    param([object]$App)

    $path = [Environment]::ExpandEnvironmentVariables([string]$App.Path)
    $launchArgs = @()
    if ($App.Args) {
        foreach ($argument in @($App.Args)) {
            $launchArgs += [Environment]::ExpandEnvironmentVariables([string]$argument)
        }
    }

    try {
        if ($launchArgs.Count -gt 0) {
            Start-Process -FilePath $path -ArgumentList $launchArgs | Out-Null
        }
        else {
            Start-Process -FilePath $path | Out-Null
        }
        Write-WinGodLog -Module 'dock' -Event 'dock.app.launched' -Message ([string]$App.Name) -Data @{ path = $path }
    }
    catch {
        Write-WinGodLog -Module 'dock' -Event 'dock.app.error' -Level 'Warn' -Message ('Falha ao lançar ' + $App.Name) -ErrorRecord $_
    }
}

function Set-WinGodDockRunState {
    param(
        [Parameter(ParameterSetName = 'Write', Mandatory)]
        [string]$ConfigPath,

        [Parameter(ParameterSetName = 'Read', Mandatory)]
        [switch]$Read
    )

    New-Item -Path $script:dockDataRoot -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

    if ($Read) {
        if (-not (Test-Path $script:dockRunFile)) { return $null }
        try {
            return Get-Content $script:dockRunFile -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            return $null
        }
    }

    @{
        pid     = $PID
        started = [DateTime]::UtcNow.ToString('o')
        config  = $ConfigPath
    } | ConvertTo-Json -Compress | Set-Content -Path $script:dockRunFile -Encoding UTF8 -Force
}

function Start-WinGodDockWindow {
    <#
        .SYNOPSIS
        Builds, shows and runs the dock window. Returns when the dock closes.

        .DESCRIPTION
        All event handlers are plain scriptblocks that close over function
        locals via the script scope; WPF raises them on this same STA thread
        so the PowerShell session state stays alive.
    #>
    param([hashtable]$Config)

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Xaml
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms

    Add-WinGodDockNative

    $theme = Get-WinGodDockTheme -Name $Config.theme
    $isGlass = ($Config.theme -eq 'glass')
    $brushConverter = New-Object System.Windows.Media.BrushConverter
    $barForeground = $brushConverter.ConvertFromString($theme.foreground)
    $barMutedForeground = $brushConverter.ConvertFromString($theme.mutedForeground)

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $script:dockScreen = $screen
    $script:dockConfig = $Config
    $script:dockCollapsed = [bool]$Config.autoHideBar
    $script:dockFullscreen = $false

    $barHeight = [double]$Config.height
    $bottomGap = 12.0
    $peekHeight = 8.0
    $windowHeight = $barHeight + $bottomGap
    $expandedTop = ($screen.Top + $screen.Height) - $windowHeight
    $collapsedTop = ($screen.Top + $screen.Height) - $peekHeight
    $initialTop = $expandedTop
    if ($Config.autoHideBar) {
        $initialTop = $collapsedTop
    }

    # ---------- Window ----------
    $window = New-Object System.Windows.Window
    $window.WindowStyle = [System.Windows.WindowStyle]::None
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    # GlassMode blur: DWM acrylic behind a transparent client; solid: the
    # opaque fallback path that is known to paint on this stack.
    $script:dockGlassBlur = ($Config.glassMode -eq 'blur')
    if ($script:dockGlassBlur) {
        $window.Background = $null
    }
    else {
        $window.Background = $brushConverter.ConvertFromString($theme.barBackground)
    }
    $window.ShowInTaskbar = $false
    $window.ShowActivated = $false
    $window.Topmost = $true
    $window.Title = 'winGodDock'
    $window.SizeToContent = [System.Windows.SizeToContent]::Width
    $window.Left = $screen.Left + (($screen.Width - 380.0) / 2.0)
    $window.Height = $windowHeight
    $window.Top = $initialTop
    $window.Background = $brushConverter.ConvertFromString($theme.barBackground)
    $script:dockWindow = $window

    # ---------- Bar ----------
    $bar = New-Object System.Windows.Controls.Border
    $bar.Height = $barHeight
    if ($script:dockGlassBlur) {
        # thin tint over the DWM acrylic; the window bg stays empty so the
        # blur shows through the gaps between the widgets
        $bar.Background = $brushConverter.ConvertFromString('#40101216')
    }
    else {
        $bar.Background = $brushConverter.ConvertFromString($theme.barBackground)
    }
    $bar.BorderBrush = $brushConverter.ConvertFromString($theme.barBorder)
    $bar.BorderThickness = New-Object System.Windows.Thickness(0, 1, 0, 1)
    $bar.CornerRadius = New-Object System.Windows.CornerRadius(20)
    $bar.Padding = New-Object System.Windows.Thickness(14, 0, 16, 0)
    $bar.VerticalAlignment = [System.Windows.VerticalAlignment]::Bottom
    $bar.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $row.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    # ---------- Pinned app tiles ----------
    if (($Config.widgets -contains 'appTiles') -and $Config.pinnedApps.Count -gt 0) {
        $tilePanel = New-Object System.Windows.Controls.StackPanel
        $tilePanel.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $tilePanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        $hoverBrush = $brushConverter.ConvertFromString($theme.tileHover)
        $script:dockTileRefs = [System.Collections.Generic.List[object]]::new()

        foreach ($app in $Config.pinnedApps) {
            if (-not $app -or -not $app.Path) { continue }

            $expandedPath = [Environment]::ExpandEnvironmentVariables([string]$app.Path)

            $tile = New-Object System.Windows.Controls.Border
            $tile.CornerRadius = New-Object System.Windows.CornerRadius(9)
            $tile.Background = [System.Windows.Media.Brushes]::Transparent
            $tile.Margin = New-Object System.Windows.Thickness(4, 5, 4, 5)
            $tile.Padding = New-Object System.Windows.Thickness(6)
            $tile.Cursor = [System.Windows.Input.Cursors]::Hand
            $tile.ToolTip = [string]$app.Name
            $tile.Width = 40
            $tile.Height = 40

            # macOS-style magnification: scale transform anchored at the bottom
            $tileScale = New-Object System.Windows.Media.ScaleTransform
            $tile.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 1.0)
            $tile.RenderTransform = $tileScale
            $script:dockTileRefs.Add(@{ tile = $tile; scale = $tileScale })

            $tile.Add_MouseEnter({ $this.Background = $hoverBrush }.GetNewClosure())
            $tile.Add_MouseLeave({ $this.Background = [System.Windows.Media.Brushes]::Transparent }.GetNewClosure())

            $tileContent = New-Object System.Windows.Controls.StackPanel
            $tileContent.Orientation = [System.Windows.Controls.Orientation]::Horizontal

            $iconPath = [string]$app.Path
            if ($app.IconPath) { $iconPath = [string]$app.IconPath }
            $iconSource = Add-WinGodDockIconSource -FilePath $iconPath

            if ($iconSource) {
                $tileIcon = New-Object System.Windows.Controls.Image
                $tileIcon.Source = $iconSource
                $tileIcon.Width = 24
                $tileIcon.Height = 24
                $tileIcon.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
                $tileIcon.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                $tileIcon.FlowDirection = [System.Windows.FlowDirection]::LeftToRight
                [void]$tileContent.Children.Add($tileIcon)
            }
            else {
                $tileLetter = New-Object System.Windows.Controls.TextBlock
                $tileLetter.Text = ([string]$app.Name).Trim().Substring(0, 1).ToUpperInvariant()
                $tileLetter.FontWeight = [System.Windows.FontWeights]::Bold
                $tileLetter.FontSize = 14
                $tileLetter.Foreground = $barForeground
                $tileLetter.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
                $tileLetter.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                [void]$tileContent.Children.Add($tileLetter)
            }

            $tile.Child = $tileContent

            $targetApp = $app
            $tile.Add_MouseLeftButtonUp({
                # bounce while launching
                try {
                    $bounce = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
                    $bounce.KeyFrames.Add((New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame(1.25, [TimeSpan]::FromMilliseconds(120))))
                    $bounce.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(1.0, [TimeSpan]::FromMilliseconds(320))))
                    $tileScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $bounce)
                    $tileScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $bounce)
                }
                catch {}
                Invoke-WinGodDockAppLaunch -App $targetApp
            }.GetNewClosure())

            [void]$tilePanel.Children.Add($tile)
        }

        # macOS magnification: neighbors scale by distance to the cursor
        $script:dockTilePanelHost = $tilePanel
        $tilePanel.Add_MouseMove({
            $ev = $args[1]
            $mx = $ev.GetPosition($script:dockTilePanelHost).X
            foreach ($ref in $script:dockTileRefs) {
                $center = $ref.tile.TranslatePoint((New-Object System.Windows.Point([double]$ref.tile.Width / 2.0, 0.0)), $script:dockTilePanelHost).X
                $delta = [Math]::Abs($mx - $center)
                $t = [Math]::Exp(-[Math]::Pow($delta / 55.0, 2.0))
                $s = 1.0 + (0.35 * $t)
                $ref.scale.ScaleX = $s
                $ref.scale.ScaleY = $s
            }
        })
        $tilePanel.Add_MouseLeave({
            foreach ($ref in $script:dockTileRefs) {
                $ref.scale.ScaleX = 1.0
                $ref.scale.ScaleY = 1.0
            }
        })
        [void]$row.Children.Add($tilePanel)
    }

    # ---------- Separator ----------
    $separator = New-Object System.Windows.Controls.Border
    $separator.Width = 1
    $separator.Height = 22
    $separator.Background = $brushConverter.ConvertFromString('#26FFFFFF')
    $separator.Margin = New-Object System.Windows.Thickness(6, 0, 6, 0)
    $separator.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [void]$row.Children.Add($separator)

    # ---------- Stats ----------
    if ($Config.widgets -contains 'stats') {
        $statsText = New-Object System.Windows.Controls.TextBlock
        $statsText.FontSize = 11.5
        $statsText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $statsText.Foreground = $barMutedForeground
        $statsText.Margin = New-Object System.Windows.Thickness(6, 0, 4, 0)
        $statsText.Text = '...'
        $script:dockStatsText = $statsText
        [void]$row.Children.Add($statsText)
    }

    # ---------- Indicators (sound + wifi shell icons) ----------
    if ($Config.widgets -contains 'indicators') {
        foreach ($indicator in @(
                @{ File = '%SystemRoot%\System32\mmres.dll';    Index = 0;   ToolTip = 'Áudio' },
                @{ File = '%SystemRoot%\System32\netshell.dll'; Index = 161; ToolTip = 'Rede' }
            )) {
            $indicatorIcon = Add-WinGodDockIconSource -FilePath $indicator.File -Index $indicator.Index
            if (-not $indicatorIcon) { continue }

            $indicatorImage = New-Object System.Windows.Controls.Image
            $indicatorImage.Source = $indicatorIcon
            $indicatorImage.Width = 18
            $indicatorImage.Height = 18
            $indicatorImage.Margin = New-Object System.Windows.Thickness(2, 0, 2, 0)
            $indicatorImage.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $indicatorImage.ToolTip = $indicator.ToolTip
            [void]$row.Children.Add($indicatorImage)
        }
    }

    # ---------- Clock ----------
    if ($Config.widgets -contains 'clock') {
        $script:dockClockFormat = if ($Config.clock24h) { 'HH:mm' } else { 'hh:mm' }

        $clockPanel = New-Object System.Windows.Controls.StackPanel
        $clockPanel.Orientation = [System.Windows.Controls.Orientation]::Vertical
        $clockPanel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $clockPanel.Margin = New-Object System.Windows.Thickness(4, 0, 6, 0)

        $clockTime = New-Object System.Windows.Controls.TextBlock
        $clockTime.FontSize = 14
        $clockTime.FontWeight = [System.Windows.FontWeights]::SemiBold
        $clockTime.Foreground = $barForeground
        $clockTime.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $script:dockClockTime = $clockTime

        $clockDate = New-Object System.Windows.Controls.TextBlock
        $clockDate.FontSize = 10
        $clockDate.Foreground = $barMutedForeground
        $clockDate.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $script:dockClockDate = $clockDate

        [void]$clockPanel.Children.Add($clockTime)
        [void]$clockPanel.Children.Add($clockDate)
        [void]$row.Children.Add($clockPanel)
    }

    # ---------- Widgets extras: day / battery / network / uptime ----------
    $script:dockDayText = $null
    $script:dockNetworkText = $null
    $script:dockBatteryText = $null
    $script:dockUptimeText = $null

    function Add-WinGodDockTextWidget {
        param([hashtable]$Config)

        $widget = New-Object System.Windows.Controls.TextBlock
        $widget.FontSize = 12
        $widget.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $widget.Foreground = $brushConverter.ConvertFromString($theme.mutedForeground)
        $widget.Margin = $widget.Margin = New-Object System.Windows.Thickness(6, 0, 2, 0)
        $widget.Text = '...'
        [void]$row.Children.Add($widget)
        return $widget
    }

    if ($Config.widgets -contains 'dayProgress') {
        $script:dockDayText = Add-WinGodDockTextWidget
    }
    if ($Config.widgets -contains 'network') {
        $script:dockNetworkText = Add-WinGodDockTextWidget
    }
    if ($Config.widgets -contains 'battery') {
        $script:dockBatteryText = Add-WinGodDockTextWidget
    }
    if ($Config.widgets -contains 'uptime') {
        $script:dockUptimeText = Add-WinGodDockTextWidget
    }

    # ---------- Personalize gear ----------
    $gearTile = New-Object System.Windows.Controls.Border
    $gearTile.CornerRadius = New-Object System.Windows.CornerRadius(9)
    $gearTile.Background = [System.Windows.Media.Brushes]::Transparent
    $gearTile.Margin = New-Object System.Windows.Thickness(4, 5, 4, 5)
    $gearTile.Cursor = [System.Windows.Input.Cursors]::Hand
    $gearTile.Width = 36
    $gearTile.Height = 36
    $gearTile.ToolTip = 'Personalizar o dock'
    $gearTile.Add_MouseEnter({ $this.Background = $hover }.GetNewClosure())
    $gearTile.Add_MouseLeave({ $this.Background = [System.Windows.Media.Brushes]::Transparent }.GetNewClosure())

    $gearText = New-Object System.Windows.Controls.TextBlock
    $gearText.FontFamily = (New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets'))
    $gearText.Text = [char]0xE713
    $gearText.Foreground = $barForeground
    $gearText.FontSize = 14
    $gearText.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $gearText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $gearTile.Child = $gearText
    $gearTile.Add_MouseLeftButtonUp({
        Start-WinGodDockPanel -Config $script:dockConfig
    }.GetNewClosure())
    [void]$row.Children.Add($gearTile)

    $bar.Child = $row
    $window.Content = $bar

    # ---------- Behavior: slide up / slide down ----------
    $hideTimer = New-Object System.Windows.Threading.DispatcherTimer
    $hideTimer.Interval = [TimeSpan]::FromMilliseconds(450)

    $hideTimer.Add_Tick({
        $script:dockHideTimer.Stop()
        if (-not $script:dockMouseInside -and $script:dockConfig.autoHideBar) {
            $script:dockCollapsed = $true
            Move-WinGodDockTo -Expanded $false
        }
    })

    $window.Add_MouseEnter({
        Write-WinGodLog -Module 'dock' -Event 'dock.mouse.enter' -Message 'hover enter'
        $script:dockMouseInside = $true
        if ($script:dockConfig.autoHideBar -and $script:dockCollapsed) {
            $script:dockHideTimer.Stop()
            $script:dockCollapsed = $false
            Move-WinGodDockTo -Expanded $true
        }
    })

    $window.Add_MouseLeave({
        Write-WinGodLog -Module 'dock' -Event 'dock.mouse.leave' -Message 'hover leave'
        $script:dockMouseInside = $false
        if ($script:dockConfig.autoHideBar -and -not $script:dockCollapsed -and -not $script:dockFullscreen) {
            $script:dockHideTimer.Stop()
            $script:dockHideTimer.Start()
        }
    })

    # ---------- Position via SetWindowPos in real physical pixels ----------
    # WPF DIP coordinates keep disagreeing with the shell across DPI mixes;
    # physical pixels after Show are the single source of truth.
    $window.Add_ContentRendered({
        param($source, $eventArgs)
        Add-WinGodDockNative
        $interop = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $source
        $handle = $interop.EnsureHandle()

        $dpi = [WinGodDockNative]::GetDpiForWindow($handle)
        $scale = $dpi / 96.0
        $physW = [int]([System.Math]::Round([System.Windows.SystemParameters]::PrimaryScreenWidth * $scale))
        $physH = [int]([System.Math]::Round([System.Windows.SystemParameters]::PrimaryScreenHeight * $scale))

        $r = New-Object WinGodDockNative+RECT
        [void][WinGodDockNative]::GetWindowRect($handle, [ref]$r)
        $w = $r.Right - $r.Left
        $h = $r.Bottom - $r.Top
        if ($w -le 0) { $w = 1 }
        if ($h -le 0) { $h = 1 }

        $x = [int]([System.Math]::Round(($physW - $w) / 2.0))
        $y = $physH - $h
        if ($script:dockConfig.autoHideBar -and $script:dockCollapsed) {
            # peeks only the top strip above the bottom edge
            $y = $physH - [int][System.Math]::Round(8.0 * $scale)
        }
        $SWP_NOSIZE = 0x1
        $SWP_NOACTIVATE = 0x10
        [void][WinGodDockNative]::SetWindowPos(
            $handle,
            [IntPtr](-1), # HWND_TOPMOST
            $x, $y, $w, $h,
            ($SWP_NOSIZE -bor $SWP_NOACTIVATE))

        Write-WinGodLog -Module 'dock' -Event 'dock.window.ready' -Message 'window handle styled' -Data @{
            dpi    = $dpi
            rect   = "$($r.Left),$($r.Top) $($r.Right),$($r.Bottom)"
            placed = "$x,$y ${w}x${h}"
        }
    })

    # ---------- Window chrome: solid rounded region + keep tiling WM away ----------
    $window.Add_Loaded({
        param($source, $eventArgs)
        Add-WinGodDockNative

        $interop = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $source
        $handle = $interop.EnsureHandle()

        $GWL_EXSTYLE = -20
        $WS_EX_TOOLWINDOW = 0x80
        if ([Environment]::Is64BitProcess) {
            [void][WinGodDockNative]::SetWindowLongPtr($handle, $GWL_EXSTYLE, [IntPtr]$WS_EX_TOOLWINDOW)
        }
        else {
            [void][WinGodDockNative]::SetWindowLong($handle.ToInt32(), $GWL_EXSTYLE, $WS_EX_TOOLWINDOW)
        }

        # Round the corners via a window region (physical pixels).
        $r = New-Object WinGodDockNative+RECT
        [void][WinGodDockNative]::GetWindowRect($handle, [ref]$r)
        $w = $r.Right - $r.Left
        $h = $r.Bottom - $r.Top
        $rgn = [WinGodDockNative]::CreateRoundRectRgn(0, 0, $w + 1, $h + 1, 24, 24)
        [void][WinGodDockNative]::SetWindowRgn($handle, $rgn, $true)

        # DWM acrylic behind the translucent bar in glass mode
        if ($script:dockGlassBlur) {
            $glassResult = [WinGodDockNative]::ApplyGlass($handle, 0x66000000)
            Write-WinGodLog -Module 'dock' -Event 'dock.glass' -Message $glassResult
        }

        Write-WinGodLog -Module 'dock' -Event 'dock.window.ready' -Message 'window handle styled'
    })

    # ---------- Timers ----------
    $clockTimer = New-Object System.Windows.Threading.DispatcherTimer
    $clockTimer.Interval = [TimeSpan]::FromSeconds(1)
    $clockTimer.Add_Tick({
        $now = [DateTime]::Now
        if ($script:dockClockTime) {
            $script:dockClockTime.Text = $now.ToString($script:dockClockFormat)
            $script:dockClockDate.Text = $now.ToString('ddd dd/MM')
        }
        if ($script:dockDayText) {
            $fraction = $now.TimeOfDay.TotalMinutes / 1440.0
            $script:dockDayText.Text = ('{0:0}% do dia' -f ($fraction * 100))
        }
    })

    $statsTimer = New-Object System.Windows.Threading.DispatcherTimer
    $statsTimer.Interval = [TimeSpan]::FromSeconds(2)
    $statsTimer.Add_Tick({
        try {
            if ($script:dockStatsText) {
                $script:dockStatsText.Text = Get-WinGodDockStatsText
            }
        }
        catch {
            if ($script:dockStatsText) {
                $script:dockStatsText.Text = 'CPU ...  RAM ...'
            }
        }
        if ($script:dockNetworkText) {
            try {
                $down = 0.0
                $up = 0.0
                Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop | ForEach-Object {
                    $down += [double]$_.BytesReceivedPersec
                    $up += [double]$_.BytesSentPersec
                }
                $script:dockNetworkText.Text = ('↓ {0} KB/s  ↑ {1} KB/s' -f [int][Math]::Round($down / 1024), [int][Math]::Round($up / 1024))
            }
            catch {
                $script:dockNetworkText.Text = '↓ ...  ↑ ...'
            }
        }
    })

    $sysTimer = New-Object System.Windows.Threading.DispatcherTimer
    $sysTimer.Interval = [TimeSpan]::FromSeconds(15)
    $sysTimer.Add_Tick({
        if ($script:dockBatteryText) {
            try {
                $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
                if ($battery) {
                    $suffix = if ($battery.BatteryStatus -in @(2, 6, 7, 8, 9, 11)) { ' ⚡' } else { '' }
                    $script:dockBatteryText.Text = ('Bateria {0:0}%{1}' -f $battery.EstimatedChargeRemaining, $suffix)
                }
                else {
                    $script:dockBatteryText.Text = 'Sem bateria'
                }
            }
            catch {
                $script:dockBatteryText.Text = 'Bateria ...'
            }
        }
        if ($script:dockUptimeText) {
            try {
                $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $uptime = [DateTime]::Now - $os.LastBootUpTime
                $script:dockUptimeText.Text = ('Ligado {0}h {1:00}m' -f [int]$uptime.TotalHours, $uptime.Minutes)
            }
            catch {
                $script:dockUptimeText.Text = 'Ligado ...'
            }
        }
    })

    $fullscreenTimer = New-Object System.Windows.Threading.DispatcherTimer
    $fullscreenTimer.Interval = [TimeSpan]::FromMilliseconds(600)
    $fullscreenTimer.Add_Tick({
        # keep the taskbar fully hidden while the dock is running
        Set-WinGodShellTrayHidden -Hidden $true

        $script:dockTickCount = ([int]$script:dockTickCount) + 1
        if ($script:dockTickCount -le 2) {
            Write-WinGodLog -Module 'dock' -Event 'dock.tick' -Message 'poll tick running' -Data @{ tick = $script:dockTickCount }
        }

        # drift correction: always re-place the dock at the edge in physical
        # pixels (this is cheap and immune to WPF layout / tiling WM races)
        Move-WinGodDockTo -Expanded (-not $script:dockCollapsed)

        if (-not $script:dockFullscreen) {
            # Re-assert topmost: other apps (and tiling WMs) re-raise above us.
            $interop = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:dockWindow
            $handle = $interop.Handle
            if ($handle -ne [IntPtr]::Zero) {
                $SWP_NOMOVE = 0x2
                $SWP_NOSIZE = 0x1
                $SWP_NOACTIVATE = 0x10
                [void][WinGodDockNative]::SetWindowPos(
                    $handle,
                    [IntPtr](-1), # HWND_TOPMOST
                    0, 0, 0, 0,
                    ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOACTIVATE))
            }
        }

        $interop = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:dockWindow
        $handle = $interop.Handle
        if ($handle -eq [IntPtr]::Zero) { return }

        $isFullscreen = Invoke-WinGodDockFullscreenCheck -DockHandle $handle
        if ($isFullscreen -ne $script:dockFullscreen) {
            $script:dockFullscreen = $isFullscreen
            if ($script:dockConfig.fullscreenHide) {
                if ($isFullscreen) {
                    $script:dockWindow.Visibility = [System.Windows.Visibility]::Hidden
                }
                else {
                    $script:dockWindow.Visibility = [System.Windows.Visibility]::Visible
                }
            }
            if ($isFullscreen) {
                Write-WinGodLog -Module 'dock' -Event 'dock.hidden' -Message 'fullscreen detected'
            }
            else {
                Write-WinGodLog -Module 'dock' -Event 'dock.shown' -Message 'fullscreen left'
            }
        }
    })

    $window.add_Closed({
        $script:dockClockTimer.Stop()
        $script:dockStatsTimer.Stop()
        $script:dockFullscreenTimer.Stop()
        $script:dockSysTimer.Stop()
        $script:dockWindow.Dispatcher.BeginInvokeShutdown([System.Windows.Threading.DispatcherPriority]::Normal)
        $script:dockWindow = $null
    })

    # ---------- Run ----------
    # Fill initial widget values BEFORE Show so the pill is measured once
    # with its final content (avoids clipped stats/clock at the right edge).
    if ($script:dockStatsText) {
        $script:dockStatsText.Text = Get-WinGodDockStatsText
    }
    if ($script:dockClockTime) {
        $now = [DateTime]::Now
        $script:dockClockTime.Text = $now.ToString($script:dockClockFormat)
        $script:dockClockDate.Text = $now.ToString('ddd dd/MM')
    }

    $script:dockClockTimer = $clockTimer
    $script:dockStatsTimer = $statsTimer
    $script:dockFullscreenTimer = $fullscreenTimer
    $script:dockHideTimer = $hideTimer
    $script:dockSysTimer = $sysTimer

    $clockTimer.Start()
    $statsTimer.Start()
    $fullscreenTimer.Start()
    $sysTimer.Start()

    $window.Show()

    if ($script:panelPending) {
        $panelTimer = New-Object System.Windows.Threading.DispatcherTimer
        $panelTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $panelTimer.Add_Tick({
            $panelTimer.Stop()
            Start-WinGodDockPanel -Config $script:dockConfig
        })
        $panelTimer.Start()
    }

    Write-WinGodLog -Module 'dock' -Event 'dock.started' -Message 'dock running' -Data @{
        height      = $Config.height
        theme       = $Config.theme
        widgets     = (@($Config.widgets) -join ',')
        auto_hide   = $Config.autoHideBar
        fullscreen  = $Config.fullscreenHide
        pinned_apps = $Config.pinnedApps.Count
    }

    try {
        [System.Windows.Threading.Dispatcher]::Run()
    }
    finally {
        Write-WinGodLog -Module 'dock' -Event 'dock.exited' -Message 'dock loop ended'
    }
}

function Get-WinGodDockWidgetCatalog {
    <#
        .SYNOPSIS
        Offline widget catalog the picker exposes (id + label + description).
    #>
    return @(
        @{ id = 'clock';       name = 'Relógio + data';   desc = 'Hora em 24h e o dia da semana' },
        @{ id = 'stats';       name = 'CPU / RAM / Disco'; desc = 'Medições do sistema a cada 2s' },
        @{ id = 'appTiles';    name = 'Apps pinados';      desc = 'Tiles dos apps escolhidos' },
        @{ id = 'indicators';  name = 'Som e rede';        desc = 'Estado de áudio e conexão' },
        @{ id = 'battery';     name = 'Bateria';           desc = 'Carga atual (se houver)' },
        @{ id = 'network';     name = 'Download / Upload'; desc = 'Velocidade da rede em KB/s' },
        @{ id = 'uptime';      name = 'Tempo ligado';      desc = 'Desde o último boot' },
        @{ id = 'dayProgress'; name = 'Progresso do dia';  desc = 'Quanto do dia já passou' }
    )
}

function Start-WinGodDockAppPicker {
    <#
        .SYNOPSIS
        Visual installed-app chooser (Start Menu shortcuts with icons).
    #>
    param(
        [hashtable]$AppState,
        [string]$ThemeName = 'glass'
    )

    $theme = Get-WinGodDockTheme -Name $ThemeName
    $brushConverter = New-Object System.Windows.Media.BrushConverter
    $foreground = $brushConverter.ConvertFromString($theme.foreground)
    $mutedForeground = $brushConverter.ConvertFromString($theme.mutedForeground)

    $window = New-Object System.Windows.Window
    $window.WindowStyle = [System.Windows.WindowStyle]::None
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $window.ShowInTaskbar = $false
    $window.Topmost = $true
    $window.Title = 'winGodDockAppPicker'
    $window.Width = 460
    $window.Height = 520
    $window.Background = $brushConverter.ConvertFromString($theme.barBackground)
    $window.Padding = New-Object System.Windows.Thickness(4)
    $script:dockAppPickerWindow = $window

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(10, 10, 10, 12)
    $window.Content = $root

    $headerRow = New-Object System.Windows.Controls.StackPanel
    $headerRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = 'Escolher apps por ícone'
    $title.Foreground = $foreground
    $title.FontSize = 14
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    [void]$headerRow.Children.Add($title)
    $close = New-Object System.Windows.Controls.Button
    $close.Content = [char]0xE8BB
    $close.FontFamily = (New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets'))
    $close.Background = [System.Windows.Media.Brushes]::Transparent
    $close.Foreground = $mutedForeground
    $close.Width = 26
    $close.Margin = New-Object System.Windows.Thickness(330, 0, 0, 0)
    $close.Add_Click({ $script:dockAppPickerWindow.Close() })
    [void]$headerRow.Children.Add($close)
    [void]$root.Children.Add($headerRow)

    $searchBox = New-Object System.Windows.Controls.TextBox
    $searchBox.Margin = New-Object System.Windows.Thickness(0, 10, 0, 6)
    $searchBox.Foreground = $foreground
    $searchBox.Background = [System.Windows.Media.Brushes]::Transparent
    $searchBox.CaretBrush = $foreground
    [void]$root.Children.Add($searchBox)

    $listHost = New-Object System.Windows.Controls.StackPanel
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.MaxHeight = 430
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $scroll.Content = $listHost
    [void]$root.Children.Add($scroll)

    # enumerate Start Menu shortcuts once
    $script:dockAppPickerItems = [System.Collections.Generic.List[object]]::new()
    $shell = New-Object -ComObject WScript.Shell
    $roots = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    )
    $seen = @{}
    foreach ($rootFolder in $roots) {
        Get-ChildItem $rootFolder -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $link = $shell.CreateShortcut($_.FullName)
                $target = [string]$link.TargetPath
                if ($target -and (Test-Path $target) -and ($target -match '\.exe$') -and -not $seen.ContainsKey($target.ToLowerInvariant())) {
                    $seen[$target.ToLowerInvariant()] = $true
                    $appEntry = @{
                        Name = [IO.Path]::GetFileNameWithoutExtension($target)
                        Path = $target
                    }
                    $iconSource = Add-WinGodDockIconSource -FilePath $target
                    if ($iconSource) { $appEntry.iconSource = $iconSource }
                    $script:dockAppPickerItems.Add($appEntry)
                }
            }
            catch {}
        }
    }

    function Set-AppPickerRow {
        param($Row, [hashtable]$Item)

        $inner = New-Object System.Windows.Controls.StackPanel
        $inner.Orientation = [System.Windows.Controls.Orientation]::Horizontal

        if ($Item.iconSource) {
            $iconImage = New-Object System.Windows.Controls.Image
            $iconImage.Source = $Item.iconSource
            $iconImage.Width = 22
            $iconImage.Height = 22
            $iconImage.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
            [void]$inner.Children.Add($iconImage)
        }

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = [string]$Item.Name
        $label.Foreground = $foreground
        $label.FontSize = 12.5
        $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        [void]$inner.Children.Add($label)

        $pinned = @($AppState.list | Where-Object { [string]$_.Path.ToLowerInvariant() -eq [string]$Item.Path.ToLowerInvariant() })
        if ($pinned.Count -gt 0) {
            $mark = New-Object System.Windows.Controls.TextBlock
            $mark.Text = ' ✓ pinado'
            $mark.Foreground = $mutedForeground
            $mark.FontSize = 11
            $mark.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
            $mark.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            [void]$inner.Children.Add($mark)
        }

        $Row.Child = $inner
        $Row.Tag = $Item

        $Row.Add_MouseEnter({
            param($sender, $eventArgs)
            $sender.Background = New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.Color]::FromArgb(0x33, 0xFF, 0xFF, 0xFF))
        }.GetNewClosure())
        $Row.Add_MouseLeftButtonUp({
            param($sender, $eventArgs)
            $app = $sender.Tag
            $already = @($AppState.list | Where-Object { [string]$_.Path.ToLowerInvariant() -eq [string]$app.Path.ToLowerInvariant() })
            if ($already.Count -eq 0) {
                $AppState.list += @{ Name = [string]$app.Name; Path = [string]$app.Path }
                Write-WinGodLog -Module 'dock' -Event 'dock.panel.app.picked' -Message ([string]$app.Name)
            }
            Show-AppRows -Filter $searchBox.Text
        }.GetNewClosure())
    }

    function Show-AppRows {
        param([string]$Filter)

        $listHost.Children.Clear()
        $shown = 0
        foreach ($item in $script:dockAppPickerItems) {
            if ($Filter -and ([string]$item.Name -notlike "*$Filter*")) { continue }
            if ($shown -ge 120) { break }
            $shown++

            $row = New-Object System.Windows.Controls.Border
            $row.CornerRadius = New-Object System.Windows.CornerRadius(8)
            $row.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)
            $row.Cursor = [System.Windows.Input.Cursors]::Hand
            $row.Background = [System.Windows.Media.Brushes]::Transparent
            $row.Tag = $null
            $row.Child = $null

            $row.Add_MouseEnter({
                param($sender, $eventArgs)
                $sender.Background = New-Object System.Windows.Media.SolidColorBrush(
                    [System.Windows.Media.Color]::FromArgb(0x33, 0xFF, 0xFF, 0xFF))
            }.GetNewClosure())

            [void]$listHost.Children.Add($row)
            Set-AppPickerRow -Row $row -Item $item
        }
    }

    $searchBox.Add_TextChanged({
        Show-AppRows -Filter $searchBox.Text
    })
    Show-AppRows -Filter ''

    $window.Show()
}

function Start-WinGodDockWidgetPicker {
    <#
        .SYNOPSIS
        Visual widget catalog: click a card to toggle the widget on/off.
    #>
    param(
        [hashtable]$WidgetState,
        [string]$ThemeName = 'glass'
    )

    $theme = Get-WinGodDockTheme -Name $ThemeName
    $brushConverter = New-Object System.Windows.Media.BrushConverter
    $foreground = $brushConverter.ConvertFromString($theme.foreground)
    $mutedForeground = $brushConverter.ConvertFromString($theme.mutedForeground)

    $window = New-Object System.Windows.Window
    $window.WindowStyle = [System.Windows.WindowStyle]::None
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $window.ShowInTaskbar = $false
    $window.Topmost = $true
    $window.Title = 'winGodDockWidgetPicker'
    $window.Width = 460
    $window.Height = 480
    $window.Background = $brushConverter.ConvertFromString($theme.barBackground)
    $window.Padding = New-Object System.Windows.Thickness(4)
    $script:dockWidgetPickerWindow = $window

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(10, 10, 10, 12)
    $window.Content = $root

    $headerRow = New-Object System.Windows.Controls.StackPanel
    $headerRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = 'Escolher widgets'
    $title.Foreground = $foreground
    $title.FontSize = 14
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    [void]$headerRow.Children.Add($title)
    $close = New-Object System.Windows.Controls.Button
    $close.Content = [char]0xE8BB
    $close.FontFamily = (New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets'))
    $close.Background = [System.Windows.Media.Brushes]::Transparent
    $close.Foreground = $mutedForeground
    $close.Width = 26
    $close.Margin = New-Object System.Windows.Thickness(330, 0, 0, 0)
    $close.Add_Click({ $script:dockWidgetPickerWindow.Close() })
    [void]$headerRow.Children.Add($close)
    [void]$root.Children.Add($headerRow)

    $listHost = New-Object System.Windows.Controls.StackPanel
    [void]$root.Children.Add($listHost)

    $script:dockWidgetSummary = $null

    foreach ($entry in (Get-WinGodDockWidgetCatalog)) {
        $card = New-Object System.Windows.Controls.Border
        $card.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $card.Margin = New-Object System.Windows.Thickness(0, 4, 0, 4)
        $card.Padding = New-Object System.Windows.Thickness(12, 8, 12, 8)
        $card.Cursor = [System.Windows.Input.Cursors]::Hand
        $card.Tag = [string]$entry.id

        $inner = New-Object System.Windows.Controls.StackPanel
        $nameRow = New-Object System.Windows.Controls.TextBlock
        $nameRow.Text = [string]$entry.name
        $nameRow.Foreground = $foreground
        $nameRow.FontSize = 12.5
        $nameRow.FontWeight = [System.Windows.FontWeights]::SemiBold
        [void]$inner.Children.Add($nameRow)
        $descRow = New-Object System.Windows.Controls.TextBlock
        $descRow.Text = [string]$entry.desc
        $descRow.Foreground = $mutedForeground
        $descRow.FontSize = 11
        [void]$inner.Children.Add($descRow)
        $card.Child = $inner

        $card.Add_MouseLeftButtonUp({
            param($sender, $eventArgs)
            $id = [string]$sender.Tag
            $has = @($WidgetState.list | Where-Object { $_ -eq $id }).Count -gt 0
            if ($has) {
                $WidgetState.list = @($WidgetState.list | Where-Object { $_ -ne $id })
            }
            else {
                $WidgetState.list += $id
            }
            if ($script:dockWidgetSummary) {
                $script:dockWidgetSummary.Text = ('Widgets: ' + (@($WidgetState.list) -join ', '))
            }
        }.GetNewClosure())

        $listHost.Children.Add($card)
    }

    $window.Show()
}

function Invoke-WinGodDockRunKeyCommand {
    <#
        .SYNOPSIS
        Writes/removes the auto-start registry entry. Works from the repo
        scripts and from the bundled exe (it targets the running program).
    #>
    param(
        [switch]$Register,
        [switch]$Unregister
    )

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $runValueName = 'winGodDock'
    $program = $script:dockProgramPath
    $isExe = [bool]($program -like '*.exe')

    $command = if ($isExe) {
        "`"$program`" -NoRunKey"
    }
    else {
        "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$program`" -NoRunKey"
    }

    if ($Unregister) {
        $existing = (Get-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue)
        if ($null -eq $existing) {
            Write-Host 'Run key do winGodDock não existe, nada a fazer.'
            return
        }
        try {
            Remove-ItemProperty -Path $runKey -Name $runValueName -Force -ErrorAction Stop
            Write-Host 'Run key do winGodDock removida.' -ForegroundColor Green
        }
        catch {
            Write-Warning "Falha ao remover a Run key: $($_.Exception.Message)"
        }
        return
    }

    if (-not (Test-Path $program)) {
        Write-Warning "Programa de dock não encontrado: $program"
        return
    }

    $existing = (Get-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue)
    if ($existing -and $existing.$runValueName -eq $command) {
        Write-Host 'Run key do winGodDock já configurada, nada a fazer.'
        return
    }

    try {
        Set-ItemProperty -Path $runKey -Name $runValueName -Value $command -Type String -Force -ErrorAction Stop
        Write-Host 'Run key do winGodDock registrada: o dock arranca com o login.' -ForegroundColor Green
    }
    catch {
        Write-Warning "Falha ao escrever a Run key: $($_.Exception.Message)"
    }
}

function Get-WinGodDockProgramPath {
    <#
        .SYNOPSIS
        Resolves the dock program file (the bundled exe or this script).
    #>
    $source = $PSCommandPath
    if ($source -and $source.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        return $source
    }
    if ($PSScriptRoot) {
        return Join-Path $PSScriptRoot 'Invoke-WinGodDock.ps1'
    }
    return Join-Path $script:dockDataRoot 'winGod-dock.ps1'
}

function Start-WinGodDockPanel {
    <#
        .SYNOPSIS
        lumabar-style personalization panel: widget toggles, appearance,
        pinned apps editor, save & restart.
    #>
    param([hashtable]$Config)

    $theme = Get-WinGodDockTheme -Name $Config.theme
    $brushConverter = New-Object System.Windows.Media.BrushConverter
    $foreground = $brushConverter.ConvertFromString($theme.foreground)
    $mutedForeground = $brushConverter.ConvertFromString($theme.mutedForeground)
    $hover = $brushConverter.ConvertFromString($theme.tileHover)

    # local working copies the panel edits
    $appsState = @{ list = @() }
    foreach ($app in $Config.pinnedApps) {
        if (-not $app -or -not $app.Path) { continue }
        $copy = @{ Name = [string]$app.Name; Path = [string]$app.Path }
        if ($app.Args)     { $copy.Args = @($app.Args) }
        if ($app.IconPath) { $copy.IconPath = [string]$app.IconPath }
        $appsState.list += $copy
    }
    $panelWidgets = @($Config.widgets)

    $window = New-Object System.Windows.Window
    $window.WindowStyle = [System.Windows.WindowStyle]::None
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $window.ShowInTaskbar = $false
    $window.Topmost = $true
    $window.Title = 'winGodDockPanel'
    $window.SizeToContent = [System.Windows.SizeToContent]::WidthAndHeight
    $window.Background = $brushConverter.ConvertFromString($theme.barBackground)
    $window.Padding = New-Object System.Windows.Thickness(4)
    # Anchor the panel window in script scope: event handlers resolve $window
    # dynamically after this function returns, which would otherwise point at
    # the MAIN dock window and close the whole dock.
    $script:dockPanelWindow = $window

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = New-Object System.Windows.Thickness(14, 12, 14, 14)
    $window.Content = $root

    function Add-PanelLabel {
        param($Parent, [string]$Caption, [double]$Size, [System.Windows.Media.Brush]$Brush)
        $text = New-Object System.Windows.Controls.TextBlock
        $text.Text = $Caption
        $text.Foreground = $Brush
        $text.FontSize = $Size
        $text.Margin = New-Object System.Windows.Thickness(0, 8, 0, 4)
        [void]$Parent.Children.Add($text)
        return $text
    }

    function Add-PanelToggle {
        param($Parent, [string]$Text, [bool]$Checked)

        $card = New-Object System.Windows.Controls.Border
        $card.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $card.Background = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.Color]::FromArgb(0x22, 0xFF, 0xFF, 0xFF))
        $card.Margin = New-Object System.Windows.Thickness(0, 3, 0, 3)

        $check = New-Object System.Windows.Controls.CheckBox
        $check.Content = $Text
        $check.IsChecked = $Checked
        $check.Foreground = $foreground
        $check.Margin = New-Object System.Windows.Thickness(12, 7, 12, 7)
        $check.FontSize = 12.5
        $card.Child = $check
        [void]$Parent.Children.Add($card)
        return $check
    }

    # ---------- header ----------
    $headerHost = New-Object System.Windows.Controls.StackPanel
    $headerRow = New-Object System.Windows.Controls.StackPanel
    $headerRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = 'winGod dock · personalizar'
    $title.Foreground = $foreground
    $title.FontSize = 14
    $title.FontWeight = [System.Windows.FontWeights]::SemiBold
    [void]$headerRow.Children.Add($title)

    $close = New-Object System.Windows.Controls.Button
    $close.Content = [char]0xE8BB
    $close.FontFamily = (New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets'))
    $close.Background = [System.Windows.Media.Brushes]::Transparent
    $close.Foreground = $mutedForeground
    $close.Width = 26
    $close.Margin = New-Object System.Windows.Thickness(180, 0, 0, 0)
    $close.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $close.Add_Click({
        $script:dockPanelWindow.Close()
    })
    [void]$headerRow.Children.Add($close)
    [void]$headerHost.Children.Add($headerRow)
    [void]$root.Children.Add($headerHost)

    # ---------- widgets ----------
    Add-PanelLabel -Parent $root -Text 'Widgets do dock' -Size 12.5 -Brush $foreground | Out-Null
    $widgetState = @{ list = @($Config.widgets) }
    $script:dockWidgetSummary = New-Object System.Windows.Controls.TextBlock
    $script:dockWidgetSummary.Text = (@($Config.widgets) -join ', ')
    $script:dockWidgetSummary.Foreground = $mutedForeground
    $script:dockWidgetSummary.FontSize = 12
    $script:dockWidgetSummary.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
    $script:dockWidgetSummary.TextWrapping = [System.Windows.TextWrapping]::Wrap
    [void]$root.Children.Add($script:dockWidgetSummary)

    $widgetChoices = New-Object System.Windows.Controls.Button
    $widgetChoices.Content = 'Escolher widgets…'
    $widgetChoices.Background = [System.Windows.Media.Brushes]::Transparent
    $widgetChoices.Foreground = $foreground
    $widgetChoices.BorderBrush = $hover
    $widgetChoices.Cursor = [System.Windows.Input.Cursors]::Hand
    $widgetChoices.Padding = New-Object System.Windows.Thickness(10, 5, 10, 5)
    $widgetChoices.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $widgetChoices.Add_Click({
        Start-WinGodDockWidgetPicker -WidgetState $widgetState -ThemeName $Config.theme
    }.GetNewClosure())
    [void]$root.Children.Add($widgetChoices)

    # ---------- appearance ----------
    Add-PanelLabel -Parent $root -Text 'Aparência' -Size 12.5 -Brush $foreground | Out-Null

    $themeRow = New-Object System.Windows.Controls.StackPanel
    $themeRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    Add-PanelLabel -Parent $themeRow -Text 'Tema:' -Size 12.5 -Brush $mutedForeground | Out-Null
    foreach ($option in @(@('Dark', 'dark'), @('Glass', 'glass'))) {
        $radio = New-Object System.Windows.Controls.RadioButton
        $radio.Content = $option[0]
        $radio.GroupName = 'panelTheme'
        $radio.IsChecked = ($Config.theme -eq $option[1])
        $radio.Margin = New-Object System.Windows.Thickness(6, 0, 6, 0)
        $radio.Foreground = $foreground
        $radio.Tag = $option[1]
        [void]$themeRow.Children.Add($radio)
    }
    [void]$root.Children.Add($themeRow)

    $heightRow = New-Object System.Windows.Controls.StackPanel
    $heightRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    Add-PanelLabel -Parent $heightRow -Text 'Altura:' -Size 12.5 -Brush $mutedForeground | Out-Null
    foreach ($option in @(@('P', 'S'), @('M', 'M'), @('G', 'L'))) {
        $radio = New-Object System.Windows.Controls.RadioButton
        $radio.Content = $option[0]
        $radio.GroupName = 'panelHeight'
        $radio.IsChecked = ($Config.heightKey -eq $option[1])
        $radio.Margin = New-Object System.Windows.Thickness(6, 0, 6, 0)
        $radio.Foreground = $foreground
        $radio.Tag = $option[1]
        [void]$heightRow.Children.Add($radio)
    }
    [void]$root.Children.Add($heightRow)

    $clockToggle = Add-PanelToggle $root 'Relógio em 24h' ([bool]$Config.clock24h)
    $autoHideToggle = Add-PanelToggle $root 'Recolher a barra quando o mouse sai' ([bool]$Config.autoHideBar)
    $fullscreenToggle = Add-PanelToggle $root 'Esconder em fullscreen' ([bool]$Config.fullscreenHide)

    # ---------- pinned apps ----------
    Add-PanelLabel -Parent $root -Text 'Apps pinados' -Size 12.5 -Brush $foreground | Out-Null
    $appList = New-Object System.Windows.Controls.StackPanel
    [void]$root.Children.Add($appList)

    $appListHost = $appList
    function Show-PanelAppRows {
        $appListHost.Children.Clear()
        foreach ($app in $appsState.list) {
            $row = New-Object System.Windows.Controls.StackPanel
            $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
            $row.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)

            $icon = Add-WinGodDockIconSource -FilePath ([string]$app.Path)
            if (-not $icon -and $app.IconPath) {
                $icon = Add-WinGodDockIconSource -FilePath ([string]$app.IconPath)
            }
            if ($icon) {
                $iconImage = New-Object System.Windows.Controls.Image
                $iconImage.Source = $icon
                $iconImage.Width = 18
                $iconImage.Height = 18
                $iconImage.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
                [void]$row.Children.Add($iconImage)
            }

            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = [string]$app.Name
            $label.Foreground = $foreground
            $label.FontSize = 12
            $label.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            $label.ToolTip = [string]$app.Path
            [void]$row.Children.Add($label)

            $spacer = New-Object System.Windows.Controls.Border
            $spacer.Width = 40
            [void]$row.Children.Add($spacer)

            $remove = New-Object System.Windows.Controls.Button
            $remove.Content = '-'
            $remove.Width = 26
            $remove.Background = [System.Windows.Media.Brushes]::Transparent
            $remove.Foreground = $mutedForeground
            $remove.BorderBrush = [System.Windows.Media.Brushes]::Transparent
            $remove.Cursor = [System.Windows.Input.Cursors]::Hand
            $remove.Tag = $app
            $remove.Add_Click({
                param($sender, $eventArgs)
                $target = $sender.Tag
                $appsState.list = @($appsState.list | Where-Object { $_.Name -ne $target.Name })
                Show-PanelAppRows
            }.GetNewClosure())
            [void]$row.Children.Add($remove)
            [void]$appListHost.Children.Add($row)
        }
    }
    Show-PanelAppRows

    $addButton = New-Object System.Windows.Controls.Button
    $addButton.Content = '+ Adicionar app'
    $addButton.Background = [System.Windows.Media.Brushes]::Transparent
    $addButton.Foreground = $foreground
    $addButton.BorderBrush = $hover
    $addButton.Cursor = [System.Windows.Input.Cursors]::Hand
    $addButton.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
    $addButton.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $addButton.Add_Click({
        Start-WinGodDockAppPicker -AppState $appsState -ThemeName $Config.theme
    })
    [void]$root.Children.Add($addButton)

    # ---------- buttons ----------
    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.Margin = New-Object System.Windows.Thickness(0, 14, 0, 0)

    $save = New-Object System.Windows.Controls.Button
    $save.Content = 'Salvar e reiniciar'
    $save.Background = $brushConverter.ConvertFromString('#FF2F4F43')
    $save.Foreground = $foreground
    $save.BorderBrush = [System.Windows.Media.Brushes]::Transparent
    $save.Cursor = [System.Windows.Input.Cursors]::Hand
    $save.Padding = New-Object System.Windows.Thickness(12, 6, 12, 6)
    [void]$buttons.Children.Add($save)

    $closePanel = New-Object System.Windows.Controls.Button
    $closePanel.Content = 'Fechar'
    $closePanel.Background = [System.Windows.Media.Brushes]::Transparent
    $closePanel.Foreground = $mutedForeground
    $closePanel.BorderBrush = [System.Windows.Media.Brushes]::Transparent
    $closePanel.Cursor = [System.Windows.Input.Cursors]::Hand
    $closePanel.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
    $closePanel.Padding = New-Object System.Windows.Thickness(12, 6, 12, 6)
    [void]$buttons.Children.Add($closePanel)
    [void]$root.Children.Add($buttons)

    $save.Add_Click({
        $next = @{
            file           = $Config.file
            heightKey      = 'M'
            theme          = $Config.theme
            clock24h       = [bool]$clockToggle.IsChecked
            widgets        = @($widgetState.list)
            autoHideBar    = [bool]$autoHideToggle.IsChecked
            fullscreenHide = [bool]$fullscreenToggle.IsChecked
            pinnedApps     = $appsState.list
        }
        foreach ($radio in @($themeRow.Children | Where-Object { $_ -is [System.Windows.Controls.RadioButton] })) {
            if ([bool]$radio.IsChecked) { $next.theme = [string]$radio.Tag }
        }
        foreach ($radio in @($heightRow.Children | Where-Object { $_ -is [System.Windows.Controls.RadioButton] })) {
            if ([bool]$radio.IsChecked) { $next.heightKey = [string]$radio.Tag }
        }

        Save-WinGodDockConfig -Config $next

        # restart once this process is gone: watcher waits for run.json removal
        $program = [string]$script:dockProgramPath
        $isExe = $program.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)
        $launchLine = if ($isExe) {
            "Start-Process `"$program`""
        }
        else {
            "Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File', '`"$program`"'"
        }
        $restartScript = (@'
$tries = 0
while ((Test-Path '<RUNFILE>') -and ($tries -lt 40)) { Start-Sleep -Milliseconds 250; $tries++ }
<LAUNCH>
'@).Replace('<RUNFILE>', [string]$script:dockRunFile).Replace('<LAUNCH>', $launchLine)
        Set-Content -Path (Join-Path $script:dockDataRoot 'restart.ps1') -Value $restartScript -Encoding UTF8
        Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:dockDataRoot 'restart.ps1'))

        Write-WinGodLog -Module 'dock' -Event 'dock.panel.saved' -Message 'config saved from panel'
        $script:dockRestartPending = $true
        $script:dockPanelWindow.Close()
        # close the main dock; the restart watcher relaunches once run.json is gone
        $script:dockWindow.Close()
    })

    $closePanel.Add_Click({
        $script:dockPanelWindow.Close()
    })

    # ---------- position above the pill, physical pixels ----------
    $window.Add_ContentRendered({
        param($source, $eventArgs)
        Add-WinGodDockNative
        $interop = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $source
        $handle = $interop.EnsureHandle()

        $r = New-Object WinGodDockNative+RECT
        [void][WinGodDockNative]::GetWindowRect($handle, [ref]$r)
        $panelW = $r.Right - $r.Left
        $panelH = $r.Bottom - $r.Top

        $dockRect = New-Object WinGodDockNative+RECT
        if ($script:dockWindow) {
            $dockInterop = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $script:dockWindow
            $dockHandle = $dockInterop.EnsureHandle()
            [void][WinGodDockNative]::GetWindowRect($dockHandle, [ref]$dockRect)
        }
        else {
            $scale = [uint32][WinGodDockNative]::GetDpiForWindow($handle) / 96.0
            $dockRect.Left = 0
            $dockRect.Right = [int]([System.Windows.SystemParameters]::PrimaryScreenWidth * $scale)
            $dockRect.Bottom = [int]([System.Windows.SystemParameters]::PrimaryScreenHeight * $scale)
            $dockRect.Top = $dockRect.Bottom - 80
        }

        $x = [int][System.Math]::Max(4, [int]($dockRect.Left + (($dockRect.Right - $dockRect.Left - $panelW) / 2.0)))
        $y = [int][System.Math]::Max(4, $dockRect.Top - $panelH - 8)
        $SWP_NOSIZE = 0x1
        $SWP_NOACTIVATE = 0x10
        [void][WinGodDockNative]::SetWindowPos(
            $handle, [IntPtr](-1), $x, $y, $panelW, $panelH,
            ($SWP_NOSIZE -bor $SWP_NOACTIVATE))
    })

    $window.Add_Loaded({
        param($source, $eventArgs)
        Add-WinGodDockNative
        $interop = New-Object System.Windows.Interop.WindowInteropHelper -ArgumentList $source
        $handle = $interop.EnsureHandle()
        $r = New-Object WinGodDockNative+RECT
        [void][WinGodDockNative]::GetWindowRect($handle, [ref]$r)
        $wg = $r.Right - $r.Left
        $hg = $r.Bottom - $r.Top
        $rgn = [WinGodDockNative]::CreateRoundRectRgn(0, 0, $wg + 1, $hg + 1, 18, 18)
        [void][WinGodDockNative]::SetWindowRgn($handle, $rgn, $true)
    })

    $window.Show()
}

function Invoke-WinGodDockInstanceStop {
    <#
        .SYNOPSIS
        Stops a running dock instance and restores the Windows taskbar.
    #>
    $state = Set-WinGodDockRunState -Read
    if (-not $state -or -not $state.pid) {
        Write-Host 'Nenhum dock a correr (run.json ausente ou sem PID).'
        return
    }

    $process = Get-Process -Id $state.pid -ErrorAction SilentlyContinue
    if (-not $process) {
        Write-Host 'O processo do dock já não existe, nada a parar.'
        return
    }

    Stop-Process -Id $state.pid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400

    Write-Host 'Dock parado.' -ForegroundColor Green
    Write-Host 'A restaurar a taskbar do Windows...' -ForegroundColor DarkGray
    Set-WinGodShellTrayHidden -Hidden $false
    Invoke-WinGodTaskbarAutoHide -Disable | Out-Null
}

# ---------- Entrypoint (skipped when dot-sourced, e.g. by the test suite) ----------
if ($MyInvocation.InvocationName -eq '.') { return }

$script:panelPending = [bool]$OpenPanel
$script:dockRestartPending = $false
$script:dockProgramPath = Get-WinGodDockProgramPath

if (-not $NoRunKey -and -not $Stop) {
    Invoke-WinGodDockRunKeyCommand -Register *> $null
}

if ($Stop) {
    try {
        $null = New-WinGodLog -Path (Join-Path $script:dockDataRoot 'logs') -Level 'Info'
        Add-WinGodLogContext -Data @{ phase = 'dock.stop' }
        Invoke-WinGodDockInstanceStop
        Write-WinGodLog -Module 'dock' -Event 'dock.stopped' -Message 'dock stopped by request'
    }
    finally {
        Close-WinGodLog
    }
    exit 0
}

$mutex = New-Object System.Threading.Mutex($false, "wingod-dock-$env:USERNAME")
$acquired = $false
try {
    $acquired = $mutex.WaitOne(0, $false)
}
catch [System.Threading.AbandonedMutexException] {
    $acquired = $true
}

if (-not $acquired) {
    Write-Host 'O dock já está a correr, nada a fazer.'
    [void]$mutex.Dispose()
    exit 0
}

$script:dockConfig = New-WinGodDockConfig -Path $ConfigPath

try {
    $null = New-WinGodLog -Path (Join-Path $script:dockDataRoot 'logs') -Level 'Info'
    Add-WinGodLogContext -Data @{ phase = 'dock' }

    Invoke-WinGodTaskbarAutoHide -Enable *> $null
    Set-WinGodShellTrayHidden -Hidden $true

    Set-WinGodDockRunState -ConfigPath $script:dockConfig.file
    Start-WinGodDockWindow -Config $script:dockConfig
}
finally {
    # a seamless restart keeps both layers applied; the new instance re-applies them
    if (-not $script:dockRestartPending) {
        Set-WinGodShellTrayHidden -Hidden $false
        Invoke-WinGodTaskbarAutoHide -Disable *> $null
    }
    Remove-Item $script:dockRunFile -Force -ErrorAction SilentlyContinue
    Close-WinGodLog
}

exit 0
