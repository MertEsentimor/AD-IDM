function Show-SearchResult {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$Results,
        [Parameter()][string]$Title = 'Arama sonuçları',
        [Parameter()][AllowEmptyString()][string]$TitleToolTip = '',
        [Parameter()][string]$EmptyMessage = 'Aramayla eşleşen kullanıcı bulunamadı.'
    )
    $items = @($Results | Where-Object { $_ })
    $script:Ui.txtResultsTitle.Text = $Title
    $script:Ui.txtResultsTitle.ToolTip = if ($TitleToolTip) { $TitleToolTip } else { $null }
    $script:State.SuppressSelection = $true
    try {
        $script:Ui.lstResults.ItemsSource = $items
        $script:Ui.lstResults.SelectedIndex = -1
    }
    finally {
        $script:State.SuppressSelection = $false
    }
    $script:Ui.txtResultCount.Text = [string]$items.Count
    $script:Ui.txtResultsEmpty.Visibility = if ($items.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    if ($script:Layout.Mode -eq 'Compact' -and $items.Count -ne 1) { Set-SidePane -Open $true }
    if ($items.Count -eq 0) {
        Write-UiLog -Message $EmptyMessage -Level Warning
    }
    else {
        Write-UiLog -Message "$($items.Count) kullanıcı bulundu." -Level Info
        if ($items.Count -eq 1) { $script:Ui.lstResults.SelectedIndex = 0 }
    }
}
function Start-EnvironmentCheck {
    [CmdletBinding()]
    param()
    [void](Invoke-BackgroundTask -Name 'Başlangıç kontrolleri' -Command 'Get-EnvironmentStatus' -OnSuccess {
            param($Result)
            $script:State.Environment = $Result
            $servers = @($Result.ExchangeServers | ForEach-Object { $_.Fqdn })
            $script:Ui.cmbExServer.ItemsSource = $servers
            if ($script:StartupExchangeServer) { $script:Ui.cmbExServer.Text = $script:StartupExchangeServer }
            elseif ($servers.Count -gt 0) { $script:Ui.cmbExServer.SelectedIndex = 0 }
            Update-ConnectionIndicator
            $script:Ui.txtSearch.Focus() | Out-Null
            if ($script:StartupExchangeMode -eq 'OnPremises') { $script:Ui.cmbExMode.SelectedIndex = 1; Start-ExchangeConnection }
        } -OnFailure {
            param($Message)
            $script:State.Environment = [pscustomobject]@{ AdAvailable = $false; UpnSuffixes = @(); ExchangeServers = @() }
            Update-ConnectionIndicator
            [void](Show-MessageDialog -Message "Active Directory'ye erişilemedi:`n`n$Message`n`nBilgisayarın etki alanına bağlı olduğundan ve ADWS (9389) erişimi olduğundan emin olun." -Icon Error)
        })
}
function Start-UserSearch {
    [CmdletBinding()]
    param()
    $query = ([string]$script:Ui.txtSearch.Text).Trim()
    if ($query.Length -lt 2) {
        Write-UiLog -Message 'Arama için en az 2 karakter girin.' -Level Warning
        return
    }
    if ($script:State.Environment -and -not $script:State.Environment.AdAvailable) {
        [void](Show-MessageDialog -Message 'Active Directory bağlantısı yok; arama yapılamıyor.' -Icon Warning)
        return
    }
    [void](Invoke-BackgroundTask -Name "Kullanıcı aranıyor: '$query'" -Command 'Find-DirectoryUser' -Arguments @{ Query = $query } -OnSuccess {
            param($Result)
            Show-SearchResult -Results $Result
        })
}
function Start-OuUserSearch {
    [CmdletBinding()]
    param()
    if ($script:State.Environment -and -not $script:State.Environment.AdAvailable) {
        [void](Show-MessageDialog -Message 'Active Directory bağlantısı yok; OU listesi okunamıyor.' -Icon Warning)
        return
    }
    if (@($script:State.OuList).Count -eq 0) {
        [void](Invoke-BackgroundTask -Name 'OU listesi okunuyor' -Command 'Get-OrganizationalUnitList' -OnSuccess {
                param($Result)
                $script:State.OuList = @($Result | Where-Object { $_ })
                if ($script:State.OuList.Count -gt 0) { Invoke-Deferred { Start-OuUserSearch } }
                else { Write-UiLog -Message 'Dizinde OU bulunamadı.' -Level Warning }
            })
        return
    }
    $last = $script:State.OuSearch
    $subtree = [bool]$last.Subtree
    $selected = [string[]]@(Show-OuPicker -Owner $script:Window -Selected @($last.Dn | Where-Object { $_ }) -Multiple -Title 'Hangi OU''lardaki kullanıcılar listelensin?' -AcceptText 'Kullanıcıları Listele' -Subtree ([ref]$subtree) | Where-Object { $_ })
    if ($selected.Count -eq 0) { return }
    $script:State.OuSearch = @{ Dn = $selected; Subtree = $subtree }
    $paths = @(foreach ($dn in $selected) {
            $match = @($script:State.OuList | Where-Object { [string]::Equals([string]$_.DistinguishedName, $dn, [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
            if ($match) { [string]$match.CanonicalName } else { $dn }
        })
    $names = @($paths | ForEach-Object { $_.Split('/')[-1] } | Sort-Object)
    $name = if ($names.Count -eq 1) { $names[0] } else { "$($names.Count) OU" }
    $scopeText = if ($subtree) { 'alt OU''lar dahil' } else { 'yalnız seçilen OU''lar' }
    $script:State.OuSearchView = @{ Name = $name; Path = (($paths | Sort-Object) -join "`n"); ScopeText = $scopeText }
    [void](Invoke-BackgroundTask -Name "OU'daki kullanıcılar okunuyor: $name" -Command 'Get-OuUser' -Arguments @{ SearchBase = $selected; Subtree = $subtree } -OnSuccess {
            param($Result)
            $view = $script:State.OuSearchView
            Show-SearchResult -Results $Result -Title "OU: $($view.Name)" -TitleToolTip "$($view.Path)`n($($view.ScopeText))" -EmptyMessage "Seçilen OU'larda kullanıcı yok: $($view.Name) ($($view.ScopeText))."
        })
}
function Show-OuPicker {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][System.Windows.Window]$Owner,
        [Parameter()][AllowEmptyCollection()][string[]]$Selected = @(),
        [Parameter()][string]$UserText,
        [Parameter()][switch]$Multiple,
        [Parameter()][string]$Title,
        [Parameter()][string]$AcceptText,
        [Parameter()][AllowNull()][ref]$Subtree
    )
    $dialog = New-MainWindow -Xaml $script:OuPickerXaml
    $checked = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    if ($Multiple) { foreach ($dn in @($Selected | Where-Object { $_ })) { [void]$checked.Add($dn) } }
    $script:State.OuPicker = @{ Window = $dialog.Window; Controls = $dialog.Controls; Result = $null; Multiple = [bool]$Multiple; Checked = $checked; Selected = [string](@($Selected) | Select-Object -First 1) }
    try {
        $c = $dialog.Controls
        $dialog.Window.Owner = $Owner
        if ($Multiple) {
            $c.txtOuTitle.Text = if ($UserText) { "${UserText}: hangi OU'lar?" } else { "OU'ları seçin" }
            $c.btnOuOk.Content = "Seçili OU'ları Ekle"
            $c.btnOuNone.Visibility = 'Visible'
        }
        elseif ($UserText) { $c.txtOuTitle.Text = "'$UserText' hangi OU'ya eklensin?" }
        if ($Title) { $c.txtOuTitle.Text = $Title; $dialog.Window.Title = $Title }
        if ($AcceptText) { $c.btnOuOk.Content = $AcceptText }
        if ($Subtree) {
            $c.chkOuSubtree.Visibility = 'Visible'
            $c.chkOuSubtree.IsChecked = [bool]$Subtree.Value
        }
        Update-OuTree
        Update-OuPickerSummary
        if (-not $Multiple -and $script:State.OuPicker.Selected -and -not (Get-OuTreeSelection)) { $c.txtOuDn.Text = "Komuttaki OU dizinde bulunamadı: $($script:State.OuPicker.Selected)" }
        $c.treeOu.Add_SelectedItemChanged({ Invoke-UiAction { if (-not $script:State.OuPicker.Multiple) { Update-OuPickerSummary } } })
        $c.txtOuFilter.Add_TextChanged({ Invoke-UiAction { Update-OuTree } })
        $c.btnOuExpand.Add_Click({ Invoke-UiAction { Set-OuTreeExpanded -Expanded $true } })
        $c.btnOuCollapse.Add_Click({ Invoke-UiAction { Set-OuTreeExpanded -Expanded $false } })
        $c.btnOuNone.Add_Click({ Invoke-UiAction { $script:State.OuPicker.Checked.Clear(); Update-OuTree; Update-OuPickerSummary } })
        $accept = {
            $picker = $script:State.OuPicker
            $pc = $picker.Controls
            if ($picker.Multiple) {
                if ($picker.Checked.Count -eq 0) { $pc.txtOuDn.Text = 'En az bir OU işaretleyin.'; return }
                $picker.Result = [string[]]@($picker.Checked)
            }
            else {
                $item = Get-OuTreeSelection
                if (-not $item -or -not $item.Tag) { $pc.txtOuDn.Text = 'Lütfen ağaçtan bir OU seçin.'; return }
                $picker.Result = [string[]]@([string]$item.Tag)
            }
            $picker.Window.DialogResult = $true
        }
        $c.btnOuOk.Add_Click({ Invoke-UiAction $accept })
        $c.treeOu.Add_MouseDoubleClick({
                param($sender, $e)
                $item = Get-OuTreeSelection
                if (-not $script:State.OuPicker.Multiple -and $item -and $item.Tag -and $item.Items.Count -eq 0) { Invoke-UiAction $accept }
            })
        $dialog.Window.Add_ContentRendered({
                $item = Get-OuTreeSelection
                if ($item) { $item.BringIntoView() }
                [void]$script:State.OuPicker.Controls.txtOuFilter.Focus()
            })
        [void]$dialog.Window.ShowDialog()
        if ($Subtree -and $script:State.OuPicker.Result) { $Subtree.Value = [bool]$c.chkOuSubtree.IsChecked }
        return $script:State.OuPicker.Result
    }
    finally {
        $script:State.OuPicker = $null
    }
}
function Update-OuTree {
    [CmdletBinding()]
    param()
    $picker = $script:State.OuPicker
    $c = $picker.Controls
    $filter = ([string]$c.txtOuFilter.Text).Trim()
    $comparison = [System.StringComparison]::CurrentCultureIgnoreCase
    $byPath = @{}
    foreach ($ou in @($script:State.OuList)) { $byPath[[string]$ou.CanonicalName] = [string]$ou.DistinguishedName }
    $nodes = @{}
    $c.treeOu.Items.Clear()
    foreach ($ou in @($script:State.OuList | Sort-Object -Property CanonicalName)) {
        if ($filter -and ([string]$ou.CanonicalName).IndexOf($filter, $comparison) -lt 0) { continue }
        $parts = ([string]$ou.CanonicalName).Split('/')
        $parent = $null
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $path = $parts[0..$i] -join '/'
            $node = $nodes[$path]
            if (-not $node) {
                $node = New-OuTreeItem -Name $parts[$i] -DistinguishedName ([string]$byPath[$path])
                $nodes[$path] = $node
                if ($parent) { [void]$parent.Items.Add($node) } else { [void]$c.treeOu.Items.Add($node) }
                if ($i -eq 0 -or $filter) { $node.IsExpanded = $true }
            }
            $parent = $node
        }
    }
    foreach ($node in $nodes.Values) {
        $dn = [string]$node.Tag
        if (-not $dn) { continue }
        $show = if ($picker.Multiple) { $picker.Checked.Contains($dn) } else { [string]::Equals($dn, $picker.Selected, [System.StringComparison]::OrdinalIgnoreCase) }
        if (-not $show) { continue }
        $up = $node.Parent
        while ($up -is [System.Windows.Controls.TreeViewItem]) { $up.IsExpanded = $true; $up = $up.Parent }
        if (-not $picker.Multiple) { $node.IsSelected = $true }
    }
    $c.txtOuDn.Visibility = 'Visible'
    if ($nodes.Count -eq 0) { $c.txtOuDn.Text = if ($filter) { "'$filter' ile eşleşen OU yok." } else { 'OU listesi boş.' } }
}
function New-OuTreeItem {
    [CmdletBinding()]
    [OutputType([System.Windows.Controls.TreeViewItem])]
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter()][AllowEmptyString()][string]$DistinguishedName)
    $item = New-Object -TypeName System.Windows.Controls.TreeViewItem
    $item.Tag = $DistinguishedName
    if ($DistinguishedName) { $item.ToolTip = $DistinguishedName }
    if ($script:State.OuPicker.Multiple -and $DistinguishedName) {
        $box = New-Object -TypeName System.Windows.Controls.CheckBox
        $box.Content = $Name
        $box.Tag = $DistinguishedName
        $box.IsChecked = $script:State.OuPicker.Checked.Contains($DistinguishedName)
        $box.Add_Click({
                param($sender, $e)
                $clicked = $sender
                Invoke-UiAction {
                    $set = $script:State.OuPicker.Checked
                    if ([bool]$clicked.IsChecked) { [void]$set.Add([string]$clicked.Tag) } else { [void]$set.Remove([string]$clicked.Tag) }
                    Update-OuPickerSummary
                }
            })
        $item.Header = $box
    }
    else {
        $item.Header = $Name
        if (-not $DistinguishedName) { $item.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'TextMutedBrush') }
    }
    return $item
}
function Get-OuTreeSelection {
    [CmdletBinding()]
    param()
    $tree = $script:State.OuPicker.Controls.treeOu
    if ($tree.SelectedItem) { return $tree.SelectedItem }
    $queue = New-Object -TypeName 'System.Collections.Generic.Queue[object]'
    foreach ($item in $tree.Items) { $queue.Enqueue($item) }
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        if ($item.IsSelected) { return $item }
        foreach ($child in $item.Items) { $queue.Enqueue($child) }
    }
    return $null
}
function Set-OuTreeExpanded {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Expanded)
    $queue = New-Object -TypeName 'System.Collections.Generic.Queue[object]'
    foreach ($item in $script:State.OuPicker.Controls.treeOu.Items) { $queue.Enqueue($item) }
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $item.IsExpanded = $Expanded
        foreach ($child in $item.Items) { $queue.Enqueue($child) }
    }
}
function Update-OuPickerSummary {
    [CmdletBinding()]
    param()
    $picker = $script:State.OuPicker
    $c = $picker.Controls
    if ($picker.Multiple) {
        $names = @(foreach ($dn in $picker.Checked) { $match = @($script:State.OuList | Where-Object { [string]::Equals($_.DistinguishedName, $dn, [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1; if ($match) { ([string]$match.CanonicalName).Split('/')[-1] } else { $dn } })
        $c.txtOuDn.Text = if ($names.Count -eq 0) { "Birden fazla OU işaretleyebilirsiniz. 'Alt OU'lar dahil' açıksa alt OU'lardaki kullanıcılar da eklenir." }
        else { "$($names.Count) OU seçili: " + (($names | Sort-Object | Select-Object -First 8) -join ', ') + $(if ($names.Count -gt 8) { " ve $($names.Count - 8) OU daha" } else { '' }) }
        return
    }
    $item = Get-OuTreeSelection
    $c.txtOuDn.Text = if (-not $item) { '' } elseif ($item.Tag) { [string]$item.Tag } else { 'Bu düzey seçilemez; altındaki bir OU''yu seçin.' }
}
function Confirm-DiscardChange {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($script:State.PendingCount -le 0) { return $true }
    $answer = Show-MessageDialog -Message "Kaydedilmemiş $($script:State.PendingCount) değişiklik var. Bu değişiklikler kaybolacak.`n`nDevam edilsin mi?" -Button YesNo -Icon Warning
    return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
}
function Start-UserLoad {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ObjectGuid,
        [Parameter()][switch]$Force
    )
    if (-not $Force -and -not (Confirm-DiscardChange)) { return }
    [void](Invoke-BackgroundTask -Name 'Kullanıcı bilgileri yükleniyor' -Command 'Get-UserProfileData' -Arguments @{ ObjectGuid = $ObjectGuid } -OnSuccess {
            param($Result)
            Show-UserProfile -Data $Result
            if ($script:State.SelectTabAfterLoad) { Select-MainTab -TabName $script:State.SelectTabAfterLoad; $script:State.SelectTabAfterLoad = $null }
            Write-UiLog -Message "Kullanıcı yüklendi: $($Result.Ad.DisplayName) ($($Result.Ad.SamAccountName))" -Level Success
        })
}
