function Update-ProfileDeviceView {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Data)
    $c = $script:Ui
    $devices = @($Data.PSObject.Properties['Devices'] | ForEach-Object { $_.Value } | Where-Object { $_ })
    $c.lstDevices.ItemsSource = $devices
    $deviceError = if ($Data.PSObject.Properties['DevicesError']) { [string]$Data.DevicesError } else { '' }
    $c.txtDevicesStatus.Text = if ($deviceError) { "Cihazlar okunamadı: $deviceError" }
    elseif ($devices.Count -eq 0) { 'Eşleşen cihaz yok.' }
    else { "$($devices.Count) cihaz. Kaynak: Ad kuralı = bilgisayar adından, Elle = managedBy ile bağlı." }
    $c.btnDeviceUnlink.IsEnabled = $false
    $c.lstDeviceSearch.ItemsSource = $null
    $c.lstDeviceSearch.Visibility = 'Collapsed'
    $c.btnDeviceLink.IsEnabled = $false
}
function Update-DeviceButtonState {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $selected = $c.lstDevices.SelectedItem
    $c.btnDeviceUnlink.IsEnabled = [bool]($selected -and $selected.Source -in 'Elle', 'İkisi')
    $c.btnDeviceLink.IsEnabled = [bool]($c.lstDeviceSearch.SelectedItem -and $script:State.CurrentData)
}
function Start-DeviceSearch {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $query = ([string]$c.txtDeviceSearch.Text).Trim()
    if ($query.Length -lt 2) { $c.txtDevicesStatus.Text = 'Aramak için bilgisayar adının en az 2 karakterini yazın.'; return }
    [void](Invoke-BackgroundTask -Name 'Bilgisayar aranıyor' -Command 'Find-DirectoryComputer' -Arguments @{ Query = $query } -OnSuccess {
            param($Result)
            $found = @($Result | Where-Object { $_ } | ForEach-Object {
                    $_ | Add-Member -NotePropertyName DisplayText -NotePropertyValue $(if ($_.ManagedByName) { "$($_.Name)  (managedBy: $($_.ManagedByName))" } else { [string]$_.Name }) -PassThru
                })
            $script:Ui.lstDeviceSearch.ItemsSource = $found
            $script:Ui.lstDeviceSearch.Visibility = if ($found.Count) { 'Visible' } else { 'Collapsed' }
            $script:Ui.txtDevicesStatus.Text = if ($found.Count) { "$($found.Count) bilgisayar bulundu (en fazla 50)." } else { 'Eşleşen bilgisayar bulunamadı.' }
            Update-DeviceButtonState
        } -OnFailure {
            param($Message)
            $script:Ui.txtDevicesStatus.Text = "Arama başarısız: $Message"
        })
}
function Start-DeviceOwnerChange {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ComputerDn, [Parameter()][AllowEmptyString()][string]$OwnerDn, [Parameter(Mandatory = $true)][string]$Name)
    $current = $script:State.CurrentData
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf; ObjectGuid = [string]$current.Ad.ObjectGuid }
    $arguments = Get-ActionArgument @{ ComputerDn = $ComputerDn; OwnerDn = [string]$OwnerDn }
    [void](Invoke-BackgroundTask -Name $Name -Command 'Set-DeviceOwner' -Arguments $arguments -OnSuccess {
            param($Result)
            $item = @($Result | Where-Object { $_ }) | Select-Object -First 1
            $text = if (-not $item.Success) { "İşlem başarısız: $($item.Message)" } elseif ($script:State.ActionContext.Simulate) { "Simülasyon: $($item.Step) için değişiklik yapılmadı." } else { "$($item.Step): $($item.Message)." }
            Write-UiLog -Message $text -Level $(if (-not $item.Success) { 'Error' } elseif ($script:State.ActionContext.Simulate) { 'Info' } else { 'Success' })
            $script:Ui.txtDevicesStatus.Text = $text
            if ($item.Success -and -not $script:State.ActionContext.Simulate) { Start-UserLoad -ObjectGuid $script:State.ActionContext.ObjectGuid -Force }
        } -OnFailure {
            param($Message)
            $script:Ui.txtDevicesStatus.Text = "İşlem başarısız: $Message"
        })
}
function Start-DeviceLink {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $computer = $c.lstDeviceSearch.SelectedItem
    $current = $script:State.CurrentData
    if (-not $computer -or -not $current) { return }
    $userDn = [string]$current.Ad.DistinguishedName
    $message = "$($computer.Name) bilgisayarı $($current.Ad.SamAccountName) kullanıcısına bağlanacak (managedBy)."
    if ($computer.ManagedBy -and -not ([string]$computer.ManagedBy).Equals($userDn, [System.StringComparison]::OrdinalIgnoreCase)) {
        $message += "`n`nDİKKAT: Bu bilgisayar şu an $($computer.ManagedByName) kullanıcısına bağlı. Devam ederseniz bağ bu kullanıcıya taşınır ve önceki kullanıcı silinirken bu cihaz silinmez."
    }
    if (-not (Show-ConfirmDialog -Message $message -Title 'Cihaz Bağla')) { return }
    Start-DeviceOwnerChange -ComputerDn ([string]$computer.DistinguishedName) -OwnerDn $userDn -Name "Cihaz bağlanıyor: $($computer.Name)"
}
function Start-DeviceUnlink {
    [CmdletBinding()]
    param()
    $device = $script:Ui.lstDevices.SelectedItem
    if (-not $device -or $device.Source -notin 'Elle', 'İkisi') { return }
    $note = if ($device.Source -eq 'İkisi') { "`n`nCihaz adı kurala uyduğu için listede 'Ad kuralı' kaynağıyla kalmaya devam eder." } else { '' }
    if (-not (Show-ConfirmDialog -Message "$($device.Name) bilgisayarının managedBy bağı kaldırılacak.$note" -Title 'Bağı Kaldır')) { return }
    Start-DeviceOwnerChange -ComputerDn ([string]$device.DistinguishedName) -OwnerDn '' -Name "Cihaz bağı kaldırılıyor: $($device.Name)"
}
function Register-DeviceEvent {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $c.lstDevices.Add_SelectionChanged({ Invoke-UiAction { Update-DeviceButtonState } })
    $c.lstDeviceSearch.Add_SelectionChanged({ Invoke-UiAction { Update-DeviceButtonState } })
    $c.btnDeviceSearch.Add_Click({ Invoke-UiAction { Start-DeviceSearch } })
    $c.txtDeviceSearch.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Return') { Invoke-UiAction { Start-DeviceSearch } } })
    $c.btnDeviceLink.Add_Click({ Invoke-UiAction { Start-DeviceLink } })
    $c.btnDeviceUnlink.Add_Click({ Invoke-UiAction { Start-DeviceUnlink } })
    $c.grpDuUsers.Add_Checked({ Invoke-UiAction { Set-DisabledPageView -View Users } })
    $c.grpDuDevices.Add_Checked({ Invoke-UiAction { Set-DisabledPageView -View Devices } })
    $c.btnDdRefresh.Add_Click({ Invoke-UiAction { Start-DeletedDeviceLoad } })
    $c.txtDdFilter.Add_TextChanged({ Invoke-UiAction { Update-DeletedDeviceView } })
    $c.lstDd.Add_SelectionChanged({ $script:Ui.btnDdShowSecrets.IsEnabled = [bool]$script:Ui.lstDd.SelectedItem })
    $c.btnDdShowSecrets.Add_Click({ Invoke-UiAction { Show-SelectedDeletedDeviceSecret } })
    $c.lstDd.Add_MouseDoubleClick({ Invoke-UiAction { Show-SelectedDeletedDeviceSecret } })
}
function Set-DisabledPageView {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Users', 'Devices')][string]$View)
    $c = $script:Ui
    $devices = $View -eq 'Devices'
    $c.pnlDuUsers.Visibility = if ($devices) { 'Collapsed' } else { 'Visible' }
    $c.pnlDuActions.Visibility = if ($devices) { 'Collapsed' } else { 'Visible' }
    $c.pnlDdDevices.Visibility = if ($devices) { 'Visible' } else { 'Collapsed' }
    $c.pnlDdActions.Visibility = if ($devices) { 'Visible' } else { 'Collapsed' }
    if ($devices -and $null -eq $script:State.DeletedDevices) { Start-DeletedDeviceLoad }
    elseif ($devices) { Update-DeletedDeviceView }
    else { Update-DisabledUserView }
}
function Start-DeletedDeviceLoad {
    [CmdletBinding()]
    param()
    $script:Ui.txtDuSummary.Text = 'Silinmiş cihazlar Geri Dönüşüm Kutusu''ndan okunuyor...'
    $started = Invoke-BackgroundTask -Name 'Silinmiş cihazlar okunuyor' -Command 'Get-DeletedDeviceList' -OnSuccess {
        param($Result)
        $script:State.DeletedDevices = @($Result | Where-Object { $_ } | ForEach-Object {
                $_ | Add-Member -NotePropertyName DeletedText -NotePropertyValue $_.DeletedAt.ToString('dd.MM.yyyy HH:mm') -PassThru |
                    Add-Member -NotePropertyName DaysLeftText -NotePropertyValue "$($_.DaysLeft) gün" -PassThru |
                    Add-Member -NotePropertyName BitLockerText -NotePropertyValue $(if ($_.BitLockerCount) { "$($_.BitLockerCount) anahtar" } else { 'Yok' }) -PassThru |
                    Add-Member -NotePropertyName LapsText -NotePropertyValue $(if ($_.LapsPresent) { 'Var' } else { 'Yok' }) -PassThru
            })
        Update-DeletedDeviceView
    } -OnFailure {
        param($Message)
        $script:State.DeletedDevices = @()
        $script:Ui.lstDd.ItemsSource = $null
        $script:Ui.txtDuSummary.Text = "Silinmiş cihazlar okunamadı: $Message"
    }
    if (-not $started) { $script:Ui.txtDuSummary.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' }
}
function Update-DeletedDeviceView {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $filter = ([string]$c.txtDdFilter.Text).Trim()
    $all = @($script:State.DeletedDevices | Where-Object { $_ })
    $comparison = [System.StringComparison]::CurrentCultureIgnoreCase
    $items = @($all | Where-Object { -not $filter -or ("$($_.Name) $($_.Owner)").IndexOf($filter, $comparison) -ge 0 })
    $c.lstDd.ItemsSource = $items
    $c.btnDdShowSecrets.IsEnabled = $false
    $c.txtDuSummary.Text = "$($all.Count) silinmiş bilgisayar Geri Dönüşüm Kutusu'nda. Gösterilen: $($items.Count)."
}
function Show-SelectedDeletedDeviceSecret {
    [CmdletBinding()]
    param()
    $device = $script:Ui.lstDd.SelectedItem
    if (-not $device) { $script:Ui.txtDuSummary.Text = 'Parolaları görmek için listeden bir cihaz seçin.'; return }
    [void](Invoke-BackgroundTask -Name "Parolalar okunuyor: $($device.Name)" -Command 'Get-DeletedDeviceSecret' -Arguments @{ ObjectGuid = [string]$device.ObjectGuid; DeviceName = [string]$device.Name } -OnSuccess {
            param($Result)
            $secret = @($Result | Where-Object { $_ }) | Select-Object -First 1
            if ($secret) { Show-DeviceSecretDialog -Secret $secret }
        } -OnFailure {
            param($Message)
            $script:Ui.txtDuSummary.Text = "Parolalar okunamadı: $Message"
        })
}
function Show-DeviceSecretDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Secret)
    $rows = New-Object -TypeName 'System.Collections.ObjectModel.ObservableCollection[object]'
    $rows.Add([pscustomobject]@{
            Label = 'LAPS yerel yönetici parolası'
            Detail = if ($Secret.LapsPassword -and $Secret.LapsExpiresAt) { "Son geçerlilik: $($Secret.LapsExpiresAt.ToString('dd.MM.yyyy HH:mm'))" } elseif ($Secret.LapsPassword) { '' } else { 'Bu cihazda LAPS parolası kayıtlı değil.' }
            Value = [string]$Secret.LapsPassword; HasValue = [bool]$Secret.LapsPassword
        })
    foreach ($key in @($Secret.BitLocker | Where-Object { $_ })) {
        $rows.Add([pscustomobject]@{ Label = 'BitLocker kurtarma anahtarı'; Detail = [string]$key.Name; Value = [string]$key.RecoveryPassword; HasValue = [bool]$key.RecoveryPassword })
    }
    if (@($Secret.BitLocker | Where-Object { $_ }).Count -eq 0) {
        $rows.Add([pscustomobject]@{ Label = 'BitLocker kurtarma anahtarı'; Detail = 'Bu cihaz için AD''de BitLocker kaydı yok.'; Value = ''; HasValue = $false })
    }
    $dialog = New-MainWindow -Xaml $script:DeviceSecretXaml
    try {
        $c = $dialog.Controls
        $dialog.Window.Owner = $script:Window
        $c.txtDsTitle.Text = [string]$Secret.DeviceName
        $c.icDsSecrets.ItemsSource = $rows
        $c.icDsSecrets.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
                param($sender, $e)
                $value = [string]$e.OriginalSource.Tag
                if ($value) { Copy-SecretToClipboard -Value $value; $c.txtDsStatus.Text = "Kopyalandı ($((Get-Date).ToString('HH:mm:ss'))); 60 saniye sonra panodan silinecek." }
            }.GetNewClosure())
        $window = $dialog.Window
        $c.btnDsClose.Add_Click({ $window.Close() }.GetNewClosure())
        [void]$dialog.Window.ShowDialog()
    }
    finally {
        $c.icDsSecrets.ItemsSource = $null
        $rows.Clear()
        $Secret = $null
    }
}
function Copy-SecretToClipboard {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)
    [System.Windows.Clipboard]::SetText($Value)
    if ($script:ClipboardTimer) { $script:ClipboardTimer.Stop() }
    $script:ClipboardSecret = $Value
    $script:ClipboardTimer = New-Object -TypeName System.Windows.Threading.DispatcherTimer
    $script:ClipboardTimer.Interval = [timespan]::FromSeconds(60)
    $script:ClipboardTimer.Add_Tick({
            $script:ClipboardTimer.Stop()
            try { if ([System.Windows.Clipboard]::ContainsText() -and [System.Windows.Clipboard]::GetText() -eq $script:ClipboardSecret) { [System.Windows.Clipboard]::Clear() } }
            catch { Write-Verbose "Pano temizlenemedi: $($_.Exception.Message)" }
            $script:ClipboardSecret = $null
        })
    $script:ClipboardTimer.Start()
}
