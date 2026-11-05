function Invoke-NewUserTest {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()][AllowEmptyString()][string]$OuPath,
        [Parameter()][AllowEmptyString()][string]$Mobile,
        [Parameter()][AllowEmptyString()][string]$MailTo,
        [Parameter()][switch]$IncludeCc,
        [Parameter()][switch]$KeepUser
    )
    $full = [bool]$OuPath
    $steps = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $runLog = Join-Path -Path $script:AppRoot -ChildPath ('Logs\NewUserTest_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
    $record = {
        param([string]$Step, [ValidateSet('OK', 'HATA', 'UYARI', 'ATLANDI')][string]$Result, [string]$Detail)
        $steps.Add([pscustomobject]@{ Adim = $Step; Sonuc = $Result; Ayrinti = $Detail })
        $color = switch ($Result) { 'OK' { 'Green' } 'HATA' { 'Red' } 'UYARI' { 'Yellow' } default { 'Gray' } }
        $line = '[{0,-7}] {1}: {2}' -f $Result, $Step, $Detail
        Write-Host $line -ForegroundColor $color
        try {
            $folder = Split-Path -Path $runLog -Parent
            if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force) }
            Add-Content -LiteralPath $runLog -Value ('{0} {1}' -f (Get-Date).ToString('HH:mm:ss'), $line) -Encoding UTF8
        }
        catch { Write-Verbose "Test günlüğü yazılamadı: $($_.Exception.Message)" }
    }
    $drain = {
        $entry = $null
        while ($script:Sync.LogQueue.TryDequeue([ref]$entry)) {
            if ($entry.Kind -eq 'Log') { Write-Host ("          {0}" -f $entry.Message) -ForegroundColor $(switch ([string]$entry.Level) { 'Error' { 'Red' } 'Warning' { 'Yellow' } 'Success' { 'Green' } default { 'DarkGray' } }) }
        }
    }
    $fail = { param([string]$Step, [string]$Detail) & $record $Step 'HATA' $Detail; throw [System.OperationCanceledException]::new($Detail) }
    Write-Host ''
    Write-Host ("Kullanıcı ekleme testi - {0}" -f $(if ($full) { 'UÇTAN UCA (gerçek test kullanıcısı oluşturulur)' } else { 'ÖN KONTROL (AD''ye yazılmaz, SMS gönderilmez)' })) -ForegroundColor Cyan
    Write-Host ''
    $created = $null
    $server = $null
    try {
        if ($full -and -not $Mobile) { & $fail 'Parametreler' '-TestOu ile -TestMobile (SMS''in gideceği sizin numaranız) zorunlu.' }
        if ($full -and -not $MailTo) { & $fail 'Parametreler' '-TestOu ile -TestMailTo (e-postanın gideceği sizin adresiniz) zorunlu.' }
        if ($MailTo -and $MailTo -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { & $fail 'Parametreler' "Geçersiz e-posta: $MailTo" }
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { & $fail 'ActiveDirectory modülü' 'Bulunamadı (RSAT AD araçları gerekli).' }
        Import-Module -Name ActiveDirectory -ErrorAction Stop -Verbose:$false
        & $record 'ActiveDirectory modülü' 'OK' 'Yüklendi.'
        $global:Sync = $script:Sync
        foreach ($relativePath in $script:WorkerScripts) { . ([scriptblock]::Create((Read-AppFile -RelativePath $relativePath))) }
        try {
            $server = Get-PdcEmulator
            $domain = Get-ADDomain -Server $server -ErrorAction Stop
            & $record 'AD bağlantısı' 'OK' "DC: $server, etki alanı: $($domain.DNSRoot)"
        }
        catch { & $fail 'AD bağlantısı' $_.Exception.Message }
        & $drain
        if ($full) {
            try {
                $ou = Get-ADObject -Identity $OuPath -Server $server -ErrorAction Stop
                & $record 'Test OU' 'OK' ([string]$ou.DistinguishedName)
            }
            catch { & $fail 'Test OU' "Bulunamadı: $OuPath ($($_.Exception.Message))" }
        }
        else { & $record 'Test OU' 'ATLANDI' 'Ön kontrol modunda kullanıcı oluşturulmaz (-TestOu verin).' }
        $sms = Get-SmsConfiguration
        $smsSecrets = $null
        if (-not $sms.Available) {
            if ($full) { & $fail 'SMS ayarı' $sms.Reason } else { & $record 'SMS ayarı' 'UYARI' $sms.Reason }
        }
        else {
            try {
                Test-SmsConfiguration -Config $sms.Config -ForTest
                $smsSecrets = Resolve-SmsSecret -Config $sms.Config
                $welcome = [string]$sms.Config.WelcomeMessageTemplate
                if ($welcome -and $welcome -notmatch '\{\{\s*Password\s*\}\}') { throw 'WelcomeMessageTemplate {{Password}} içermeli.' }
                $smsHost = ([uri][string]$sms.Config.Url).Host
                & $record 'SMS ayarı' 'OK' "$($sms.Config.Provider) ($smsHost), gizli bilgiler okundu."
                $smsUri = [uri][string]$sms.Config.Url
                if ($sms.Config.Proxy) { & $record 'SMS servisine erişim' 'ATLANDI' "Proxy kullanılıyor ($($sms.Config.Proxy)); doğrudan port testi yapılmadı." }
                elseif (Test-TcpPort -ComputerName $smsUri.Host -Port $smsUri.Port -TimeoutMs 3000) { & $record 'SMS servisine erişim' 'OK' "$($smsUri.Host):$($smsUri.Port) açık." }
                else { & $record 'SMS servisine erişim' $(if ($full) { 'HATA' } else { 'UYARI' }) (Get-ConnectivityHint -HostName $smsUri.Host -Port $smsUri.Port -Purpose Http) }
            }
            catch { if ($full) { & $fail 'SMS ayarı' $_.Exception.Message } else { & $record 'SMS ayarı' 'UYARI' $_.Exception.Message } }
        }
        $outsource = Get-OutsourceMailConfiguration
        $mailArgument = $null
        if (-not $outsource.Available) {
            if ($MailTo) { & $fail 'Outsource e-posta ayarı' $outsource.Reason } else { & $record 'Outsource e-posta ayarı' 'UYARI' $outsource.Reason }
        }
        else {
            $config = $outsource.Config
            $section = $outsource.Section
            $cc = @($section.Cc | Where-Object { $_ })
            & $record 'Outsource e-posta ayarı' 'OK' ("Metin: {0}, ek: {1}, CC: {2}" -f (Split-Path -Path $outsource.BodyFile -Leaf), $(if ($outsource.Attachments.Count) { (@($outsource.Attachments | ForEach-Object { '{0} ({1:N0} KB)' -f (Split-Path -Path $_ -Leaf), ((Get-Item -LiteralPath $_).Length / 1KB) }) -join ', ') } else { 'yok' }), $(if ($cc.Count) { $cc -join ', ' } else { 'tanımlı değil' }))
            if ($cc.Count -eq 0) { & $record 'CC adresleri' 'UYARI' 'mail-config.json -> OutsourceMail.Cc boş.' }
            if (Test-TcpPort -ComputerName ([string]$config.SmtpServer) -Port $(if ($config.Port) { [int]$config.Port } else { 25 }) -TimeoutMs 3000) { & $record 'SMTP erişimi' 'OK' "$($config.SmtpServer):$(if ($config.Port) { $config.Port } else { 25 }) açık." }
            else { & $fail 'SMTP erişimi' "$($config.SmtpServer):$(if ($config.Port) { $config.Port } else { 25 }) portuna bağlanılamadı." }
        }
        $stamp = (Get-Date).ToString('yyMMddHHmm')
        $sam = "zztest$stamp"
        $upnSuffix = if ($domain) { [string]$domain.DNSRoot } else { [string]$env:USERDNSDOMAIN }
        $values = @{
            SamAccountName = $sam; UserPrincipalName = "$sam@$upnSuffix"; DisplayName = "ZZ Test Kullanici $stamp"; GivenName = 'ZZ Test'; Surname = "Kullanici $stamp"
            EmailAddress = ''; Company = ''; Department = ''; Title = ''; Office = ''
            Domain = if ($domain) { [string]$domain.NetBIOSName } else { [string]$env:USERDOMAIN }; DomainDns = $upnSuffix
        }
        if ($outsource.Available) {
            try {
                $html = ConvertTo-WelcomeMailHtml -Path $outsource.BodyFile -Values $values
                $preview = Join-Path -Path $script:AppRoot -ChildPath ('Logs\OutsourceMail_Onizleme_{0}.html' -f $stamp)
                $folder = Split-Path -Path $preview -Parent
                if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force) }
                Set-Content -LiteralPath $preview -Value $html -Encoding UTF8 -ErrorAction Stop
                & $record 'E-posta metni' 'OK' "Önizleme kaydedildi: $preview"
                $credentialFile = if ($config.CredentialFile) { [string]$config.CredentialFile } else { 'Secrets\smtp-credential.xml' }
                if (-not [System.IO.Path]::IsPathRooted($credentialFile)) { $credentialFile = Join-Path -Path $script:AppRoot -ChildPath $credentialFile }
                if ($MailTo) {
                    $mailArgument = @{
                        SmtpServer = [string]$config.SmtpServer; Port = $(if ($config.Port) { [int]$config.Port } else { 25 }); UseSsl = [bool]$config.UseSsl
                        Authentication = [string]$config.Authentication; CredentialFile = $credentialFile
                        From = $(if ($section.From) { [string]$section.From } else { [string]$config.From })
                        FromName = $(if ($section.FromName) { [string]$section.FromName } elseif ($config.FromName) { [string]$config.FromName } else { '' })
                        To = [string[]]@($MailTo); Cc = [string[]]$(if ($IncludeCc) { $cc } else { @() })
                        Subject = '[TEST] ' + (Expand-MailTemplate -Template $(if ($section.Subject) { [string]$section.Subject } else { 'Kullanıcınız hazır: {{SamAccountName}}' }) -Values $values)
                        Html = $html; Attachments = [string[]]@($outsource.Attachments)
                    }
                }
            }
            catch { & $fail 'E-posta metni' $_.Exception.Message }
        }
        if (-not $full) {
            if ($mailArgument) {
                try {
                    $sent = Send-WelcomeMail -Mail $mailArgument -Confirm:$false
                    & $record 'Test e-postası' 'OK' "Gönderildi: $($sent.To)$(if ($sent.Cc) { " (CC: $($sent.Cc))" }), $($sent.Detail)"
                }
                catch { & $fail 'Test e-postası' "$(Get-ExceptionDetail -Exception $_.Exception) $(Get-ConnectivityHint -HostName ([string]$mailArgument.SmtpServer) -Port ([int]$mailArgument.Port) -Purpose Smtp)" }
            }
            else { & $record 'Test e-postası' 'ATLANDI' 'Göndermek için -TestMailTo verin.' }
        }
        else {
            $attributes = @{ Name = $values.DisplayName; DisplayName = $values.DisplayName; GivenName = $values.GivenName; Surname = $values.Surname; SamAccountName = $sam; UserPrincipalName = $values.UserPrincipalName; MobilePhone = $Mobile; Description = "AD-IDM kullanıcı ekleme testi ($env:USERNAME, $((Get-Date).ToString('dd.MM.yyyy HH:mm')))" }
            $smsValues = $values.Clone()
            Write-Host ''
            Write-Host "Test kullanıcısı oluşturuluyor: $sam -> $OuPath" -ForegroundColor Cyan
            try {
                $created = New-DirectoryUser -Attributes $attributes -Path $OuPath -ChangePasswordAtLogon $true -Enabled $true -Sms $sms.Config -SmsSecrets $smsSecrets -SmsValues $smsValues -WelcomeMail $mailArgument -Confirm:$false
                & $drain
            }
            catch { & $drain; & $fail 'Kullanıcı oluşturma' $_.Exception.Message }
            if (-not $created) { & $fail 'Kullanıcı oluşturma' 'Sonuç dönmedi.' }
            [void](Write-AuditEvent -Action 'user.create.test' -Result 'success' -Fields ([ordered]@{ target_user = $sam; target_guid = [string]$created.ObjectGuid; target_dn = [string]$created.DistinguishedName }))
            & $record 'Kullanıcı oluşturma' 'OK' ([string]$created.DistinguishedName)
            if ($created.Sms) { & $record 'Hoş geldiniz SMS''i' $(if ($created.Sms.Success) { 'OK' } else { 'HATA' }) "$($created.Sms.To): $($created.Sms.Detail)" }
            if ($created.Mail) { & $record 'Bilgilendirme e-postası' $(if ($created.Mail.Success) { 'OK' } else { 'HATA' }) "$($created.Mail.To)$(if ($created.Mail.Cc) { " (CC: $($created.Mail.Cc))" }): $($created.Mail.Detail)" }
            try {
                $check = Get-ADUser -Identity $created.ObjectGuid -Server $server -Properties mobile, pwdLastSet, DisplayName, UserPrincipalName -ErrorAction Stop
                $problems = @()
                if (-not $check.Enabled) { $problems += 'hesap etkin değil' }
                if ([string]$check.mobile -ne $Mobile) { $problems += "mobile alanı '$($check.mobile)'" }
                if ([string]$check.UserPrincipalName -ne $values.UserPrincipalName) { $problems += "UPN '$($check.UserPrincipalName)'" }
                if ([long]$check.pwdLastSet -ne 0) { $problems += 'ilk oturumda parola değiştirme işaretli değil' }
                if ($problems.Count) { & $record 'AD doğrulama' 'HATA' ($problems -join '; ') }
                else { & $record 'AD doğrulama' 'OK' 'Etkin, UPN ve cep telefonu doğru, ilk oturumda parola değiştirme işaretli.' }
            }
            catch { & $record 'AD doğrulama' 'HATA' $_.Exception.Message }
        }
    }
    catch [System.OperationCanceledException] { Write-Verbose 'Test bir adımda durdu.' }
    catch { & $record 'Beklenmeyen hata' 'HATA' $_.Exception.Message }
    finally {
        if ($created -and $created.ObjectGuid) {
            if ($KeepUser) { & $record 'Temizlik' 'ATLANDI' "Test kullanıcısı bırakıldı (-KeepTestUser): $($created.DistinguishedName). İşiniz bitince silin." }
            else {
                try {
                    Remove-ADUser -Identity ([string]$created.ObjectGuid) -Server $server -Confirm:$false -ErrorAction Stop
                    [void](Write-AuditEvent -Action 'user.delete.test' -Result 'success' -Fields ([ordered]@{ target_guid = [string]$created.ObjectGuid; target_dn = [string]$created.DistinguishedName }))
                    & $record 'Temizlik' 'OK' "Test kullanıcısı silindi: $($created.DistinguishedName)"
                }
                catch { & $record 'Temizlik' 'HATA' "Test kullanıcısı silinemedi, elle silin: $($created.DistinguishedName) ($($_.Exception.Message))" }
            }
        }
        & $drain
    }
    $errors = @($steps | Where-Object { $_.Sonuc -eq 'HATA' }).Count
    $warnings = @($steps | Where-Object { $_.Sonuc -eq 'UYARI' }).Count
    Write-Host ''
    Write-Host ("Sonuç: {0} adım, {1} hata, {2} uyarı. Günlük: {3}" -f $steps.Count, $errors, $warnings, $runLog) -ForegroundColor $(if ($errors) { 'Red' } elseif ($warnings) { 'Yellow' } else { 'Green' })
    $steps | Format-Table -AutoSize -Wrap | Out-String | Write-Host
    return $(if ($errors) { 1 } else { 0 })
}
