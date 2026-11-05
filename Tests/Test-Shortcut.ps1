# Çalıştırma: pwsh -NoProfile -File Tests/Test-Shortcut.ps1  (veya Windows'ta powershell.exe). Masaüstüne yazmaz, yönetici izni istemez.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}
. (Join-Path -Path $projectRoot -ChildPath 'Core/Elevation.ps1')

# ---- Yeniden başlatma argümanları
$arguments = @(Get-RelaunchArgument -ScriptPath 'C:\Yol Var\Start-ADIDM.ps1' -ExecutionPolicy 'RemoteSigned' -Parameters ([ordered]@{ Theme = 'Dark'; LogPath = 'C:\Log Dizini\a.log'; Verbose = [System.Management.Automation.SwitchParameter]::new($true); Debug = [System.Management.Automation.SwitchParameter]::new($false); ExchangeServer = 'ex"01' }))
Assert-True (($arguments[0..4] -join ' ') -eq '-NoProfile -ExecutionPolicy RemoteSigned -STA -File') 'Yürütme ilkesi ve STA taşınır'
Assert-True ($arguments[5] -eq '"C:\Yol Var\Start-ADIDM.ps1"') 'Boşluklu betik yolu tırnaklanır'
Assert-True (($arguments -join ' ') -match '-Theme "Dark"' -and ($arguments -join ' ') -match '-LogPath "C:\\Log Dizini\\a\.log"') 'Değerli parametreler taşınır'
Assert-True ($arguments -contains '-Verbose' -and $arguments -notcontains 'True' -and $arguments -notcontains '-Debug') 'Anahtar parametre değer almadan taşınır, kapalısı atlanır'
Assert-True ($arguments -contains '"ex\"01"') 'Değerdeki tırnak kaçırılır'

# ---- Yönetici bayrağı
$linkBytes = New-Object -TypeName byte[] -ArgumentList 80
$linkBytes[0] = 0x4C
$linkBytes[0x15] = 0x01
$flagged = Set-ShortcutRunAsAdministrator -Bytes $linkBytes
Assert-True ($flagged[0x15] -eq 0x21 -and $flagged.Length -eq 80) 'Kısayolda yönetici biti açılır, diğer bitler korunur'
$rejected = $null
try { [void](Set-ShortcutRunAsAdministrator -Bytes (New-Object -TypeName byte[] -ArgumentList 80)) } catch { $rejected = $_.Exception.Message }
Assert-True ($rejected -match 'Geçerli') 'Kısayol olmayan dosya reddedilir'

# ---- Simge
$iconPath = Join-Path -Path $projectRoot -ChildPath 'Assets/AD-IDM.ico'
$icon = [System.IO.File]::ReadAllBytes($iconPath)
$entryCount = [BitConverter]::ToUInt16($icon, 4)
Assert-True ($icon[0] -eq 0 -and $icon[2] -eq 1 -and $entryCount -eq 6) 'ICO başlığı geçerli, 6 boyut'
$iconSizes = @(for ($index = 0; $index -lt $entryCount; $index++) { $size = $icon[6 + 16 * $index]; if ($size -eq 0) { 256 } else { [int]$size } })
Assert-True (($iconSizes -contains 256) -and ($iconSizes -contains 32) -and ($iconSizes -contains 16)) "Masaüstü boyutları var: $($iconSizes -join ',')"
$frameOffset = [BitConverter]::ToUInt32($icon, 6 + 12)
Assert-True ($icon[$frameOffset] -eq 0x89 -and $icon[$frameOffset + 1] -eq 0x50) 'Kare verisi PNG'

# ---- Açılış sırası
$startText = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'Start-ADIDM.ps1'))
$elevationIndex = $startText.IndexOf('Test-IsAdministrator')
foreach ($headless in 'exit (Invoke-LeaveCheck', 'Install-LeaveTask -Account', 'exit (Invoke-NewUserTest', 'exit (Invoke-MailTest', 'Install-DesktopShortcut') {
    Assert-True ($startText.IndexOf($headless) -gt 0 -and $startText.IndexOf($headless) -lt $elevationIndex) "Yükseltme öncesi çalışır: $headless"
}
Assert-True ($elevationIndex -lt $startText.IndexOf('Start-MainWindow')) 'Arayüz yükseltme kontrolünden sonra açılır'
Assert-True ($startText -match "Verb = 'RunAs'|Verb RunAs") 'Yönetici değilse RunAs ile yeniden başlar'

# ---- Panelden oluşturma
$settingsText = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/Handlers/Settings.ps1'))
$windowText = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/MainWindow.xaml'))
$pageStart = $windowText.IndexOf('x:Name="pageSettings"')
Assert-True ($pageStart -ge 0 -and $windowText.IndexOf('x:Name="btnSetShortcut"') -gt $pageStart) 'Kısayol düğmesi Ayarlar sayfasında'
Assert-True ($settingsText -match 'btnSetShortcut\.Add_Click\(\{ Invoke-UiAction \{ Start-DesktopShortcutInstall') 'Düğme işleve bağlı'
$messages = @{}
function Install-DesktopShortcut { if ($script:FailShortcut) { throw 'erişim reddedildi' } 'C:\Masaustu\AD-IDM.lnk' }
function Write-UiLog { param($Message, $Level) $script:LoggedLevel = $Level }
function Invoke-ShortcutHandler {
    $definition = [regex]::Match($settingsText, '(?s)function Start-DesktopShortcutInstall \{.*?\n\}\n').Value
    . ([scriptblock]::Create($definition))
    $script:Ui = @{ txtSetMessage = [pscustomobject]@{ Text = '' } }
    Start-DesktopShortcutInstall
}
$script:FailShortcut = $false
Invoke-ShortcutHandler
Assert-True ($script:Ui.txtSetMessage.Text -match 'AD-IDM\.lnk' -and $script:LoggedLevel -eq 'Success') 'Başarı sayfada ve günlükte gösterilir'
$script:FailShortcut = $true
Invoke-ShortcutHandler
Assert-True ($script:Ui.txtSetMessage.Text -match 'erişim reddedildi' -and $script:LoggedLevel -eq 'Error') 'Hata uygulamayı düşürmez, gösterilir'

Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
