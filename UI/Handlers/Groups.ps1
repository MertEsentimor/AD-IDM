function Update-GroupView {
    [CmdletBinding()]
    param()
    $items = foreach ($entry in $script:State.GroupList) {
        $group = $entry.Group
        $state = [string]$entry.State
        $stateText = switch ($state) {
            'Added' { 'Eklenecek' }
            'Removed' { 'Kaldırılacak' }
            default { if ($group.IsPrimary) { 'Birincil grup' } elseif (-not $group.CanEdit) { 'Salt okunur' } else { '' } }
        }
        if ($state -eq 'Existing' -and $stateText) { $state = 'Info' }
        [pscustomobject]@{
            Name       = $group.Name
            DetailText = (@($group.ScopeText, $group.Description) | Where-Object { $_ }) -join '  |  '
            State      = $state
            StateText  = $stateText
            Entry      = $entry
        }
    }
    $script:Ui.lstGroups.ItemsSource = @($items | Sort-Object -Property Name)
    $active = @($script:State.GroupList | Where-Object { $_.State -ne 'Removed' }).Count
    $script:Ui.txtGroupCount.Text = "$active grup"
}
function Find-GroupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DistinguishedName)
    foreach ($entry in $script:State.GroupList) {
        if ([string]::Equals($entry.Group.DistinguishedName, $DistinguishedName, [System.StringComparison]::OrdinalIgnoreCase)) { return $entry }
    }
    return $null
}
function Start-GroupSearch {
    [CmdletBinding()]
    param()
    if (-not $script:State.CurrentData) { return }
    $query = ([string]$script:Ui.txtGroupSearch.Text).Trim()
    if ($query.Length -lt 2) {
        Write-UiLog -Message 'Grup araması için en az 2 karakter girin.' -Level Warning
        return
    }
    [void](Invoke-BackgroundTask -Name 'Grup aranıyor' -Command 'Find-DirectoryGroup' -Arguments @{ Query = $query } -OnSuccess {
            param($Result)
            Show-GroupSearchResult -Groups $Result
        })
}
function Show-GroupSearchResult {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Groups)
    $items = foreach ($group in @($Groups | Where-Object { $_ })) {
        $entry = Find-GroupEntry -DistinguishedName $group.DistinguishedName
        [pscustomobject]@{
            Name       = $group.Name
            DetailText = (@($group.ScopeText, $group.Description) | Where-Object { $_ }) -join '  |  '
            MemberText = if (-not $entry) { '' } elseif ($entry.State -eq 'Added') { 'Eklenecek' } elseif ($entry.State -eq 'Existing') { 'Zaten üye' } else { '' }
            Group      = $group
        }
    }
    $items = @($items)
    $script:Ui.lstGroupResults.ItemsSource = $items
    $script:Ui.txtGroupResultInfo.Text = if ($items.Count -gt 0) { "$($items.Count) grup bulundu. Eklemek istediklerinizi seçin." } else { 'Grup bulunamadı.' }
    $script:Ui.bdGroupResults.Visibility = 'Visible'
}
function Add-SelectedGroup {
    [CmdletBinding()]
    param()
    $selected = @($script:Ui.lstGroupResults.SelectedItems)
    if ($selected.Count -eq 0) { Write-UiLog -Message 'Eklemek için arama sonuçlarından grup seçin.' -Level Warning; return }
    foreach ($item in $selected) {
        $entry = Find-GroupEntry -DistinguishedName $item.Group.DistinguishedName
        if ($entry) {
            if ($entry.State -eq 'Removed') { $entry.State = 'Existing' }
            else { Write-UiLog -Message "Kullanıcı zaten '$($item.Group.Name)' grubunun üyesi." -Level Info }
            continue
        }
        $script:State.GroupList.Add([pscustomobject]@{ Group = $item.Group; State = 'Added' })
    }
    Update-GroupView
    Show-GroupSearchResult -Groups @($script:Ui.lstGroupResults.ItemsSource | ForEach-Object { $_.Group })
    Update-ChangeIndicator
}
function Switch-SelectedGroupRemoval {
    [CmdletBinding()]
    param()
    $selected = @($script:Ui.lstGroups.SelectedItems)
    if ($selected.Count -eq 0) { Write-UiLog -Message 'Kaldırmak için listeden grup seçin.' -Level Warning; return }
    foreach ($item in $selected) {
        $entry = $item.Entry
        switch ([string]$entry.State) {
            'Added' { [void]$script:State.GroupList.Remove($entry) }
            'Removed' { $entry.State = 'Existing' }
            default {
                if ($entry.Group.IsPrimary) { Write-UiLog -Message "'$($entry.Group.Name)' kullanıcının birincil grubu; kaldırılamaz." -Level Warning }
                elseif (-not $entry.Group.CanEdit) { Write-UiLog -Message "'$($entry.Group.Name)' bu araçtan değiştirilemez (başka etki alanı)." -Level Warning }
                else { $entry.State = 'Removed' }
            }
        }
    }
    Update-GroupView
    Update-ChangeIndicator
}
