function Start-DashboardLoad {
    [CmdletBinding()]
    param()
    $script:Ui.txtHomeStatus.Text = 'Özet okunuyor...'
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
