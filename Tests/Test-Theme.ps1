# Çalıştırma: pwsh -NoProfile -File Tests/Test-Theme.ps1  (veya Windows'ta powershell.exe). WPF gerektirmez.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}
function Read-Palette {
    param([string]$Name)
    $text = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath "UI/Themes/$Name.xaml"))
    $palette = @{}
    foreach ($match in [regex]::Matches($text, 'x:Key="(\w+)" Color="(#[0-9A-Fa-f]{6})"')) { $palette[$match.Groups[1].Value] = $match.Groups[2].Value }
    return $palette
}
function Get-RelativeLuminance {
    param([string]$Hex)
    $channels = foreach ($offset in 1, 3, 5) {
        $value = [Convert]::ToInt32($Hex.Substring($offset, 2), 16) / 255.0
        if ($value -le 0.03928) { $value / 12.92 } else { [math]::Pow(($value + 0.055) / 1.055, 2.4) }
    }
    return 0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
}
function Get-ContrastRatio {
    param([string]$First, [string]$Second)
    $a = Get-RelativeLuminance -Hex $First
    $b = Get-RelativeLuminance -Hex $Second
    return ([math]::Max($a, $b) + 0.05) / ([math]::Min($a, $b) + 0.05)
}

$palettes = @{ Light = Read-Palette -Name 'Light'; Dark = Read-Palette -Name 'Dark' }
$lightOnly = @($palettes.Light.Keys | Where-Object { -not $palettes.Dark.ContainsKey($_) })
$darkOnly = @($palettes.Dark.Keys | Where-Object { -not $palettes.Light.ContainsKey($_) })
Assert-True (($lightOnly.Count + $darkOnly.Count) -eq 0) "Açık ve koyu temada aynı adlar var: $($lightOnly + $darkOnly -join ', ')"

$textPairs = @(
    @('TextBrush', 'CanvasBrush'), @('TextBrush', 'SurfaceBrush'), @('TextBrush', 'SurfaceSubtleBrush'), @('TextBrush', 'SurfaceHoverBrush'), @('TextBrush', 'SelectedBrush')
    @('TextMutedBrush', 'CanvasBrush'), @('TextMutedBrush', 'SurfaceBrush'), @('TextMutedBrush', 'SurfaceSubtleBrush'), @('TextMutedBrush', 'SurfaceHoverBrush')
    @('OnAccentBrush', 'AccentBrush'), @('OnAccentBrush', 'AccentHoverBrush'), @('OnAccentBrush', 'AccentPressedBrush')
    @('OnDangerBrush', 'DangerBrush'), @('OnDangerBrush', 'DangerHoverBrush')
    @('AccentTextBrush', 'SurfaceBrush'), @('AccentTextBrush', 'CanvasBrush'), @('AccentTextBrush', 'InfoBgBrush'), @('TextBrush', 'WarningBgBrush')
    @('SuccessBrush', 'SurfaceBrush'), @('WarningBrush', 'SurfaceBrush'), @('DangerBrush', 'SurfaceBrush')
    @('SuccessBrush', 'SuccessBgBrush'), @('WarningBrush', 'WarningBgBrush'), @('DangerBrush', 'DangerBgBrush'), @('TextBrush', 'InfoBgBrush')
    @('ChromeTextBrush', 'ChromeBrush'), @('ChromeTextBrush', 'ChromeRaisedBrush'), @('ChromeTextBrush', 'ChromeHoverBrush'), @('ChromeTextBrush', 'ChromeSelectedBrush')
    @('ChromeMutedBrush', 'ChromeBrush'), @('ChromeMutedBrush', 'ChromeRaisedBrush'), @('ChromeMutedBrush', 'ChromeSelectedBrush')
)
$nonTextPairs = @(
    @('ControlLineBrush', 'SurfaceBrush'), @('ControlLineBrush', 'CanvasBrush'), @('AccentBrush', 'SurfaceBrush'), @('AccentTextBrush', 'SelectedBrush')
    @('ChromeAccentBrush', 'ChromeSelectedBrush'), @('ChromeAccentBrush', 'ChromeBrush'), @('StatusNeutralBrush', 'SurfaceBrush'), @('StatusNeutralBrush', 'ChromeRaisedBrush'), @('ChromeSuccessBrush', 'ChromeRaisedBrush'), @('ChromeWarningBrush', 'ChromeRaisedBrush'), @('ChromeDangerBrush', 'ChromeRaisedBrush')
)
foreach ($themeName in 'Light', 'Dark') {
    $palette = $palettes[$themeName]
    foreach ($pair in $textPairs) {
        $ratio = Get-ContrastRatio -First $palette[$pair[0]] -Second $palette[$pair[1]]
        Assert-True ($ratio -ge 4.5) ('{0} metin {1} / {2}: {3:N2}' -f $themeName, $pair[0], $pair[1], $ratio)
    }
    foreach ($pair in $nonTextPairs) {
        $ratio = Get-ContrastRatio -First $palette[$pair[0]] -Second $palette[$pair[1]]
        Assert-True ($ratio -ge 3.0) ('{0} denetim {1} / {2}: {3:N2}' -f $themeName, $pair[0], $pair[1], $ratio)
    }
}

