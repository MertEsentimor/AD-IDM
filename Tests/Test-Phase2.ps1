# Çalıştırma: pwsh -NoProfile -File Tests/Test-Phase2.ps1  (veya Windows'ta powershell.exe). AD gerektirmez, dış servise bağlanmaz.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0
$temporaryFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("adidm-test-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -Path $temporaryFolder -ItemType Directory -Force)

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Name)
    $message = $null
    try { [void](& $Action) } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "$Name ($message)"
}
function Get-FreePort {
    $probe = New-Object -TypeName System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()
    return $port
}
function Start-BackgroundScript {
    param([string]$Script, [hashtable]$Arguments)
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Script)
    foreach ($key in $Arguments.Keys) { [void]$ps.AddParameter($key, $Arguments[$key]) }
    return @{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

$script:AppRoot = $temporaryFolder
$script:Ui = @{}
$script:State = @{ CurrentData = $null }
$script:SmsConfigPath = Join-Path -Path $temporaryFolder -ChildPath 'sms-config.json'
$script:MailConfigPath = Join-Path -Path $temporaryFolder -ChildPath 'mail-config.json'
foreach ($relativePath in 'Core/Audit.ps1', 'Core/Config.ps1', 'Core/Secrets.ps1', 'Core/Notify.ps1', 'Core/Runspace.ps1') {
    . (Join-Path -Path $projectRoot -ChildPath $relativePath)
}

try {
    # ---- Şablonlar
    foreach ($templateName in 'sms-config.template.json', 'mail-config.template.json') {
        $template = Get-Content -LiteralPath (Join-Path -Path $projectRoot -ChildPath "Configs/$templateName") -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($template.Enabled -eq $false) "$templateName varsayılan olarak kapalı"
    }
    $smsTemplate = Get-Content -LiteralPath (Join-Path -Path $projectRoot -ChildPath 'Configs/sms-config.template.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ([string]::IsNullOrEmpty($smsTemplate.Url) -and [string]::IsNullOrEmpty($smsTemplate.Body)) 'SMS şablonunda Url ve Body boş'

    # ---- Telefon biçimi
    Assert-True ((Format-SmsPhone -Number '0532 123 45 67' -Format International) -eq '905321234567') 'Telefon: International'
    Assert-True ((Format-SmsPhone -Number '+90 532 123 45 67' -Format E164) -eq '+905321234567') 'Telefon: E164'
    Assert-True ((Format-SmsPhone -Number '00905321234567' -Format National0) -eq '05321234567') 'Telefon: National0'
    Assert-True ((Format-SmsPhone -Number ' 0532-123 ' -Format Raw) -eq '0532-123') 'Telefon: Raw'
    Assert-Throws { Format-SmsPhone -Number '12345' } 'geçersiz' 'Telefon: kısa numara reddedilir'
    Assert-True ((Get-MaskedPhone -Number '905321234567') -eq '905*******67') 'Telefon maskelenir'

    # ---- Şablon
    $values = @{ PhoneNumber = '905321234567'; Message = 'a&b "c"' }
    Assert-True ((Expand-SmsTemplate -Template 'n={{PhoneNumber}}&m={{Message}}' -Values $values -Encoding Url) -eq 'n=905321234567&m=a%26b%20%22c%22') 'Şablon: URL kodlama'
    Assert-True ((Expand-SmsTemplate -Template '{"m":"{{Message}}"}' -Values $values -Encoding Json) -eq '{"m":"a&b \"c\""}') 'Şablon: JSON kaçış'
    Assert-True ((Expand-SmsTemplate -Template '<m>{{Message}}</m>' -Values $values -Encoding Xml) -match '&amp;') 'Şablon: XML kaçış'
    Assert-True ((Expand-SmsTemplate -Template 'n=%mobNo%' -Values $values) -eq 'n=905321234567') 'Şablon: ADSelfService yer tutucusu'
    Assert-True ((Expand-SmsTemplate -Template 'k={{Secret:ApiKey}}' -Values $values -Secrets @{ ApiKey = 'gizli' }) -eq 'k=gizli') 'Şablon: gizli bilgi'
    Assert-Throws { Expand-SmsTemplate -Template '{{Yok}}' -Values $values } 'bilinmeyen' 'Şablon: bilinmeyen yer tutucu reddedilir'
    Assert-Throws { Expand-SmsTemplate -Template '{{Secret:Yok}}' -Values $values } 'tanımlı değil' 'Şablon: eksik gizli bilgi reddedilir'

    # ---- SMS ayar doğrulama
    $validConfig = @{ Url = 'https://sms.example/send'; Method = 'POST'; Body = 'to={{PhoneNumber}}&m={{Message}}'; MessageTemplate = 'Parola: {{Password}}' }
    Test-SmsConfiguration -Config $validConfig
    Assert-True $true 'SMS ayarı: geçerli ayar kabul edilir'
    Assert-Throws { Test-SmsConfiguration -Config @{ Url = 'ftp://x'; Method = 'POST' } } 'http' 'SMS ayarı: Url şeması'
    Assert-Throws { Test-SmsConfiguration -Config @{ Url = 'https://x'; Method = 'POST'; Body = '{{Message}}' } } 'telefon' 'SMS ayarı: telefon yer tutucusu zorunlu'
    Assert-Throws { Test-SmsConfiguration -Config @{ Url = 'https://x/?p={{Password}}'; Method = 'POST'; Body = '{{PhoneNumber}} {{Message}}'; MessageTemplate = '{{Password}}' } } 'yalnızca GET' 'SMS ayarı: parola POST Url içinde olamaz'

    # ---- Parola
    $passwords = 1..50 | ForEach-Object { New-SmsPassword -Length 14 -Symbols '.' }
    Assert-True (@($passwords | Where-Object { $_.Length -ne 14 }).Count -eq 0) 'Parola uzunluğu'
    Assert-True (@($passwords | Where-Object { $_ -cnotmatch '[A-Z]' -or $_ -cnotmatch '[a-z]' -or $_ -notmatch '\d' -or $_ -notmatch '\.' }).Count -eq 0) 'Parola tüm karakter kümelerini içerir'
    Assert-True (@($passwords | Where-Object { $_ -cmatch '[IOl01]' }).Count -eq 0) 'Parolada karışan karakter yok'
    Assert-True (@($passwords | Select-Object -Unique).Count -eq 50) 'Parolalar tekrar etmez'

    # ---- SMS gönderimi (yerel HTTP sunucusu)
    $httpPort = Get-FreePort
    $httpLog = [System.Collections.ArrayList]::Synchronized((New-Object -TypeName System.Collections.ArrayList))
    $httpServer = Start-BackgroundScript -Arguments @{ Port = $httpPort; RequestLog = $httpLog } -Script @'
param($Port, $RequestLog)
$listener = New-Object -TypeName System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
while ($true) {
    $context = $listener.GetContext()
    $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $context.Request.InputStream, ([System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $path = $context.Request.Url.AbsolutePath
    [void]$RequestLog.Add("$path|$body")
    if ($path -eq '/stop') { $context.Response.Close(); $listener.Stop(); return }
    $status = 200
    $text = 'OK'
    if ($path -eq '/fail500') { $status = 500; $text = 'hata' }
    if ($path -eq '/fail400') { $status = 400; $text = 'hata' }
    if ($path -eq '/echo') { $text = "RED $body" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $context.Response.StatusCode = $status
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.Close()
}
'@
    Start-Sleep -Milliseconds 800
    $smsBase = @{ Method = 'POST'; BodyFormat = 'Form'; ContentType = 'application/x-www-form-urlencoded'; TimeoutSeconds = 5; RetryCount = 0; Body = 'to={{PhoneNumber}}&m={{Message}}&k={{Secret:ApiKey}}' }
    $smsSecrets = @{ ApiKey = 'GIZLI+ANAHTAR' }
    $newSmsConfig = { param([string]$Path, [hashtable]$Extra = @{}) $config = $smsBase.Clone(); $config.Url = "http://127.0.0.1:$httpPort$Path"; foreach ($key in $Extra.Keys) { $config[$key] = $Extra[$key] }; $config }

    $sendResult = Send-SmsMessage -Config (& $newSmsConfig '/ok') -Secrets $smsSecrets -PhoneNumber '905321234567' -Message 'Parola: Xy.9'
    Assert-True ($sendResult.Success -and $sendResult.StatusCode -eq 200) "SMS: HTTP 200 başarılı ($($sendResult.Detail))"
    Assert-True ($httpLog[-1] -eq '/ok|to=905321234567&m=Parola%3A%20Xy.9&k=GIZLI%2BANAHTAR') "SMS: gövde kodlanır ($($httpLog[-1]))"

    $patternResult = Send-SmsMessage -Config (& $newSmsConfig '/ok' @{ SuccessPattern = 'BASARILI' }) -Secrets $smsSecrets -PhoneNumber '905321234567' -Message 'm'
    Assert-True (-not $patternResult.Success) 'SMS: SuccessPattern uymazsa başarısız'
    $failurePatternResult = Send-SmsMessage -Config (& $newSmsConfig '/ok' @{ FailurePattern = 'OK' }) -Secrets $smsSecrets -PhoneNumber '905321234567' -Message 'm'
    Assert-True (-not $failurePatternResult.Success) 'SMS: FailurePattern uyarsa başarısız'

    $requestCountBefore = $httpLog.Count
    $badRequestResult = Send-SmsMessage -Config (& $newSmsConfig '/fail400' @{ RetryCount = 2 }) -Secrets $smsSecrets -PhoneNumber '905321234567' -Message 'm'
    Assert-True ((-not $badRequestResult.Success) -and ($httpLog.Count - $requestCountBefore) -eq 1) 'SMS: 4xx tekrar denenmez'
    $requestCountBefore = $httpLog.Count
    $serverErrorResult = Send-SmsMessage -Config (& $newSmsConfig '/fail500' @{ RetryCount = 1 }) -Secrets $smsSecrets -PhoneNumber '905321234567' -Message 'm'
    Assert-True ((-not $serverErrorResult.Success) -and ($httpLog.Count - $requestCountBefore) -eq 2) 'SMS: 5xx tekrar denenir'

    $echoResult = Send-SmsMessage -Config (& $newSmsConfig '/echo' @{ SuccessPattern = 'BASARILI' }) -Secrets $smsSecrets -PhoneNumber '905321234567' -Message 'Parola: Xy.9' -Scrub @('Xy.9')
    Assert-True ($echoResult.Detail -notmatch 'GIZLI|Xy\.9|905321234567') "SMS: yanıttaki sırlar maskelenir ($($echoResult.Detail))"

    $closedPort = Get-FreePort
    $closedConfig = & $newSmsConfig '/ok'
    $closedConfig.Url = "http://127.0.0.1:$closedPort/"
    $closedResult = Send-SmsMessage -Config $closedConfig -Secrets $smsSecrets -PhoneNumber '905321234567' -Message 'm'
    Assert-True ((-not $closedResult.Success) -and $closedResult.Detail -match 'erişilemiyor') "SMS: bağlantı hatası tanılanır"

    try { Invoke-WebRequest -Uri "http://127.0.0.1:$httpPort/stop" -UseBasicParsing -TimeoutSec 3 | Out-Null } catch { Write-Verbose $_.Exception.Message }
    $httpServer.PowerShell.Dispose()

    # ---- E-posta gönderimi (yerel SMTP sunucusu)
    $smtpPort = Get-FreePort
    $smtpLog = [System.Collections.ArrayList]::Synchronized((New-Object -TypeName System.Collections.ArrayList))
    $smtpServer = Start-BackgroundScript -Arguments @{ Port = $smtpPort; Conversation = $smtpLog } -Script @'
param($Port, $Conversation)
$listener = New-Object -TypeName System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), $Port
$listener.Start()
$client = $listener.AcceptTcpClient()
$stream = $client.GetStream()
$reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $stream
$writer = New-Object -TypeName System.IO.StreamWriter -ArgumentList $stream
$writer.AutoFlush = $true
$writer.NewLine = "`r`n"
$writer.WriteLine('220 test')
while ($null -ne ($line = $reader.ReadLine())) {
    [void]$Conversation.Add($line)
    if ($line -like 'DATA*') {
        $writer.WriteLine('354 go')
        while (($line = $reader.ReadLine()) -ne '.') { [void]$Conversation.Add($line) }
        $writer.WriteLine('250 ok')
    }
    elseif ($line -like 'QUIT*') { $writer.WriteLine('221 bye'); break }
    else { $writer.WriteLine('250 ok') }
}
$client.Close()
$listener.Stop()
'@
    Start-Sleep -Milliseconds 800
    $mailBase = @{ SmtpServer = '127.0.0.1'; Port = $smtpPort; UseSsl = $false; Authentication = 'Anonymous'; From = 'adidm@example.test'; FromName = 'AD-IDM'; To = @('alici@example.test'); Cc = @('kopya@example.test'); Subject = 'Konu'; Html = '<p>Merhaba</p>' }
    $mailResult = Send-WelcomeMail -Mail $mailBase -Confirm:$false
    Assert-True ($mailResult.Success -and $mailResult.To -eq 'alici@example.test') 'E-posta: gönderilir'
    $smtpText = $smtpLog -join "`n"
    Assert-True ($smtpText -match 'RCPT TO:<alici@example\.test>' -and $smtpText -match 'RCPT TO:<kopya@example\.test>') 'E-posta: To ve Cc alıcıları'
    $missingAttachment = $mailBase.Clone()
    $missingAttachment.Attachments = @(Join-Path -Path $temporaryFolder -ChildPath 'yok.pdf')
    Assert-Throws { Send-WelcomeMail -Mail $missingAttachment -Confirm:$false } 'Ek dosyası bulunamadı' 'E-posta: eksik ek reddedilir'
    $missingCredential = $mailBase.Clone()
    $missingCredential.Authentication = 'Credential'
    $missingCredential.CredentialFile = Join-Path -Path $temporaryFolder -ChildPath 'yok.xml'
    Assert-Throws { Send-WelcomeMail -Mail $missingCredential -Confirm:$false } 'kimlik dosyası yok' 'E-posta: eksik kimlik dosyası reddedilir'
    $smtpServer.PowerShell.Dispose()

    # ---- E-posta şablonu
    Assert-True ((Expand-MailTemplate -Template 'A {{Ad}} {{Yok}}' -Values @{ Ad = '<b>' } -Html) -eq 'A &lt;b&gt; {{Yok}}') 'E-posta şablonu: HTML kodlama'
    Assert-True ((@(Split-MailAddressList -Text 'a@x; b@x, a@x') -join '|') -eq 'a@x|b@x') 'E-posta listesi ayrılır'
    $bodyPath = Join-Path -Path $temporaryFolder -ChildPath 'govde.txt'
    [System.IO.File]::WriteAllText($bodyPath, "Sayın {{Ad}}`nhttps://portal.example", (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
    $welcomeHtml = ConvertTo-WelcomeMailHtml -Path $bodyPath -Values @{ Ad = '<Ayşe>' }
    Assert-True ($welcomeHtml -match 'Sayın &lt;Ayşe&gt;<br>' -and $welcomeHtml -match '<a href="https://portal\.example"') 'E-posta şablonu: metin HTML olur'

    # ---- Ayar okuma
    Assert-True ((Get-SmsConfiguration).Reason -match 'ayar dosyası yok') 'SMS ayarı: dosya yok'
    Set-Content -LiteralPath $script:SmsConfigPath -Value '{ bozuk' -Encoding UTF8
    Assert-True ((Get-SmsConfiguration).Reason -match 'okunamadı') 'SMS ayarı: bozuk JSON raporlanır'
    Set-Content -LiteralPath $script:SmsConfigPath -Value '{"Enabled":false,"Url":"https://x"}' -Encoding UTF8
    (Get-Item -LiteralPath $script:SmsConfigPath).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-30)
    Assert-True ((Get-SmsConfiguration).Reason -match 'Enabled = false') 'SMS ayarı: kapalı'
    Set-Content -LiteralPath $script:SmsConfigPath -Value '{"Enabled":true,"Url":"https://x"}' -Encoding UTF8
    (Get-Item -LiteralPath $script:SmsConfigPath).LastWriteTimeUtc = [datetime]::UtcNow.AddSeconds(-20)
    $loadedSms = Get-SmsConfiguration
    Assert-True ($loadedSms.Available -and $loadedSms.Config.Provider -eq 'SMS servisi') 'SMS ayarı: değişiklik yeniden okunur'

    Set-Content -LiteralPath $script:MailConfigPath -Value '{"Enabled":true,"SmtpServer":"BURAYA","From":"a@x","To":["b@x"]}' -Encoding UTF8
    Assert-True ((Get-MailConfiguration).Reason -match 'SmtpServer') 'E-posta ayarı: doldurulmamış alan'
    Set-Content -LiteralPath $script:MailConfigPath -Value '{"Enabled":true,"SmtpServer":"s","From":"a@x","To":["b@x"],"OutsourceMail":{"Enabled":true,"BodyFile":"yok.txt"}}' -Encoding UTF8
    Assert-True ((Get-MailConfiguration).Available) 'E-posta ayarı: hazır'
    Assert-True ((Get-OutsourceMailConfiguration).Reason -match 'bulunamadı') 'Outsource ayarı: eksik metin dosyası'

    # ---- Gizli bilgi
    Assert-True ((Get-SmsSecretPath -Name 'ApiKey') -eq (Join-Path -Path $temporaryFolder -ChildPath 'Secrets\ApiKey.xml')) 'Gizli bilgi yolu'
    Assert-Throws { Resolve-SmsSecret -Config @{ Secrets = @{ ApiKey = @{ Source = 'CliXml'; Path = (Join-Path -Path $temporaryFolder -ChildPath 'yok.xml') } } } } 'dosyası yok' 'Gizli bilgi: eksik dosya'
    Assert-Throws { Resolve-SmsSecret -Config @{ Secrets = @{ ApiKey = @{ Source = 'Bilinmeyen' } } } } 'bilinmeyen Source' 'Gizli bilgi: bilinmeyen kaynak'
    if ($env:OS -eq 'Windows_NT') {
        $secretPath = Join-Path -Path $temporaryFolder -ChildPath 'ApiKey.xml'
        $secretText = 'DPAPI-TEST-' + [guid]::NewGuid().ToString('N')
        ConvertTo-SecureString -String $secretText -AsPlainText -Force | Export-Clixml -LiteralPath $secretPath
        Assert-True (-not ([System.IO.File]::ReadAllText($secretPath)).Contains($secretText)) 'DPAPI: dosyada düz metin yok'
        $resolved = Resolve-SmsSecret -Config @{ Secrets = @{ ApiKey = @{ Source = 'CliXml'; Path = $secretPath } } }
        Assert-True ((ConvertTo-PlainSecret -Secret $resolved.ApiKey) -ceq $secretText) 'DPAPI: aynı hesapla çözülür'
    }
    else { Write-Host 'SKIP  DPAPI gidiş-dönüş (yalnızca Windows)' }

    # ---- Değişiklik günlüğü
    $auditPath = Join-Path -Path $temporaryFolder -ChildPath 'Logs/audit.log'
    Initialize-Audit -Path $auditPath -Format KeyValue
    Assert-True (Write-AuditEvent -Action 'test.kv' -Result 'success' -Fields ([ordered]@{ message = "a`nb `"c`""; password = 'GIZLI1'; api_token = 'GIZLI2'; ChangePasswordAtLogon = $true })) 'Audit: yazılır'
    $keyValueLine = Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8
    Assert-True ($keyValueLine -match 'action="test\.kv"' -and $keyValueLine -match 'result="success"') 'Audit: KeyValue biçimi'
    Assert-True ($keyValueLine -notmatch 'GIZLI') 'Audit: gizli alanlar yazılmaz'
    Assert-True ($keyValueLine -match 'ChangePasswordAtLogon="true"') 'Audit: AtLogon alanı korunur'
    Assert-True ($keyValueLine -match 'message="a \| b ''c''"') 'Audit: tek satır, tırnak güvenli'
    Assert-True (([regex]::Matches($keyValueLine, "`r`n")).Count -eq 1) 'Audit: kayıt başına bir satır'
    $auditBytes = [System.IO.File]::ReadAllBytes($auditPath)
    Assert-True ($auditBytes[0] -ne 0xEF) 'Audit: BOM yok'

    $jsonPath = Join-Path -Path $temporaryFolder -ChildPath 'Logs/audit-json.log'
    Initialize-Audit -Path $jsonPath -Format Json
    [void](Write-AuditEvent -Action 'test.json' -Result 'failure' -Fields ([ordered]@{ message = 'ş' }))
    $jsonRecord = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($jsonRecord.action -eq 'test.json' -and $jsonRecord.message -eq 'ş' -and $jsonRecord.session_id) 'Audit: JSON biçimi'

    $rotationPath = Join-Path -Path $temporaryFolder -ChildPath 'Rotation/audit.log'
    Initialize-Audit -Path $rotationPath
    $script:Audit.MaxBytes = 100
    [void](Write-AuditEvent -Action 'test.one' -Result 'info')
    [void](Write-AuditEvent -Action 'test.two' -Result 'info')
    $rotatedFiles = @(Get-ChildItem -LiteralPath (Split-Path -Path $rotationPath -Parent))
    Assert-True ($rotatedFiles.Count -eq 2 -and (Get-Content -LiteralPath $rotationPath -Raw) -match 'test\.two' -and (Get-Content -LiteralPath $rotationPath -Raw) -notmatch 'test\.one') 'Audit: boyut aşılınca arşivlenir, kayıt silinmez'

    $blockedPath = Join-Path -Path $temporaryFolder -ChildPath 'dosya.txt'
    Set-Content -LiteralPath $blockedPath -Value 'x'
    Initialize-Audit -Path (Join-Path -Path $blockedPath -ChildPath 'audit.log')
    Assert-True (-not (Write-AuditEvent -Action 'test.block' -Result 'info')) 'Audit: yazılamazsa false döner, uygulamayı düşürmez'
    Assert-True ($script:Audit.Failed) 'Audit: hata durumu işaretlenir'

    # ---- Motor ile audit bağlantısı
    $engineAuditPath = Join-Path -Path $temporaryFolder -ChildPath 'Logs/engine-audit.log'
    Initialize-Audit -Path $engineAuditPath
    $workerExtraPath = Join-Path -Path $temporaryFolder -ChildPath 'worker-extra.ps1'
    Set-Content -LiteralPath $workerExtraPath -Encoding UTF8 -Value @'
function global:Connect-ExchangeEnvironment {
    param([string]$Server, [string]$Password, [switch]$Fail)
    if ($Fail) { throw 'bağlanamadı' }
    return 'ok'
}
'@
    $engineMessages = New-Object -TypeName System.Collections.ArrayList
    Initialize-TaskEngine -WorkerScriptPaths @((Join-Path -Path $projectRoot -ChildPath 'Core/WorkerBootstrap.ps1'), (Join-Path -Path $projectRoot -ChildPath 'Core/Notify.ps1'), (Join-Path -Path $PSScriptRoot -ChildPath 'DemoWorker.ps1'), $workerExtraPath) `
        -OnMessage { param($Item) [void]$engineMessages.Add($Item) } -OnBusyChanged { param($IsBusy, $Message) }
    [void](Invoke-BackgroundTask -Name 'Bağlan' -Command 'Connect-ExchangeEnvironment' -Arguments @{ Server = 'ex01'; Password = 'GIZLIPAROLA' })
    [void](Invoke-BackgroundTask -Name 'Bağlan hata' -Command 'Connect-ExchangeEnvironment' -Arguments @{ Server = 'ex01'; Fail = $true })
    [void](Invoke-BackgroundTask -Name 'Denetimsiz' -Command 'Invoke-DemoTask' -Arguments @{ Seconds = 1; StepMilliseconds = 10 })
    $deadline = (Get-Date).AddSeconds(20)
    while (($script:TaskEngine.CurrentJob -or $script:TaskEngine.Queue.Count -gt 0) -and (Get-Date) -lt $deadline) {
        Invoke-TaskPump
        Start-Sleep -Milliseconds 10
    }
    $notifyLoaded = [powershell]::Create()
    $notifyLoaded.Runspace = $script:TaskEngine.Runspace
    [void]$notifyLoaded.AddScript('[bool](Get-Command -Name Send-SmsMessage -ErrorAction SilentlyContinue)')
    Assert-True ([bool]($notifyLoaded.Invoke() | Select-Object -First 1)) 'Motor: Notify worker içinde yüklü'
    $notifyLoaded.Dispose()
    [void](Stop-TaskEngine)
    $engineAudit = @(Get-Content -LiteralPath $engineAuditPath -Encoding UTF8)
    Assert-True ($engineAudit.Count -eq 2) "Motor: yalnızca denetlenen komutlar kaydedilir ($($engineAudit.Count))"
    Assert-True ($engineAudit[0] -match 'action="exchange\.connect"' -and $engineAudit[0] -match 'result="success"' -and $engineAudit[0] -match 'Server=ex01') 'Motor: başarı kaydı'
    Assert-True ($engineAudit[1] -match 'result="failure"' -and $engineAudit[1] -match 'bağlanamadı') 'Motor: hata kaydı'
    Assert-True (($engineAudit -join ' ') -notmatch 'GIZLIPAROLA') 'Motor: parola argümanı kaydedilmez'
}
finally {
    Remove-Item -LiteralPath $temporaryFolder -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
