$script:Layout = @{ MinWidth = 640; MinHeight = 520; Mode = $null; Density = $null; PaneOpen = $true }
$script:UiScaleSetting = 'Auto'
$script:UiScale = 1.0
$script:UiScaleSteps = [double[]](0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0)
$script:NativeReady = $false
function Initialize-NativeMethod {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($script:NativeReady) { return $true }
    try {
        if (-not ('ADEUM.NativeUi' -as [type])) {
            $definition = @'
[DllImport("user32.dll", SetLastError = true)] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
'@
            Add-Type -Namespace 'ADEUM' -Name 'NativeUi' -MemberDefinition $definition -ErrorAction Stop
        }
        $script:NativeReady = $true
    }
    catch {
        Write-Verbose "Yerel arayüz çağrıları kullanılamıyor: $($_.Exception.Message)"
        $script:NativeReady = $false
    }
    return $script:NativeReady
}
function Initialize-DpiAwareness {
    [CmdletBinding()]
    param()
    $wpfLoaded = @([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'PresentationCore' }).Count -gt 0
    if ($wpfLoaded) {
        Write-Verbose 'WPF bu süreçte zaten yüklü (ör. ISE); DPI farkındalığı değiştirilmedi.'
        return
    }
    try {
        [System.AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
        if (-not (Initialize-NativeMethod)) { return }
        $perMonitorV2 = New-Object -TypeName System.IntPtr -ArgumentList (-4)
        if ([ADEUM.NativeUi]::SetProcessDpiAwarenessContext($perMonitorV2)) { Write-Verbose 'DPI farkındalığı: Per-Monitor V2.' }
        else { Write-Verbose "DPI farkındalığı değiştirilemedi (Win32 hata $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())); süreç ayarı korunuyor." }
    }
    catch { Write-Verbose "DPI farkındalığı ayarlanamadı: $($_.Exception.Message)" }
}
function Set-WindowChrome {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Windows.Window]$Window)
    if (-not $script:NativeReady) { return }
    try {
        $handle = (New-Object -TypeName System.Windows.Interop.WindowInteropHelper -ArgumentList $Window).Handle
        if ($handle -eq [IntPtr]::Zero) { return }
        # Başlık çubuğu her iki temada koyu şeritle birleşir.
        $dark = 1
        if ([ADEUM.NativeUi]::DwmSetWindowAttribute($handle, 20, [ref]$dark, 4) -ne 0) { [void][ADEUM.NativeUi]::DwmSetWindowAttribute($handle, 19, [ref]$dark, 4) }
        foreach ($pair in @(@(35, 'ChromeBrush'), @(36, 'ChromeTextBrush'))) {
            $colorRef = Get-PaletteColorRef -Token $pair[1]
            [void][ADEUM.NativeUi]::DwmSetWindowAttribute($handle, $pair[0], [ref]$colorRef, 4)
        }
    }
    catch { Write-Verbose "Başlık çubuğu teması uygulanamadı: $($_.Exception.Message)" }
}
function Get-WorkAreaSize {
    [CmdletBinding()]
    [OutputType([System.Windows.Rect])]
    param()
    return [System.Windows.SystemParameters]::WorkArea
}
function Get-AutoUiScale {
    [CmdletBinding()]
    [OutputType([double])]
    param()
    $area = Get-WorkAreaSize
    $width = $area.Width
    $height = $area.Height
    if ($width -ge 3400 -and $height -ge 1800) { return 1.5 }
    if ($width -ge 2800 -and $height -ge 1500) { return 1.25 }
    if ($width -ge 2300 -and $height -ge 1250) { return 1.1 }
    return 1.0
}
function Initialize-UiScale {
    [CmdletBinding()]
    param()
    $saved = Read-AppSetting
    $setting = 'Auto'
    if ($saved -and $saved.PSObject.Properties['UiScale']) {
        $raw = [string]$saved.UiScale
        $number = 0.0
        if ($raw -ne 'Auto' -and [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -ge 0.8 -and $number -le 2.0) {
            $setting = $number
        }
    }
    $script:UiScaleSetting = $setting
    $script:UiScale = if ($setting -eq 'Auto') { Get-AutoUiScale } else { [double]$setting }
}
function Set-WindowScale {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Windows.Window]$Window)
    $content = $Window.Content
    if ($content -isnot [System.Windows.FrameworkElement]) { return }
    if ([math]::Abs($script:UiScale - 1.0) -lt 0.001) {
        $content.LayoutTransform = [System.Windows.Media.Transform]::Identity
    }
    else {
        $transform = New-Object -TypeName System.Windows.Media.ScaleTransform -ArgumentList $script:UiScale, $script:UiScale
        $transform.Freeze()
        $content.LayoutTransform = $transform
    }
}
function Initialize-DialogBound {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Windows.Window]$Window)
    $area = Get-WorkAreaSize
    $maxWidth = [math]::Floor($area.Width * 0.96)
    $maxHeight = [math]::Floor($area.Height * 0.96)
    $scale = $script:UiScale
    foreach ($name in 'Width', 'MinWidth') {
        $value = $Window.$name
        if (-not [double]::IsNaN($value) -and $value -gt 0) { $Window.$name = [math]::Min($maxWidth, [math]::Round($value * $scale)) }
    }
    foreach ($name in 'Height', 'MinHeight') {
        $value = $Window.$name
        if (-not [double]::IsNaN($value) -and $value -gt 0) { $Window.$name = [math]::Min($maxHeight, [math]::Round($value * $scale)) }
    }
    $limit = $Window.MaxHeight
    $Window.MaxHeight = if ([double]::IsInfinity($limit) -or [double]::IsNaN($limit)) { $maxHeight } else { [math]::Min($maxHeight, [math]::Round($limit * $scale)) }
}
function Set-UiScale {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)
    $steps = $script:UiScaleSteps
    switch ($Value) {
        'Auto' { $script:UiScaleSetting = 'Auto'; $script:UiScale = Get-AutoUiScale }
        'Up' {
            $next = @($steps | Where-Object { $_ -gt $script:UiScale + 0.001 } | Select-Object -First 1)
            if ($next.Count -eq 0) { return }
            $script:UiScaleSetting = $next[0]; $script:UiScale = $next[0]
        }
        'Down' {
            $next = @($steps | Where-Object { $_ -lt $script:UiScale - 0.001 } | Select-Object -Last 1)
            if ($next.Count -eq 0) { return }
            $script:UiScaleSetting = $next[0]; $script:UiScale = $next[0]
        }
        default {
            $number = [double]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
            $number = [math]::Max(0.8, [math]::Min(2.0, $number))
            $script:UiScaleSetting = $number; $script:UiScale = $number
        }
    }
    if ($script:Window) {
        Set-WindowScale -Window $script:Window
        foreach ($owned in @($script:Window.OwnedWindows)) { Set-WindowScale -Window $owned }
        Update-RootSize
    }
    Update-ScaleView
    $saveValue = if ($script:UiScaleSetting -eq 'Auto') { 'Auto' } else { ([double]$script:UiScaleSetting).ToString([System.Globalization.CultureInfo]::InvariantCulture) }
    Save-AppSetting -Values @{ UiScale = $saveValue }
    if ($script:Ui -and $script:Ui.ContainsKey('txtStatus')) { $script:Ui.txtStatus.Text = 'Arayüz ölçeği: %{0}{1}' -f [int][math]::Round($script:UiScale * 100), $(if ($script:UiScaleSetting -eq 'Auto') { ' (otomatik)' } else { '' }) }
}
function Update-ScaleView {
    [CmdletBinding()]
    param()
    $ui = $script:Ui
    if (-not $ui -or -not $ui.ContainsKey('txtScaleValue')) { return }
    $ui.txtScaleValue.Text = '%{0}' -f [int][math]::Round($script:UiScale * 100)
    $script:Layout.ScaleSync = $true
    try { $ui.chkScaleAuto.IsChecked = ($script:UiScaleSetting -eq 'Auto') }
    finally { $script:Layout.ScaleSync = $false }
    $area = Get-WorkAreaSize
    $ui.txtScaleInfo.Text = 'Çalışma alanı {0} x {1} (Windows ölçeği sonrası). Otomatik öneri: %{2}' -f [int]$area.Width, [int]$area.Height, [int][math]::Round((Get-AutoUiScale) * 100)
    $ui.btnScaleDown.IsEnabled = $script:UiScale -gt ($script:UiScaleSteps[0] + 0.001)
    $ui.btnScaleUp.IsEnabled = $script:UiScale -lt ($script:UiScaleSteps[-1] - 0.001)
}
function Initialize-WindowSize {
    [CmdletBinding()]
    param()
    $window = $script:Window
    $workArea = Get-WorkAreaSize
    $saved = Read-AppSetting
    $placement = if ($saved -and $saved.PSObject.Properties['Window']) { $saved.Window } else { $null }
    $restored = $false
    if ($placement) {
        try {
            $left = [double]$placement.Left; $top = [double]$placement.Top
            $width = [double]$placement.Width; $height = [double]$placement.Height
            $screen = New-Object -TypeName System.Windows.Rect -ArgumentList ([System.Windows.SystemParameters]::VirtualScreenLeft), ([System.Windows.SystemParameters]::VirtualScreenTop), ([System.Windows.SystemParameters]::VirtualScreenWidth), ([System.Windows.SystemParameters]::VirtualScreenHeight)
            $titleBar = New-Object -TypeName System.Windows.Rect -ArgumentList ($left + 40), $top, ([math]::Max(1, [math]::Min(120, $width - 80))), 40
            if ($width -ge $window.MinWidth -and $height -ge $window.MinHeight -and $screen.Contains($titleBar)) {
                $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
                $window.Left = $left; $window.Top = $top; $window.Width = $width; $window.Height = $height
                if ([bool]$placement.Maximized) { $window.WindowState = [System.Windows.WindowState]::Maximized }
                $restored = $true
            }
        }
        catch { Write-Verbose "Kayıtlı pencere konumu kullanılamadı: $($_.Exception.Message)" }
    }
    if (-not $restored) {
        $scale = $script:UiScale
        $window.Width = [math]::Min(1380 * $scale, [math]::Floor($workArea.Width * 0.95))
        $window.Height = [math]::Min(920 * $scale, [math]::Floor($workArea.Height * 0.95))
        if ($workArea.Width -lt 1400 * $scale -or $workArea.Height -lt 860 * $scale) {
            $window.WindowState = [System.Windows.WindowState]::Maximized
        }
    }
}
function Save-WindowPlacement {
    [CmdletBinding()]
    param()
    try {
        $window = $script:Window
        $bounds = if ($window.WindowState -eq [System.Windows.WindowState]::Normal) { New-Object -TypeName System.Windows.Rect -ArgumentList $window.Left, $window.Top, $window.ActualWidth, $window.ActualHeight } else { $window.RestoreBounds }
        if ($bounds.IsEmpty -or $bounds.Width -le 0) { return }
        Save-AppSetting -Values @{ Window = [ordered]@{
                Left      = [math]::Round($bounds.Left)
                Top       = [math]::Round($bounds.Top)
                Width     = [math]::Round($bounds.Width)
                Height    = [math]::Round($bounds.Height)
                Maximized = ($window.WindowState -eq [System.Windows.WindowState]::Maximized)
            }
        }
    }
    catch { Write-Verbose "Pencere konumu kaydedilemedi: $($_.Exception.Message)" }
}
function Update-RootSize {
    [CmdletBinding()]
    param()
    $viewer = $script:Ui.svRoot
    $viewportWidth = if ($viewer.ViewportWidth -gt 0) { $viewer.ViewportWidth } else { $viewer.ActualWidth }
    $viewportHeight = if ($viewer.ViewportHeight -gt 0) { $viewer.ViewportHeight } else { $viewer.ActualHeight }
    if ($viewportWidth -le 0 -or $viewportHeight -le 0) { return }
    $width = [math]::Max($script:Layout.MinWidth, $viewportWidth)
    $height = [math]::Max($script:Layout.MinHeight, $viewportHeight)
    if ($script:Ui.grdRoot.Width -ne $width) { $script:Ui.grdRoot.Width = $width }
    if ($script:Ui.grdRoot.Height -ne $height) { $script:Ui.grdRoot.Height = $height }
    Update-ResponsiveLayout -Width $width -Height $height
}
function New-Thickness {
    [CmdletBinding()]
    [OutputType([System.Windows.Thickness])]
    param([Parameter(Mandatory = $true)][double[]]$Value)
    if ($Value.Count -eq 1) { return New-Object -TypeName System.Windows.Thickness -ArgumentList $Value[0] }
    return New-Object -TypeName System.Windows.Thickness -ArgumentList $Value[0], $Value[1], $Value[2], $Value[3]
}
function Set-SidePane {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Open)
    $script:Layout.PaneOpen = $Open
    if ($script:Layout.Mode -ne 'Compact') { return }
    $ui = $script:Ui
    $ui.bdResults.Visibility = if ($Open) { 'Visible' } else { 'Collapsed' }
    $ui.colResults.Width = New-Object -TypeName System.Windows.GridLength -ArgumentList $(if ($Open) { 260 } else { 0 })
    $ui.btnPane.Content = if ($Open) { [string][char]0xE76B } else { [string][char]0xE700 }
}
function Update-ResponsiveLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][double]$Width,
        [Parameter(Mandatory = $true)][double]$Height
    )
    $ui = $script:Ui
    $density = if ($Width -ge 1100) { 'Full' } else { 'Icons' }
    if ($density -ne $script:Layout.Density) {
        $script:Layout.Density = $density
        $pillText = if ($density -eq 'Full') { 'Visible' } else { 'Collapsed' }
        $ui.txtAdStatus.Visibility = $pillText
        $ui.txtExStatus.Visibility = $pillText
        $dotMargin = if ($density -eq 'Full') { New-Thickness 0, 0, 8, 0 } else { New-Thickness 0 }
        $ui.elAd.Margin = $dotMargin
        $ui.elEx.Margin = $dotMargin
        $ui.txtSearch.Width = if ($density -eq 'Full') { 380 } else { 220 }
    }
    $mode = if ($Width -ge 1500) { 'Wide' } elseif ($Width -ge 900) { 'Medium' } else { 'Compact' }
    if ($mode -ne $script:Layout.Mode) {
        $previous = $script:Layout.Mode
        $script:Layout.Mode = $mode
        $ui.btnPane.Visibility = if ($mode -eq 'Compact') { 'Visible' } else { 'Collapsed' }
        if ($mode -eq 'Compact') { Set-SidePane -Open (-not $script:State.CurrentData) }
        else {
            $ui.bdResults.Visibility = 'Visible'
            $ui.colResults.Width = New-Object -TypeName System.Windows.GridLength -ArgumentList $(if ($mode -eq 'Wide') { 320 } else { 260 })
        }
        Write-Verbose "Yerleşim modu: $previous -> $mode ($([int]$Width)x$([int]$Height), ölçek %$([int]($script:UiScale * 100)))"
    }
    $logHeight = if ($Height -ge 1200) { 240 } elseif ($Height -ge 820) { 160 } else { 100 }
    if ($ui.lstLog.Height -ne $logHeight) { $ui.lstLog.Height = $logHeight }
}
