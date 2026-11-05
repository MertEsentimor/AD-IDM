function global:Get-AccurateLastLogon {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter()][long]$LastLogonTimestamp = 0,
        [Parameter()][int]$ProgressStart = 15,
        [Parameter()][int]$ProgressRange = 45
    )
    $latest = [long]0
    $source = $null
    $queried = 0
    $failed = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $controllers = @([pscustomobject]@{ HostName = (Get-PdcEmulator) })
    for ($i = 0; $i -lt $controllers.Count; $i++) {
        $dcHost = [string]$controllers[$i].HostName
        $percent = $ProgressStart + [int]($ProgressRange * $i / [math]::Max(1, $controllers.Count))
        Set-WorkerProgress -Percent $percent -Status ("Son oturum açma bilgisi sorgulanıyor: {0} ({1}/{2})" -f $dcHost, ($i + 1), $controllers.Count)
        if (-not (Test-TcpPort -ComputerName $dcHost -Port 9389)) {
            $failed.Add($dcHost)
            Write-WorkerLog -Message "DC'ye erişilemedi (ADWS 9389): $dcHost" -Level Warning
            continue
        }
        try {
            $dcUser = Get-ADUser -Identity $Identity -Server $dcHost -Properties lastLogon -ErrorAction Stop
            $queried++
            $value = [long]$dcUser.lastLogon
            if ($value -gt $latest) { $latest = $value; $source = $dcHost }
        }
        catch {
            $failed.Add($dcHost)
            Write-WorkerLog -Message "DC sorgusu başarısız ($dcHost): $($_.Exception.Message)" -Level Warning
        }
    }
    if ($LastLogonTimestamp -gt $latest) {
        $latest = $LastLogonTimestamp
        $source = 'lastLogonTimestamp (replike değer)'
    }
    $lastLogon = $null
    if ($latest -gt 0) {
        try { $lastLogon = [datetime]::FromFileTime($latest) } catch { $lastLogon = $null }
    }
    return [pscustomobject]@{
        LastLogon    = $lastLogon
        Source       = $source
        QueriedCount = $queried
        TotalDCs     = $controllers.Count
        FailedDCs    = $failed.ToArray()
    }
}
function global:Get-PasswordStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][object]$AdUser)
    $pwdLastSetRaw = [long]$AdUser.pwdLastSet
    $computed = [long]$AdUser.'msDS-UserPasswordExpiryTimeComputed'
    $result = [ordered]@{
        PasswordLastSet     = $null
        PasswordLastSetText = $null
        ExpirationDate      = $null
        ExpirationText      = $null
        DaysRemaining       = $null
        State               = 'Ok'
        PolicyText          = $null
    }
    if ($pwdLastSetRaw -eq 0) {
        $result.PasswordLastSetText = 'Ayarlanmamış (bir sonraki oturumda değiştirilmeli)'
    }
    else {
        try { $result.PasswordLastSet = [datetime]::FromFileTime($pwdLastSetRaw) } catch { $result.PasswordLastSetText = 'Okunamadı' }
    }
    if ([bool]$AdUser.PasswordNeverExpires) {
        $result.State = 'Never'
        $result.ExpirationText = 'Süresi dolmaz (PasswordNeverExpires = True)'
    }
    elseif ($pwdLastSetRaw -eq 0) {
        $result.State = 'MustChange'
        $result.ExpirationText = 'Parola bir sonraki oturum açışta değiştirilmeli'
    }
    elseif ($computed -le 0 -or $computed -eq [long]::MaxValue) {
        $result.State = 'Never'
        $result.ExpirationText = 'Süresi dolmaz (politika: MaxPasswordAge = 0)'
    }
    else {
        try {
            $expiry = [datetime]::FromFileTime($computed)
            $days = [math]::Floor(($expiry - (Get-Date)).TotalDays)
            $result.ExpirationDate = $expiry
            $result.DaysRemaining = [int]$days
            if ($expiry -lt (Get-Date)) { $result.State = 'Expired' }
            elseif ($days -le 14) { $result.State = 'Warning' }
        }
        catch {
            $result.State = 'Unknown'
            $result.ExpirationText = 'Hesaplanamadı'
        }
    }
    try {
        $pso = Get-ADUserResultantPasswordPolicy -Identity $AdUser.ObjectGUID -ErrorAction Stop
        if ($pso) {
            $result.PolicyText = 'FGPP: {0} (MaxPasswordAge: {1} gün)' -f $pso.Name, [int]$pso.MaxPasswordAge.TotalDays
        }
        else {
            $defaultPolicy = Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop
            $result.PolicyText = 'Varsayılan etki alanı politikası (MaxPasswordAge: {0} gün)' -f [int]$defaultPolicy.MaxPasswordAge.TotalDays
        }
    }
    catch {
        $result.PolicyText = 'Parola politikası okunamadı (yetki gerekebilir)'
    }
    return [pscustomobject]$result
}
function global:Get-UserProfileData {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$ObjectGuid)
    Set-WorkerProgress -Percent 5 -Status 'Active Directory kullanıcı bilgileri okunuyor...'
    $properties = @(
        'GivenName', 'Surname', 'DisplayName', 'Description', 'Office', 'EmailAddress', 'mail', 'HomePhone', 'MobilePhone',
        'UserPrincipalName', 'SamAccountName', 'Enabled', 'LockedOut', 'PasswordNeverExpires', 'pwdLastSet',
        'lastLogonTimestamp', 'msDS-UserPasswordExpiryTimeComputed', 'proxyAddresses', 'whenCreated',
        'AccountExpirationDate', 'CanonicalName', 'thumbnailPhoto', 'lockoutTime', 'badPwdCount',
        'memberOf', 'primaryGroupID', $Sync.PreviousOuAttribute, $Sync.LeaveAttribute
    )
    if ($Sync.LegacyLeaveEndAttribute) { $properties += $Sync.LegacyLeaveEndAttribute }
    try {
        $user = Get-ADUser -Identity $ObjectGuid -Properties $properties -ErrorAction Stop
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        $user = Get-ADUser -Identity $ObjectGuid -Properties $properties -Server (Get-PdcEmulator) -ErrorAction Stop
    }
    $ad = [pscustomobject]@{
        ObjectGuid            = $user.ObjectGUID.ToString()
        SamAccountName        = [string]$user.SamAccountName
        UserPrincipalName     = [string]$user.UserPrincipalName
        GivenName             = [string]$user.GivenName
        Surname               = [string]$user.Surname
        DisplayName           = [string]$user.DisplayName
        Description           = [string]$user.Description
        Office                = [string]$user.Office
        EmailAddress          = [string]$user.EmailAddress
        HomePhone             = [string]$user.HomePhone
        MobilePhone           = [string]$user.MobilePhone
        Enabled               = [bool]$user.Enabled
        LockedOut             = [bool]$user.LockedOut
        DistinguishedName     = [string]$user.DistinguishedName
        CanonicalName         = [string]$user.CanonicalName
        WhenCreated           = $user.whenCreated
        AccountExpirationDate = $user.AccountExpirationDate
        PasswordNeverExpires  = [bool]$user.PasswordNeverExpires
        ParentOu              = Get-ParentDn -DistinguishedName ([string]$user.DistinguishedName)
        PreviousOu            = Get-StoredPreviousOu -Value ([string]$user.($Sync.PreviousOuAttribute))
        DisabledUsersOu       = $null
        LockoutTime           = $null
        BadPwdCount           = [int]$user.badPwdCount
        Leave                 = $null
    }
    try { $ad.DisabledUsersOu = Get-DisabledUsersOu } catch { Write-WorkerLog -Message "DisabledUsers OU belirlenemedi: $($_.Exception.Message)" -Level Warning }
    $ad.Leave = Get-UserLeaveInfo -User $user -Enabled $ad.Enabled -Protected (Test-LeaveProtected -DistinguishedName $ad.DistinguishedName -Marker ([string]$user.($Sync.PreviousOuAttribute)) -DisabledOu ([string]$ad.DisabledUsersOu))
    Set-WorkerProgress -Percent 10 -Status 'Hesap kilit durumu PDC Emulator üzerinden kontrol ediliyor...'
    try {
        $pdc = Get-PdcEmulator
        $lockInfo = Get-ADUser -Identity $ObjectGuid -Server $pdc -Properties LockedOut, lockoutTime, badPwdCount -ErrorAction Stop
        $ad.LockedOut = [bool]$lockInfo.LockedOut
        $ad.BadPwdCount = [int]$lockInfo.badPwdCount
        if ($ad.LockedOut -and [long]$lockInfo.lockoutTime -gt 0) { $ad.LockoutTime = [datetime]::FromFileTime([long]$lockInfo.lockoutTime) }
    }
    catch {
        Write-WorkerLog -Message "PDC üzerinden kilit durumu okunamadı, yerel DC değeri kullanılıyor: $($_.Exception.Message)" -Level Warning
        if ($ad.LockedOut -and [long]$user.lockoutTime -gt 0) { $ad.LockoutTime = [datetime]::FromFileTime([long]$user.lockoutTime) }
    }
    $lastLogon = Get-AccurateLastLogon -Identity $ObjectGuid -LastLogonTimestamp ([long]$user.lastLogonTimestamp)
    Set-WorkerProgress -Percent 65 -Status 'Parola durumu hesaplanıyor...'
    $password = Get-PasswordStatus -AdUser $user
    Set-WorkerProgress -Percent 67 -Status 'Grup üyelikleri okunuyor...'
    $groups = @()
    try { $groups = @(Get-UserGroupMembership -AdUser $user) }
    catch { Write-WorkerLog -Message "Grup üyelikleri okunamadı: $($_.Exception.Message)" -Level Warning }
    Set-WorkerProgress -Percent 70 -Status 'Exchange bilgileri okunuyor...'
    try {
        $exchange = Get-ExchangeUserData -AdUser $user
    }
    catch {
        Write-WorkerLog -Message "Exchange verisi okunamadı: $($_.Exception.Message)" -Level Error
        $exchange = [pscustomobject]@{
            Mode = $Sync.ExchangeMode; HasMailbox = $false; RecipientTypeDetails = $null; Identity = $null
            AddressSource = 'AD'; CanEditAddresses = $false
            EmailAddresses = @($user.proxyAddresses | Where-Object { $_ } | ForEach-Object { [string]$_ })
            EmailAddressPolicyEnabled = $null; Cas = $null; Usage = $null
            Archive = $null; Policies = $null; Database = $null; ArchiveDatabase = $null; DatabaseOptions = @(); Move = $null
            Notes = @("Exchange verisi okunamadı: $($_.Exception.Message)")
        }
    }
    $photo = Get-UserPhotoBytes -AdUser $user -ExchangeIdentity $(if ($exchange.HasMailbox) { $exchange.Identity } else { $null })
    Set-WorkerProgress -Percent 100 -Status 'Kullanıcı bilgileri yüklendi.'
    return [pscustomobject]@{
        Ad        = $ad
        LastLogon = $lastLogon
        Password  = $password
        Exchange  = $exchange
        Photo     = $photo
        Groups    = $groups
        LoadedAt  = Get-Date
    }
}
function global:Get-UserPhotoBytes {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$AdUser,
        [Parameter()][string]$ExchangeIdentity
    )
    $bytes = $null
    $source = $null
    if ($AdUser.thumbnailPhoto) { $bytes = [byte[]]$AdUser.thumbnailPhoto; $source = 'AD thumbnailPhoto' }
    if (-not $bytes -and $ExchangeIdentity -and $Sync.ExchangeMode -ne 'None' -and (Get-Command -Name Get-UserPhoto -ErrorAction SilentlyContinue)) {
        try {
            $photo = Get-UserPhoto -Identity $ExchangeIdentity -ErrorAction Stop
            if ($photo.PictureData) { $bytes = [byte[]]$photo.PictureData; $source = 'Exchange posta kutusu' }
        }
        catch { Write-WorkerLog -Message 'Exchange posta kutusunda fotoğraf yok.' -Level Verbose }
    }
    return [pscustomobject]@{ Bytes = $bytes; Source = $source }
}
function global:Set-DirectoryUserAttribute {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter()][hashtable]$Replace = @{},
        [Parameter()][string[]]$Clear = @()
    )
    $parts = @()
    if ($Replace.Count -gt 0) {
        $parts += '-Replace @{' + (($Replace.GetEnumerator() | Sort-Object -Property Key | ForEach-Object { "{0}='{1}'" -f $_.Key, (@($_.Value) -join ';') }) -join '; ') + '}'
    }
    if ($Clear.Count -gt 0) { $parts += '-Clear ' + ($Clear -join ',') }
    $description = $parts -join ' '
    if ($WhatIfPreference) {
        Write-WorkerLog -Message "[WhatIf] Set-ADUser -Identity $Identity $description" -Level Warning
        return
    }
    if ($PSCmdlet.ShouldProcess($Identity, "Set-ADUser $description")) {
        $params = @{ Identity = $Identity; ErrorAction = 'Stop' }
        if ($Replace.Count -gt 0) { $params.Replace = $Replace }
        if ($Clear.Count -gt 0) { $params.Clear = $Clear }
        Set-ADUser @params
        Write-WorkerLog -Message "Set-ADUser başarılı: $description" -Level Success
    }
}
function global:Unlock-UserAccount {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory = $true)][string]$Identity)
    $server = Get-PdcEmulator
    if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] Unlock-ADAccount -Identity $Identity -Server $server" -Level Warning; return }
    if ($PSCmdlet.ShouldProcess($Identity, 'Unlock-ADAccount')) {
        Unlock-ADAccount -Identity $Identity -Server $server -ErrorAction Stop
        Write-WorkerLog -Message "Hesap kilidi açıldı (PDC: $server)." -Level Success
    }
}
function global:Reset-UserPassword {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter()][System.Security.SecureString]$NewPassword,
        [Parameter()][bool]$ChangePasswordAtLogon = $true,
        [Parameter()][bool]$Unlock = $false,
        [Parameter()][hashtable]$Sms,
        [Parameter()][hashtable]$SmsSecrets = @{},
        [Parameter()][hashtable]$SmsValues = @{}
    )
    $server = Get-PdcEmulator
    if (-not $Sms -and -not $NewPassword) { throw 'Yeni parola veya SMS ayarı verilmelidir.' }
    $phone = $null
    $plain = $null
    if ($Sms) {
        Set-WorkerProgress -Percent 10 -Status 'SMS ayarları ve telefon numarası doğrulanıyor...'
        Test-SmsConfiguration -Config $Sms
        $attribute = if ($Sms.PhoneAttribute) { [string]$Sms.PhoneAttribute } else { 'mobile' }
        $user = Get-ADUser -Identity $Identity -Properties $attribute -Server $server -ErrorAction Stop
        $rawPhone = ([string]$user.$attribute).Trim()
        if (-not $rawPhone) { throw "Kullanıcının '$attribute' özniteliğinde cep telefonu yok; parola değiştirilmedi." }
        $phone = Format-SmsPhone -Number $rawPhone -CountryCode $(if ($null -ne $Sms.CountryCode) { [string]$Sms.CountryCode } else { '90' }) `
            -Format $(if ($Sms.PhoneFormat) { [string]$Sms.PhoneFormat } else { 'International' }) -NationalLength $(if ($null -ne $Sms.NationalLength) { [int]$Sms.NationalLength } else { 10 })
        $probe = $SmsValues.Clone(); $probe.Password = 'x'
        [void](Expand-SmsTemplate -Template ([string]$Sms.MessageTemplate) -Values $probe -Encoding Text)
        foreach ($template in @([string]$Sms.Url, [string]$Sms.Body) + @(if ($Sms.Headers) { $Sms.Headers.Values })) {
            [void](Expand-SmsTemplate -Template ([string]$template) -Values @{ PhoneNumber = $phone; Message = 'x'; MessageId = 'x'; Time = 'x' } -Secrets $SmsSecrets -Encoding Text)
        }
        $masked = Get-MaskedPhone -Number $phone
        Write-WorkerLog -Message "SMS ayarı doğrulandı; parola $masked numarasına gönderilecek ($([string]$Sms.Provider))." -Level Info
    }
    if ($WhatIfPreference) {
        $how = if ($Sms) { "rastgele parola üretilip $(Get-MaskedPhone -Number $phone) numarasına SMS ile gönderilecekti" } else { 'elle girilen parola' }
        Write-WorkerLog -Message "[WhatIf] Set-ADAccountPassword -Reset ($how; ChangePasswordAtLogon=$ChangePasswordAtLogon, Unlock=$Unlock)" -Level Warning
        [pscustomobject]@{ Step = 'Parola sıfırlama'; Success = $true; Message = 'Simüle edildi (değişiklik yapılmadı)' }
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Identity, 'Parolayı sıfırla')) { return }
    if ($Sms) {
        $length = if ($Sms.PasswordLength) { [int]$Sms.PasswordLength } else { 14 }
        $symbols = if ($null -ne $Sms.PasswordSymbols) { [string]$Sms.PasswordSymbols } else { '.' }
        $plain = New-SmsPassword -Length $length -Symbols $symbols
        $NewPassword = ConvertTo-SecureString -String $plain -AsPlainText -Force
    }
    Set-WorkerProgress -Percent 20 -Status 'Parola sıfırlanıyor...'
    try { Set-ADAccountPassword -Identity $Identity -Reset -NewPassword $NewPassword -Server $server -ErrorAction Stop }
    catch { $plain = $null; throw }
    Write-WorkerLog -Message "Parola sıfırlandı (PDC: $server)." -Level Success
    [pscustomobject]@{ Step = 'Parola sıfırlama'; Success = $true; Message = 'Başarılı' }
    if ($ChangePasswordAtLogon) {
        Set-WorkerProgress -Percent 60 -Status 'İlk oturumda parola değişikliği ayarlanıyor...'
        try {
            Set-ADUser -Identity $Identity -ChangePasswordAtLogon $true -Server $server -ErrorAction Stop
            [pscustomobject]@{ Step = 'Bir sonraki oturumda parola değiştirilmeli'; Success = $true; Message = 'Başarılı' }
        }
        catch { [pscustomobject]@{ Step = 'Bir sonraki oturumda parola değiştirilmeli'; Success = $false; Message = $_.Exception.Message } }
    }
    if ($Unlock) {
        Set-WorkerProgress -Percent 80 -Status 'Hesap kilidi açılıyor...'
        try {
            Unlock-ADAccount -Identity $Identity -Server $server -ErrorAction Stop
            [pscustomobject]@{ Step = 'Hesap kilidini açma'; Success = $true; Message = 'Başarılı' }
        }
        catch { [pscustomobject]@{ Step = 'Hesap kilidini açma'; Success = $false; Message = $_.Exception.Message } }
    }
    if ($Sms) {
        Set-WorkerProgress -Percent 90 -Status 'Parola SMS ile gönderiliyor...'
        $masked = Get-MaskedPhone -Number $phone
        $provider = [string]$Sms.Provider
        try {
            $values = $SmsValues.Clone()
            $values.Password = $plain
            $text = Expand-SmsTemplate -Template ([string]$Sms.MessageTemplate) -Values $values -Encoding Text
            $send = Send-SmsMessage -Config $Sms -Secrets $SmsSecrets -PhoneNumber $phone -Message $text -Scrub @($plain)
            if ($send.Success) {
                Write-WorkerLog -Message "Yeni parola SMS ile gönderildi: $masked ($provider, $($send.Detail))." -Level Success
                [pscustomobject]@{ Step = 'SMS gönderimi'; Success = $true; Message = "Gönderildi: $masked ($($send.Detail))"; SmsTo = $masked; SmsProvider = $provider; SmsStatus = $send.StatusCode }
            }
            else {
                Write-WorkerLog -Message "SMS gönderilemedi ($masked): $($send.Detail)" -Level Error
                [pscustomobject]@{ Step = 'SMS gönderimi'; Success = $false; Message = "SMS gönderilemedi ($masked): $($send.Detail). Parola sıfırlandı ancak kullanıcıya iletilemedi; sorunu giderip parolayı yeniden sıfırlayın."; SmsTo = $masked; SmsProvider = $provider; SmsStatus = $send.StatusCode }
            }
        }
        catch {
            $detail = ([string]$_.Exception.Message)
            if ($plain) { $detail = $detail.Replace($plain, '***') }
            [pscustomobject]@{ Step = 'SMS gönderimi'; Success = $false; Message = "SMS gönderilemedi ($masked): $detail. Parola sıfırlandı ancak kullanıcıya iletilemedi; parolayı yeniden sıfırlayın."; SmsTo = $masked; SmsProvider = $provider; SmsStatus = $null }
        }
        finally {
            $plain = $null; $text = $null; $values = $null
        }
    }
    Set-WorkerProgress -Percent 100 -Status 'Parola sıfırlama tamamlandı.'
}
function global:Set-UserPhotoData {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$ObjectGuid,
        [Parameter()][byte[]]$ThumbnailBytes,
        [Parameter()][byte[]]$ExchangeBytes,
        [Parameter()][string]$ExchangeIdentity,
        [Parameter()][switch]$Remove
    )
    $action = if ($Remove) { 'kaldır' } else { 'güncelle' }
    if ($WhatIfPreference) {
        Write-WorkerLog -Message "[WhatIf] Kullanıcı fotoğrafı $action (AD$(if ($ExchangeIdentity) { ' + Exchange' }))" -Level Warning
        [pscustomobject]@{ Step = 'Fotoğraf'; Success = $true; Message = 'Simüle edildi (değişiklik yapılmadı)' }
        return
    }
    if (-not $PSCmdlet.ShouldProcess($ObjectGuid, "Kullanıcı fotoğrafını $action")) { return }
    try {
        if ($Remove) { Set-ADUser -Identity $ObjectGuid -Clear thumbnailPhoto -ErrorAction Stop }
        else { Set-ADUser -Identity $ObjectGuid -Replace @{ thumbnailPhoto = $ThumbnailBytes } -ErrorAction Stop }
        [pscustomobject]@{ Step = 'AD thumbnailPhoto'; Success = $true; Message = 'Başarılı' }
    }
    catch { [pscustomobject]@{ Step = 'AD thumbnailPhoto'; Success = $false; Message = $_.Exception.Message } }
    if ($ExchangeIdentity -and $Sync.ExchangeMode -ne 'None') {
        try {
            if ($Remove) { Remove-UserPhoto -Identity $ExchangeIdentity -Confirm:$false -ErrorAction Stop }
            else { Set-UserPhoto -Identity $ExchangeIdentity -PictureData $ExchangeBytes -Confirm:$false -ErrorAction Stop }
            [pscustomobject]@{ Step = 'Exchange posta kutusu fotoğrafı'; Success = $true; Message = 'Başarılı' }
        }
        catch { [pscustomobject]@{ Step = 'Exchange posta kutusu fotoğrafı'; Success = $false; Message = $_.Exception.Message } }
    }
}
function global:Set-UserAccountFlag {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][hashtable]$Flags
    )
    $server = Get-PdcEmulator
    $attribute = $Sync.PreviousOuAttribute
    $prefix = 'ADEUM-PreviousOU='
    $description = ($Flags.GetEnumerator() | Sort-Object -Property Key | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; '
    if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] Hesap seçenekleri değiştirilecekti: $description" -Level Warning; return }
    if (-not $PSCmdlet.ShouldProcess($Identity, "Hesap seçenekleri: $description")) { return }
    if ($Flags.ContainsKey('PasswordNeverExpires')) {
        Set-ADUser -Identity $Identity -Server $server -PasswordNeverExpires ([bool]$Flags.PasswordNeverExpires) -ErrorAction Stop
        Write-WorkerLog -Message "PasswordNeverExpires = $([bool]$Flags.PasswordNeverExpires)" -Level Success
    }
    if (-not $Flags.ContainsKey('Enabled')) { return }
    $user = Get-ADUser -Identity $Identity -Server $server -Properties $attribute -ErrorAction Stop
    $parent = Get-ParentDn -DistinguishedName ([string]$user.DistinguishedName)
    $disabledOu = Get-DisabledUsersOu
    $inDisabledOu = [string]::Equals($parent, $disabledOu, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not [bool]$Flags.Enabled) {
        try { $null = Get-ADOrganizationalUnit -Identity $disabledOu -Server $server -ErrorAction Stop }
        catch { throw "Devre dışı kullanıcılar OU'su bulunamadı: $disabledOu. OU'yu oluşturun veya -DisabledUsersOu parametresiyle belirtin. Hesapta değişiklik yapılmadı." }
        $existing = [string]$user.$attribute
        if (-not $inDisabledOu -and $existing -and -not $existing.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "$attribute özniteliği başka bir değer içeriyor ('$existing'); önceki OU kaydedilemez. -PreviousOuAttribute ile başka bir öznitelik seçin. Hesapta değişiklik yapılmadı."
        }
        $stamp = '|By={0}\{1}|At={2}' -f $env:USERDOMAIN, $env:USERNAME, (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        Disable-ADAccount -Identity $Identity -Server $server -ErrorAction Stop
        Write-WorkerLog -Message "Hesap devre dışı bırakıldı (PDC: $server)." -Level Success
        if ($inDisabledOu) {
            Write-WorkerLog -Message "Kullanıcı zaten $disabledOu içinde; taşıma gerekmedi." -Level Info
            if (-not $existing -or $existing.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $keep = (Get-StoredDisableInfo -Value $existing).PreviousOu
                try { Set-ADUser -Identity $Identity -Server $server -Replace @{ $attribute = "$prefix$keep$stamp" } -ErrorAction Stop }
                catch { Write-WorkerLog -Message "Devre dışı bırakma kaydı yazılamadı: $($_.Exception.Message)" -Level Warning }
            }
            return
        }
        try {
            Set-ADUser -Identity $Identity -Server $server -Replace @{ $attribute = "$prefix$parent$stamp" } -ErrorAction Stop
            Move-ADObject -Identity $user.ObjectGUID -TargetPath $disabledOu -Server $server -ErrorAction Stop
        }
        catch {
            throw "Hesap devre dışı bırakıldı ancak $disabledOu konumuna taşınamadı: $($_.Exception.Message) (Nesne 'yanlışlıkla silinmeye karşı koru' ile korunuyor olabilir.)"
        }
        Write-WorkerLog -Message "Kullanıcı taşındı: $parent -> $disabledOu (önceki OU '$attribute' özniteliğine kaydedildi)." -Level Success
    }
    else {
        Enable-ADAccount -Identity $Identity -Server $server -ErrorAction Stop
        Write-WorkerLog -Message "Hesap etkinleştirildi (PDC: $server)." -Level Success
        $previous = Get-StoredPreviousOu -Value ([string]$user.$attribute)
        if (-not $previous) {
            $record = [string]$user.$attribute
            if ($record -and $record.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { Set-ADUser -Identity $Identity -Server $server -Clear $attribute -ErrorAction Stop }
            if ($inDisabledOu) { Write-WorkerLog -Message "Önceki OU kaydı yok; kullanıcı $disabledOu içinde kaldı. Gerekirse elle taşıyın." -Level Warning }
            return
        }
        if ([string]::Equals($parent, $previous, [System.StringComparison]::OrdinalIgnoreCase)) {
            Set-ADUser -Identity $Identity -Server $server -Clear $attribute -ErrorAction Stop
            return
        }
        try {
            $null = Get-ADObject -Identity $previous -Server $server -ErrorAction Stop
            Move-ADObject -Identity $user.ObjectGUID -TargetPath $previous -Server $server -ErrorAction Stop
            Set-ADUser -Identity $Identity -Server $server -Clear $attribute -ErrorAction Stop
        }
        catch {
            throw "Hesap etkinleştirildi ancak eski OU'ya ($previous) taşınamadı: $($_.Exception.Message)"
        }
        Write-WorkerLog -Message "Kullanıcı eski OU'suna geri taşındı: $previous" -Level Success
    }
}
function global:Invoke-AdReplication {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param()
    $exe = Get-Command -Name 'repadmin.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { throw 'repadmin.exe bulunamadı. RSAT "AD DS Araçları" yüklü olmalı (Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0).' }
    $targets = @(Get-PdcEmulator)
    foreach ($dc in $targets) {
        if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] repadmin /syncall $dc /APed" -Level Warning; continue }
        if (-not $PSCmdlet.ShouldProcess($dc, 'repadmin /syncall /APed')) { continue }
        Set-WorkerProgress -Status "AD replikasyonu başlatılıyor: repadmin /syncall $dc /APed"
        $output = @(& $exe.Source /syncall $dc /APed 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
        $code = $LASTEXITCODE
        foreach ($line in $output) { Write-WorkerLog -Message "repadmin: $line" -Level Verbose }
        if ($code -ne 0 -or ($output -match 'fatal')) {
            throw ("repadmin /syncall $dc başarısız (çıkış kodu $code): " + (($output | Select-Object -Last 3) -join ' | '))
        }
        Write-WorkerLog -Message "AD replikasyonu tamamlandı: repadmin /syncall $dc /APed" -Level Success
    }
}
function global:Invoke-UserUpdate {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$ObjectGuid,
        [Parameter()][hashtable]$AdReplace = @{},
        [Parameter()][string[]]$AdClear = @(),
        [Parameter()][AllowEmptyCollection()][string[]]$SmtpAddresses,
        [Parameter()][AllowEmptyCollection()][string[]]$OriginalAddresses = @(),
        [Parameter()][ValidateSet('AD', 'Mailbox', 'RemoteMailbox')][string]$AddressSource = 'AD',
        [Parameter()][string]$ExchangeIdentity,
        [Parameter()][bool]$PrimaryChanged = $false,
        [Parameter()][bool]$UpdateMailAttribute = $true,
        [Parameter()][hashtable]$CasChanges = @{},
        [Parameter()][hashtable]$PolicyChanges = @{},
        [Parameter()][hashtable]$AccountFlags = @{},
        [Parameter()][AllowEmptyCollection()][string[]]$GroupAdd = @(),
        [Parameter()][AllowEmptyCollection()][string[]]$GroupRemove = @(),
        [Parameter()][hashtable]$Leave = @{},
        [Parameter()][hashtable]$DisableCleanup = @{}
    )
    if ($DisableCleanup.Count -gt 0 -and -not ($AccountFlags.ContainsKey('Enabled') -and -not [bool]$AccountFlags.Enabled)) { $DisableCleanup = @{} }
    $steps = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($AdReplace.Count -gt 0 -or $AdClear.Count -gt 0) { $steps.Add('AD') }
    if ($GroupAdd.Count -gt 0 -or $GroupRemove.Count -gt 0) { $steps.Add('Groups') }
    if ($AccountFlags.Count -gt 0) { $steps.Add('AccountFlags') }
    if ($DisableCleanup.RemoveGroups) { $steps.Add('GroupCleanup') }
    if ($DisableCleanup.Pst) { $steps.Add('PstExport') }
    if ($Leave.Count -gt 0) { $steps.Add('Leave') }
    if ($PSBoundParameters.ContainsKey('SmtpAddresses')) { $steps.Add('Addresses') }
    if ($CasChanges.Count -gt 0) { $steps.Add('Cas') }
    if ($PolicyChanges.Count -gt 0) { $steps.Add('Policies') }
    $prefix = if ($WhatIfPreference) { '[WhatIf] ' } else { '' }
    $index = 0
    $disableFailed = $false
    foreach ($step in $steps) {
        $index++
        $percent = [int](($index - 1) / $steps.Count * 100)
        $result = [ordered]@{ Step = $null; Success = $false; Message = $null; Data = $null }
        $stepMessage = $null
        try {
            switch ($step) {
                'AD' {
                    $result.Step = 'Active Directory öznitelikleri'
                    Set-WorkerProgress -Percent $percent -Status "${prefix}AD öznitelikleri güncelleniyor..."
                    Set-DirectoryUserAttribute -Identity $ObjectGuid -Replace $AdReplace -Clear $AdClear -Confirm:$false
                }
                'Groups' {
                    $result.Step = 'Grup üyelikleri'
                    Set-WorkerProgress -Percent $percent -Status "${prefix}Grup üyelikleri güncelleniyor..."
                    Set-UserGroupMembership -Identity $ObjectGuid -Add $GroupAdd -Remove $GroupRemove -Confirm:$false
                }
                'Leave' {
                    $result.Step = 'İzin planı'
                    Set-WorkerProgress -Percent $percent -Status "${prefix}İzin planı kaydediliyor..."
                    $account = if ($AccountFlags.ContainsKey('Enabled') -or -not $Leave.Account) { 'None' } else { [string]$Leave.Account }
                    Set-UserLeave -Identity $ObjectGuid -Value ([string]$Leave.Value) -Account $account -ClearLegacy ([bool]$Leave.ClearLegacy) -Confirm:$false
                }
                'AccountFlags' {
                    $result.Step = 'Hesap seçenekleri'
                    Set-WorkerProgress -Percent $percent -Status "${prefix}Hesap seçenekleri güncelleniyor..."
                    Set-UserAccountFlag -Identity $ObjectGuid -Flags $AccountFlags -Confirm:$false
                }
                'GroupCleanup' {
                    $result.Step = 'Grup temizliği'
                    if ($disableFailed) { throw 'Hesap devre dışı bırakılamadığı için grup üyeliklerine dokunulmadı.' }
                    Set-WorkerProgress -Percent $percent -Status "${prefix}Domain Users dışındaki gruplardan çıkarılıyor..."
                    $cleanup = Clear-UserGroupMembership -Identity $ObjectGuid -Confirm:$false
                    $result.Data = $cleanup
                    $stepMessage = if (-not $cleanup -or $cleanup.Removed.Count -eq 0) { 'Domain Users dışında grup üyeliği yoktu.' }
                    else { "$($cleanup.Removed.Count) gruptan çıkarıldı: $($cleanup.Removed -join ', ')" }
                }
                'PstExport' {
                    $result.Step = 'PST dışa aktarma'
                    if ($disableFailed) { throw 'Hesap devre dışı bırakılamadığı için PST dışa aktarma başlatılmadı.' }
                    Set-WorkerProgress -Percent $percent -Status "${prefix}PST dışa aktarma isteği oluşturuluyor..."
                    if ([string]::IsNullOrWhiteSpace($ExchangeIdentity)) { throw 'Posta kutusu kimliği belirlenemedi.' }
                    $export = Start-MailboxPstExport -Identity $ExchangeIdentity -FilePath ([string]$DisableCleanup.Pst.FilePath) -RemoveMailbox ([bool]$DisableCleanup.Pst.RemoveMailbox) -Confirm:$false
                    $result.Data = $export
                    if ($export) { $stepMessage = "İstek oluşturuldu: $($export.FilePath)$(if ($export.Archive) { ' (+ arşiv)' })$(if ($export.RemoveMailbox) { '; tamamlanınca posta kutusu silinecek' })" }
                }
                'Addresses' {
                    $result.Step = 'E-posta adresleri'
                    Set-WorkerProgress -Percent $percent -Status "${prefix}E-posta adresleri güncelleniyor..."
                    if ($AddressSource -ne 'AD' -and $Sync.ExchangeMode -eq 'None') { throw 'Exchange bağlantısı yok.' }
                    $identity = if ($AddressSource -eq 'AD') { $ObjectGuid } else { $ExchangeIdentity }
                    if ([string]::IsNullOrWhiteSpace($identity)) { throw 'Exchange kimliği belirlenemedi.' }
                    Set-UserEmailAddress -Source $AddressSource -Identity $identity -SmtpAddresses $SmtpAddresses `
                        -OriginalAddresses $OriginalAddresses -PrimaryChanged $PrimaryChanged -UpdateMailAttribute $UpdateMailAttribute -Confirm:$false
                }
                'Cas' {
                    $result.Step = 'Posta kutusu özellikleri (CAS)'
                    Set-WorkerProgress -Percent $percent -Status "${prefix}Posta kutusu özellikleri güncelleniyor..."
                    if ($Sync.ExchangeMode -eq 'None') { throw 'Exchange bağlantısı yok.' }
                    if ([string]::IsNullOrWhiteSpace($ExchangeIdentity)) { throw 'Posta kutusu kimliği belirlenemedi.' }
                    Set-UserMailboxFeature -Identity $ExchangeIdentity -Features $CasChanges -Confirm:$false
                }
                'Policies' {
                    $result.Step = 'Posta kutusu politikaları'
                    Set-WorkerProgress -Percent $percent -Status "${prefix}Politikalar güncelleniyor..."
                    if ($Sync.ExchangeMode -eq 'None') { throw 'Exchange bağlantısı yok.' }
                    if ([string]::IsNullOrWhiteSpace($ExchangeIdentity)) { throw 'Posta kutusu kimliği belirlenemedi.' }
                    Set-UserMailboxPolicy -Identity $ExchangeIdentity -Policies $PolicyChanges -Confirm:$false
                }
            }
            $result.Success = $true
            $result.Message = if ($WhatIfPreference) { 'Simüle edildi (değişiklik yapılmadı)' } elseif ($stepMessage) { $stepMessage } else { 'Başarılı' }
        }
        catch {
            $result.Success = $false
            $result.Message = $_.Exception.Message
            if ($_.Exception.Data -and $_.Exception.Data.Contains('Result')) { $result.Data = $_.Exception.Data['Result'] }
            Write-WorkerLog -Message ("{0} başarısız: {1}" -f $result.Step, $_.Exception.Message) -Level Error
            if ($step -eq 'AccountFlags' -and $AccountFlags.ContainsKey('Enabled')) { $disableFailed = $true }
        }
        [pscustomobject]$result
    }
    Set-WorkerProgress -Percent 100 -Status "${prefix}Güncelleme tamamlandı."
}
