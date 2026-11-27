function Start-DashboardLoad {
    [CmdletBinding()]
    param()
    $script:Ui.txtHomeStatus.Text = 'Özet okunuyor...'
    Start-DashboardInactiveLoad
    [void](Invoke-BackgroundTask -Name 'Ana sayfa özeti okunuyor' -Command 'Get-DashboardSummary' -OnSuccess {
            param($Result)
            $script:State.Dashboard = $Result
            Update-DashboardView
        } -OnFailure {
            param($Message)
            $script:Ui.txtHomeStatus.Text = "Özet okunamadı: $Message"
        })
}
function Update-DashboardView {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $summary = $script:State.Dashboard
    if (-not $summary) { return }
    $c.txtHomeLockedCount.Text = [string]$summary.LockedCount
    $c.txtHomeExpiringCount.Text = [string]$summary.ExpiringCount
    $c.txtHomeExpiringLabel.Text = "Parolası $($summary.ExpiryDays) gün içinde dolacak"
    $c.txtHomeExpiringTitle.Text = "Parolası $($summary.ExpiryDays) gün içinde dolacaklar"
    if ($null -eq $summary.DisabledCount) {
        $c.txtHomeDisabledCount.Text = '?'
        $c.txtHomeDisabledDetail.Text = 'Okunamadı'
    }
    else {
        $c.txtHomeDisabledCount.Text = [string]$summary.DisabledCount
        $c.txtHomeDisabledDetail.Text = "$($summary.DisabledOverdue) tanesi 1 ayı doldurdu" + $(if ($summary.DisabledUnknown -gt 0) { "; $($summary.DisabledUnknown) tanesinin tarihi bilinmiyor" } else { '' })
    }
    foreach ($pair in @(@{ Count = 'txtHomeLockedCount'; Alert = $summary.LockedCount -gt 0 }, @{ Count = 'txtHomeDisabledCount'; Alert = $summary.DisabledOverdue -gt 0 })) {
        if ($pair.Alert) { $c[$pair.Count].SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'WarningBrush') }
        else { $c[$pair.Count].ClearValue([System.Windows.Controls.TextBlock]::ForegroundProperty) }
    }
    $c.lstHomeLocked.ItemsSource = @($summary.Locked)
    $c.txtHomeLockedEmpty.Visibility = if ($summary.LockedCount -eq 0) { 'Visible' } else { 'Collapsed' }
    $c.lstHomeExpiring.ItemsSource = @($summary.Expiring)
    $c.txtHomeExpiringEmpty.Visibility = if ($summary.ExpiringCount -eq 0) { 'Visible' } else { 'Collapsed' }
    $status = "Son yenileme: $($summary.At.ToString('HH:mm')). Kullanıcıyı açmak için listede çift tıklayın."
    if (@($summary.Errors).Count -gt 0) { $status += '  Hata: ' + (@($summary.Errors) -join ' | ') }
    $c.txtHomeStatus.Text = $status
}
function Open-DashboardUser {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Windows.Controls.ListBox]$List)
    $item = $List.SelectedItem
    if (-not $item) { return }
    if (-not (Confirm-DiscardChange)) { return }
    $script:Ui.navUsers.IsChecked = $true
    $script:Ui.txtSearch.Text = [string]$item.SamAccountName
    Start-UserLoad -ObjectGuid ([string]$item.ObjectGuid) -Force
}
function Get-DashboardInactiveOu {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $saved = Read-AppSetting
    if ($saved -and $saved.DashboardInactiveOu) { return [string[]]@($saved.DashboardInactiveOu | Where-Object { $_ }) }
    return [string[]]@()
}
function Start-DashboardInactiveLoad {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $ous = Get-DashboardInactiveOu
    $c.txtHomeInactiveOu.Text = if ($ous.Count -eq 0) { 'OU seçilmedi' } else { "$($ous.Count) OU, alt OU'lar dahil" }
    $c.txtHomeInactiveOu.ToolTip = if ($ous.Count -gt 0) { $ous -join "`n" } else { $null }
    if ($ous.Count -eq 0) {
        $c.lstHomeInactive.ItemsSource = $null
        $c.txtHomeInactiveTitle.Text = '1 aydan uzun süredir oturum açmayanlar'
        $c.txtHomeInactiveEmpty.Text = 'Listelemek için OU seçin.'
        $c.txtHomeInactiveEmpty.Visibility = 'Visible'
        return
    }
    $c.txtHomeInactiveEmpty.Text = 'Okunuyor...'
    $c.txtHomeInactiveEmpty.Visibility = 'Visible'
    [void](Invoke-BackgroundTask -Name 'Uzun süredir oturum açmayanlar okunuyor' -Command 'Get-InactiveUserList' -Arguments @{ SearchBase = $ous } -OnSuccess {
            param($Result)
            $c = $script:Ui
            $c.txtHomeInactiveTitle.Text = "1 aydan uzun süredir oturum açmayanlar ($($Result.Count))"
            $c.lstHomeInactive.ItemsSource = @($Result.Users)
            $empty = if (@($Result.Errors).Count -gt 0) { 'Hata: ' + (@($Result.Errors) -join ' | ') } elseif ($Result.Count -eq 0) { 'Seçili OU''larda 1 aydan uzun süredir oturum açmayan etkin kullanıcı yok.' } else { '' }
            $c.txtHomeInactiveEmpty.Text = $empty
            $c.txtHomeInactiveEmpty.Visibility = if ($empty) { 'Visible' } else { 'Collapsed' }
        } -OnFailure {
            param($Message)
            $script:Ui.txtHomeInactiveEmpty.Text = "Okunamadı: $Message"
            $script:Ui.txtHomeInactiveEmpty.Visibility = 'Visible'
        })
}
function Select-DashboardInactiveOu {
    [CmdletBinding()]
    param()
    if (@($script:State.OuList).Count -eq 0) {
        [void](Invoke-BackgroundTask -Name 'OU listesi okunuyor' -Command 'Get-OrganizationalUnitList' -OnSuccess {
                param($Result)
                $script:State.OuList = @($Result | Where-Object { $_ })
                if ($script:State.OuList.Count -gt 0) { Invoke-Deferred { Select-DashboardInactiveOu } }
                else { Write-UiLog -Message 'Dizinde OU bulunamadı.' -Level Warning }
            })
        return
    }
    $selected = [string[]]@(Show-OuPicker -Owner $script:Window -Selected (Get-DashboardInactiveOu) -Multiple -Title 'Oturum açmayanlar listesi hangi OU''ları kapsasın? (alt OU''lar dahil)' -AcceptText 'Seçili OU''ları Kullan' | Where-Object { $_ })
    if ($selected.Count -eq 0) { return }
    Save-AppSetting -Values @{ DashboardInactiveOu = $selected }
    Start-DashboardInactiveLoad
}
