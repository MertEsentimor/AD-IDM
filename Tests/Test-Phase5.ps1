# Çalıştırma: pwsh -NoProfile -File Tests/Test-Phase5.ps1  (veya Windows'ta powershell.exe). AD, SMS ve SMTP komutları sahtedir; dış servise bağlanmaz.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}

$global:Sync = [hashtable]::Synchronized(@{
        LogQueue = New-Object -TypeName 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
        ExchangeMode = 'OnPremises'; Pdc = 'dc01.test.local'; DefaultDc = 'dc01.test.local'
    })
$script:Ui = @{}
foreach ($relativePath in 'Core/WorkerBootstrap.ps1', 'Core/Notify.ps1', 'Modules/AD/Search.ps1', 'Modules/Workflows/Provision.ps1', 'UI/Handlers/NewUser.ps1', 'UI/Shell.ps1') {
    . (Join-Path -Path $projectRoot -ChildPath $relativePath)
}
$ErrorActionPreference = 'Stop'

$script:Calls = New-Object -TypeName System.Collections.ArrayList
$script:Behavior = @{}
function global:Get-ADUser { param($LDAPFilter, $Server, $ErrorAction) if ($script:Behavior.Conflict) { [pscustomobject]@{ DistinguishedName = 'CN=Var,DC=test' } } elseif ($script:Behavior.Existing) { [pscustomobject]@{ ObjectGUID = [guid]::Empty; DistinguishedName = 'CN=Yeni,DC=test' } } }
function global:New-ADUser {
    [CmdletBinding()]
    param($Path, $AccountPassword, $ChangePasswordAtLogon, $Enabled, $Server, [switch]$PassThru, $Name, $SamAccountName, $UserPrincipalName, $MobilePhone, $EmailAddress, $DisplayName)
    [void]$script:Calls.Add('New-ADUser')
    $script:Behavior.ChangeAtLogon = $ChangePasswordAtLogon
    return [pscustomobject]@{ ObjectGUID = [guid]::NewGuid(); DistinguishedName = "CN=$Name,$Path" }
}
function global:Remove-ADUser { [void]$script:Calls.Add('Remove-ADUser') }
function global:Enable-UserMailbox { [CmdletBinding()] param($Identity, $Database, $Alias, $Confirm) [void]$script:Calls.Add('Enable-UserMailbox'); if ($script:Behavior.FailMailbox) { throw 'veritabanı kapalı' }; [pscustomobject]@{ PrimarySmtpAddress = 'yeni@test.local' } }
function global:Send-SmsMessage { param($Config, $Secrets, $PhoneNumber, $Message, $Scrub) [void]$script:Calls.Add('Send-SmsMessage'); $script:Behavior.SmsText = $Message; if ($script:Behavior.ThrowSms) { throw "bağlantı koptu $($Scrub[0])" }; [pscustomobject]@{ Success = -not $script:Behavior.FailSms; StatusCode = 200; Detail = 'HTTP 500'; Attempts = 1 } }
function global:Send-WelcomeMail { [CmdletBinding()] param($Mail, $Confirm) [void]$script:Calls.Add('Send-WelcomeMail'); if ($script:Behavior.FailMail) { throw 'smtp kapalı' }; [pscustomobject]@{ Success = $true; To = 'firma@test.local'; Cc = ''; Subject = 'Konu'; Detail = '0 ek' } }
function global:Get-ConnectivityHint { param($HostName, $Port, $Purpose) 'ipucu' }

$smsConfig = @{ Provider = 'Test'; Url = 'https://sms.test/send'; Method = 'POST'; Body = '{{PhoneNumber}} {{Message}}'; WelcomeMessageTemplate = 'Hoş geldiniz {{DisplayName}} {{SamAccountName}} {{Password}}'; PhoneFormat = 'International' }
$attributes = @{ Name = 'Yeni Kisi'; DisplayName = 'Yeni Kisi'; SamAccountName = 'ykisi'; UserPrincipalName = 'ykisi@test.local'; MobilePhone = '05321234567'; EmailAddress = 'ykisi@test.local' }
$values = @{ DisplayName = 'Yeni Kisi'; SamAccountName = 'ykisi' }
$mail = @{ SmtpServer = 'smtp.test'; Port = 25; To = @('firma@test.local'); Cc = @(); Subject = 'Konu'; Html = '<p>x</p>'; From = 'a@test.local' }
function Invoke-Provision {
    param([hashtable]$Extra = @{})
    $script:Calls.Clear()
    $arguments = @{ Attributes = $attributes.Clone(); Path = 'OU=IT,DC=test'; Sms = $smsConfig; SmsValues = $values; CreateMailbox = $true; WelcomeMail = $mail; Confirm = $false }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    return New-DirectoryUser @arguments
}
function Get-QueuedText {
    $lines = New-Object -TypeName System.Collections.ArrayList
    $entry = $null
    while ($global:Sync.LogQueue.TryDequeue([ref]$entry)) { [void]$lines.Add([string]$entry.Message) }
    return $lines -join "`n"
}

