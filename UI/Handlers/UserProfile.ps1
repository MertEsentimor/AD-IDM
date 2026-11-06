function Show-UserProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Data)
    $script:State.IsPopulating = $true
    try {
        $script:State.CurrentData = $Data
        $ad = $Data.Ad
        $exchange = $Data.Exchange
        $script:State.Original = @{}
        foreach ($key in $script:FieldMap.Keys) {
            $value = ([string]$ad.$key).Trim()
            $script:State.Original[$key] = $value
            $script:Ui[$script:FieldMap[$key].Control].Text = $value
        }
        $script:State.OriginalFlags = @{}
        foreach ($key in $script:AccountFlagMap.Keys) {
            $script:State.OriginalFlags[$key] = [bool]$ad.$key
            $script:Ui[$script:AccountFlagMap[$key].Check].IsChecked = [bool]$ad.$key
        }
        Reset-DisableOption
        $script:State.PendingOu = $null
        $disabledOu = if ($ad.DisabledUsersOu) { $ad.DisabledUsersOu } else { 'DisabledUsers OU' }
        $script:Ui.txtAccountLocation.Text = if ($ad.Enabled) { "Konum: $($ad.ParentOu)`nDevre dışı bırakılırsa '$disabledOu' OU'suna taşınır; yeniden etkinleştirilince buraya döner." }
        elseif ($ad.PreviousOu) { "Hesap devre dışı. Şu anki konum: $($ad.ParentOu)`nEtkinleştirilirse eski OU'suna döner: $($ad.PreviousOu)" }
        else { "Hesap devre dışı. Konum: $($ad.ParentOu)`nÖnceki OU kaydı yok; etkinleştirilirse bu konumda kalır." }
        $script:Ui.txtDn.Text = $ad.DistinguishedName
        $script:Ui.txtCanonicalName.Text = $ad.CanonicalName
        if ($script:State.Environment -and $script:State.Environment.NetBiosName) {
            $script:Ui.lblSamPrefix.Text = "Kullanıcı Oturum Açma Adı (Windows 2000 öncesi):  $($script:State.Environment.NetBiosName)\"
        }
        $allAddresses = @($exchange.EmailAddresses | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $smtp = @($allAddresses | Where-Object { $_ -match '^smtp:' } | ForEach-Object {
                if ($_.StartsWith('SMTP:', [System.StringComparison]::Ordinal)) { $_ } else { 'smtp:' + $_.Substring(5) }
            })
        $script:State.OriginalSmtp = $smtp
        $script:State.SmtpList = New-Object -TypeName 'System.Collections.Generic.List[string]'
        foreach ($address in $smtp) { $script:State.SmtpList.Add($address) }
        $script:Ui.lstOtherAddresses.ItemsSource = @($allAddresses | Where-Object { $_ -notmatch '^smtp:' })
        $leaveToday = (Get-Date).Date
        $script:State.LeaveEdit = New-Object -TypeName 'System.Collections.Generic.List[object]'
        if ($ad.Leave) {
            foreach ($period in @($ad.Leave.Periods | Where-Object { $_ -and (Get-LeaveUntilUi -Period $_) -gt $leaveToday })) {
                $script:State.LeaveEdit.Add((New-LeavePeriodUi -Start ([datetime]$period.Start) -Until (Get-LeaveUntilUi -Period $period)))
            }
        }
        $script:Ui.chkLeaveNow.IsChecked = $false
        $script:State.LeaveEditTarget = $null
        $script:Ui.txtLeaveNewTitle.Text = 'Yeni izin ekle'
        $script:Ui.btnLeaveAdd.Content = 'Listeye Ekle'
        $script:Ui.btnLeaveEditCancel.Visibility = 'Collapsed'
        $script:Ui.dpLeaveStart.SelectedDate = $null
        $script:Ui.dpLeaveEnd.SelectedDate = $null
        $script:Ui.cmbLeaveStartTime.SelectedIndex = 0
        $script:Ui.cmbLeaveEndTime.SelectedIndex = 0
        $script:State.LeaveNowCandidate = [string](Get-LeaveChange).Candidate
        Show-LeaveStatus
        $script:State.GroupList = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($group in @($Data.Groups | Where-Object { $_ })) { $script:State.GroupList.Add([pscustomobject]@{ Group = $group; State = 'Existing' }) }
        $script:Ui.lstGroupResults.ItemsSource = $null
        $script:Ui.bdGroupResults.Visibility = 'Collapsed'
        Update-GroupView
        Update-LeaveView
        $sourceText = switch ($exchange.AddressSource) {
            'Mailbox' { 'Kaynak: Exchange On-Premises posta kutusu (Set-Mailbox -EmailAddresses)' }
            'RemoteMailbox' { 'Kaynak: Hibrit uzak posta kutusu (Set-RemoteMailbox -EmailAddresses)' }
            default { 'Kaynak: Active Directory proxyAddresses özniteliği (Set-ADUser)' }
        }
        if ($null -ne $exchange.EmailAddressPolicyEnabled) {
            $sourceText += "  |  E-posta adresi politikası: " + $(if ($exchange.EmailAddressPolicyEnabled) { 'Etkin (birincil değişirse devre dışı bırakılır)' } else { 'Devre dışı' })
        }
        $script:Ui.txtAddressSource.Text = $sourceText
        $canEdit = [bool]$exchange.CanEditAddresses
        foreach ($name in 'btnAddAddress', 'btnSetPrimary', 'btnRemoveAddress', 'txtNewAddress') { $script:Ui[$name].IsEnabled = $canEdit }
        Update-AddressView
        if ($exchange.Cas) {
            $script:State.OriginalCas = @{}
            foreach ($key in $script:CasMap.Keys) {
                $script:State.OriginalCas[$key] = [bool]$exchange.Cas.$key
                $script:Ui[$script:CasMap[$key].Check].IsChecked = [bool]$exchange.Cas.$key
                $script:Ui[$script:CasMap[$key].Check].IsEnabled = $true
            }
            $script:Ui.bdCasNotice.Visibility = 'Collapsed'
        }
        else {
            $script:State.OriginalCas = $null
            foreach ($key in $script:CasMap.Keys) {
                $script:Ui[$script:CasMap[$key].Check].IsChecked = $false
                $script:Ui[$script:CasMap[$key].Check].IsEnabled = $false
            }
            $script:Ui.txtCasNotice.Text = if ($exchange.Mode -eq 'None') { 'Posta kutusu özelliklerini görmek ve değiştirmek için Exchange''e bağlanın.' } else { 'Bu kullanıcı için CAS özellikleri bu bağlantı üzerinden okunamadı (posta kutusu yok veya farklı ortamda).' }
            $script:Ui.bdCasNotice.Visibility = 'Visible'
        }
        $usage = $exchange.Usage
        if ($usage) {
            $script:Ui.bdUsageNotice.Visibility = 'Collapsed'
            $script:Ui.pnlUsage.Visibility = 'Visible'
            $script:Ui.txtUsageTotal.Text = $usage.TotalItemSize
            $script:Ui.txtUsageOfQuota.Text = "/ $($usage.LimitText)"
            $script:Ui.txtUsageItemCount.Text = '{0:N0}' -f $usage.ItemCount
            $script:Ui.txtUsageDeleted.Text = $usage.DeletedItemSize
            $script:Ui.txtUsageWarn.Text = $usage.IssueWarningQuota
            $script:Ui.txtUsageProhibitSend.Text = $usage.ProhibitSendQuota
            $script:Ui.txtUsageProhibitSendReceive.Text = $usage.ProhibitSendReceive
            $script:Ui.txtUsageQuotaOrigin.Text = $usage.QuotaOrigin
            $script:Ui.txtUsageDatabase.Text = $usage.Database
            $script:Ui.txtUsageLastAccess.Text = Format-DateText -Date $usage.LastLogonTime
            if ($null -ne $usage.UsagePercent) {
                $percent = [double]$usage.UsagePercent
                $script:Ui.prgUsage.Value = [math]::Min(100, $percent)
                $script:Ui.prgUsage.SetResourceReference([System.Windows.Controls.ProgressBar]::ForegroundProperty, $(if ($percent -ge 90) { 'DangerBrush' } elseif ($percent -ge 75) { 'WarningBrush' } else { 'SuccessBrush' }))
                $script:Ui.txtUsagePercent.Text = "Doluluk: %$percent (ProhibitSend kotasına göre)"
            }
            else {
                $script:Ui.prgUsage.Value = 0
                $script:Ui.txtUsagePercent.Text = 'Kota sınırsız; doluluk oranı hesaplanamaz.'
            }
        }
        else {
            $script:Ui.pnlUsage.Visibility = 'Collapsed'
            $script:Ui.txtUsageNotice.Text = if ($exchange.Mode -eq 'None') { 'Posta kutusu kullanımını görmek için Exchange''e bağlanın.' } else { 'Bu kullanıcı için posta kutusu istatistikleri bu bağlantı üzerinden okunamadı.' }
            $script:Ui.bdUsageNotice.Visibility = 'Visible'
        }
        $script:Ui.txtStatusName.Text = if ($ad.DisplayName) { $ad.DisplayName } else { $ad.SamAccountName }
        $script:Ui.txtStatusUpn.Text = "$($ad.UserPrincipalName)  |  $($ad.SamAccountName)"
        if ($ad.Enabled) { Set-Badge -BorderName bdgEnabled -TextName txtEnabled -Text 'Etkin' -Kind Success } else { Set-Badge -BorderName bdgEnabled -TextName txtEnabled -Text 'Devre dışı' -Kind Error }
        if ($ad.LockedOut) { Set-Badge -BorderName bdgLocked -TextName txtLocked -Text 'Kilitli' -Kind Error } else { Set-Badge -BorderName bdgLocked -TextName txtLocked -Text 'Kilitli değil' -Kind Neutral }
        $noMailboxTypes = @('', 'User', 'DisabledUser')
        $mailboxType = [string]$exchange.RecipientTypeDetails
        if ($exchange.Mode -eq 'None') { Set-Badge -BorderName bdgMailbox -TextName txtMailboxType -Text 'Exchange bağlı değil' -Kind Neutral }
        elseif ($exchange.HasMailbox -or $mailboxType -notin $noMailboxTypes) { Set-Badge -BorderName bdgMailbox -TextName txtMailboxType -Text $mailboxType -Kind Accent }
        else { Set-Badge -BorderName bdgMailbox -TextName txtMailboxType -Text 'Posta kutusu yok' -Kind Warning }
        $canCreateMailbox = ($exchange.Mode -eq 'OnPremises') -and (-not $exchange.HasMailbox) -and ($mailboxType -in $noMailboxTypes)
        $script:Ui.bdMailboxPanel.Visibility = if ($canCreateMailbox) { 'Visible' } else { 'Collapsed' }
        $lastLogon = $Data.LastLogon
        if ($lastLogon.LastLogon) {
            $script:Ui.txtLastLogon.Text = Format-DateText -Date $lastLogon.LastLogon
            $detail = '{0}  |  Kaynak: {1}' -f (Format-RelativeTime -Date $lastLogon.LastLogon), $lastLogon.Source
        }
        else {
            $script:Ui.txtLastLogon.Text = 'Hiç oturum açmamış'
            $detail = 'Kaynak: {0}' -f $script:Sync.Pdc
        }
        if (@($lastLogon.FailedDCs).Count -gt 0) { $detail += "  |  Erişilemeyen: $(@($lastLogon.FailedDCs) -join ', ')" }
        $script:Ui.txtLastLogonDetail.Text = $detail
        $password = $Data.Password
        if ($password.PasswordLastSet) {
            $script:Ui.txtPwdLastSet.Text = Format-DateText -Date $password.PasswordLastSet
            $script:Ui.txtPwdLastSetDetail.Text = Format-RelativeTime -Date $password.PasswordLastSet
        }
        else {
            $script:Ui.txtPwdLastSet.Text = $password.PasswordLastSetText
            $script:Ui.txtPwdLastSetDetail.Text = ''
        }
        if ($password.ExpirationDate) {
            $script:Ui.txtPwdExpire.Text = Format-DateText -Date $password.ExpirationDate
            $script:Ui.txtPwdExpireDetail.Text = if ($password.State -eq 'Expired') { "Parolanın süresi doldu ($(Format-RelativeTime -Date $password.ExpirationDate))" } else { "$($password.DaysRemaining) gün kaldı" }
        }
        else {
            $script:Ui.txtPwdExpire.Text = $password.ExpirationText
            $script:Ui.txtPwdExpireDetail.Text = ''
        }
        $stateToken = switch ($password.State) { 'Ok' { 'SuccessBrush' } 'Warning' { 'WarningBrush' } 'Expired' { 'DangerBrush' } 'MustChange' { 'DangerBrush' } 'Never' { 'AccentTextBrush' } default { 'StatusNeutralBrush' } }
        $script:Ui.elPwdState.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $stateToken)
        $script:Ui.txtPwdPolicy.Text = $password.PolicyText
        if ($ad.AccountExpirationDate) {
            $expires = [datetime]$ad.AccountExpirationDate
            $script:Ui.txtAccountExpires.Text = (Format-DateText -Date $expires) + $(if ($expires -lt (Get-Date)) { '  (süresi doldu)' } else { '' })
        }
        else {
            $script:Ui.txtAccountExpires.Text = 'Süresiz (Never)'
        }
        $script:Ui.txtWhenCreated.Text = Format-DateText -Date $ad.WhenCreated
        if ($ad.LockedOut) {
            $lockText = 'Hesap kilitli'
            if ($ad.LockoutTime) { $lockText += ": $(Format-DateText -Date $ad.LockoutTime) ($(Format-RelativeTime -Date $ad.LockoutTime))" }
            $lockText += "  |  Hatalı parola denemesi: $($ad.BadPwdCount)"
            $script:Ui.txtLockDetail.Text = $lockText
            $script:Ui.bdLockPanel.Visibility = 'Visible'
        }
        else {
            $script:Ui.bdLockPanel.Visibility = 'Collapsed'
        }
        Show-UserPhoto -Data $Data
        Show-ArchiveInfo -Exchange $exchange
        Show-DatabaseInfo -Exchange $exchange
        Show-PolicyState -Exchange $exchange
        $script:Ui.pnlEmptyState.Visibility = 'Collapsed'
        $script:Ui.pnlTabs.Visibility = 'Visible'
    }
    finally {
        $script:State.IsPopulating = $false
    }
    foreach ($note in @($exchange.Notes)) { if ($note) { Write-UiLog -Message $note -Level Info } }
    Update-ChangeIndicator
}
function Show-UserPhoto {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Data)
    $ad = $Data.Ad
    $bytes = if ($Data.Photo) { [byte[]]$Data.Photo.Bytes } else { $null }
    $image = $null
    if ($bytes -and $bytes.Length -gt 0) {
        try {
            $stream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (, $bytes)
            $image = New-Object -TypeName System.Windows.Media.Imaging.BitmapImage
            $image.BeginInit()
            $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $image.StreamSource = $stream
            $image.EndInit()
            $image.Freeze()
            $stream.Dispose()
        }
        catch {
            $image = $null
            Write-UiLog -Message "Kullanıcı fotoğrafı görüntülenemedi: $($_.Exception.Message)" -Level Warning
        }
    }
    if ($image) {
        $brush = New-Object -TypeName System.Windows.Media.ImageBrush -ArgumentList $image
        $brush.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        $script:Ui.elPhoto.Fill = $brush
        $script:Ui.elPhoto.ToolTip = "Kaynak: $($Data.Photo.Source)  |  $([math]::Round($bytes.Length / 1KB, 1)) KB  |  $($image.PixelWidth)x$($image.PixelHeight)"
        $script:Ui.txtInitials.Visibility = 'Collapsed'
    }
    else {
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
        $initials = ''
        if ($ad.GivenName) { $initials += $ad.GivenName.Substring(0, 1) }
        if ($ad.Surname) { $initials += $ad.Surname.Substring(0, 1) }
        if (-not $initials -and $ad.DisplayName) { $initials = $ad.DisplayName.Substring(0, 1) }
        if (-not $initials) { $initials = $ad.SamAccountName.Substring(0, 1) }
        $script:Ui.txtInitials.Text = $initials.ToUpper($culture)
        $script:Ui.txtInitials.Visibility = 'Visible'
        $script:Ui.elPhoto.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'AccentBrush')
        $script:Ui.elPhoto.ToolTip = 'Fotoğraf yok'
    }
}
function Get-PendingChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $replace = @{}
    $clear = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $changedFields = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $summary = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $cas = @{}
    $policies = @{}
    $flags = @{}
    $addressChanged = $false
    $primaryChanged = $false
    $restoredGroupFile = $null
    $moveToOu = $null
    $groupAdd = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $groupRemove = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $leaveChanged = $false
    $leaveChange = $null
    $disableCleanup = @{}
    $audit = New-Object -TypeName 'System.Collections.Generic.List[object]'
    if ($script:State.CurrentData) {
        foreach ($key in $script:FieldMap.Keys) {
            $definition = $script:FieldMap[$key]
            $current = ([string]$script:Ui[$definition.Control].Text).Trim()
            $original = [string]$script:State.Original[$key]
            if (-not [string]::Equals($current, $original, [System.StringComparison]::Ordinal)) {
                $changedFields.Add($key)
                if ([string]::IsNullOrEmpty($current)) {
                    $clear.Add($definition.Ldap)
                    $summary.Add("AD  |  $($definition.Label): '$original' -> (temizlenecek)")
                }
                else {
                    $replace[$definition.Ldap] = $current
                    $summary.Add("AD  |  $($definition.Label): '$original' -> '$current'")
                }
                $audit.Add(@{ Step = 'AD'; Action = 'user.attribute.change'; Category = 'ad'; Field = $definition.Ldap; Label = $definition.Label; Operation = $(if ($current) { 'set' } else { 'clear' }); Old = $original; New = $current })
            }
        }
        foreach ($key in $script:AccountFlagMap.Keys) {
            $current = [bool]$script:Ui[$script:AccountFlagMap[$key].Check].IsChecked
            if ($current -ne [bool]$script:State.OriginalFlags[$key]) {
                $flags[$key] = $current
                $ad = $script:State.CurrentData.Ad
                $text = if ($key -eq 'Enabled') {
                    if ($current) { 'Hesap etkinleştirilecek' + $(if ($ad.PreviousOu) { " ve '$($ad.PreviousOu)' OU'suna geri taşınacak" } else { '' }) }
                    else { "Hesap devre dışı bırakılacak ve '$(if ($ad.DisabledUsersOu) { $ad.DisabledUsersOu } else { 'DisabledUsers' })' OU'suna taşınacak" }
                }
                else { "$($script:AccountFlagMap[$key].Text): " + $(if ($current) { 'Açılacak' } else { 'Kapatılacak' }) }
                $summary.Add("Hesap  |  $text")
                $audit.Add(@{ Step = 'AccountFlags'; Action = $(if ($key -eq 'Enabled') { $(if ($current) { 'account.enable' } else { 'account.disable' }) } else { 'account.flag.change' }); Category = 'account'; Field = $key; Operation = 'set'; Old = [bool]$script:State.OriginalFlags[$key]; New = $current })
            }
        }
        $parentOu = [string]$script:State.CurrentData.Ad.ParentOu
        if ($script:State.PendingOu -and -not [string]::Equals($script:State.PendingOu, $parentOu, [System.StringComparison]::OrdinalIgnoreCase)) {
            $moveToOu = [string]$script:State.PendingOu
            $summary.Add("Hesap  |  OU: '$parentOu' -> '$moveToOu'")
            $audit.Add(@{ Step = 'Move'; Action = 'user.move'; Category = 'account'; Field = 'distinguishedName'; Label = 'OU'; Operation = 'set'; Old = $parentOu; New = $moveToOu })
        }
        if ($flags.ContainsKey('Enabled') -and -not $flags.Enabled) {
            $disableCleanup = Get-DisableCleanup
            if ($disableCleanup.Count -gt 0) { Add-DisableCleanupChange -Cleanup $disableCleanup -Summary $summary -Audit $audit }
        }
        $leaveChange = Get-LeaveChange
        if ($leaveChange.Changed) {
            $leaveChanged = $true
            foreach ($line in $leaveChange.Summary) { $summary.Add($line) }
            foreach ($item in $leaveChange.Audit) { $audit.Add($item) }
        }
        foreach ($entry in $script:State.GroupList) {
            if ($entry.State -eq 'Added') {
                $groupAdd.Add([string]$entry.Group.DistinguishedName); $summary.Add("Grup  |  Eklenecek: $($entry.Group.Name)")
                $audit.Add(@{ Step = 'Groups'; Action = 'user.group.add'; Category = 'group'; Field = 'memberOf'; Label = [string]$entry.Group.Name; Operation = 'add'; Old = ''; New = [string]$entry.Group.DistinguishedName })
            }
            elseif ($entry.State -eq 'Removed') {
                $groupRemove.Add([string]$entry.Group.DistinguishedName); $summary.Add("Grup  |  Kaldırılacak: $($entry.Group.Name)")
                $audit.Add(@{ Step = 'Groups'; Action = 'user.group.remove'; Category = 'group'; Field = 'memberOf'; Label = [string]$entry.Group.Name; Operation = 'remove'; Old = [string]$entry.Group.DistinguishedName; New = '' })
            }
        }
        if ($flags.ContainsKey('Enabled') -and $flags.Enabled) {
            $removedGroups = Get-RemovedGroupList -SamAccountName ([string]$script:State.CurrentData.Ad.SamAccountName)
            if ($removedGroups) {
                $knownGroups = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($entry in $script:State.GroupList) { [void]$knownGroups.Add([string]$entry.Group.DistinguishedName) }
                $restoredNames = New-Object -TypeName 'System.Collections.Generic.List[string]'
                foreach ($dn in $removedGroups.GroupDn) {
                    if (-not $knownGroups.Add($dn)) { continue }
                    $groupName = ($dn -replace '^CN=((?:\\,|[^,])+),.*$', '$1') -replace '\\,', ','
                    $groupAdd.Add($dn)
                    $restoredNames.Add($groupName)
                    $audit.Add(@{ Step = 'Groups'; Action = 'user.group.add'; Category = 'group'; Field = 'memberOf'; Label = $groupName; Operation = 'add'; Old = ''; New = $dn })
                }
                if ($restoredNames.Count -gt 0) {
                    $restoredGroupFile = $removedGroups.Path
                    $summary.Add("Grup  |  Geri eklenecek ($($restoredNames.Count) grup, $($removedGroups.SavedAt.ToString('dd.MM.yyyy')) listesinden): $($restoredNames -join ', ')")
                }
            }
        }
        $originalKey = ConvertTo-AddressKey -Addresses $script:State.OriginalSmtp
        $currentKey = ConvertTo-AddressKey -Addresses $script:State.SmtpList.ToArray()
        if (-not [string]::Equals($originalKey, $currentKey, [System.StringComparison]::Ordinal)) {
            $addressChanged = $true
            $originalSet = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
            $currentSet = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($a in $script:State.OriginalSmtp) { [void]$originalSet.Add($a.Substring(5)) }
            foreach ($a in $script:State.SmtpList) { [void]$currentSet.Add($a.Substring(5)) }
            foreach ($a in $currentSet) {
                if (-not $originalSet.Contains($a)) {
                    $summary.Add("Adres  |  Eklenecek: $a")
                    $audit.Add(@{ Step = 'Addresses'; Action = 'mailbox.address.add'; Category = 'address'; Field = 'proxyAddresses'; Operation = 'add'; Old = ''; New = "smtp:$a" })
                }
            }
            foreach ($a in $originalSet) {
                if (-not $currentSet.Contains($a)) {
                    $summary.Add("Adres  |  Kaldırılacak: $a")
                    $audit.Add(@{ Step = 'Addresses'; Action = 'mailbox.address.remove'; Category = 'address'; Field = 'proxyAddresses'; Operation = 'remove'; Old = "smtp:$a"; New = '' })
                }
            }
            $originalPrimary = Get-PrimarySmtp -Addresses $script:State.OriginalSmtp
            $currentPrimary = Get-PrimarySmtp -Addresses $script:State.SmtpList.ToArray()
            if (-not [string]::Equals($originalPrimary, $currentPrimary, [System.StringComparison]::Ordinal)) {
                $primaryChanged = $true
                $summary.Add("Adres  |  Birincil: '$originalPrimary' -> '$currentPrimary'")
                $audit.Add(@{ Step = 'Addresses'; Action = 'mailbox.address.primary'; Category = 'address'; Field = 'PrimarySmtpAddress'; Operation = 'set'; Old = $originalPrimary; New = $currentPrimary })
            }
        }
        if ($script:State.OriginalCas) {
            foreach ($key in $script:CasMap.Keys) {
                $current = [bool]$script:Ui[$script:CasMap[$key].Check].IsChecked
                if ($current -ne [bool]$script:State.OriginalCas[$key]) {
                    $cas[$key] = $current
                    $summary.Add("Exchange  |  $($script:CasMap[$key].Text): " + $(if ($current) { 'Etkinleştirilecek' } else { 'Devre dışı bırakılacak' }))
                    $audit.Add(@{ Step = 'Cas'; Action = 'mailbox.cas.change'; Category = 'cas'; Field = $key; Label = $script:CasMap[$key].Text; Operation = 'set'; Old = [bool]$script:State.OriginalCas[$key]; New = $current })
                }
            }
        }
        if ($script:State.OriginalPolicy) {
            foreach ($key in $script:PolicyMap.Keys) {
                if (-not $script:State.OriginalPolicy.ContainsKey($key)) { continue }
                $current = Get-SelectedPolicy -Key $key
                $original = [string]$script:State.OriginalPolicy[$key]
                if (-not [string]::Equals($current, $original, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $policies[$key] = $current
                    $summary.Add("Politika  |  $($script:PolicyMap[$key].Text): '$(if ($original) { $original } else { $script:NoPolicyText })' -> '$(if ($current) { $current } else { $script:NoPolicyText })'")
                    $audit.Add(@{ Step = 'Policies'; Action = 'mailbox.policy.change'; Category = 'policy'; Field = $key; Label = $script:PolicyMap[$key].Text; Operation = 'set'; Old = $original; New = $current })
                }
            }
        }
    }
    return [pscustomobject]@{
        AdReplace      = $replace
        AdClear        = $clear.ToArray()
        ChangedFields  = $changedFields.ToArray()
        AddressChanged = $addressChanged
        PrimaryChanged = $primaryChanged
        CasChanges     = $cas
        PolicyChanges  = $policies
        AccountFlags   = $flags
        GroupAdd       = $groupAdd.ToArray()
        GroupRemove    = $groupRemove.ToArray()
        LeaveChanged   = $leaveChanged
        LeaveChange    = $leaveChange
        DisableCleanup = $disableCleanup
        RestoredGroupFile = $restoredGroupFile
        MoveToOu       = $moveToOu
        AuditItems     = $audit.ToArray()
        Summary        = $summary.ToArray()
        Count          = $changedFields.Count + $cas.Count + $policies.Count + $flags.Count + $groupAdd.Count + $groupRemove.Count + $(if ($addressChanged) { 1 } else { 0 }) + $(if ($leaveChanged) { 1 } else { 0 }) + $(if ($moveToOu) { 1 } else { 0 })
    }
}
function Select-PendingOu {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data) { return }
    if (@($script:State.OuList).Count -eq 0) {
        [void](Invoke-BackgroundTask -Name 'OU listesi okunuyor' -Command 'Get-OrganizationalUnitList' -OnSuccess {
                param($Result)
                $script:State.OuList = @($Result | Where-Object { $_ })
                if ($script:State.OuList.Count -gt 0) { Invoke-Deferred { Select-PendingOu } }
                else { Write-UiLog -Message 'Dizinde OU bulunamadı.' -Level Warning }
            })
        return
    }
    $current = if ($script:State.PendingOu) { [string]$script:State.PendingOu } else { [string]$data.Ad.ParentOu }
    $ou = [string](@(Show-OuPicker -Owner $script:Window -Selected $current -Title "'$($data.Ad.SamAccountName)' hangi OU'ya taşınsın?" -AcceptText 'OU''yu Seç') | Select-Object -First 1)
    if (-not $ou) { return }
    # Mevcut OU seçilirse bekleyen taşıma kalkar.
    $script:State.PendingOu = if ([string]::Equals($ou, [string]$data.Ad.ParentOu, [System.StringComparison]::OrdinalIgnoreCase)) { $null } else { $ou }
    Update-ChangeIndicator
}
function Get-PendingChipModel {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$Summary = @())
    $lines = @($Summary | Where-Object { $_ })
    $items = @(foreach ($line in $lines) {
            $flat = $line -replace '\s*\r?\n\s*', ' '
            $title = $flat
            $detail = ''
            if ($flat -match '^(?<group>.+?)\s+\|\s+(?<rest>.*)$') {
                $title = $Matches['group']
                $detail = $Matches['rest']
                if ($detail -match '^(?<field>[^:]{1,60}):\s+(?<value>.*)$') {
                    $title = $Matches['field']
                    $detail = $Matches['value']
                }
            }
            [pscustomobject]@{ Title = $title; Detail = $detail -replace ' -> ', " $([char]0x2192) "; Tip = $line }
        })
    return [pscustomobject]@{ Items = $items; FullText = $lines -join "`n" }
}
function Test-PendingChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][psobject]$Changes)
    $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $emailPattern = '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    if ($Changes.DisableCleanup -and $Changes.DisableCleanup.Count -gt 0) { Test-DisableCleanup -Cleanup $Changes.DisableCleanup -Errors $errors -Warnings $warnings }
    if ($Changes.LeaveChanged) {
        $leaveChange = $Changes.LeaveChange
        $leave = $script:State.CurrentData.Ad.Leave
        if ($leaveChange.Value.Length -gt 1024) { $errors.Add("İzin planı $($leave.Attribute) için çok uzun (en fazla 1024 karakter); bazı dönemleri kaldırın.") }
        if ($leave.Raw -and -not $leave.Owned) { $warnings.Add("$($leave.Attribute) özniteliğindeki izin dışı değer ('$($leave.Raw)') silinecek.") }
        if ($leave.Problem) { $warnings.Add("Kayıtlı izin değerindeki hatalı kısım silinecek ($($leave.Problem)).") }
        if ($Changes.AccountFlags.ContainsKey('Enabled') -and $leaveChange.Account) { $warnings.Add("Hesap sekmesindeki 'Etkin' değişikliği uygulanır; İzin sekmesindeki hesabı şimdi kapat / aç seçeneği atlanır.") }
        elseif ($leaveChange.Candidate -eq 'Disable' -and -not $leaveChange.Account) { $warnings.Add("İzin bugün sürüyor ama hesap şimdi kapatılmayacak; gece görevi bu gece 00:00'da kapatır.") }
        elseif ($leaveChange.Candidate -eq 'Enable' -and -not $leaveChange.Account) { $warnings.Add("İzin bitti ama hesap şimdi açılmayacak; gece görevi bu gece 00:00'da açar.") }
    }
    if ($Changes.AccountFlags.ContainsKey('Enabled') -and $Changes.AccountFlags.Enabled -and (Get-LeaveChange).Active) {
        $warnings.Add('Kullanıcının izni bugün sürüyor: hesap etkinleştirilse de gece görevi bu gece 00:00''da yeniden kapatır. Kullanıcı izinden erken döndüyse İzin sekmesinde dönemi kısaltın veya kaldırın.')
    }
    if ($Changes.ChangedFields -contains 'SamAccountName') {
        $sam = $script:Ui.txtSamAccountName.Text.Trim()
        if ([string]::IsNullOrEmpty($sam)) { $errors.Add('SamAccountName boş olamaz.') }
        elseif ($sam.Length -gt 20) { $errors.Add('SamAccountName en fazla 20 karakter olabilir.') }
        elseif ($sam -match '["/\\\[\]:;|=,+*?<>@]') { $errors.Add('SamAccountName geçersiz karakter içeriyor.') }
        elseif ($sam.EndsWith('.')) { $errors.Add('SamAccountName nokta ile bitemez.') }
    }
    if ($Changes.ChangedFields -contains 'UserPrincipalName') {
        $upn = $script:Ui.txtUpn.Text.Trim()
        if ($upn -notmatch '^[^@\s]+@[^@\s]+$') { $errors.Add('UserPrincipalName "kullanici@sonek" biçiminde olmalıdır.') }
        elseif ($script:State.Environment -and @($script:State.Environment.UpnSuffixes).Count -gt 0) {
            $suffix = $upn.Split('@')[1]
            $known = @($script:State.Environment.UpnSuffixes | Where-Object { [string]::Equals([string]$_, $suffix, [System.StringComparison]::OrdinalIgnoreCase) })
            if ($known.Count -eq 0) { $warnings.Add("UPN son eki '$suffix' ormanda tanımlı değil.") }
        }
    }
    if ($Changes.ChangedFields -contains 'EmailAddress') {
        $mail = $script:Ui.txtEmail.Text.Trim()
        if ($mail -and $mail -notmatch $emailPattern) { $errors.Add('E-Mail alanı geçerli bir adres değil.') }
        if ($script:State.CurrentData.Exchange.AddressSource -ne 'AD') { $warnings.Add('Posta kutusu olan kullanıcılarda mail özniteliği Exchange tarafından birincil SMTP ile yeniden yazılabilir.') }
    }
    if ($Changes.AddressChanged -and $script:State.CurrentData.Exchange.AddressSource -ne 'AD') {
        if (-not (Get-PrimarySmtp -Addresses $script:State.SmtpList.ToArray())) { $errors.Add('Bir birincil SMTP adresi seçilmelidir.') }
        if ($script:Sync.ExchangeMode -eq 'None') { $errors.Add('Adres değişikliği için Exchange bağlantısı gerekiyor.') }
    }
    if ($Changes.CasChanges.Count -gt 0 -and $script:Sync.ExchangeMode -eq 'None') { $errors.Add('Posta kutusu özellikleri için Exchange bağlantısı gerekiyor.') }
    if ($Changes.AccountFlags.ContainsKey('Enabled') -and -not $Changes.AccountFlags.Enabled) {
        $self = [string]::Equals([string]$script:State.CurrentData.Ad.SamAccountName, [string]$env:USERNAME, [System.StringComparison]::OrdinalIgnoreCase)
        if ($self) { $errors.Add('Kendi hesabınızı devre dışı bırakamazsınız.') }
        else { $warnings.Add('Hesap devre dışı bırakılınca kullanıcı oturum açamaz ve DisabledUsers OU''suna taşınır; OU''ya bağlı GPO ve izinler değişir.') }
    }
    if ($Changes.MoveToOu) {
        $ad = $script:State.CurrentData.Ad
        if ($Changes.AccountFlags.ContainsKey('Enabled') -and -not $Changes.AccountFlags.Enabled) { $errors.Add('Devre dışı bırakılan hesap DisabledUsers OU''suna taşınır; OU değişikliğini ayrı kaydedin.') }
        elseif ($Changes.AccountFlags.ContainsKey('Enabled') -and $Changes.AccountFlags.Enabled -and $ad.PreviousOu) { $warnings.Add("Hesap önce eski OU'suna ($($ad.PreviousOu)) döner, ardından seçilen OU'ya taşınır.") }
        elseif (-not $ad.Enabled -and $ad.PreviousOu) { $warnings.Add("Hesap devre dışı: etkinleştirilince kayıtlı eski OU'suna ($($ad.PreviousOu)) döner.") }
        $warnings.Add('OU değişince hesaba farklı GPO ve izinler uygulanabilir.')
    }
    if ($Changes.AccountFlags.ContainsKey('PasswordNeverExpires') -and $Changes.AccountFlags.PasswordNeverExpires -and $script:State.CurrentData.Password.State -eq 'MustChange') {
        $warnings.Add('Kullanıcıya "bir sonraki oturumda parola değiştirmeli" atanmış; parola süresiz yapılınca bu zorunluluk uygulanmaz.')
    }
    if ($Changes.PolicyChanges.Count -gt 0 -and $script:Sync.ExchangeMode -eq 'None') { $errors.Add('Politika değişikliği için Exchange bağlantısı gerekiyor.') }
    if ($Changes.PolicyChanges.ContainsKey('AddressBookPolicy')) { $warnings.Add('Adres defteri politikası değişikliğinin Outlook/OWA tarafında görünmesi zaman alabilir.') }
    $needsExchange = ($Changes.CasChanges.Count -gt 0) -or ($Changes.PolicyChanges.Count -gt 0) -or ($Changes.AddressChanged -and $script:State.CurrentData.Exchange.AddressSource -ne 'AD')
    if ($needsExchange -and $script:State.CurrentData.Exchange.Mode -ne $script:Sync.ExchangeMode) {
        $errors.Add('Exchange bağlantısı kullanıcı yüklendikten sonra değişti. Lütfen kullanıcıyı yenileyin (F5).')
    }
    return [pscustomobject]@{ Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
}
function Start-UserUpdate {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data) { return }
    $changes = Get-PendingChange
    if ($changes.Count -eq 0) {
        Write-UiLog -Message 'Güncellenecek değişiklik yok.' -Level Info
        return
    }
    $validation = Test-PendingChange -Changes $changes
    if ($validation.Errors.Count -gt 0) {
        [void](Show-MessageDialog -Message ("Değişiklikler doğrulanamadı:`n`n| " + ($validation.Errors -join "`n| ")) -Icon Warning)
        return
    }
    $chips = Get-PendingChipModel -Summary $changes.Summary
    $message = "'$($data.Ad.SamAccountName)' kullanıcısına $($chips.Items.Count) değişiklik uygulanacak."
    if ($validation.Warnings.Count -gt 0) { $message += "`n`nUyarılar:`n| " + ($validation.Warnings -join "`n| ") }
    if (-not (Show-ConfirmDialog -Message $message -Title 'Değişiklikleri Onayla' -Items $chips.Items -ApplyText "$($chips.Items.Count) değişikliği uygula")) {
        Write-UiLog -Message 'Güncelleme kullanıcı tarafından iptal edildi.' -Level Info
        return
    }
    $simulate = [bool]$script:State.Options.WhatIf
    $request = @{ ObjectGuid = $data.Ad.ObjectGuid; Confirm = $false }
    if ($changes.AdReplace.Count -gt 0) { $request.AdReplace = $changes.AdReplace }
    if ($changes.AdClear.Count -gt 0) { $request.AdClear = [string[]]$changes.AdClear }
    if ($changes.AddressChanged) {
        $request.SmtpAddresses = [string[]]$script:State.SmtpList.ToArray()
        $request.OriginalAddresses = [string[]]@($data.Exchange.EmailAddresses | Where-Object { $_ })
        $request.AddressSource = [string]$data.Exchange.AddressSource
        $request.PrimaryChanged = [bool]$changes.PrimaryChanged
        $request.UpdateMailAttribute = -not ($changes.ChangedFields -contains 'EmailAddress')
    }
    if ($changes.CasChanges.Count -gt 0) { $request.CasChanges = $changes.CasChanges }
    if ($changes.PolicyChanges.Count -gt 0) { $request.PolicyChanges = $changes.PolicyChanges }
    if ($changes.AccountFlags.Count -gt 0) { $request.AccountFlags = $changes.AccountFlags }
    if ($changes.GroupAdd.Count -gt 0) { $request.GroupAdd = [string[]]$changes.GroupAdd }
    if ($changes.GroupRemove.Count -gt 0) { $request.GroupRemove = [string[]]$changes.GroupRemove }
    if ($changes.MoveToOu) { $request.MoveToOu = [string]$changes.MoveToOu }
    if ($changes.LeaveChanged) {
        $request.Leave = @{ Value = [string]$changes.LeaveChange.Value; Account = [string]$changes.LeaveChange.Account; ClearLegacy = [bool]$changes.LeaveChange.ClearLegacy }
    }
    if ($changes.DisableCleanup -and $changes.DisableCleanup.Count -gt 0) {
        $request.DisableCleanup = $changes.DisableCleanup
        if ($changes.DisableCleanup.Pst -and -not $simulate) { Save-AppSetting -Values @{ PstFolder = [string]$changes.DisableCleanup.Pst.Folder } }
    }
    if ($data.Exchange.Identity) { $request.ExchangeIdentity = [string]$data.Exchange.Identity }
    if ($simulate) { $request.WhatIf = $true }
    $script:State.LastUpdateSimulated = $simulate
    $script:State.RestoredGroupFile = if ($simulate) { $null } else { $changes.RestoredGroupFile }
    $taskName = if ($simulate) { 'Değişiklikler simüle ediliyor' } else { 'Değişiklikler uygulanıyor' }
    [void](Invoke-BackgroundTask -Name $taskName -Command 'Invoke-UserUpdate' -Arguments $request -AuditChanges $changes.AuditItems -OnSuccess {
            param($Result)
            Complete-UserUpdate -Results $Result
        })
}
function Complete-UserUpdate {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Results)
    $items = @($Results | Where-Object { $_ })
    $failed = @($items | Where-Object { -not $_.Success })
    foreach ($item in $items) {
        Write-UiLog -Message ("{0}: {1}" -f $item.Step, $item.Message) -Level $(if ($item.Success) { 'Success' } else { 'Error' })
    }
    if ($script:State.LastUpdateSimulated) {
        [void](Show-MessageDialog -Message 'Simülasyon tamamlandı. Hiçbir değişiklik uygulanmadı; yapılacak işlemler günlükte listelendi.' -Icon Information)
        return
    }
    $cleanup = $items | Where-Object { $_.Step -eq 'Grup temizliği' -and $_.Data -and $_.Data.RemovedDn.Count -gt 0 } | Select-Object -First 1
    if ($script:State.RestoredGroupFile -and ($items | Where-Object { $_.Step -eq 'Grup üyelikleri' -and $_.Success })) { Complete-RemovedGroupList -Path $script:State.RestoredGroupFile }
    $script:State.RestoredGroupFile = $null
    if ($cleanup) { Save-RemovedGroupList -SamAccountName ([string]$script:State.CurrentData.Ad.SamAccountName) -GroupDn $cleanup.Data.RemovedDn }
    if ($items | Where-Object { $_.Step -eq 'PST dışa aktarma' -and $_.Success }) {
        $script:State.PstScanned = $false
        $script:Ui.txtPstMonitor.Text = 'PST dışa aktarma kuyruğa alındı...'
        $script:Ui.txtPstMonitor.Visibility = 'Visible'
    }
    if ($failed.Count -eq 0) {
        Write-UiLog -Message 'Tüm değişiklikler başarıyla uygulandı. Kullanıcı yeniden yükleniyor...' -Level Success
        Complete-ChangeCycle -ObjectGuid $script:State.CurrentData.Ad.ObjectGuid
    }
    else {
        $lines = $failed | ForEach-Object { "| $($_.Step): $($_.Message)" }
        $okCount = $items.Count - $failed.Count
        [void](Show-MessageDialog -Message ("Bazı adımlar başarısız oldu ($okCount başarılı, $($failed.Count) başarısız):`n`n" + ($lines -join "`n") + "`n`nForm değerleriniz korunuyor. Güncel durumu görmek için Yenile (F5) kullanın.") -Icon Warning)
    }
}
function Update-ChangeIndicator {
    [CmdletBinding()]
    param()
    $changes = Get-PendingChange
    $changedTabs = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    foreach ($key in $script:FieldMap.Keys) {
        $definition = $script:FieldMap[$key]
        $control = $script:Ui[$definition.Control]
        if ($changes.ChangedFields -contains $key) {
            $control.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, 'WarningBrush')
            $control.SetResourceReference([System.Windows.Controls.Control]::BackgroundProperty, 'WarningBgBrush')
            [void]$changedTabs.Add($definition.Tab)
        }
        else {
            $control.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty)
            $control.ClearValue([System.Windows.Controls.Control]::BackgroundProperty)
        }
    }
    foreach ($key in $script:AccountFlagMap.Keys) {
        $label = $script:Ui[$script:AccountFlagMap[$key].Label]
        if ($changes.AccountFlags.ContainsKey($key)) {
            $label.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'WarningBrush')
            $label.Text = "$($script:AccountFlagMap[$key].Text)  (değişti)"
            [void]$changedTabs.Add('tabAccount')
        }
        else {
            $label.ClearValue([System.Windows.Controls.TextBlock]::ForegroundProperty)
            $label.Text = $script:AccountFlagMap[$key].Text
        }
    }
    foreach ($key in $script:CasMap.Keys) {
        $label = $script:Ui[$script:CasMap[$key].Label]
        if ($changes.CasChanges.ContainsKey($key)) {
            $label.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'WarningBrush')
            $label.Text = "$($script:CasMap[$key].Text)  (değişti)"
            [void]$changedTabs.Add('tabFeatures')
        }
        else {
            $label.ClearValue([System.Windows.Controls.TextBlock]::ForegroundProperty)
            $label.Text = $script:CasMap[$key].Text
        }
    }
    foreach ($key in $script:PolicyMap.Keys) {
        $label = $script:Ui[$script:PolicyMap[$key].Label]
        if ($changes.PolicyChanges.ContainsKey($key)) {
            $label.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'WarningBrush')
            $label.Text = "$($script:PolicyMap[$key].Text)  (değişti)"
            [void]$changedTabs.Add('tabPolicies')
        }
        else {
            $label.ClearValue([System.Windows.Controls.TextBlock]::ForegroundProperty)
            $label.Text = $script:PolicyMap[$key].Text
        }
    }
    $script:Ui.txtAddressChanged.Visibility = if ($changes.AddressChanged) { 'Visible' } else { 'Collapsed' }
    if ($changes.AddressChanged) { [void]$changedTabs.Add('tabAddresses') }
    $groupChanged = ($changes.GroupAdd.Count + $changes.GroupRemove.Count) -gt 0
    $script:Ui.txtGroupChanged.Visibility = if ($groupChanged) { 'Visible' } else { 'Collapsed' }
    if ($groupChanged) { [void]$changedTabs.Add('tabGroups') }
    $script:Ui.txtMoveOuPending.Text = if ($changes.MoveToOu) { "Taşınacak: $($changes.MoveToOu)" } else { '' }
    $script:Ui.txtMoveOuPending.Visibility = if ($changes.MoveToOu) { 'Visible' } else { 'Collapsed' }
    if ($changes.MoveToOu) { [void]$changedTabs.Add('tabAccount') }
    $leavePending = [bool]$changes.LeaveChanged
    $script:Ui.txtLeaveChanged.Visibility = if ($leavePending) { 'Visible' } else { 'Collapsed' }
    if ($leavePending) { [void]$changedTabs.Add('tabLeave') }
    Update-DisableOptionView
    foreach ($groupKey in $script:TabGroups.Keys) {
        foreach ($tabName in $script:TabGroups[$groupKey]) { $script:Ui[$tabName].Tag = if ($changedTabs.Contains($tabName)) { 'Changed' } else { $null } }
    }
    $script:State.PendingCount = $changes.Count
    if ($changes.Count -gt 0) {
        $chips = Get-PendingChipModel -Summary $changes.Summary
        $script:Ui.txtPending.Text = "$($chips.Items.Count) bekleyen değişiklik"
        $script:Ui.txtPending.ToolTip = $chips.FullText
        $script:Ui.icPending.ItemsSource = @($chips.Items)
        $script:Ui.btnUpdate.Content = "$($chips.Items.Count) değişikliği kaydet"
        $script:Ui.bdActionBar.Visibility = 'Visible'
    }
    else {
        $script:Ui.txtPending.ClearValue([System.Windows.FrameworkElement]::ToolTipProperty)
        $script:Ui.icPending.ItemsSource = $null
        $script:Ui.bdActionBar.Visibility = 'Collapsed'
    }
    Update-ActionState
}
function Update-ActionState {
    [CmdletBinding()]
    param()
    $busy = [bool]$script:TaskEngine.CurrentJob -and -not $script:TaskEngine.CurrentJob.Silent
    $loaded = [bool]$script:State.CurrentData
    $pending = $script:State.PendingCount -gt 0
    $idle = (-not $busy) -and $loaded
    $data = $script:State.CurrentData
    foreach ($name in 'btnSearch', 'btnOuSearch', 'btnReplicate', 'btnNewUser', 'lstResults') { $script:Ui[$name].IsEnabled = -not $busy }
    $script:Ui.btnReload.IsEnabled = $idle
    $script:Ui.btnReset.IsEnabled = (-not $busy) -and $pending
    $script:Ui.btnUpdate.IsEnabled = (-not $busy) -and $pending
    foreach ($name in 'btnGroupSearch', 'btnGroupAdd', 'btnGroupRemove') { $script:Ui[$name].IsEnabled = $idle }
    foreach ($key in $script:AccountFlagMap.Keys) { $script:Ui[$script:AccountFlagMap[$key].Check].IsEnabled = $loaded }
    $script:Ui.btnResetPassword.IsEnabled = $idle
    $script:Ui.btnMoveOu.IsEnabled = $idle
    $script:Ui.btnUnlock.IsEnabled = $idle -and [bool]$data.Ad.LockedOut
    $script:Ui.btnPhotoChange.IsEnabled = $idle
    $script:Ui.btnPhotoRemove.IsEnabled = $idle -and [bool]$data.Photo.Bytes
    $connected = $script:Sync.ExchangeMode -ne 'None'
    $script:Ui.cmbExMode.IsEnabled = (-not $busy) -and (-not $connected)
    $script:Ui.cmbExServer.IsEnabled = (-not $busy) -and (-not $connected)
    $script:Ui.btnExConnect.IsEnabled = (-not $busy) -and ($connected -or $script:Ui.cmbExMode.SelectedIndex -gt 0)
    $script:Ui.btnCreateMailbox.IsEnabled = $idle -and ($script:Sync.ExchangeMode -eq 'OnPremises')
    $exchange = if ($loaded) { $data.Exchange } else { $null }
    $exchangeReady = $idle -and $connected -and $exchange -and ($exchange.Mode -eq $script:Sync.ExchangeMode)
    $archive = if ($exchange) { $exchange.Archive } else { $null }
    $script:Ui.btnArchiveEnable.IsEnabled = $exchangeReady -and $archive -and (-not $archive.Enabled)
    $script:Ui.btnArchiveDisable.IsEnabled = $exchangeReady -and $archive -and [bool]$archive.Enabled
    $script:Ui.cmbArchiveDb.IsEnabled = $exchangeReady
    $move = $script:State.CurrentMove
    $moveActive = $move -and $move.Exists -and (-not $move.IsFinal)
    $hasDatabase = $exchangeReady -and ($script:Sync.ExchangeMode -eq 'OnPremises') -and [bool]$exchange.Database
    $script:Ui.btnStartMove.IsEnabled = $hasDatabase -and (-not $moveActive)
    $script:Ui.cmbTargetDb.IsEnabled = $hasDatabase -and (-not $moveActive)
    $script:Ui.cmbMoveScope.IsEnabled = $hasDatabase -and (-not $moveActive)
    $script:Ui.btnMoveRefresh.IsEnabled = $hasDatabase
    $script:Ui.btnMoveClear.IsEnabled = $hasDatabase -and $move -and [bool]$move.Exists
    $script:Ui.pnlLeaveNew.IsEnabled = $loaded
    $script:Ui.lstLeave.IsEnabled = $loaded
    foreach ($name in 'btnLeaveRemove', 'btnLeaveClear', 'btnLeaveEdit') { $script:Ui[$name].IsEnabled = $loaded }
    $script:Ui.btnLeaveScheduleTab.IsEnabled = -not $busy
    if ($script:State.Settings) {
        foreach ($name in 'btnSetTestMail', 'btnSetTestSms') { $script:Ui[$name].IsEnabled = -not $busy }
    }
    if ($script:State.Report) { Update-ReportState }
    $script:Ui.pnlTabs.IsHitTestVisible = -not $busy
    $script:Ui.pnlTabs.Opacity = if ($busy) { 0.7 } else { 1.0 }
}
function Update-ConnectionIndicator {
    [CmdletBinding()]
    param()
    $environment = $script:State.Environment
    $fill = [System.Windows.Shapes.Shape]::FillProperty
    if ($environment -and $environment.AdAvailable) {
        $script:Ui.elAd.SetResourceReference($fill, 'ChromeSuccessBrush')
        $script:Ui.txtAdStatus.Text = "AD: $($environment.DomainName)"
    }
    elseif ($environment) {
        $script:Ui.elAd.SetResourceReference($fill, 'ChromeDangerBrush')
        $script:Ui.txtAdStatus.Text = 'AD: erişilemiyor'
    }
    if ($script:Sync.ExchangeMode -eq 'OnPremises') {
        $script:Ui.elEx.SetResourceReference($fill, 'ChromeSuccessBrush')
        $script:Ui.txtExStatus.Text = "Exchange On-Prem: $($script:Sync.ExchangeServer)"
        $script:Ui.btnExConnect.Content = 'Bağlantıyı Kes'
    }
    else {
        $script:Ui.elEx.SetResourceReference($fill, 'StatusNeutralBrush')
        $script:Ui.txtExStatus.Text = 'Exchange: bağlı değil'
        $script:Ui.btnExConnect.Content = 'Bağlan'
    }
    Update-ActionState
}
