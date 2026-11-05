$script:Theme = 'Light'
$script:ThemeDictionary = $null
$script:ThemeAppLevel = $false
$script:PaletteDictionary = $null
$script:SettingsPath = if ($env:APPDATA) { Join-Path -Path $env:APPDATA -ChildPath 'AD-IDM-V2\settings.json' } else { $null }

function Get-InitialTheme {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:ThemePreference -in @('Light', 'Dark')) { return $script:ThemePreference }
    $saved = Read-AppSetting
    if ($saved -and [string]$saved.Theme -in @('Light', 'Dark')) { return [string]$saved.Theme }
    try {
        $value = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        if ([int]$value -eq 0) { return 'Dark' }
    }
    catch { Write-Verbose "Windows tema ayarı okunamadı: $($_.Exception.Message)" }
    return 'Light'
}
function Read-AppSetting {
    [CmdletBinding()]
    [OutputType([psobject])]
    param()
    try {
        if ($script:SettingsPath -and (Test-Path -LiteralPath $script:SettingsPath)) { return (Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    }
    catch { Write-Verbose "Ayar dosyası okunamadı: $($_.Exception.Message)" }
    return $null
}
function Save-AppSetting {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Values)
    try {
        $current = [ordered]@{}
        $existing = Read-AppSetting
        if ($existing) { foreach ($property in $existing.PSObject.Properties) { $current[$property.Name] = $property.Value } }
        foreach ($key in $Values.Keys) { $current[$key] = $Values[$key] }
        $folder = Split-Path -Path $script:SettingsPath -Parent
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop }
        [pscustomobject]$current | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 -ErrorAction Stop
    }
    catch { Write-UiLog -Message "Ayar kaydedilemedi: $($_.Exception.Message)" -Level Warning }
}
function Set-ThemeButton {
    [CmdletBinding()]
    param()
    $button = $script:Ui.btnTheme
    if (-not $button) { return }
    if ($script:Theme -eq 'Dark') {
        $button.Content = [string][char]0xE706
        $button.ToolTip = 'Açık temaya geç (seçim hatırlanır)'
    }
    else {
        $button.Content = [string][char]0xE708
        $button.ToolTip = 'Koyu temaya geç (seçim hatırlanır)'
    }
}
function Initialize-Theme {
    [CmdletBinding()]
    param()
    $script:ThemeDictionary = New-Object -TypeName System.Windows.ResourceDictionary
    $script:ThemeAppLevel = $false
    try {
        $app = [System.Windows.Application]::Current
        if (-not $app) {
            $app = New-Object -TypeName System.Windows.Application
            $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
            $app.Properties['ADIDM'] = $true
        }
        # Başkasının uygulaması (ör. PowerShell ISE) yeniden stillenmesin; o durumda tema pencereye eklenir.
        if ($app.Properties['ADIDM']) {
            $previous = $app.Properties['ADIDM.Theme']
            if ($previous) { [void]$app.Resources.MergedDictionaries.Remove($previous) }
            $app.Resources.MergedDictionaries.Add($script:ThemeDictionary.PSObject.BaseObject)
            $app.Properties['ADIDM.Theme'] = $script:ThemeDictionary.PSObject.BaseObject
            $script:ThemeAppLevel = $true
        }
    }
    catch { Write-Verbose "Uygulama düzeyi tema kullanılamadı: $($_.Exception.Message)" }
    $styles = [System.Windows.Markup.XamlReader]::Parse($script:DesignXaml)
    $script:ThemeDictionary.MergedDictionaries.Add($styles.PSObject.BaseObject)
    Set-AppTheme -Theme (Get-InitialTheme)
}
function Set-AppTheme {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Light', 'Dark')][string]$Theme,
        [Parameter()][switch]$Save
    )
    $palette = ([System.Windows.Markup.XamlReader]::Parse((Read-AppFile -RelativePath "UI\Themes\$Theme.xaml"))).PSObject.BaseObject
    # Eski uyumluluk modunda bu anahtarlar ControlBrushKey / ControlTextBrushKey döner; XAML'de yinelenen anahtar hatası verir.
    foreach ($inactiveKey in @(
            @{ Key = [System.Windows.SystemColors]::InactiveSelectionHighlightBrushKey; Token = 'SurfaceHoverBrush' }
            @{ Key = [System.Windows.SystemColors]::InactiveSelectionHighlightTextBrushKey; Token = 'TextBrush' }
        )) {
        $resourceKey = $inactiveKey.Key.PSObject.BaseObject
        if (-not $palette.Contains($resourceKey)) { $palette.Add($resourceKey, $palette[$inactiveKey.Token]) }
    }
    # DynamicResource bağları sözlük değişince kendiliğinden yenilenir.
    $merged = $script:ThemeDictionary.MergedDictionaries
    if ($script:PaletteDictionary) { [void]$merged.Remove($script:PaletteDictionary) }
    $script:PaletteDictionary = $palette
    $merged.Add($script:PaletteDictionary)
    $script:Theme = $Theme
    if ($script:Window) {
        Set-WindowChrome -Window $script:Window
        foreach ($owned in @($script:Window.OwnedWindows)) { Set-WindowChrome -Window $owned }
    }
    if ($script:Ui -and $script:Ui.ContainsKey('btnTheme') -and $script:Ui.btnTheme) { Set-ThemeButton }
    if ($Save) { Save-AppSetting -Values @{ Theme = $Theme } }
}
function Get-PaletteColorRef {
    # DWM COLORREF biçimi: 0x00BBGGRR
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][string]$Token)
    $color = $script:PaletteDictionary[$Token].Color
    return [int]$color.R + ([int]$color.G -shl 8) + ([int]$color.B -shl 16)
}