# Başarılı akış
$result = Invoke-Provision
Assert-True (($script:Calls -join ',') -ceq 'New-ADUser,Enable-UserMailbox,Send-SmsMessage,Send-WelcomeMail') "Sıra: AD, posta kutusu, SMS, e-posta ($($script:Calls -join ','))"
Assert-True ($result.Sms.Success -and $result.Mail.Success -and -not $result.Warning) 'Başarılı akışta uyarı yok'
Assert-True ($script:Behavior.ChangeAtLogon -eq $true) 'İlk oturumda parola değişimi zorunlu'
$sentPassword = ($script:Behavior.SmsText -split ' ')[-1]
Assert-True ($sentPassword.Length -ge 14 -and $sentPassword -cmatch '[A-Z]' -and $sentPassword -cmatch '[a-z]' -and $sentPassword -match '\d') 'Üretilen parola karmaşık ve SMS metninde'
$serialized = $result | ConvertTo-Json -Depth 5 -Compress
$logText = Get-QueuedText
Assert-True (-not $serialized.Contains($sentPassword) -and -not $logText.Contains($sentPassword)) 'Parola sonuçta ve günlükte yok'
Assert-True (-not $logText.Contains('905321234567')) 'Telefon günlükte maskeli'

# Hata akışları: kullanıcı silinmez
$script:Behavior.FailSms = $true
$smsFailed = Invoke-Provision
$script:Behavior.FailSms = $false
Assert-True ($script:Calls -notcontains 'Remove-ADUser' -and $smsFailed.ObjectGuid) 'SMS başarısızsa kullanıcı silinmez'
Assert-True ($smsFailed.Warning -match 'SMS' -and -not $smsFailed.Sms.Success) 'SMS hatası uyarıyla biter'
Assert-True ($script:Calls -contains 'Send-WelcomeMail') 'SMS hatasından sonra e-posta yine gönderilir'
$script:Behavior.ThrowSms = $true
$smsThrown = Invoke-Provision
$script:Behavior.ThrowSms = $false
Assert-True ($smsThrown.ObjectGuid -and $smsThrown.Sms.Detail -match '\*\*\*' -and -not ($smsThrown.Sms.Detail -cmatch 'koptu [A-Za-z0-9.]{14}')) 'SMS istisnasında parola maskelenir'
$script:Behavior.FailMailbox = $true
$mailboxFailed = Invoke-Provision
$script:Behavior.FailMailbox = $false
Assert-True ($mailboxFailed.Warning -match 'posta kutusu açılamadı' -and $script:Calls -contains 'Send-SmsMessage' -and $script:Calls -notcontains 'Remove-ADUser') 'Posta kutusu hatasında akış sürer'
$script:Behavior.FailMail = $true
$mailFailed = Invoke-Provision
$script:Behavior.FailMail = $false
Assert-True ($mailFailed.Warning -match 'e-postası gönderilemedi' -and -not $mailFailed.Mail.Success -and $script:Calls -notcontains 'Remove-ADUser') 'E-posta hatası uyarıyla biter'

# Ön kontroller: hiçbir şey yazılmaz
$script:Behavior.Conflict = $true
$conflictMessage = $null
try { [void](Invoke-Provision) } catch { $conflictMessage = $_.Exception.Message }
$script:Behavior.Conflict = $false
Assert-True ($conflictMessage -match 'zaten kullanılıyor' -and $script:Calls.Count -eq 0) 'Çakışmada kullanıcı oluşturulmaz'
$noPhone = $attributes.Clone()
$noPhone.MobilePhone = ''
$phoneMessage = $null
try { [void](Invoke-Provision -Extra @{ Attributes = $noPhone }) } catch { $phoneMessage = $_.Exception.Message }
Assert-True ($phoneMessage -match 'cep telefonu' -and $script:Calls.Count -eq 0) 'Telefon yoksa kullanıcı oluşturulmaz'
$noRecipient = $mail.Clone()
$noRecipient.To = @()
$recipientMessage = $null
try { [void](Invoke-Provision -Extra @{ WelcomeMail = $noRecipient }) } catch { $recipientMessage = $_.Exception.Message }
Assert-True ($recipientMessage -match 'alıcı yok' -and $script:Calls.Count -eq 0) 'E-posta alıcısı yoksa kullanıcı oluşturulmaz'
[void](Get-QueuedText)
$simulated = Invoke-Provision -Extra @{ WhatIf = $true }
Assert-True ($script:Calls.Count -eq 0 -and $null -eq $simulated) 'Simülasyon yazmaz, SMS göndermez'
Assert-True ((Get-QueuedText) -match '\[WhatIf\] New-ADUser') 'Simülasyon komutu günlüğe yazar'

# Komuttan form doldurma
$parsed = ConvertFrom-NewAdUserCommand -Text 'New-ADUser -Name "Ali Veli" -SamAccountName aveli -AccountPassword (Read-Host -AsSecureString) -Enabled $true -Bilinmeyen x'
Assert-True ($parsed.Values.Name -eq 'Ali Veli' -and $parsed.Values.SamAccountName -eq 'aveli' -and $parsed.Values.Enabled -eq $true) 'New-ADUser komutu okunur'
Assert-True (-not $parsed.Values.ContainsKey('AccountPassword') -and @($parsed.Notes).Count -eq 1 -and @($parsed.Skipped) -contains 'Bilinmeyen') 'Komuttaki parola alınmaz, bilinmeyen atlanır'
Assert-True ((ConvertFrom-NewAdUserCommand -Text 'Get-ADUser x').Error -match 'bulunamadı') 'New-ADUser olmayan metin reddedilir'

Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
