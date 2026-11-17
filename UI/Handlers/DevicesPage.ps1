function Test-DeviceAttentionFilter {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][psobject]$Item, [Parameter(Mandatory = $true)][bool]$OnlyAttention)
    return (-not $OnlyAttention) -or [bool]$Item.NeedsAttention
}
function Update-DevicesPageSummary {
    [CmdletBinding()]
    param()
    $items = @($script:State.DevicesPage.Items)
    $script:Ui.txtDvSummary.Text = "$($items.Count) bilgisayar, $(@($items | Where-Object { $_.NeedsAttention }).Count) uyarı."
}
function Update-DevicesPageButtonState {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $count = @($c.lstDv.SelectedItems).Count
    $c.btnDvAssign.IsEnabled = [bool]($count -ge 1 -and $c.lstDvUserResults.SelectedItem)
    $c.btnDvUnlink.IsEnabled = $count -ge 1
    $c.btnDvSecret.IsEnabled = $count -eq 1
}
function Initialize-DevicesPage {
    [CmdletBinding()]
    param()
    $page = $script:State.DevicesPage
    if (-not $page.Items) {
        $page.Items = New-Object -TypeName 'System.Collections.ObjectModel.ObservableCollection[object]'
        $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($page.Items)
        $view.Filter = [System.Predicate[object]]{ param($item) Test-DeviceAttentionFilter -Item $item -OnlyAttention ([bool]$script:Ui.chkDvAttention.IsChecked) }
        $script:Ui.lstDv.ItemsSource = $view
    }
    if (@($page.Ou).Count -eq 0) { $script:Ui.txtDvSummary.Text = 'Başlamak için "OU Seç" ile bilgisayarların bulunduğu OU''ları seçin.' }
}
function Start-DevicesPagePickOu {
    [CmdletBinding()]
    param()
    if (@($script:State.OuList).Count -eq 0) {
        [void](Invoke-BackgroundTask -Name 'OU listesi okunuyor' -Command 'Get-OrganizationalUnitList' -OnSuccess {
                param($Result)
                $script:State.OuList = @($Result | Where-Object { $_ })
                if ($script:State.OuList.Count -gt 0) { Invoke-Deferred { Start-DevicesPagePickOu } }
                else { Write-UiLog -Message 'Dizinde OU bulunamadı.' -Level Warning }
            })
        return
    }
    $page = $script:State.DevicesPage
    $subtree = [bool]$page.Subtree
    $selected = [string[]]@(Show-OuPicker -Owner $script:Window -Selected @($page.Ou | Where-Object { $_ }) -Multiple -Title 'Hangi OU''lardaki bilgisayarlar listelensin?' -AcceptText 'Bilgisayarları Listele' -Subtree ([ref]$subtree) | Where-Object { $_ })
    if ($selected.Count -eq 0) { return }
    $page.Ou = $selected
    $page.Subtree = $subtree
    $script:Ui.txtDvOu.Text = "$($selected.Count) OU, $(if ($subtree) { 'alt OU''lar dahil' } else { 'yalnız seçilenler' })"
    $script:Ui.txtDvOu.ToolTip = $selected -join "`n"
    Start-DevicesPageLoad
}
function Start-DevicesPageLoad {
    [CmdletBinding()]
    param()
    $page = $script:State.DevicesPage
    if (@($page.Ou).Count -eq 0) { Initialize-DevicesPage; return }
    $script:Ui.txtDvSummary.Text = 'Bilgisayarlar okunuyor...'
    $started = Invoke-BackgroundTask -Name 'OU''daki bilgisayarlar okunuyor' -Command 'Get-OuDeviceList' -Arguments @{ OuDn = [string[]]$page.Ou; Subtree = [bool]$page.Subtree } -OnSuccess {
        param($Result)
        $page = $script:State.DevicesPage
        $page.Items.Clear()
        foreach ($row in @($Result | Where-Object { $_ })) { $page.Items.Add($row) }
        Update-DevicesPageSummary
        Update-DevicesPageButtonState
    } -OnFailure {
        param($Message)
        $script:Ui.txtDvSummary.Text = "Bilgisayarlar okunamadı: $Message"
    }
    if (-not $started) { $script:Ui.txtDvSummary.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' }
}
function Start-DevicesPageUserSearch {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $query = ([string]$c.txtDvUser.Text).Trim()
    if ($query.Length -lt 2) { $c.txtDvSummary.Text = 'Aramak için kullanıcı adının en az 2 karakterini yazın.'; return }
    [void](Invoke-BackgroundTask -Name 'Kullanıcı aranıyor' -Command 'Find-DirectoryUser' -Arguments @{ Query = $query } -OnSuccess {
            param($Result)
            $found = @($Result | Where-Object { $_ } | ForEach-Object {
                    $_ | Add-Member -NotePropertyName DisplayText -NotePropertyValue "$($_.DisplayName) — $($_.SamAccountName)" -Force -PassThru
                })
            $script:Ui.lstDvUserResults.ItemsSource = $found
            $script:Ui.lstDvUserResults.Visibility = if ($found.Count) { 'Visible' } else { 'Collapsed' }
            $script:Ui.txtDvSummary.Text = if ($found.Count) { "$($found.Count) kullanıcı bulundu." } else { 'Eşleşen kullanıcı bulunamadı.' }
            Update-DevicesPageButtonState
        } -OnFailure {
            param($Message)
            $script:Ui.txtDvSummary.Text = "Arama başarısız: $Message"
        })
}
function Start-DevicesPageOwnerChange {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Rows, [Parameter()][AllowEmptyString()][string]$OwnerDn)
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf; Affected = @(@($OwnerDn) + @($Rows | ForEach-Object { [string]$_.ManagedBy }) | Where-Object { $_ }) }
    $arguments = Get-ActionArgument @{ ComputerDn = [string[]]@($Rows | ForEach-Object { [string]$_.DistinguishedName }); OwnerDn = $OwnerDn }
    [void](Invoke-BackgroundTask -Name "Cihaz sahibi değiştiriliyor ($($Rows.Count))" -Command 'Set-DeviceOwnerBulk' -Arguments $arguments -OnSuccess {
            param($Result)
            $results = @($Result | Where-Object { $_ })
            $failed = @($results | Where-Object { -not $_.Success })
            $simulate = [bool]$script:State.ActionContext.Simulate
            $text = if ($failed.Count) { "$($failed.Count) bilgisayarda hata: " + (($failed | ForEach-Object { "$($_.Step): $($_.Message)" }) -join '; ') }
            elseif ($simulate) { "Simülasyon: $($results.Count) bilgisayar için değişiklik yapılmadı." }
            else { "$($results.Count) bilgisayarın sahibi güncellendi." }
            Write-UiLog -Message $text -Level $(if ($failed.Count) { 'Error' } elseif ($simulate) { 'Info' } else { 'Success' })
            Start-DevicesPageLoad
            $script:Ui.txtDvSummary.Text = $text
            $current = $script:State.CurrentData
            if (-not $simulate -and $current -and @($script:State.ActionContext.Affected | Where-Object { ([string]$_).Equals([string]$current.Ad.DistinguishedName, [System.StringComparison]::OrdinalIgnoreCase) }).Count) {
                Start-UserLoad -ObjectGuid $current.Ad.ObjectGuid -Force
            }
        } -OnFailure {
            param($Message)
            $script:Ui.txtDvSummary.Text = "İşlem başarısız: $Message"
        })
}
function Start-DevicesPageAssign {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $rows = @($c.lstDv.SelectedItems)
    $user = $c.lstDvUserResults.SelectedItem
    if ($rows.Count -eq 0 -or -not $user) { return }
    $ownerDn = [string]$user.DistinguishedName
    $changing = @($rows | Where-Object { $_.ManagedBy -and -not ([string]$_.ManagedBy).Equals($ownerDn, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($changing.Count) {
        $lines = @($changing | ForEach-Object { "$($_.Name) ($($_.OwnerName) → $($user.DisplayName))" })
        if (-not (Show-ConfirmDialog -Message 'Bu bilgisayarların mevcut sahibi değiştirilecek.' -Title 'Sahibi Değiştir' -Warning -Items $lines -ApplyText 'Ata')) { return }
    }
    Start-DevicesPageOwnerChange -Rows $rows -OwnerDn $ownerDn
}
function Start-DevicesPageUnlink {
    [CmdletBinding()]
    param()
    $rows = @($script:Ui.lstDv.SelectedItems)
    if ($rows.Count -eq 0) { return }
    if (-not (Show-ConfirmDialog -Message "$($rows.Count) bilgisayarın sahibi kaldırılacak." -Title 'Bağı Kaldır')) { return }
    Start-DevicesPageOwnerChange -Rows $rows -OwnerDn ''
}
function Show-DevicesPageSecret {
    [CmdletBinding()]
    param()
    $rows = @($script:Ui.lstDv.SelectedItems)
    if ($rows.Count -ne 1) { return }
    $device = $rows[0]
    [void](Invoke-BackgroundTask -Name "Parolalar okunuyor: $($device.Name)" -Command 'Get-DeviceSecret' -Arguments @{ ComputerDn = [string]$device.DistinguishedName; DeviceName = [string]$device.Name } -OnSuccess {
            param($Result)
            $secret = @($Result | Where-Object { $_ }) | Select-Object -First 1
            if ($secret) { Show-DeviceSecretDialog -Secret $secret -EmptyHint 'kayıtlı değil veya okuma yetkiniz yok' }
        } -OnFailure {
            param($Message)
            $script:Ui.txtDvSummary.Text = "Parolalar okunamadı: $Message"
        })
}
function Register-DevicesPageEvent {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $c.btnDvPickOu.Add_Click({ Invoke-UiAction { Start-DevicesPagePickOu } })
    $c.btnDvRefresh.Add_Click({ Invoke-UiAction { Start-DevicesPageLoad } })
    $c.chkDvAttention.Add_Click({ Invoke-UiAction { if ($script:State.DevicesPage.Items) { [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:State.DevicesPage.Items).Refresh() } } })
    $c.lstDv.Add_SelectionChanged({ Invoke-UiAction { Update-DevicesPageButtonState } })
    $c.lstDvUserResults.Add_SelectionChanged({ Invoke-UiAction { Update-DevicesPageButtonState } })
    $c.btnDvUserSearch.Add_Click({ Invoke-UiAction { Start-DevicesPageUserSearch } })
    $c.txtDvUser.Add_KeyDown({ param($sender, $e) if ($e.Key -eq 'Return') { Invoke-UiAction { Start-DevicesPageUserSearch } } })
    $c.btnDvAssign.Add_Click({ Invoke-UiAction { Start-DevicesPageAssign } })
    $c.btnDvUnlink.Add_Click({ Invoke-UiAction { Start-DevicesPageUnlink } })
    $c.btnDvSecret.Add_Click({ Invoke-UiAction { Show-DevicesPageSecret } })
}
