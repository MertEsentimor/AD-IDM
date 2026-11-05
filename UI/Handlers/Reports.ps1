function Get-ReportFieldCatalog {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $leaveHeader = "İzin dönemleri (kapanış - açılış)"
    @(
        @('Kimlik', 'DisplayName', 'Ad Soyad (DisplayName)', $true), @('Kimlik', 'SamAccountName', 'Kullanıcı adı (SamAccountName)', $true),
        @('Kimlik', 'GivenName', 'Ad', $false), @('Kimlik', 'Surname', 'Soyad', $false), @('Kimlik', 'UserPrincipalName', 'UPN', $true),
        @('Kimlik', 'EmployeeID', 'Sicil no (EmployeeID)', $false),
        @('İletişim', 'EmailAddress', 'E-posta', $true), @('İletişim', 'ProxyAddresses', 'Tüm SMTP adresleri', $false),
        @('İletişim', 'MobilePhone', 'Cep telefonu', $false), @('İletişim', 'OfficePhone', 'İş telefonu', $false),
        @('Organizasyon', 'Department', 'Departman', $true), @('Organizasyon', 'Title', 'Unvan', $true), @('Organizasyon', 'Company', 'Şirket', $false),
        @('Organizasyon', 'Office', 'Ofis', $false), @('Organizasyon', 'City', 'Şehir', $false), @('Organizasyon', 'Manager', 'Yönetici', $false),
        @('Organizasyon', 'Description', 'Açıklama', $false),
        @('Hesap', 'Enabled', 'Etkin', $true), @('Hesap', 'LockedOut', 'Kilitli', $false), @('Hesap', 'PasswordNeverExpires', 'Parola süresiz', $false),
        @('Hesap', 'PasswordExpired', 'Parola süresi dolmuş', $false), @('Hesap', 'PasswordLastSet', 'Parola son değişim', $false),
        @('Hesap', 'LastLogonDate', 'Son oturum açma', $true), @('Hesap', 'AccountExpirationDate', 'Hesap bitiş tarihi', $false),
        @('Hesap', 'WhenCreated', 'Oluşturulma', $false), @('Hesap', 'WhenChanged', 'Son değişiklik', $false), @('Hesap', 'Leave', $leaveHeader, $false),
        @('Konum ve gruplar', 'Ou', 'OU', $true), @('Konum ve gruplar', 'DistinguishedName', 'DistinguishedName', $false), @('Konum ve gruplar', 'MemberOf', 'Grup üyelikleri', $false)
    ) | ForEach-Object { [pscustomobject]@{ Group = $_[0]; Key = $_[1]; Header = $_[2]; Default = [bool]$_[3] } }
}
function Get-ReportSelectedField {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $state = $script:State.Report
    return [string[]]@(foreach ($field in $state.Catalog) { if ([bool]$state.Boxes[$field.Key].IsChecked) { $field.Key } })
}
function Set-ReportFieldSelection {
    [CmdletBinding()]
    param([Parameter()][AllowEmptyCollection()][string[]]$Keys = @())
    $state = $script:State.Report
    foreach ($field in $state.Catalog) { $state.Boxes[$field.Key].IsChecked = $Keys -contains $field.Key }
    Update-ReportState
}
function Update-ReportState {
    [CmdletBinding()]
    param()
    $state = $script:State.Report
    if (-not $state) { return }
    $c = $state.Controls
    $fields = @(Get-ReportSelectedField)
    $c.txtRpFieldCount.Text = "$($fields.Count) / $($state.Catalog.Count) seçili"
    $busy = [bool][bool]($script:TaskEngine.CurrentJob -and -not $script:TaskEngine.CurrentJob.Silent)
    $c.btnRpRun.IsEnabled = -not $busy -and $fields.Count -gt 0 -and @($state.Ou).Count -gt 0
    $stale = $state.Rows -and (($fields -join ',') -ne $state.RowsKey)
    $c.btnRpSave.IsEnabled = -not $busy -and @($state.Rows).Count -gt 0 -and -not $stale
    if (@($state.Ou).Count -eq 0) { $c.txtRpSummary.Text = 'Başlamak için OU seçin.' }
    elseif ($fields.Count -eq 0) { $c.txtRpSummary.Text = 'En az bir alan seçin.' }
    elseif ($stale) { $c.txtRpSummary.Text = 'Seçimler değişti; kaydetmeden önce raporu yeniden oluşturun.' }
    elseif ($state.Rows) { $c.txtRpSummary.Text = "$(@($state.Rows).Count) kullanıcı, $($fields.Count) alan. Kaydetmeye hazır." }
    else { $c.txtRpSummary.Text = "Hazır: 'Raporu Oluştur' deyin." }
}
function Select-ReportOu {
    [CmdletBinding()]
    param()
    $state = $script:State.Report
    if (-not $state) { return }
    if (@($script:State.OuList).Count -eq 0) {
        $state.Controls.txtRpOu.Text = 'OU listesi okunuyor...'
        [void](Invoke-BackgroundTask -Name 'OU listesi okunuyor' -Command 'Get-OrganizationalUnitList' -OnSuccess {
                param($Result)
                $script:State.OuList = @($Result | Where-Object { $_ })
                if ($script:State.OuList.Count -gt 0 -and $script:State.Report) { Invoke-Deferred { Select-ReportOu } }
            })
        return
    }
    $subtree = [bool]$state.Subtree
    $selected = [string[]]@(Show-OuPicker -Owner $state.Window -Selected @($state.Ou | Where-Object { $_ }) -Multiple -Title 'Rapora hangi OU''lar girsin?' -AcceptText 'Seçili OU''ları Kullan' -Subtree ([ref]$subtree) | Where-Object { $_ })
    if ($selected.Count -eq 0) { return }
    $state.Ou = $selected
    $state.Subtree = $subtree
    $state.Rows = $null
    $names = @(foreach ($dn in $selected) {
            $match = @($script:State.OuList | Where-Object { [string]::Equals([string]$_.DistinguishedName, $dn, [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
            if ($match) { [string]$match.CanonicalName } else { $dn }
        }) | Sort-Object
    $state.Controls.txtRpOu.Text = "$($names.Count) OU ($(if ($subtree) { 'alt OU''lar dahil' } else { 'yalnız seçilenler' })):`n" + (($names | Select-Object -First 6) -join "`n") + $(if ($names.Count -gt 6) { "`nve $($names.Count - 6) OU daha" } else { '' })
    Update-ReportState
}
function Start-ReportRun {
    [CmdletBinding()]
    param()
    $state = $script:State.Report
    if (-not $state) { return }
    $fields = @(Get-ReportSelectedField)
    if (@($state.Ou).Count -eq 0 -or $fields.Count -eq 0) { Update-ReportState; return }
    $headers = @{}
    foreach ($field in $state.Catalog) { $headers[$field.Key] = $field.Header }
    $status = @('All', 'Enabled', 'Disabled')[[math]::Max(0, $state.Controls.cmbRpStatus.SelectedIndex)]
    $state.PendingKey = $fields -join ','
    $state.PendingFields = [string[]]$fields
    $state.Controls.txtRpSummary.Text = 'Rapor oluşturuluyor...'
    $started = Invoke-BackgroundTask -Name 'Rapor oluşturuluyor' -Command 'Get-UserReport' -Arguments @{ SearchBase = [string[]]$state.Ou; Subtree = [bool]$state.Subtree; Status = $status; Fields = [string[]]$fields; Headers = $headers } -OnSuccess {
        param($Result)
        Show-ReportResult -Rows $Result
    } -OnFailure {
        param($Message)
        if ($script:State.Report) { $script:State.Report.Controls.txtRpSummary.Text = "Rapor oluşturulamadı: $Message" }
    }
    if (-not $started) { $state.Controls.txtRpSummary.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' }
}
function Show-ReportResult {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Rows)
    $state = $script:State.Report
    if (-not $state) { return }
    $items = @($Rows | Where-Object { $_ -and $_ -is [psobject] -and $_.PSObject.Properties.Name })
    $table = New-Object -TypeName System.Data.DataTable
    $headers = if ($items.Count -gt 0) { @($items[0].PSObject.Properties.Name) } else { @() }
    $keys = @($state.PendingFields)
    $columns = New-Object -TypeName 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $name = if ($i -lt $keys.Count -and $keys[$i]) { [string]$keys[$i] } else { "Col$i" }
        $column = $table.Columns.Add($name, [string])
        $column.Caption = [string]$headers[$i]
        $columns.Add($name)
    }
    foreach ($item in $items) {
        $row = $table.NewRow()
        for ($i = 0; $i -lt $headers.Count; $i++) { $row[$columns[$i]] = [string]$item.($headers[$i]) }
        [void]$table.Rows.Add($row)
    }
    $state.Table = $table
    $state.Rows = $items
    $state.RowsKey = $state.PendingKey
    $state.Controls.dgRp.ItemsSource = $table.DefaultView
    $state.Controls.txtRpEmpty.Text = 'Seçilen OU''larda ölçütlere uyan kullanıcı yok.'
    $state.Controls.txtRpEmpty.Visibility = if ($items.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    Write-UiLog -Message "Rapor oluşturuldu: $($items.Count) kullanıcı." -Level Success
    Update-ReportState
}
function Export-ReportCsv {
    [CmdletBinding()]
    param()
    $state = $script:State.Report
    if (-not $state -or @($state.Rows).Count -eq 0) { return }
    $dialog = New-Object -TypeName Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'CSV dosyası (*.csv)|*.csv|Tüm dosyalar (*.*)|*.*'
    $dialog.FileName = 'KullaniciRaporu_{0:yyyyMMdd_HHmm}.csv' -f (Get-Date)
    if (-not $dialog.ShowDialog($state.Window)) { return }
    $delimiter = switch ($state.Controls.cmbRpDelimiter.SelectedIndex) { 1 { ',' } 2 { "`t" } default { ';' } }
    $encoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    try {
        $state.Rows | Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding $encoding -Delimiter $delimiter -ErrorAction Stop
        Save-AppSetting -Values @{ ReportFields = [string[]]@(Get-ReportSelectedField); ReportDelimiter = [int]$state.Controls.cmbRpDelimiter.SelectedIndex }
        $state.Controls.txtRpSummary.Text = "Kaydedildi: $($dialog.FileName) ($(@($state.Rows).Count) satır)"
        Write-UiLog -Message "Rapor kaydedildi: $($dialog.FileName)" -Level Success
    }
    catch {
        $state.Controls.txtRpSummary.Text = "Kaydedilemedi: $($_.Exception.Message)"
        Write-UiLog -Message "Rapor kaydedilemedi: $($_.Exception.Message)" -Level Error
    }
}
function Initialize-ReportPage {
    [CmdletBinding()]
    param()
    $catalog = @(Get-ReportFieldCatalog)
    $script:State.Report = @{ Window = $script:Window; Controls = $script:Ui; Catalog = $catalog; Boxes = @{}; Ou = @($script:State.OuSearch.Dn | Where-Object { $_ }); Subtree = [bool]$script:State.OuSearch.Subtree; Rows = $null; RowsKey = ''; PendingKey = ''; PendingFields = @(); Table = $null }
    $c = $script:Ui
        $state = $script:State.Report
        $saved = Read-AppSetting
        $savedFields = @(if ($saved -and $saved.PSObject.Properties['ReportFields']) { @($saved.ReportFields | ForEach-Object { [string]$_ }) })
        if ($saved -and $saved.PSObject.Properties['ReportDelimiter']) { $c.cmbRpDelimiter.SelectedIndex = [math]::Min(2, [math]::Max(0, [int]$saved.ReportDelimiter)) }
        $group = ''
        foreach ($field in $catalog) {
            if ($field.Group -ne $group) {
                $group = $field.Group
                $label = New-Object -TypeName System.Windows.Controls.TextBlock
                $label.Text = $group
                $label.Style = $script:Window.TryFindResource('FieldLabel')
                $label.Margin = [System.Windows.Thickness]::new(0, $(if ($c.pnlRpFields.Children.Count -gt 0) { 8 } else { 0 }), 0, 4)
                [void]$c.pnlRpFields.Children.Add($label)
            }
            $box = New-Object -TypeName System.Windows.Controls.CheckBox
            $box.Content = $field.Header
            $box.Tag = $field.Key
            $box.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
            $box.IsChecked = if ($savedFields.Count -gt 0) { $savedFields -contains $field.Key } else { $field.Default }
            $box.Add_Click({ Invoke-UiAction { Update-ReportState } })
            $state.Boxes[$field.Key] = $box
            [void]$c.pnlRpFields.Children.Add($box)
        }
        $c.dgRp.Add_AutoGeneratingColumn({
                param($sender, $e)
                $table = $script:State.Report.Table
                if ($table -and $table.Columns.Contains($e.PropertyName)) { $e.Column.Header = $table.Columns[$e.PropertyName].Caption }
                $e.Column.MaxWidth = 420
            })
        $c.btnRpOu.Add_Click({ Invoke-UiAction { Select-ReportOu } })
        $c.btnRpAll.Add_Click({ Invoke-UiAction { Set-ReportFieldSelection -Keys @($script:State.Report.Catalog | ForEach-Object { $_.Key }) } })
        $c.btnRpDefault.Add_Click({ Invoke-UiAction { Set-ReportFieldSelection -Keys @($script:State.Report.Catalog | Where-Object { $_.Default } | ForEach-Object { $_.Key }) } })
        $c.btnRpNone.Add_Click({ Invoke-UiAction { Set-ReportFieldSelection -Keys @() } })
        $c.cmbRpStatus.Add_SelectionChanged({ Invoke-UiAction { if ($script:State.Report) { $script:State.Report.RowsKey = '#'; Update-ReportState } } })
        $c.btnRpRun.Add_Click({ Invoke-UiAction { Start-ReportRun } })
        $c.btnRpSave.Add_Click({ Invoke-UiAction { Export-ReportCsv } })
        Update-ReportState
}
function Sync-ReportOu {
    [CmdletBinding()]
    param()
    $state = $script:State.Report
    $c = $script:Ui
    if (@($state.Ou).Count -gt 0 -or @($script:State.OuSearch.Dn | Where-Object { $_ }).Count -eq 0) { return }
    $state.Ou = @($script:State.OuSearch.Dn | Where-Object { $_ })
    $state.Subtree = [bool]$script:State.OuSearch.Subtree
        if (@($state.Ou).Count -gt 0) {
            $names = @(foreach ($dn in $state.Ou) { $match = @($script:State.OuList | Where-Object { [string]::Equals([string]$_.DistinguishedName, $dn, [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1; if ($match) { [string]$match.CanonicalName } else { $dn } }) | Sort-Object
            $c.txtRpOu.Text = "Son OU araması kullanılıyor ($($names.Count) OU):`n" + (($names | Select-Object -First 6) -join "`n") + $(if ($names.Count -gt 6) { "`nve $($names.Count - 6) OU daha" } else { '' })
        }
    Update-ReportState
}
