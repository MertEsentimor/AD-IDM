function global:New-DirectoryUser {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Attributes,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][System.Security.SecureString]$AccountPassword,
        [Parameter()][bool]$ChangePasswordAtLogon = $true,
        [Parameter()][bool]$Enabled = $true,
        [Parameter()][bool]$CreateMailbox = $false,
        [Parameter()][AllowEmptyString()][string]$MailboxDatabase = '',
        [Parameter()][hashtable]$Sms,
        [Parameter()][hashtable]$SmsSecrets = @{},
        [Parameter()][hashtable]$SmsValues = @{},
        [Parameter()][hashtable]$WelcomeMail
    )
    if (-not $Sms -and -not $AccountPassword) { throw 'Parola veya SMS ayarı verilmelidir.' }
    if ($WelcomeMail) {
        foreach ($file in @($WelcomeMail.Attachments | Where-Object { $_ })) { if (-not (Test-Path -LiteralPath $file)) { throw "Bilgilendirme e-postasının eki bulunamadı: $file; kullanıcı oluşturulmadı." } }
        if (@($WelcomeMail.To | Where-Object { $_ }).Count -eq 0) { throw 'Bilgilendirme e-postası için alıcı yok; kullanıcı oluşturulmadı.' }
    }
    $allowed = @('Name', 'GivenName', 'Surname', 'DisplayName', 'SamAccountName', 'UserPrincipalName', 'EmailAddress',
        'Office', 'Company', 'Department', 'Title', 'MobilePhone', 'OfficePhone', 'Description')
    $server = Get-PdcEmulator
    $params = @{ Path = $Path; AccountPassword = $AccountPassword; ChangePasswordAtLogon = $ChangePasswordAtLogon; Enabled = $Enabled; Server = $server; PassThru = $true; ErrorAction = 'Stop' }
    foreach ($key in $Attributes.Keys) {
        $value = ([string]$Attributes[$key]).Trim()
        if ($allowed -contains $key -and $value) { $params[$key] = $value }
    }
    $sam = [string]$params.SamAccountName
    $upn = [string]$params.UserPrincipalName
    $phone = $null
    $plain = $null
    $welcome = $null
    if ($Sms) {
        Set-WorkerProgress -Percent 10 -Status 'SMS ayarları ve telefon numarası doğrulanıyor...'
        Test-SmsConfiguration -Config $Sms -ForTest
        $welcome = if ($Sms.WelcomeMessageTemplate) { [string]$Sms.WelcomeMessageTemplate } else { "Hoş geldiniz, {{DisplayName}}!`n`nKullanıcı bilgileriniz`nKullanıcı adı: {{SamAccountName}}`nOturum adı: {{UserPrincipalName}}`nGeçici parola: {{Password}}`n`nİlk oturum açılışınızda parolanızı değiştirmeniz istenecektir." }
        if ($welcome -notmatch '\{\{\s*Password\s*\}\}') { throw 'SMS ayarı: WelcomeMessageTemplate {{Password}} içermeli.' }
        $rawPhone = ([string]$params.MobilePhone).Trim()
        if (-not $rawPhone) { throw 'Parola SMS ile gönderilecek ancak cep telefonu (MobilePhone) boş; kullanıcı oluşturulmadı.' }
        $phone = Format-SmsPhone -Number $rawPhone -CountryCode $(if ($null -ne $Sms.CountryCode) { [string]$Sms.CountryCode } else { '90' }) `
            -Format $(if ($Sms.PhoneFormat) { [string]$Sms.PhoneFormat } else { 'International' }) -NationalLength $(if ($null -ne $Sms.NationalLength) { [int]$Sms.NationalLength } else { 10 })
        $probe = $SmsValues.Clone(); $probe.Password = 'x'
        [void](Expand-SmsTemplate -Template $welcome -Values $probe -Encoding Text)
        foreach ($template in @([string]$Sms.Url, [string]$Sms.Body) + @(if ($Sms.Headers) { $Sms.Headers.Values })) {
            [void](Expand-SmsTemplate -Template ([string]$template) -Values @{ PhoneNumber = $phone; Message = 'x'; MessageId = 'x'; Time = 'x' } -Secrets $SmsSecrets -Encoding Text)
        }
        Write-WorkerLog -Message "SMS ayarı doğrulandı; hoş geldiniz mesajı ve parola $(Get-MaskedPhone -Number $phone) numarasına gönderilecek ($([string]$Sms.Provider))." -Level Info
    }
    Set-WorkerProgress -Percent 20 -Status 'Çakışma kontrolü yapılıyor (SamAccountName / UPN)...'
    $filter = '(|(sAMAccountName={0}){1})' -f (ConvertTo-LdapFilterValue -Value $sam), $(if ($upn) { '(userPrincipalName={0})' -f (ConvertTo-LdapFilterValue -Value $upn) } else { '' })
    $conflict = @(Get-ADUser -LDAPFilter $filter -Server $server -ErrorAction Stop)
    if ($conflict.Count -gt 0) { throw "Bu SamAccountName veya UPN zaten kullanılıyor: $(($conflict | ForEach-Object { $_.DistinguishedName }) -join '; ')" }
    $summary = "New-ADUser -Name '$($params.Name)' -SamAccountName '$sam' -UserPrincipalName '$upn' -Path '$Path' -Enabled $Enabled -ChangePasswordAtLogon $ChangePasswordAtLogon"
    if ($CreateMailbox) { $summary += "  +  Enable-Mailbox -Database '$(if ($MailboxDatabase) { $MailboxDatabase } else { 'otomatik' })'" }
    if ($Sms) { $summary += "  +  parola üretilip $(Get-MaskedPhone -Number $phone) numarasına hoş geldiniz SMS'iyle gönderilecek" }
    if ($WelcomeMail) { $summary += "  +  bilgilendirme e-postası: $(@($WelcomeMail.To) -join ', ')$(if (@($WelcomeMail.Cc).Count) { " (CC: $(@($WelcomeMail.Cc) -join ', '))" }), $(@($WelcomeMail.Attachments).Count) ek" }
    if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] $summary" -Level Warning; return }
    if (-not $PSCmdlet.ShouldProcess($sam, $summary)) { return }
    if ($Sms) {
        $plain = New-SmsPassword -Length $(if ($Sms.PasswordLength) { [int]$Sms.PasswordLength } else { 14 }) -Symbols $(if ($null -ne $Sms.PasswordSymbols) { [string]$Sms.PasswordSymbols } else { '.' })
        $params.AccountPassword = ConvertTo-SecureString -String $plain -AsPlainText -Force
    }
    Set-WorkerProgress -Percent 50 -Status "Kullanıcı oluşturuluyor: $sam"
    try {
        $created = New-ADUser @params
        Write-WorkerLog -Message "Kullanıcı oluşturuldu: $($created.DistinguishedName) (PDC: $server)" -Level Success
        $warning = $null
        if ($CreateMailbox) {
            Set-WorkerProgress -Percent 75 -Status "Posta kutusu oluşturuluyor: $sam"
            try {
                $mailbox = Enable-UserMailbox -Identity ([string]$created.DistinguishedName) -Database $MailboxDatabase -Alias $sam -Confirm:$false
                $requested = [string]$params.EmailAddress
                if ($mailbox -and $requested -and -not [string]::Equals($requested, [string]$mailbox.PrimarySmtpAddress, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Write-WorkerLog -Message "Birincil adres e-posta adresi politikasından atandı: $($mailbox.PrimarySmtpAddress) (formdaki adres: $requested). Gerekirse E-posta Adresleri sekmesinden değiştirin." -Level Warning
                }
            }
            catch {
                $warning = "Kullanıcı oluşturuldu ancak posta kutusu açılamadı: $($_.Exception.Message)`n`nKullanıcı ekranındaki 'Posta Kutusu Oluştur' düğmesiyle tekrar deneyebilirsiniz."
                Write-WorkerLog -Message $warning -Level Warning
            }
        }
        $smsResult = $null
        if ($Sms) {
            Set-WorkerProgress -Percent 90 -Status 'Hoş geldiniz SMS''i gönderiliyor...'
            $masked = Get-MaskedPhone -Number $phone
            try {
                $values = $SmsValues.Clone()
                $values.Password = $plain
                $text = Expand-SmsTemplate -Template $welcome -Values $values -Encoding Text
                $send = Send-SmsMessage -Config $Sms -Secrets $SmsSecrets -PhoneNumber $phone -Message $text -Scrub @($plain)
                $smsResult = [pscustomobject]@{ Success = [bool]$send.Success; To = $masked; Provider = [string]$Sms.Provider; Status = $send.StatusCode; Detail = [string]$send.Detail }
            }
            catch {
                $detail = [string]$_.Exception.Message
                if ($plain) { $detail = $detail.Replace($plain, '***') }
                $smsResult = [pscustomobject]@{ Success = $false; To = $masked; Provider = [string]$Sms.Provider; Status = $null; Detail = $detail }
            }
            finally { $plain = $null; $text = $null; $values = $null }
            if ($smsResult.Success) { Write-WorkerLog -Message "Hoş geldiniz SMS'i ve parola gönderildi: $masked ($($smsResult.Provider), $($smsResult.Detail))." -Level Success }
            else {
                $smsWarning = "Kullanıcı oluşturuldu ancak parola SMS'i gönderilemedi ($masked): $($smsResult.Detail)`n`nSorunu giderip kullanıcı ekranındaki 'Parola Sıfırla' ile parolayı SMS olarak yeniden gönderin."
                Write-WorkerLog -Message $smsWarning -Level Error
                $warning = if ($warning) { "$warning`n`n$smsWarning" } else { $smsWarning }
            }
        }
        $mailResult = $null
        if ($WelcomeMail) {
            Set-WorkerProgress -Percent 95 -Status 'Bilgilendirme e-postası gönderiliyor...'
            try {
                $mailResult = Send-WelcomeMail -Mail $WelcomeMail -Confirm:$false
                Write-WorkerLog -Message "Bilgilendirme e-postası gönderildi: $($mailResult.To)$(if ($mailResult.Cc) { " (CC: $($mailResult.Cc))" }), $($mailResult.Detail)." -Level Success
            }
            catch {
                $detail = Get-ExceptionDetail -Exception $_.Exception
                $detail = "$detail $(Get-ConnectivityHint -HostName ([string]$WelcomeMail.SmtpServer) -Port ([int]$WelcomeMail.Port) -Purpose Smtp)"
                $mailResult = [pscustomobject]@{ Success = $false; To = (@($WelcomeMail.To) -join ', '); Cc = (@($WelcomeMail.Cc) -join ', '); Subject = [string]$WelcomeMail.Subject; Detail = $detail }
                $mailWarning = "Kullanıcı oluşturuldu ancak bilgilendirme e-postası gönderilemedi ($($mailResult.To)): $($mailResult.Detail)"
                Write-WorkerLog -Message $mailWarning -Level Error
                $warning = if ($warning) { "$warning`n`n$mailWarning" } else { $mailWarning }
            }
        }
        return [pscustomobject]@{ ObjectGuid = $created.ObjectGUID.ToString(); DistinguishedName = [string]$created.DistinguishedName; Warning = $warning; Sms = $smsResult; Mail = $mailResult }
    }
    catch {
        $plain = $null
        $message = $_.Exception.Message
        $existing = Get-ADUser -LDAPFilter ('(sAMAccountName={0})' -f (ConvertTo-LdapFilterValue -Value $sam)) -Server $server -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $existing) { throw }
        Write-WorkerLog -Message "Kullanıcı oluşturuldu ancak bir adım başarısız oldu: $message" -Level Warning
        return [pscustomobject]@{ ObjectGuid = $existing.ObjectGUID.ToString(); DistinguishedName = [string]$existing.DistinguishedName; Warning = "Kullanıcı oluşturuldu ancak tamamlanamadı (muhtemelen devre dışı): $message`n`nKullanıcıyı açıp parolayı sıfırlayın ve hesabı etkinleştirin." }
    }
}
function global:Get-NewUserContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $context = @{ OuList = @(Get-OrganizationalUnitList); Databases = @() }
    if ($Sync.ExchangeMode -eq 'OnPremises') {
        try { $context.Databases = @((Get-ExchangeCatalog).Databases) }
        catch { Write-WorkerLog -Message "Posta kutusu veritabanları okunamadı: $($_.Exception.Message)" -Level Warning }
    }
    return $context
}
