function global:ConvertTo-ByteCount {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value.PSObject.Properties['IsUnlimited'] -and $Value.IsUnlimited) { return [long]-1 }
    if ($Value.PSObject.Properties['Value'] -and $null -ne $Value.Value -and $Value.Value.PSObject.Methods['ToBytes']) {
        return [long]$Value.Value.ToBytes()
    }
    if ($Value.PSObject.Methods['ToBytes']) { return [long]$Value.ToBytes() }
    $text = [string]$Value
    if ($text -match '^\s*Unlimited\s*$') { return [long]-1 }
    if ($text -match '\(([\d\.,\s]+)\s*bytes\)') { return [long]($Matches[1] -replace '[^\d]', '') }
    return $null
}
function global:Format-ByteSize {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][object]$Bytes)
    if ($null -eq $Bytes) { return '-' }
    $value = [double]$Bytes
    if ($value -lt 0) { return 'Sınırsız' }
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) { $value = $value / 1024; $index++ }
    return ('{0:N2} {1}' -f $value, $units[$index])
}
function global:Get-MailboxFeatureState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Identity)
    $cas = Get-CASMailbox -Identity $Identity -ErrorAction Stop
    return [pscustomobject]@{
        OWAEnabled        = [bool]$cas.OWAEnabled
        ActiveSyncEnabled = [bool]$cas.ActiveSyncEnabled
        ImapEnabled       = [bool]$cas.ImapEnabled
        PopEnabled        = [bool]$cas.PopEnabled
        MAPIEnabled       = [bool]$cas.MAPIEnabled
        OwaMailboxPolicy        = [string]$cas.OwaMailboxPolicy
        ActiveSyncMailboxPolicy = [string]$cas.ActiveSyncMailboxPolicy
    }
}
function global:Get-MailboxUsage {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$Mailbox,
        [Parameter(Mandatory = $true)][string]$Identity
    )
    $stats = Get-MailboxStatistics -Identity $Identity -ErrorAction Stop
    $total = ConvertTo-ByteCount -Value $stats.TotalItemSize
    $deleted = ConvertTo-ByteCount -Value $stats.TotalDeletedItemSize
    $quotaSource = $Mailbox
    $quotaOrigin = 'Posta kutusu'
    if ($Sync.ExchangeMode -eq 'OnPremises' -and [string]$Mailbox.UseDatabaseQuotaDefaults -eq 'True') {
        try {
            $quotaSource = Get-MailboxDatabase -Identity ([string]$Mailbox.Database) -ErrorAction Stop
            $quotaOrigin = 'Veritabanı varsayılanı'
        }
        catch {
            $quotaOrigin = 'Veritabanı varsayılanı (okunamadı)'
            Write-WorkerLog -Message "Veritabanı kotaları okunamadı: $($_.Exception.Message)" -Level Warning
        }
    }
    $warning = ConvertTo-ByteCount -Value $quotaSource.IssueWarningQuota
    $prohibitSend = ConvertTo-ByteCount -Value $quotaSource.ProhibitSendQuota
    $prohibitSendReceive = ConvertTo-ByteCount -Value $quotaSource.ProhibitSendReceiveQuota
    $limit = $null
    if ($prohibitSend -gt 0) { $limit = $prohibitSend } elseif ($prohibitSendReceive -gt 0) { $limit = $prohibitSendReceive }
    $percent = $null
    if ($limit -and $null -ne $total) { $percent = [math]::Round(($total / $limit) * 100, 1) }
    return [pscustomobject]@{
        TotalItemSize       = Format-ByteSize -Bytes $total
        TotalItemSizeBytes  = $total
        ItemCount           = [long]$stats.ItemCount
        DeletedItemSize     = Format-ByteSize -Bytes $deleted
        IssueWarningQuota   = Format-ByteSize -Bytes $warning
        ProhibitSendQuota   = Format-ByteSize -Bytes $prohibitSend
        ProhibitSendReceive = Format-ByteSize -Bytes $prohibitSendReceive
        LimitText           = if ($limit) { Format-ByteSize -Bytes $limit } else { 'Sınırsız' }
        UsagePercent        = $percent
        QuotaOrigin         = $quotaOrigin
        Database            = if ($Mailbox.Database) { [string]$Mailbox.Database } else { '-' }
        LastLogonTime       = $stats.LastLogonTime
    }
}
function global:Get-ExchangeUserData {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][object]$AdUser)
    $data = [ordered]@{
        Mode                      = $Sync.ExchangeMode
        HasMailbox                = $false
        RecipientTypeDetails      = $null
        Identity                  = $null
        AddressSource             = 'AD'
        CanEditAddresses          = $true
        EmailAddresses            = @()
        EmailAddressPolicyEnabled = $null
        Cas                       = $null
        Usage                     = $null
        Archive                   = $null
        Policies                  = $null
        Database                  = $null
        ArchiveDatabase           = $null
        DatabaseOptions           = @()
        Move                      = $null
        Notes                     = New-Object -TypeName 'System.Collections.Generic.List[string]'
    }
    $adAddresses = @($AdUser.proxyAddresses | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $guid = $AdUser.ObjectGUID.ToString()
    switch ($Sync.ExchangeMode) {
        'None' {
            $data.EmailAddresses = $adAddresses
            $data.Notes.Add('Exchange bağlantısı yok: adresler AD proxyAddresses özniteliğinden okunur ve yazılır.')
        }
        'OnPremises' {
            $recipient = $null
            try { $recipient = Get-Recipient -Identity $guid -ErrorAction Stop } catch { $recipient = $null }
            if (-not $recipient) {
                $data.EmailAddresses = $adAddresses
                $data.Notes.Add('Kullanıcı bir Exchange alıcısı değil; adresler AD proxyAddresses üzerinden yönetilir.')
                break
            }
            $type = [string]$recipient.RecipientTypeDetails
            $data.RecipientTypeDetails = $type
            if ($type -like 'Remote*Mailbox') {
                $remote = Get-RemoteMailbox -Identity $guid -ErrorAction Stop
                $data.Identity = [string]$remote.DistinguishedName
                $data.AddressSource = 'RemoteMailbox'
                $data.EmailAddresses = @($remote.EmailAddresses | ForEach-Object { [string]$_ })
                $data.EmailAddressPolicyEnabled = [bool]$remote.EmailAddressPolicyEnabled
                $data.Notes.Add('Posta kutusu bulutta (hibrit RemoteMailbox). Adresler Set-RemoteMailbox ile yönetilir; posta kutusu özellikleri ve kullanımı bu araçtan yönetilemez.')
            }
            elseif ($type -like '*Mailbox') {
                Set-WorkerProgress -Percent 75 -Status 'Posta kutusu bilgileri okunuyor...'
                $mailbox = Get-Mailbox -Identity $guid -ErrorAction Stop
                $data.HasMailbox = $true
                $data.Identity = [string]$mailbox.DistinguishedName
                $data.AddressSource = 'Mailbox'
                $data.EmailAddresses = @($mailbox.EmailAddresses | ForEach-Object { [string]$_ })
                $data.EmailAddressPolicyEnabled = [bool]$mailbox.EmailAddressPolicyEnabled
                Set-WorkerProgress -Percent 82 -Status 'CAS özellikleri okunuyor...'
                try { $data.Cas = Get-MailboxFeatureState -Identity $data.Identity } catch { $data.Notes.Add("CAS özellikleri okunamadı: $($_.Exception.Message)") }
                Set-WorkerProgress -Percent 90 -Status 'Posta kutusu istatistikleri okunuyor...'
                try { $data.Usage = Get-MailboxUsage -Mailbox $mailbox -Identity $data.Identity } catch { $data.Notes.Add("Posta kutusu istatistikleri okunamadı: $($_.Exception.Message)") }
                Add-MailboxExtendedData -Data $data -Mailbox $mailbox
            }
            else {
                $data.EmailAddresses = $adAddresses
                $data.Notes.Add("Kullanıcının posta kutusu yok (alıcı türü: $type); adresler AD proxyAddresses üzerinden yönetilir.")
            }
        }
    }
    $data.Notes = $data.Notes.ToArray()
    return [pscustomobject]$data
}
function global:Set-UserEmailAddress {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('AD', 'Mailbox', 'RemoteMailbox')][string]$Source,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SmtpAddresses,
        [Parameter()][AllowEmptyCollection()][string[]]$OriginalAddresses = @(),
        [Parameter()][bool]$PrimaryChanged = $false,
        [Parameter()][bool]$UpdateMailAttribute = $true
    )
    $other = @($OriginalAddresses | Where-Object { $_ -and $_ -notmatch '^smtp:' })
    $final = [string[]]@(@($other) + @($SmtpAddresses) | Where-Object { $_ })
    $primary = @($SmtpAddresses | Where-Object { $_ -cmatch '^SMTP:' }) | Select-Object -First 1
    if ($Source -ne 'AD' -and -not $primary) { throw 'Exchange alıcıları için bir birincil SMTP adresi belirlenmelidir.' }
    $primaryAddress = if ($primary) { $primary.Substring(5) } else { $null }
    $summary = '{0} SMTP adresi, birincil: {1}' -f @($SmtpAddresses).Count, $(if ($primaryAddress) { $primaryAddress } else { '-' })
    if ($WhatIfPreference) {
        Write-WorkerLog -Message "[WhatIf] E-posta adresleri ($Source) güncellenecekti: $summary :: $($final -join ', ')" -Level Warning
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Identity, "E-posta adreslerini güncelle ($Source): $summary")) { return }
    switch ($Source) {
        'AD' {
            $params = @{ Identity = $Identity; ErrorAction = 'Stop' }
            $replace = @{}
            if ($final.Count -gt 0) { $replace.proxyAddresses = $final } else { $params.Clear = @('proxyAddresses') }
            if ($PrimaryChanged -and $UpdateMailAttribute -and $primaryAddress) { $replace.mail = $primaryAddress }
            if ($replace.Count -gt 0) { $params.Replace = $replace }
            Set-ADUser @params
        }
        'Mailbox' {
            $params = @{ Identity = $Identity; EmailAddresses = $final; ErrorAction = 'Stop' }
            if ($PrimaryChanged -and $Sync.ExchangeMode -eq 'OnPremises') {
                $params.EmailAddressPolicyEnabled = $false
                Write-WorkerLog -Message 'Birincil adres değiştiği için EmailAddressPolicyEnabled = False olarak ayarlanıyor.' -Level Warning
            }
            Set-Mailbox @params
        }
        'RemoteMailbox' {
            $params = @{ Identity = $Identity; EmailAddresses = $final; ErrorAction = 'Stop' }
            if ($PrimaryChanged) {
                $params.EmailAddressPolicyEnabled = $false
                Write-WorkerLog -Message 'Birincil adres değiştiği için EmailAddressPolicyEnabled = False olarak ayarlanıyor.' -Level Warning
            }
            Set-RemoteMailbox @params
        }
    }
    Write-WorkerLog -Message "E-posta adresleri güncellendi ($Source): $summary" -Level Success
}
function global:Set-UserMailboxFeature {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][hashtable]$Features
    )
    $description = ($Features.GetEnumerator() | Sort-Object -Property Key | ForEach-Object { '-{0}:${1}' -f $_.Key, $_.Value }) -join ' '
    if ($WhatIfPreference) {
        Write-WorkerLog -Message "[WhatIf] Set-CASMailbox -Identity $Identity $description" -Level Warning
        return
    }
    if ($PSCmdlet.ShouldProcess($Identity, "Set-CASMailbox $description")) {
        $params = @{ Identity = $Identity; ErrorAction = 'Stop' }
        foreach ($key in $Features.Keys) { $params[$key] = [bool]$Features[$key] }
        Set-CASMailbox @params
        Write-WorkerLog -Message "Set-CASMailbox başarılı: $description" -Level Success
    }
}
function global:Get-ArchiveInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$Mailbox,
        [Parameter(Mandatory = $true)][string]$Identity
    )
    $archiveGuid = [string]$Mailbox.ArchiveGuid
    $enabled = ($archiveGuid -and $archiveGuid -ne '00000000-0000-0000-0000-000000000000') -or ([string]$Mailbox.ArchiveStatus -eq 'Active')
    $quota = ConvertTo-ByteCount -Value $Mailbox.ArchiveQuota
    $info = [ordered]@{
        Enabled       = [bool]$enabled
        Status        = [string]$Mailbox.ArchiveStatus
        Name          = [string](@($Mailbox.ArchiveName) | Select-Object -First 1)
        Database      = [string]$Mailbox.ArchiveDatabase
        AutoExpanding = if ($null -eq $Mailbox.AutoExpandingArchiveEnabled) { '-' } elseif ([string]$Mailbox.AutoExpandingArchiveEnabled -eq 'True') { 'Etkin' } else { 'Devre dışı' }
        Quota         = Format-ByteSize -Bytes $quota
        WarningQuota  = Format-ByteSize -Bytes (ConvertTo-ByteCount -Value $Mailbox.ArchiveWarningQuota)
        TotalItemSize = '-'
        ItemCount     = $null
        UsagePercent  = $null
        StatsError    = $null
    }
    if ($enabled) {
        try {
            $stats = Get-MailboxStatistics -Identity $Identity -Archive -ErrorAction Stop
            $total = ConvertTo-ByteCount -Value $stats.TotalItemSize
            $info.TotalItemSize = Format-ByteSize -Bytes $total
            $info.ItemCount = [long]$stats.ItemCount
            if ($quota -gt 0 -and $null -ne $total) { $info.UsagePercent = [math]::Round(($total / $quota) * 100, 1) }
        }
        catch { $info.StatsError = $_.Exception.Message }
    }
    return [pscustomobject]$info
}
function global:Get-UserPolicyState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$Mailbox,
        [Parameter()][object]$Cas,
        [Parameter(Mandatory = $true)][hashtable]$Catalog
    )
    $current = [ordered]@{
        RetentionPolicy         = [string]$Mailbox.RetentionPolicy
        AddressBookPolicy       = [string]$Mailbox.AddressBookPolicy
        SharingPolicy           = [string]$Mailbox.SharingPolicy
        RoleAssignmentPolicy    = [string]$Mailbox.RoleAssignmentPolicy
        OwaMailboxPolicy        = if ($Cas) { [string]$Cas.OwaMailboxPolicy } else { '' }
        ActiveSyncMailboxPolicy = if ($Cas) { [string]$Cas.ActiveSyncMailboxPolicy } else { '' }
    }
    $state = [ordered]@{}
    foreach ($key in $current.Keys) {
        $state[$key] = [pscustomobject]@{ Current = $current[$key]; Options = @($Catalog.Policies[$key]) }
    }
    return [pscustomobject]$state
}
function global:Get-MailboxMoveStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string[]]$Identity)
    foreach ($id in $Identity) {
        $request = $null
        try { $request = Get-MoveRequest -Identity $id -ErrorAction Stop } catch { $request = $null }
        if (-not $request) {
            [pscustomobject]@{ Identity = $id; Exists = $false; IsFinal = $true; CheckedAt = Get-Date }
            continue
        }
        $stats = $null
        try { $stats = Get-MoveRequestStatistics -Identity $id -ErrorAction Stop } catch { $stats = $null }
        $status = [string]$request.Status
        [pscustomobject]@{
            Identity            = $id
            Exists              = $true
            DisplayName         = [string]$request.DisplayName
            Status              = $status
            StatusDetail        = if ($stats) { [string]$stats.StatusDetail } else { '' }
            PercentComplete     = if ($stats) { [int]$stats.PercentComplete } else { 0 }
            SourceDatabase      = [string]$request.SourceDatabase
            TargetDatabase      = if ([string]$request.TargetDatabase) { [string]$request.TargetDatabase } else { [string]$request.ArchiveTargetDatabase }
            BytesTransferred    = if ($stats) { Format-ByteSize -Bytes (ConvertTo-ByteCount -Value $stats.BytesTransferred) } else { '-' }
            TotalMailboxSize    = if ($stats) { Format-ByteSize -Bytes (ConvertTo-ByteCount -Value $stats.TotalMailboxSize) } else { '-' }
            QueuedTimestamp     = if ($stats) { $stats.QueuedTimestamp } else { $null }
            StartTimestamp      = if ($stats) { $stats.StartTimestamp } else { $null }
            CompletionTimestamp = if ($stats) { $stats.CompletionTimestamp } else { $null }
            FailureMessage      = if ($stats -and $status -like 'Failed*') { [string]$stats.Message } else { '' }
            IsFinal             = $status -in @('Completed', 'CompletedWithWarning', 'Failed')
            CheckedAt           = Get-Date
        }
    }
}
function global:Add-MailboxExtendedData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Data,
        [Parameter(Mandatory = $true)][object]$Mailbox
    )
    Set-WorkerProgress -Percent 93 -Status 'Arşiv, politika ve veritabanı bilgileri okunuyor...'
    $catalog = Get-ExchangeCatalog
    try { $Data.Archive = Get-ArchiveInfo -Mailbox $Mailbox -Identity $Data.Identity } catch { $Data.Notes.Add("Arşiv bilgisi okunamadı: $($_.Exception.Message)") }
    try { $Data.Policies = Get-UserPolicyState -Mailbox $Mailbox -Cas $Data.Cas -Catalog $catalog } catch { $Data.Notes.Add("Politikalar okunamadı: $($_.Exception.Message)") }
    if ($Sync.ExchangeMode -eq 'OnPremises') {
        $Data.Database = [string]$Mailbox.Database
        $Data.ArchiveDatabase = [string]$Mailbox.ArchiveDatabase
        $Data.DatabaseOptions = @($catalog.Databases)
        try { $Data.Move = Get-MailboxMoveStatus -Identity $Data.Identity | Select-Object -First 1 } catch { $Data.Notes.Add("Taşıma isteği durumu okunamadı: $($_.Exception.Message)") }
    }
}
function global:Set-UserArchiveState {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][bool]$Enable,
        [Parameter()][string]$ArchiveDatabase
    )
    if ($Sync.ExchangeMode -eq 'None') { throw 'Exchange bağlantısı yok.' }
    $action = if ($Enable) { 'Enable-Mailbox -Archive' } else { 'Disable-Mailbox -Archive' }
    if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] $action -Identity $Identity" -Level Warning; return }
    if (-not $PSCmdlet.ShouldProcess($Identity, $action)) { return }
    Set-WorkerProgress -Status "$action çalıştırılıyor..."
    if ($Enable) {
        $params = @{ Identity = $Identity; Archive = $true; ErrorAction = 'Stop' }
        if ($ArchiveDatabase -and $Sync.ExchangeMode -eq 'OnPremises') { $params.ArchiveDatabase = $ArchiveDatabase }
        Enable-Mailbox @params | Out-Null
        Write-WorkerLog -Message 'Arşiv posta kutusu etkinleştirildi.' -Level Success
    }
    else {
        Disable-Mailbox -Identity $Identity -Archive -Confirm:$false -ErrorAction Stop | Out-Null
        Write-WorkerLog -Message 'Arşiv posta kutusu devre dışı bırakıldı.' -Level Success
    }
}
function global:Start-MailboxMove {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$TargetDatabase,
        [Parameter()][ValidateSet('All', 'PrimaryOnly', 'ArchiveOnly')][string]$Scope = 'All'
    )
    if ($Sync.ExchangeMode -ne 'OnPremises') { throw 'Veritabanı taşıma yalnızca Exchange On-Premises bağlantısında yapılabilir.' }
    $params = @{ Identity = $Identity; ErrorAction = 'Stop' }
    switch ($Scope) {
        'All' { $params.TargetDatabase = $TargetDatabase }
        'PrimaryOnly' { $params.TargetDatabase = $TargetDatabase; $params.PrimaryOnly = $true }
        'ArchiveOnly' { $params.ArchiveTargetDatabase = $TargetDatabase; $params.ArchiveOnly = $true }
    }
    if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] New-MoveRequest -Identity $Identity -> $TargetDatabase ($Scope)" -Level Warning; return }
    if (-not $PSCmdlet.ShouldProcess($Identity, "New-MoveRequest -> $TargetDatabase ($Scope)")) { return }
    Set-WorkerProgress -Status "Taşıma isteği oluşturuluyor: $TargetDatabase..."
    New-MoveRequest @params | Out-Null
    Write-WorkerLog -Message "Taşıma isteği oluşturuldu: $TargetDatabase ($Scope)" -Level Success
    return (Get-MailboxMoveStatus -Identity $Identity | Select-Object -First 1)
}
function global:Remove-MailboxMove {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][string]$Identity)
    if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] Remove-MoveRequest -Identity $Identity" -Level Warning; return }
    if ($PSCmdlet.ShouldProcess($Identity, 'Remove-MoveRequest')) {
        Remove-MoveRequest -Identity $Identity -Confirm:$false -ErrorAction Stop
        Write-WorkerLog -Message 'Taşıma isteği kaldırıldı.' -Level Success
    }
}
function global:Set-UserMailboxPolicy {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][hashtable]$Policies
    )
    $mailboxKeys = @('RetentionPolicy', 'AddressBookPolicy', 'SharingPolicy', 'RoleAssignmentPolicy')
    $mailboxParams = @{}
    $casParams = @{}
    foreach ($key in $Policies.Keys) {
        $value = if ([string]::IsNullOrEmpty([string]$Policies[$key])) { $null } else { [string]$Policies[$key] }
        if ($mailboxKeys -contains $key) { $mailboxParams[$key] = $value } else { $casParams[$key] = $value }
    }
    $description = ($Policies.GetEnumerator() | Sort-Object -Property Key | ForEach-Object { "{0}='{1}'" -f $_.Key, $(if ($_.Value) { $_.Value } else { '(Yok)' }) }) -join '; '
    if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] Politikalar güncellenecekti: $description" -Level Warning; return }
    if (-not $PSCmdlet.ShouldProcess($Identity, "Politikaları güncelle: $description")) { return }
    if ($mailboxParams.Count -gt 0) { Set-Mailbox -Identity $Identity @mailboxParams -ErrorAction Stop }
    if ($casParams.Count -gt 0) { Set-CASMailbox -Identity $Identity @casParams -ErrorAction Stop }
    Write-WorkerLog -Message "Politikalar güncellendi: $description" -Level Success
}
function global:Enable-UserMailbox {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter()][AllowEmptyString()][string]$Database,
        [Parameter()][AllowEmptyString()][string]$Alias
    )
    if ($Sync.ExchangeMode -ne 'OnPremises') {
        throw 'Posta kutusu oluşturmak için Exchange On-Premises''e bağlanın.'
    }
    $server = Get-PdcEmulator
    $params = @{ Identity = $Identity; DomainController = $server; ErrorAction = 'Stop' }
    if ($Database) { $params.Database = $Database }
    if ($Alias) { $params.Alias = $Alias }
    $target = if ($Database) { $Database } else { 'otomatik veritabanı seçimi' }
    if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] Enable-Mailbox -Identity '$Identity' -Database '$target' -DomainController $server" -Level Warning; return }
    if (-not $PSCmdlet.ShouldProcess($Identity, "Enable-Mailbox ($target)")) { return }
    Set-WorkerProgress -Status "Posta kutusu oluşturuluyor ($target)..."
    $mailbox = Enable-Mailbox @params
    Write-WorkerLog -Message "Posta kutusu oluşturuldu: $($mailbox.PrimarySmtpAddress) (veritabanı: $($mailbox.Database))" -Level Success
    return [pscustomobject]@{ PrimarySmtpAddress = [string]$mailbox.PrimarySmtpAddress; Database = [string]$mailbox.Database }
}
