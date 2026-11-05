function Update-AddressView {
    [CmdletBinding()]
    param()
    $items = foreach ($entry in $script:State.SmtpList) {
        $isPrimary = $entry.StartsWith('SMTP:', [System.StringComparison]::Ordinal)
        [pscustomobject]@{
            Address   = $entry.Substring(5)
            IsPrimary = $isPrimary
            TypeText  = if ($isPrimary) { 'BİRİNCİL' } else { 'Alias' }
            Raw       = $entry
        }
    }
    $script:Ui.lstAddresses.ItemsSource = @($items | Sort-Object -Property @{ Expression = 'IsPrimary'; Descending = $true }, Address)
}
function Show-ArchiveInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Exchange)
    $archive = $Exchange.Archive
    if (-not $archive) {
        $script:Ui.pnlArchive.Visibility = 'Collapsed'
        $script:Ui.txtArchiveNotice.Text = if ($Exchange.Mode -eq 'None') { 'Arşiv bilgilerini görmek ve yönetmek için Exchange''e bağlanın.' }
        elseif ($Exchange.AddressSource -eq 'RemoteMailbox') { 'Kullanıcının posta kutusu bulutta (hibrit uzak posta kutusu); arşiv bu araçtan yönetilemez.' }
        else { 'Bu kullanıcı için posta kutusu bulunamadı; arşiv yönetilemiyor.' }
        $script:Ui.bdArchiveNotice.Visibility = 'Visible'
        return
    }
    $script:Ui.bdArchiveNotice.Visibility = 'Collapsed'
    $script:Ui.pnlArchive.Visibility = 'Visible'
    $statusText = if ($archive.Status) { " ($($archive.Status))" } else { '' }
    if ($archive.Enabled) { Set-Badge -BorderName bdgArchive -TextName txtArchiveState -Text "Arşiv etkin$statusText" -Kind Success }
    else { Set-Badge -BorderName bdgArchive -TextName txtArchiveState -Text 'Arşiv etkin değil' -Kind Neutral }
    $options = @($Exchange.DatabaseOptions)
    if ($Exchange.Mode -eq 'OnPremises' -and -not $archive.Enabled -and $options.Count -gt 0) {
        $script:Ui.cmbArchiveDb.ItemsSource = $options
        $script:Ui.cmbArchiveDb.SelectedItem = $(if ($options -contains $Exchange.Database) { $Exchange.Database } else { $options[0] })
        $script:Ui.cmbArchiveDb.Visibility = 'Visible'
    }
    else {
        $script:Ui.cmbArchiveDb.ItemsSource = $null
        $script:Ui.cmbArchiveDb.Visibility = 'Collapsed'
    }
    $script:Ui.txtArchiveName.Text = if ($archive.Name) { $archive.Name } else { '-' }
    $script:Ui.txtArchiveDb.Text = if ($archive.Database) { $archive.Database } else { '-' }
    $script:Ui.txtArchiveAutoExpand.Text = $archive.AutoExpanding
    $script:Ui.txtArchiveQuota.Text = $archive.Quota
    $script:Ui.txtArchiveWarnQuota.Text = $archive.WarningQuota
    $script:Ui.txtArchiveItems.Text = if ($null -ne $archive.ItemCount) { '{0:N0}' -f $archive.ItemCount } else { '-' }
    if ($archive.Enabled) {
        $script:Ui.txtArchiveSize.Text = $archive.TotalItemSize
        $script:Ui.txtArchiveOfQuota.Text = "/ $($archive.Quota)"
        if ($null -ne $archive.UsagePercent) {
            $percent = [double]$archive.UsagePercent
            $script:Ui.prgArchive.Value = [math]::Min(100, $percent)
            $script:Ui.prgArchive.SetResourceReference([System.Windows.Controls.ProgressBar]::ForegroundProperty, $(if ($percent -ge 90) { 'DangerBrush' } elseif ($percent -ge 75) { 'WarningBrush' } else { 'SuccessBrush' }))
            $script:Ui.txtArchivePercent.Text = "Doluluk: %$percent (arşiv kotasına göre)"
        }
        else {
            $script:Ui.prgArchive.Value = 0
            $script:Ui.txtArchivePercent.Text = if ($archive.StatsError) { "Arşiv istatistikleri okunamadı: $($archive.StatsError)" } else { 'Doluluk oranı hesaplanamadı.' }
        }
    }
    else {
        $script:Ui.txtArchiveSize.Text = '-'
        $script:Ui.txtArchiveOfQuota.Text = ''
        $script:Ui.prgArchive.Value = 0
        $script:Ui.txtArchivePercent.Text = 'Arşiv etkinleştirildiğinde boyut ve öğe sayısı burada görünür.'
    }
}
function Show-DatabaseInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Exchange)
    if ($Exchange.Mode -ne 'OnPremises' -or -not $Exchange.Database) {
        $script:Ui.pnlDatabase.Visibility = 'Collapsed'
        $script:Ui.txtDbNotice.Text = switch ($Exchange.Mode) {
            'None' { 'Veritabanı bilgisi ve taşıma için Exchange On-Premises''e bağlanın.' }
            default { 'Bu kullanıcının bu sunucuda bir posta kutusu yok (uzak posta kutusu veya posta kutusu yok); veritabanı taşıma yapılamaz.' }
        }
        $script:Ui.bdDbNotice.Visibility = 'Visible'
        $script:State.CurrentMove = $null
        return
    }
    $script:Ui.bdDbNotice.Visibility = 'Collapsed'
    $script:Ui.pnlDatabase.Visibility = 'Visible'
    $script:Ui.txtCurrentDb.Text = $Exchange.Database
    $script:Ui.txtCurrentArchiveDb.Text = if ($Exchange.ArchiveDatabase) { $Exchange.ArchiveDatabase } else { '-' }
    $targets = @($Exchange.DatabaseOptions | Where-Object { $_ -and $_ -ne $Exchange.Database })
    $script:Ui.cmbTargetDb.ItemsSource = $targets
    $script:Ui.cmbTargetDb.SelectedIndex = -1
    $script:Ui.cmbMoveScope.SelectedIndex = 0
    $move = $Exchange.Move
    Show-MoveStatus -Move $move
    if ($move -and $move.Exists -and -not $move.IsFinal) { Add-MonitoredMove -Move $move }
}
function Get-MoveStatusText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$Status)
    switch ($Status) {
        'Queued' { 'Kuyrukta' }
        'InProgress' { 'Sürüyor' }
        'CompletionInProgress' { 'Tamamlanıyor' }
        'AutoSuspended' { 'Otomatik askıya alındı (tamamlanmayı bekliyor)' }
        'Suspended' { 'Askıya alındı' }
        'Completed' { 'Tamamlandı' }
        'CompletedWithWarning' { 'Uyarılarla tamamlandı' }
        'Failed' { 'Başarısız' }
        default { $Status }
    }
}
function Show-MoveStatus {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][psobject]$Move)
    $script:State.CurrentMove = $Move
    if (-not $Move -or -not $Move.Exists) {
        $script:Ui.txtMoveStatus.Text = 'Aktif taşıma isteği yok'
        $script:Ui.txtMoveStatus.ClearValue([System.Windows.Controls.TextBlock]::ForegroundProperty)
        $script:Ui.prgMove.Value = 0
        $script:Ui.txtMoveDetail.Text = ''
        $script:Ui.txtMoveUpdated.Text = if ($Move) { "Son kontrol: $(([datetime]$Move.CheckedAt).ToString('HH:mm:ss'))" } else { '' }
        Update-ActionState
        return
    }
    $percent = [int]$Move.PercentComplete
    $text = '{0}  -  %{1}' -f (Get-MoveStatusText -Status $Move.Status), $percent
    if ($Move.StatusDetail -and $Move.StatusDetail -ne $Move.Status) { $text += "  ($($Move.StatusDetail))" }
    $script:Ui.txtMoveStatus.Text = $text
    $colorToken = switch -Wildcard ($Move.Status) { 'Completed*' { 'SuccessBrush' } 'Failed' { 'DangerBrush' } '*Suspended' { 'WarningBrush' } default { 'AccentTextBrush' } }
    $script:Ui.txtMoveStatus.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $colorToken)
    $script:Ui.prgMove.Value = [math]::Min(100, $percent)
    $script:Ui.prgMove.SetResourceReference([System.Windows.Controls.ProgressBar]::ForegroundProperty, $colorToken)
    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $lines.Add("Kaynak: $($Move.SourceDatabase)   ->   Hedef: $($Move.TargetDatabase)")
    $lines.Add("Aktarılan: $($Move.BytesTransferred) / $($Move.TotalMailboxSize)")
    $times = @()
    if ($Move.QueuedTimestamp) { $times += "Kuyruğa alındı: $(Format-DateText -Date $Move.QueuedTimestamp)" }
    if ($Move.StartTimestamp) { $times += "Başladı: $(Format-DateText -Date $Move.StartTimestamp)" }
    if ($Move.CompletionTimestamp) { $times += "Tamamlandı: $(Format-DateText -Date $Move.CompletionTimestamp)" }
    if ($times.Count -gt 0) { $lines.Add($times -join '   |   ') }
    if ($Move.FailureMessage) { $lines.Add("Hata: $($Move.FailureMessage)") }
    if ($Move.Status -eq 'AutoSuspended') { $lines.Add('Not: İstek -SuspendWhenReadyToComplete ile oluşturulmuş; tamamlamak için Resume-MoveRequest gerekir.') }
    if ($Move.IsFinal) { $lines.Add('İşlem sona erdi. Yeni taşıma başlatmadan önce "İsteği Kaldır" ile tamamlanmış isteği temizleyin.') }
    $script:Ui.txtMoveDetail.Text = $lines -join "`n"
    $script:Ui.txtMoveUpdated.Text = "Son kontrol: $(([datetime]$Move.CheckedAt).ToString('HH:mm:ss'))"
    Update-ActionState
}
function Show-PolicyState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Exchange)
    $policies = $Exchange.Policies
    $script:State.OriginalPolicy = $null
    if (-not $policies) {
        foreach ($key in $script:PolicyMap.Keys) {
            $combo = $script:Ui[$script:PolicyMap[$key].Combo]
            $combo.ItemsSource = $null
            $combo.IsEnabled = $false
        }
        $script:Ui.txtPolicyNotice.Text = if ($Exchange.Mode -eq 'None') { 'Politikaları görmek ve değiştirmek için Exchange''e bağlanın.' }
        else { 'Bu kullanıcı için politika bilgisi bu bağlantı üzerinden okunamadı (posta kutusu yok veya farklı ortamda).' }
        $script:Ui.bdPolicyNotice.Visibility = 'Visible'
        return
    }
    $script:Ui.bdPolicyNotice.Visibility = 'Collapsed'
    $script:State.OriginalPolicy = @{}
    $unreadable = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($key in $script:PolicyMap.Keys) {
        $definition = $script:PolicyMap[$key]
        $combo = $script:Ui[$definition.Combo]
        $entry = $policies.$key
        $current = if ($entry) { [string]$entry.Current } else { '' }
        $options = New-Object -TypeName 'System.Collections.Generic.List[string]'
        if ($definition.AllowNone -or -not $current) { $options.Add($script:NoPolicyText) }
        foreach ($option in @($entry.Options)) { if ($option -and -not $options.Contains([string]$option)) { $options.Add([string]$option) } }
        if ($current -and -not $options.Contains($current)) { $options.Add($current) }
        $combo.ItemsSource = $options.ToArray()
        $combo.SelectedItem = if ($current) { $current } else { $script:NoPolicyText }
        $canChange = @($entry.Options).Count -gt 0
        $combo.IsEnabled = $canChange
        if (-not $canChange) { $unreadable.Add($definition.Text) }
        $script:State.OriginalPolicy[$key] = $current
    }
    if ($unreadable.Count -gt 0) {
        $script:Ui.txtPolicyNotice.Text = "Şu politikaların listesi okunamadı (yetki veya ortam desteği yok), yalnızca mevcut değer gösteriliyor: $($unreadable -join ', ')"
        $script:Ui.bdPolicyNotice.Visibility = 'Visible'
    }
}
function Get-SelectedPolicy {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Key)
    $value = [string]$script:Ui[$script:PolicyMap[$Key].Combo].SelectedItem
    if ($value -eq $script:NoPolicyText) { return '' }
    return $value
}
function ConvertTo-AddressKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$Addresses)
    $normalized = foreach ($address in @($Addresses | Where-Object { $_ })) { $address.Substring(0, 5) + $address.Substring(5).ToLowerInvariant() }
    return (@($normalized) | Sort-Object) -join '|'
}
function Get-PrimarySmtp {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$Addresses)
    $primary = @($Addresses | Where-Object { $_ -and $_.StartsWith('SMTP:', [System.StringComparison]::Ordinal) }) | Select-Object -First 1
    if ($primary) { return $primary.Substring(5).ToLowerInvariant() }
    return ''
}
function Add-SmtpAlias {
    [CmdletBinding()]
    param()
    $address = ([string]$script:Ui.txtNewAddress.Text).Trim()
    if ($address -like 'smtp:*') { $address = $address.Substring(5) }
    if ($address -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        Write-UiLog -Message "Geçersiz e-posta adresi: '$address'" -Level Warning
        return
    }
    foreach ($existing in $script:State.SmtpList) {
        if ([string]::Equals($existing.Substring(5), $address, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-UiLog -Message "Adres zaten listede: $address" -Level Warning
            return
        }
    }
    $hasPrimary = [bool](Get-PrimarySmtp -Addresses $script:State.SmtpList.ToArray())
    $script:State.SmtpList.Add($(if ($hasPrimary) { "smtp:$address" } else { "SMTP:$address" }))
    $script:Ui.txtNewAddress.Text = ''
    Update-AddressView
    Update-ChangeIndicator
}
function Set-SelectedPrimarySmtp {
    [CmdletBinding()]
    param()
    $selected = $script:Ui.lstAddresses.SelectedItem
    if (-not $selected) { Write-UiLog -Message 'Birincil yapmak için listeden bir adres seçin.' -Level Warning; return }
    $newList = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($entry in $script:State.SmtpList) {
        $address = $entry.Substring(5)
        if ([string]::Equals($address, $selected.Address, [System.StringComparison]::OrdinalIgnoreCase)) { $newList.Add("SMTP:$address") }
        else { $newList.Add("smtp:$address") }
    }
    $script:State.SmtpList = $newList
    Update-AddressView
    Update-ChangeIndicator
}
function Remove-SelectedSmtp {
    [CmdletBinding()]
    param()
    $selected = $script:Ui.lstAddresses.SelectedItem
    if (-not $selected) { Write-UiLog -Message 'Kaldırmak için listeden bir adres seçin.' -Level Warning; return }
    if ($selected.IsPrimary -and $script:State.CurrentData.Exchange.AddressSource -ne 'AD') {
        Write-UiLog -Message 'Birincil adres kaldırılamaz. Önce başka bir adresi birincil yapın.' -Level Warning
        return
    }
    [void]$script:State.SmtpList.Remove($selected.Raw)
    Update-AddressView
    Update-ChangeIndicator
}
function Test-ExchangeReady {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $exchange = $script:State.CurrentData.Exchange
    if ($script:Sync.ExchangeMode -eq 'None') {
        [void](Show-MessageDialog -Message 'Bu işlem için Exchange bağlantısı gerekiyor.' -Icon Warning)
        return $false
    }
    if ($exchange.Mode -ne $script:Sync.ExchangeMode) {
        [void](Show-MessageDialog -Message 'Exchange bağlantısı kullanıcı yüklendikten sonra değişti. Lütfen kullanıcıyı yenileyin (F5).' -Icon Warning)
        return $false
    }
    if (-not $exchange.Identity) {
        [void](Show-MessageDialog -Message 'Kullanıcının posta kutusu kimliği belirlenemedi.' -Icon Warning)
        return $false
    }
    return $true
}
function Start-ExchangeConnection {
    [CmdletBinding()]
    param()
    if ($script:Sync.ExchangeMode -ne 'None') {
        [void](Invoke-BackgroundTask -Name 'Exchange bağlantısı kesiliyor' -Command 'Disconnect-ExchangeEnvironment' -OnSuccess {
                param($Result)
                Update-ConnectionIndicator
                if ($script:State.CurrentData) { Start-UserLoad -ObjectGuid $script:State.CurrentData.Ad.ObjectGuid -Force }
            })
        return
    }
    $arguments = @{}
    switch ($script:Ui.cmbExMode.SelectedIndex) {
        1 {
            $server = ([string]$script:Ui.cmbExServer.Text).Trim()
            if (-not $server) {
                [void](Show-MessageDialog -Message 'Lütfen Exchange sunucusunun FQDN adını girin (ör. ex01.contoso.local).' -Icon Warning)
                return
            }
            $arguments.Mode = 'OnPremises'
            $arguments.Server = $server
            $defaultUser = if ($script:State.LastExchangeUser) { $script:State.LastExchangeUser } else { "$env:USERDOMAIN\" }
            $credential = Show-CredentialDialog -Server $server -DefaultUserName $defaultUser
            if (-not $credential) {
                Write-UiLog -Message 'Kimlik bilgisi girilmedi; Exchange bağlantısı iptal edildi.' -Level Warning
                return
            }
            $script:State.LastExchangeUser = $credential.UserName
            $arguments.Credential = $credential
        }
        default {
            [void](Show-MessageDialog -Message 'Lütfen bir Exchange bağlantı türü seçin.' -Icon Information)
            return
        }
    }
    [void](Invoke-BackgroundTask -Name 'Exchange bağlantısı kuruluyor' -Command 'Connect-ExchangeEnvironment' -Arguments $arguments -OnSuccess {
            param($Result)
            Update-ConnectionIndicator
            if ($script:State.CurrentData) { Start-UserLoad -ObjectGuid $script:State.CurrentData.Ad.ObjectGuid -Force }
        } -OnFailure {
            param($Message)
            Update-ConnectionIndicator
            $hint = ''
            if ($Message -match 'management roles|CmdletAccessDenied') {
                $hint = "`n`nGirilen hesaba Exchange yönetim rolü atanmamış. Recipient Management veya Organization Management rol grubuna üye bir hesapla tekrar deneyin."
            }
            elseif ($Message -match 'Access is denied|Erişim engellendi|logon failure|user name or password') {
                $hint = "`n`nKullanıcı adı veya parola hatalı olabilir."
            }
            [void](Show-MessageDialog -Message "Exchange bağlantısı kurulamadı:`n`n$Message$hint" -Icon Error)
        })
}
function Show-CredentialDialog {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter()][string]$DefaultUserName
    )
    $dialog = New-MainWindow -Xaml $script:CredentialXaml
    $script:CredDialog = @{ Window = $dialog.Window; Controls = $dialog.Controls; Result = $null }
    try {
        $dialog.Window.Owner = $script:Window
        $dialog.Controls.txtCredServer.Text = "Sunucu: $Server"
        $dialog.Controls.txtCredUser.Text = $DefaultUserName
        $dialog.Controls.btnCredOk.Add_Click({
                Invoke-UiAction {
                    $controls = $script:CredDialog.Controls
                    $userName = ([string]$controls.txtCredUser.Text).Trim()
                    $error_ = $null
                    if (-not $userName -or $userName.EndsWith('\')) { $error_ = 'Lütfen kullanıcı adını girin.' }
                    elseif ($controls.pwdCred.SecurePassword.Length -eq 0) { $error_ = 'Lütfen parolayı girin.' }
                    if ($error_) {
                        $controls.txtCredError.Text = $error_
                        $controls.txtCredError.Visibility = 'Visible'
                        return
                    }
                    if ($userName -notmatch '[\\@]' -and $script:State.Environment -and $script:State.Environment.NetBiosName) {
                        $userName = '{0}\{1}' -f $script:State.Environment.NetBiosName, $userName
                    }
                    $script:CredDialog.Result = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $userName, $controls.pwdCred.SecurePassword
                    $script:CredDialog.Window.DialogResult = $true
                }
            })
        $dialog.Window.Add_ContentRendered({
                $controls = $script:CredDialog.Controls
                $user = [string]$controls.txtCredUser.Text
                if ($user -and -not $user.EndsWith('\')) { [void]$controls.pwdCred.Focus() }
                else { [void]$controls.txtCredUser.Focus(); $controls.txtCredUser.CaretIndex = $user.Length }
            })
        [void]$dialog.Window.ShowDialog()
        return $script:CredDialog.Result
    }
    finally {
        $script:CredDialog = $null
    }
}
function Start-ArchiveChange {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Enable)
    $data = $script:State.CurrentData
    if (-not $data -or -not (Test-ExchangeReady)) { return }
    if (Test-ActionBlockedByChange) { return }
    $arguments = @{ Identity = [string]$data.Exchange.Identity; Enable = $Enable }
    if ($Enable) {
        $message = "'$($data.Ad.SamAccountName)' için arşiv posta kutusu etkinleştirilecek (Enable-Mailbox -Archive)."
        $database = [string]$script:Ui.cmbArchiveDb.SelectedItem
        if ($script:Sync.ExchangeMode -eq 'OnPremises' -and $database) {
            $arguments.ArchiveDatabase = $database
            $message += "`n`nArşiv veritabanı: $database"
        }
        $icon = [System.Windows.MessageBoxImage]::Question
    }
    else {
        $message = "'$($data.Ad.SamAccountName)' için arşiv posta kutusu devre dışı bırakılacak (Disable-Mailbox -Archive).`n`nDİKKAT: Arşiv kullanıcıdan ayrılır. "
        $message += 'On-Premises''te bağlantısı kesilen arşiv, veritabanının "silinen posta kutusu saklama" süresi dolunca kalıcı olarak silinir.'
        $icon = [System.Windows.MessageBoxImage]::Warning
    }
    if (-not (Confirm-Action -Message $message -Icon $icon)) { return }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf }
    $name = if ($Enable) { 'Arşiv etkinleştiriliyor' } else { 'Arşiv devre dışı bırakılıyor' }
    $script:State.ActionContext.Title = if ($Enable) { 'Arşiv etkinleştirme' } else { 'Arşivi devre dışı bırakma' }
    [void](Invoke-BackgroundTask -Name $name -Command 'Set-UserArchiveState' -Arguments (Get-ActionArgument $arguments) -OnSuccess {
            param($Result)
            Complete-SingleAction -Title $script:State.ActionContext.Title -Results $null -Simulated $script:State.ActionContext.Simulate
        })
}
function Add-MonitoredMove {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Move)
    if (-not $Move.Identity) { return }
    $script:State.MonitoredMoves[[string]$Move.Identity] = $Move
    Update-MoveMonitor
}
function Update-MoveMonitor {
    [CmdletBinding()]
    param()
    $moves = @($script:State.MonitoredMoves.Values)
    if ($moves.Count -eq 0) {
        $script:Ui.txtMonitor.Visibility = 'Collapsed'
        $script:Ui.txtMonitor.Text = ''
        return
    }
    $parts = foreach ($move in $moves) {
        $label = if ($move.DisplayName) { $move.DisplayName } else { $move.Identity }
        '{0}: {1} %{2}' -f $label, (Get-MoveStatusText -Status $move.Status), [int]$move.PercentComplete
    }
    $script:Ui.txtMonitor.Text = "Taşıma izleniyor ($($moves.Count))  |  " + ($parts -join '  |  ')
    $script:Ui.txtMonitor.ToolTip = 'Taşıma istekleri 15 saniyede bir kontrol edilir. Ayrıntılar: Veritabanı ve Taşıma sekmesi.'
    $script:Ui.txtMonitor.Visibility = 'Visible'
}
function Receive-MoveStatus {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Results)
    $currentIdentity = if ($script:State.CurrentData) { [string]$script:State.CurrentData.Exchange.Identity } else { $null }
    $reloadCurrent = $false
    foreach ($move in @($Results | Where-Object { $_ })) {
        $identity = [string]$move.Identity
        $previous = $script:State.MonitoredMoves[$identity]
        if ($currentIdentity -and $identity -eq $currentIdentity) { Show-MoveStatus -Move $move }
        if ($move.Exists -and -not $move.IsFinal) {
            if ($previous -and $previous.Status -ne $move.Status) {
                Write-UiLog -Message ("Taşıma durumu değişti: {0} -> {1} (%{2})" -f $(if ($move.DisplayName) { $move.DisplayName } else { $identity }), (Get-MoveStatusText -Status $move.Status), $move.PercentComplete) -Level Info
            }
            $script:State.MonitoredMoves[$identity] = $move
            continue
        }
        if ($previous) {
            [void]$script:State.MonitoredMoves.Remove($identity)
            $label = if ($move.DisplayName) { $move.DisplayName } elseif ($previous.DisplayName) { $previous.DisplayName } else { $identity }
            if (-not $move.Exists) { Write-UiLog -Message "Taşıma isteği artık yok (kaldırılmış): $label" -Level Warning }
            elseif ($move.Status -eq 'Failed') { Write-UiLog -Message "Taşıma BAŞARISIZ: $label  -  $($move.FailureMessage)" -Level Error }
            else { Write-UiLog -Message "Taşıma tamamlandı: $label -> $($move.TargetDatabase) ($(Get-MoveStatusText -Status $move.Status))" -Level Success }
            if ($currentIdentity -and $identity -eq $currentIdentity -and $move.Exists -and $move.Status -ne 'Failed') { $reloadCurrent = $true }
        }
    }
    Update-MoveMonitor
    if ($reloadCurrent -and $script:State.PendingCount -eq 0) { Start-UserLoad -ObjectGuid $script:State.CurrentData.Ad.ObjectGuid -Force }
}
function Start-MovePoll {
    [CmdletBinding()]
    param()
    if ($script:State.MonitoredMoves.Count -eq 0 -or $script:State.CurrentJob) { return }
    if (-not $script:Ui.chkMoveAutoRefresh.IsChecked -or $script:Sync.ExchangeMode -ne 'OnPremises') { return }
    $identities = [string[]]@($script:State.MonitoredMoves.Keys)
    [void](Invoke-BackgroundTask -Name 'Taşıma durumu izleme' -Command 'Get-MailboxMoveStatus' -Arguments @{ Identity = $identities } -Silent -OnSuccess {
            param($Result)
            Receive-MoveStatus -Results $Result
        })
}
function Start-MoveRefresh {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data -or -not (Test-ExchangeReady)) { return }
    [void](Invoke-BackgroundTask -Name 'Taşıma durumu sorgulanıyor' -Command 'Get-MailboxMoveStatus' -Arguments @{ Identity = [string[]]@([string]$data.Exchange.Identity) } -OnSuccess {
            param($Result)
            $move = @($Result | Where-Object { $_ }) | Select-Object -First 1
            if ($move -and $move.Exists -and -not $move.IsFinal) { Add-MonitoredMove -Move $move }
            Receive-MoveStatus -Results $move
            if ($move -and -not $move.Exists) { Write-UiLog -Message 'Bu kullanıcı için taşıma isteği yok.' -Level Info }
        })
}
function Start-MailboxMoveAction {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data -or -not (Test-ExchangeReady)) { return }
    $target = [string]$script:Ui.cmbTargetDb.SelectedItem
    if (-not $target) {
        [void](Show-MessageDialog -Message 'Lütfen hedef veritabanını seçin.' -Icon Warning)
        return
    }
    $scope = switch ($script:Ui.cmbMoveScope.SelectedIndex) { 1 { 'PrimaryOnly' } 2 { 'ArchiveOnly' } default { 'All' } }
    $archiveEnabled = $data.Exchange.Archive -and $data.Exchange.Archive.Enabled
    if ($scope -eq 'ArchiveOnly' -and -not $archiveEnabled) {
        [void](Show-MessageDialog -Message 'Kullanıcının arşivi etkin değil; "Yalnızca arşiv" taşıması yapılamaz.' -Icon Warning)
        return
    }
    if ($script:State.CurrentMove -and $script:State.CurrentMove.Exists) {
        [void](Show-MessageDialog -Message 'Bu posta kutusu için zaten bir taşıma isteği var. Yeni taşıma için önce tamamlanmış/başarısız isteği "İsteği Kaldır" ile temizleyin.' -Icon Warning)
        return
    }
    $scopeText = switch ($scope) { 'PrimaryOnly' { 'yalnızca birincil posta kutusu' } 'ArchiveOnly' { 'yalnızca arşiv' } default { $(if ($archiveEnabled) { 'posta kutusu ve arşiv' } else { 'posta kutusu' }) } }
    $message = "'$($data.Ad.SamAccountName)' için taşıma isteği oluşturulacak (New-MoveRequest).`n`n| Kaynak: $($data.Exchange.Database)`n| Hedef: $target`n| Kapsam: $scopeText`n`nTaşıma Mailbox Replication Service (MRS) tarafından arka planda yürütülür; ilerleme bu sekmede ve durum çubuğunda izlenir. Tamamlanma aşamasında kullanıcının Outlook bağlantısı kısa süre kesilebilir."
    if (-not (Confirm-Action -Message $message)) { return }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf }
    $script:State.ActionContext.Sam = $data.Ad.SamAccountName
    $script:State.ActionContext.Target = $target
    $arguments = Get-ActionArgument @{ Identity = [string]$data.Exchange.Identity; TargetDatabase = $target; Scope = $scope }
    [void](Invoke-BackgroundTask -Name 'Taşıma isteği oluşturuluyor' -Command 'Start-MailboxMove' -Arguments $arguments -OnSuccess {
            param($Result)
            if ($script:State.ActionContext.Simulate) {
                [void](Show-MessageDialog -Message 'Taşıma simüle edildi. Hiçbir istek oluşturulmadı.' -Icon Information)
                return
            }
            $move = @($Result | Where-Object { $_ }) | Select-Object -First 1
            if ($move) {
                Show-MoveStatus -Move $move
                if ($move.Exists -and -not $move.IsFinal) { Add-MonitoredMove -Move $move }
            }
            $script:Ui.chkMoveAutoRefresh.IsChecked = $true
            Write-UiLog -Message "Taşıma izlemeye alındı: $($script:State.ActionContext.Sam) -> $($script:State.ActionContext.Target)" -Level Info
        })
}
function Remove-MoveAction {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    $move = $script:State.CurrentMove
    if (-not $data -or -not $move -or -not $move.Exists -or -not (Test-ExchangeReady)) { return }
    $message = "'$($data.Ad.SamAccountName)' için taşıma isteği kaldırılacak (Remove-MoveRequest). Durum: $(Get-MoveStatusText -Status $move.Status)"
    if (-not $move.IsFinal) { $message += "`n`nDİKKAT: Taşıma sürüyor. İsteği kaldırmak taşımayı İPTAL eder; posta kutusu kaynak veritabanında kalır." }
    if (-not (Confirm-Action -Message $message -Icon Warning)) { return }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf }
    $identity = [string]$data.Exchange.Identity
    $script:State.ActionContext.Identity = $identity
    [void](Invoke-BackgroundTask -Name 'Taşıma isteği kaldırılıyor' -Command 'Remove-MailboxMove' -Arguments (Get-ActionArgument @{ Identity = $identity }) -OnSuccess {
            param($Result)
            if (-not $script:State.ActionContext.Simulate) {
                [void]$script:State.MonitoredMoves.Remove($script:State.ActionContext.Identity)
                Update-MoveMonitor
            }
            Complete-SingleAction -Title 'Taşıma isteğini kaldırma' -Results $null -Simulated $script:State.ActionContext.Simulate
        })
}
function Show-DatabasePicker {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][System.Windows.Window]$Owner,
        [Parameter()][string[]]$Databases,
        [Parameter()][string]$UserText,
        [Parameter()][switch]$AllowSkip
    )
    $dialog = New-MainWindow -Xaml $script:DbPickerXaml
    $script:State.DbPicker = @{ Window = $dialog.Window; Controls = $dialog.Controls; Result = $null }
    try {
        $c = $dialog.Controls
        $dialog.Window.Owner = $Owner
        if ($UserText) { $c.txtDbTitle.Text = "'$UserText' için posta kutusu hangi veritabanında oluşturulsun?" }
        $items = @($script:AutoDatabaseText) + @($Databases | Where-Object { $_ })
        $c.lstDb.ItemsSource = $items
        $c.lstDb.SelectedIndex = 0
        if (@($Databases | Where-Object { $_ }).Count -eq 0) { $c.txtDbInfo.Text = 'Veritabanı listesi okunamadı veya boş; Exchange en uygun veritabanını kendisi seçer.' }
        $c.btnDbSkip.Visibility = if ($AllowSkip) { 'Visible' } else { 'Collapsed' }
        $accept = {
            $pc = $script:State.DbPicker.Controls
            $selected = [string]$pc.lstDb.SelectedItem
            if (-not $selected) { $pc.txtDbInfo.Text = 'Lütfen listeden bir veritabanı seçin.'; return }
            $script:State.DbPicker.Result = @{ Create = $true; Database = $(if ($selected -eq $script:AutoDatabaseText) { '' } else { $selected }) }
            $script:State.DbPicker.Window.DialogResult = $true
        }
        $c.btnDbOk.Add_Click({ Invoke-UiAction $accept })
        $c.lstDb.Add_MouseDoubleClick({ Invoke-UiAction $accept })
        $c.btnDbSkip.Add_Click({
                $script:State.DbPicker.Result = @{ Create = $false; Database = '' }
                $script:State.DbPicker.Window.DialogResult = $true
            })
        [void]$dialog.Window.ShowDialog()
        return $script:State.DbPicker.Result
    }
    finally {
        $script:State.DbPicker = $null
    }
}
function Start-MailboxCreate {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data) { return }
    if ($script:Sync.ExchangeMode -ne 'OnPremises') {
        [void](Show-MessageDialog -Message 'Posta kutusu oluşturmak için Exchange On-Premises''e bağlanın.' -Icon Warning)
        return
    }
    if ($data.Exchange.Mode -ne $script:Sync.ExchangeMode) {
        [void](Show-MessageDialog -Message 'Exchange bağlantısı kullanıcı yüklendikten sonra değişti. Lütfen kullanıcıyı yenileyin (F5).' -Icon Warning)
        return
    }
    if (Test-ActionBlockedByChange) { return }
    [void](Invoke-BackgroundTask -Name 'Posta kutusu veritabanları okunuyor' -Command 'Get-ExchangeCatalog' -OnSuccess {
            param($Result)
            $script:State.MailboxDatabases = @($Result.Databases)
            Invoke-Deferred { Request-MailboxCreate }
        })
}
function Request-MailboxCreate {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data) { return }
    $ad = $data.Ad
    $name = if ($ad.DisplayName) { $ad.DisplayName } else { $ad.SamAccountName }
    $choice = Show-DatabasePicker -Owner $script:Window -Databases $script:State.MailboxDatabases -UserText $name
    if (-not $choice) { return }
    $target = if ($choice.Database) { $choice.Database } else { 'otomatik (Exchange seçer)' }
    $message = "'$name' ($($ad.SamAccountName)) için posta kutusu oluşturulacak.`n`n| Veritabanı: $target`n| Komut: Enable-Mailbox (PDC: $($script:Sync.Pdc))`n`nBirincil e-posta adresi, e-posta adresi politikasına göre atanır."
    if (-not (Confirm-Action -Message $message -Title 'Posta Kutusu Oluştur')) { return }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf }
    $arguments = Get-ActionArgument @{ Identity = [string]$ad.DistinguishedName; Database = [string]$choice.Database; Alias = [string]$ad.SamAccountName }
    [void](Invoke-BackgroundTask -Name "Posta kutusu oluşturuluyor: $($ad.SamAccountName)" -Command 'Enable-UserMailbox' -Arguments $arguments -OnSuccess {
            param($Result)
            Complete-SingleAction -Title 'Posta kutusu oluşturma' -Results $null -Simulated $script:State.ActionContext.Simulate
        })
}