foreach ($themeName in 'Light', 'Dark') {
    $paletteSource = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath "UI/Themes/$themeName.xaml"))
    Assert-True ($paletteSource -notmatch 'InactiveSelectionHighlight') "$themeName`: uyumluluk modunda yinelenen sistem anahtarı yok"
}

$stylesText = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/Styles.xaml'))
$windowText = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/MainWindow.xaml'))
$dialogFiles = @(Get-ChildItem -Path (Join-Path -Path $projectRoot -ChildPath 'UI/Dialogs') -Filter '*.xaml')
$dialogText = ($dialogFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
$scriptText = (Get-ChildItem -Path (Join-Path -Path $projectRoot -ChildPath 'UI') -Filter '*.ps1' -Recurse | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
$hardcodedInStyles = @([regex]::Matches($stylesText, '#[0-9A-Fa-f]{6,8}') | ForEach-Object { $_.Value } | Where-Object { $_ -ne '#000000' })
Assert-True ($hardcodedInStyles.Count -eq 0) "Styles.xaml içinde sabit renk yok: $($hardcodedInStyles -join ', ')"
$hardcodedInWindow = @([regex]::Matches($windowText + $dialogText, '(Background|Foreground|BorderBrush|Fill|Stroke)="(#|White|Black)[^"]*"') | ForEach-Object { $_.Value })
Assert-True ($hardcodedInWindow.Count -eq 0) "Pencerelerde sabit renk yok: $($hardcodedInWindow -join ', ')"
$hardcodedSetters = @([regex]::Matches($windowText + $dialogText, 'Property="(Background|Foreground|BorderBrush|Fill|Stroke)" Value="#[^"]*"') | ForEach-Object { $_.Value })
Assert-True ($hardcodedSetters.Count -eq 0) "Tetikleyicilerde sabit renk yok: $($hardcodedSetters -join ', ')"
$hardcodedInScripts = @([regex]::Matches($scriptText, "'#[0-9A-Fa-f]{6}'") | ForEach-Object { $_.Value })
Assert-True ($hardcodedInScripts.Count -eq 0) "UI betiklerinde sabit renk yok: $($hardcodedInScripts -join ', ')"

$colorResources = @([regex]::Matches($stylesText + $windowText + $dialogText + $scriptText, '(\w+Brush)\b') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -cmatch '^[A-Z]' -and $_ -notin 'BorderBrush', 'CaretBrush', 'SelectionBrush', 'ImageBrush', 'HorizontalGridLinesBrush', 'VerticalGridLinesBrush' } | Select-Object -Unique)
$missingColors = @($colorResources | Where-Object { -not $palettes.Light.ContainsKey($_) })
Assert-True ($missingColors.Count -eq 0) "Kullanılan tüm renk adları tanımlı: $($missingColors -join ', ')"
# ---- Yerleşim
[xml]$windowDocument = $windowText
$namesInWindow = @([regex]::Matches($windowText, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
foreach ($removedName in 'bdStatus', 'colStatus', 'expLog', 'dpHeader', 'rowMainBottom') { Assert-True ($removedName -notin $namesInWindow) "Eski yerleşim kaldırıldı: $removedName" }
Assert-True ($windowText -match 'x:Name="bdRail"[^>]*ChromePane') 'Simge şeridi koyu şerit stilini kullanır'
$shellText = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/Shell.ps1'))
$groupedTabs = @([regex]::Matches(([regex]::Match($shellText, '(?s)\$script:TabGroups = \[ordered\]@\{.*?\n\}').Value), "'(tab\w+)'") | ForEach-Object { $_.Groups[1].Value })
$windowTabs = @($namesInWindow | Where-Object { $_ -cmatch '^tab[A-Z]' -and $_ -ne 'tabMain' -and $_ -notlike 'tabSet*' })
Assert-True ($groupedTabs.Count -eq 10 -and @($windowTabs | Where-Object { $_ -notin $groupedTabs }).Count -eq 0) "10 sekmenin hepsi bir grupta ($($groupedTabs.Count))"
$pageTargets = @([regex]::Matches(([regex]::Match($shellText, '\$script:Pages = @\{.*?\}').Value), "(nav\w+) = '(page\w+)'"))
Assert-True ($pageTargets.Count -eq 6 -and @($pageTargets | Where-Object { $_.Groups[1].Value -notin $namesInWindow -or $_.Groups[2].Value -notin $namesInWindow }).Count -eq 0) "6 sayfa ve gezinme düğmesi eşleşir ($($pageTargets.Count))"
$lastLogonIndex = $windowText.IndexOf('x:Name="txtLastLogon"')
$passwordIndex = $windowText.IndexOf('x:Name="txtPwdExpire"')
$datesText = [regex]::Match($windowText, '(?s)x:Name="pnlProfileDates".*?</Grid>').Value
Assert-True ($lastLogonIndex -lt $passwordIndex -and $datesText.Contains('txtLastLogon') -and $datesText.Contains('txtPwdExpire') -and $datesText -match 'Grid\.Row="1" Grid\.Column="1"') 'Son oturum ve parola bitiş alt alta'

# ---- Ayarlar menüsü
$settingsText = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/Handlers/Settings.ps1'))
$settingsTabs = @([regex]::Matches(([regex]::Match($shellText, '(?s)\$script:SettingsTabGroups = \[ordered\]@\{.*?\n\}').Value), "'(tabSet\w+)'") | ForEach-Object { $_.Groups[1].Value })
Assert-True ($settingsTabs.Count -eq 7 -and @($settingsTabs | Where-Object { $_ -notin $namesInWindow }).Count -eq 0) "Ayarlarda 7 sekme gruplanır ($($settingsTabs.Count))"
$expectedSettingsHeaders = 'Sunucu', 'Outsource Bilgilendirme', 'İzin Raporu', 'Servis', 'Telefon', 'Mesajlar', 'Şifre'
$settingsHeaders = @([regex]::Matches($windowText, 'x:Name="tabSet\w+" Header="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
Assert-True (($settingsHeaders -join '|') -ceq ($expectedSettingsHeaders -join '|')) "Ayarlar başlıkları istenen sırada: $($settingsHeaders -join ', ')"
foreach ($passwordField in 'PasswordLength', 'PasswordSymbols', 'AllowManualPassword') { Assert-True ($settingsText -match "@\('Password', 'Sms', '$passwordField'") "$passwordField Şifre sekmesinde" }
foreach ($panelName in 'pnlSetSmtp', 'pnlSetOutsource', 'pnlSetLeave', 'pnlSetSmsService', 'pnlSetSmsPhone', 'pnlSetSmsMessages', 'pnlSetPassword') { Assert-True ($panelName -in $namesInWindow -and $settingsText.Contains($panelName)) "$panelName bağlı" }
$panelKeys = @([regex]::Matches(([regex]::Match($settingsText, '\$panels = @\{.*?\}').Value), '(\w+) = \$c\.') | ForEach-Object { $_.Groups[1].Value })
$fieldTabs = @([regex]::Matches($settingsText, "@\('(\w+)', '(?:Mail|Sms)', '[\w.]+',") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
Assert-True (@($fieldTabs | Where-Object { $_ -notin $panelKeys }).Count -eq 0) "Her alan bir panele gider: $($fieldTabs -join ', ')"

# ---- Açıklama metni ait olduğu kutuya yapışık olmalı
$inputTypes = 'TextBox', 'PasswordBox', 'DatePicker', 'ComboBox'
function Get-InputGapViolation {
    param([System.Xml.XmlNode]$Node, [string]$FileName)
    $previous = $null
    foreach ($child in @($Node.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
        if ($previous -and $previous.LocalName -in $inputTypes -and $child.LocalName -eq 'TextBlock' -and $child.GetAttribute('Style') -match 'HintText') {
            $inputMargin = $previous.GetAttribute('Margin')
            $hintMargin = $child.GetAttribute('Margin')
            # Margin yazılmamış TextBox/PasswordBox/DatePicker stilden 14 birim alt boşluk alır.
            $inputBottom = if ($inputMargin) { [double]($inputMargin -split ',')[-1] } elseif ($previous.LocalName -eq 'ComboBox') { 0 } else { 14 }
            $hintTop = if ($hintMargin -and ($hintMargin -split ',').Count -eq 4) { [double]($hintMargin -split ',')[1] } elseif ($hintMargin) { [double]$hintMargin } else { 0 }
            if (($inputBottom + $hintTop) -gt 8) { "$FileName`: $($previous.GetAttribute('Name')) (boşluk $($inputBottom + $hintTop))" }
        }
        Get-InputGapViolation -Node $child -FileName $FileName
        $previous = $child
    }
}
$gapViolations = @(foreach ($xamlFile in @(Get-Item -LiteralPath (Join-Path -Path $projectRoot -ChildPath 'UI/MainWindow.xaml')) + $dialogFiles) {
        $document = New-Object -TypeName System.Xml.XmlDocument
        $document.LoadXml([System.IO.File]::ReadAllText($xamlFile.FullName))
        Get-InputGapViolation -Node $document.DocumentElement -FileName $xamlFile.Name
    })
Assert-True ($gapViolations.Count -eq 0) "Kutu ile açıklaması arasında geniş boşluk yok: $($gapViolations -join '; ')"
Assert-True ($settingsText -match '\(\$field\.Hint\) \{ 3 \}' -and $settingsText -match '\$hint\.Margin = \[System\.Windows\.Thickness\]::new\(0, 0, 0, 14\)') 'Ayarlar alanlarında açıklama kutuya yapışık'

# ---- Gerçek WPF yüklemesi (yalnızca Windows, STA)
if ($env:OS -eq 'Windows_NT' -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA) {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $root = New-Object -TypeName System.Windows.ResourceDictionary
    $root.MergedDictionaries.Add(([System.Windows.Markup.XamlReader]::Parse($stylesText)).PSObject.BaseObject)
    foreach ($themeName in 'Light', 'Dark') {
        $paletteText = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath "UI/Themes/$themeName.xaml"))
        $paletteDictionary = ([System.Windows.Markup.XamlReader]::Parse($paletteText)).PSObject.BaseObject
        $root.MergedDictionaries.Add($paletteDictionary)
        $window = [System.Windows.Markup.XamlReader]::Parse($windowText)
        $window.Resources.MergedDictionaries.Add($root)
        $window.ShowInTaskbar = $false
        $window.WindowStartupLocation = 'Manual'
        $window.Left = -32000
        $window.Show()
        $window.UpdateLayout()
        $mainTabs = $window.FindName('tabMain')
        Assert-True ($mainTabs.Items.Count -eq 10) "WPF ${themeName}: pencere yüklenir, 10 sekme"
        Assert-True ($window.FindName('bdRail').Background.Color.ToString().Substring(3) -eq $palettes[$themeName].ChromeBrush.Substring(1)) "WPF ${themeName}: sol şerit tema rengini alır"
        foreach ($tab in $mainTabs.Items) { $tab.Visibility = 'Visible'; $mainTabs.SelectedItem = $tab; $window.UpdateLayout() }
        foreach ($pageName in 'pageLeave', 'pagePst', 'pageDisabled', 'pageReports', 'pageSettings') { $window.FindName($pageName).Visibility = 'Visible'; $window.UpdateLayout(); $window.FindName($pageName).Visibility = 'Collapsed' }
        Assert-True $true "WPF ${themeName}: tüm sekmeler çizilir"
        foreach ($dialogFile in $dialogFiles) {
            $dialog = [System.Windows.Markup.XamlReader]::Parse([System.IO.File]::ReadAllText($dialogFile.FullName))
            $dialog.Resources.MergedDictionaries.Add($root)
            $dialog.ShowInTaskbar = $false
            $dialog.WindowStartupLocation = 'Manual'
            $dialog.Left = -32000
            $dialog.Show()
            $dialog.UpdateLayout()
            Assert-True $true "WPF ${themeName}: $($dialogFile.Name) çizilir"
            $dialog.Close()
            [void]$dialog.Resources.MergedDictionaries.Remove($root)
        }
        $window.Close()
        $window.Resources.MergedDictionaries.Remove($root) | Out-Null
        [void]$root.MergedDictionaries.Remove($paletteDictionary)
    }
}
else { Write-Host 'SKIP  Gerçek WPF yüklemesi (yalnızca Windows, STA)' }

Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
