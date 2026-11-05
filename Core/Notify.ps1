function global:ConvertTo-PlainSecret {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][object]$Secret)
    if ($Secret -is [System.Management.Automation.PSCredential]) { $Secret = $Secret.Password }
    if ($Secret -is [string]) { return $Secret }
    if ($Secret -isnot [System.Security.SecureString]) { throw 'Gizli bilgi SecureString veya PSCredential olmalıdır.' }
    $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}
function global:Format-SmsPhone {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Number,
        [Parameter()][string]$CountryCode = '90',
        [Parameter()][ValidateSet('International', 'E164', 'National', 'National0', 'Raw')][string]$Format = 'International',
        [Parameter()][int]$NationalLength = 10
    )
    if ($Format -eq 'Raw') {
        if ([string]::IsNullOrWhiteSpace($Number)) { throw 'Telefon numarası boş.' }
        return $Number.Trim()
    }
    $digits = $Number -replace '\D', ''
    if ($digits.StartsWith('00')) { $digits = $digits.Substring(2) }
    $national = if ($CountryCode -and $digits.StartsWith($CountryCode) -and ($NationalLength -le 0 -or $digits.Length -eq $CountryCode.Length + $NationalLength)) { $digits.Substring($CountryCode.Length) }
    elseif ($digits.StartsWith('0')) { $digits.TrimStart('0') }
    else { $digits }
    if ([string]::IsNullOrEmpty($national) -or ($NationalLength -gt 0 -and $national.Length -ne $NationalLength)) {
        throw "Telefon numarası geçersiz: '$Number' (ülke kodu $CountryCode, $NationalLength haneli numara bekleniyor)."
    }
    switch ($Format) {
        'E164' { return "+$CountryCode$national" }
        'National' { return $national }
        'National0' { return "0$national" }
        default { return "$CountryCode$national" }
    }
}
function global:Get-MaskedPhone {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$Number)
    if ([string]::IsNullOrEmpty($Number) -or $Number.Length -le 5) { return '***' }
    return $Number.Substring(0, 3) + ('*' * ($Number.Length - 5)) + $Number.Substring($Number.Length - 2)
}
function global:ConvertFrom-AdssPlaceholder {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Template)
    $result = [regex]::Replace($Template, '%mobNo%|%mobileNo%|%mobile%|%phoneNumber%', '{{PhoneNumber}}', 'IgnoreCase')
    return [regex]::Replace($result, '%message%|%msg%|%smsText%', '{{Message}}', 'IgnoreCase')
}
function global:Expand-SmsTemplate {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Template,
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [Parameter()][hashtable]$Secrets = @{},
        [Parameter()][ValidateSet('Text', 'Url', 'Json', 'Xml', 'Form')][string]$Encoding = 'Text'
    )
    $evaluator = {
        param($match)
        $name = $match.Groups[1].Value
        if ($name -like 'Secret:*') {
            $parts = $name.Substring(7).Split('.')
            $secret = $Secrets[$parts[0]]
            if ($null -eq $secret) { throw "SMS ayarı: '$($parts[0])' gizli bilgisi tanımlı değil veya okunamadı." }
            $value = if ($parts.Count -gt 1 -and $parts[1] -eq 'UserName') {
                if ($secret -is [System.Management.Automation.PSCredential]) { $secret.UserName } else { throw "SMS ayarı: '$($parts[0])' kullanıcı adı içermiyor." }
            }
            else { ConvertTo-PlainSecret -Secret $secret }
        }
        elseif ($Values.ContainsKey($name)) { $value = [string]$Values[$name] }
        else { throw "SMS ayarı: bilinmeyen yer tutucu {{$name}}." }
        switch ($Encoding) {
            'Url' { return [System.Uri]::EscapeDataString($value) }
            'Form' { return [System.Uri]::EscapeDataString($value) }
            'Json' { return ((ConvertTo-Json -InputObject ([string]$value) -Compress) -replace '^"|"$', '') }
            'Xml' { return [System.Security.SecurityElement]::Escape($value) }
            default { return $value }
        }
    }
    $Template = ConvertFrom-AdssPlaceholder -Template $Template
    if ($Encoding -eq 'Text') {
        # Ayarlar ekranına yapıştırılan '\n' yazısını gerçek satır sonuna çevir; CRLF'yi LF yap.
        $Template = ($Template -replace '\\r\\n|\\n', "`n") -replace "`r`n", "`n"
    }
    try { return [regex]::Replace($Template, '\{\{\s*([A-Za-z0-9_:.]+)\s*\}\}', [System.Text.RegularExpressions.MatchEvaluator]$evaluator) }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        throw $inner.Message
    }
}
function global:Test-SmsConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter()][switch]$ForTest)
    if (-not $Config.Url) { throw 'SMS ayarı: Url boş.' }
    if (([string]$Config.Url) -notmatch '^https?://') { throw 'SMS ayarı: Url http:// veya https:// ile başlamalı.' }
    if (@('GET', 'POST', 'PUT') -notcontains ([string]$Config.Method).ToUpperInvariant()) { throw 'SMS ayarı: Method GET, POST veya PUT olmalı.' }
    $request = ConvertFrom-AdssPlaceholder -Template ("$([string]$Config.Url) $([string]$Config.Body)")
    if ($request -notmatch '\{\{\s*PhoneNumber\s*\}\}') { throw 'SMS ayarı: Url veya Body içinde telefon numarası yer tutucusu yok. {{PhoneNumber}} yazın (ADSelfService Plus''taki %mobNo% karşılığı).' }
    if ($request -notmatch '\{\{\s*Message\s*\}\}') { throw 'SMS ayarı: Url veya Body içinde mesaj yer tutucusu yok. {{Message}} yazın (ADSelfService Plus''taki %message% karşılığı).' }
    if (-not $ForTest -and ([string]$Config.MessageTemplate) -notmatch '\{\{\s*Password\s*\}\}') { throw 'SMS ayarı: MessageTemplate {{Password}} içermeli.' }
    if (([string]$Config.Url) -match '\{\{\s*Password\s*\}\}' -or ([string]$Config.Url) -match '\{\{\s*Message\s*\}\}' -and ([string]$Config.Method).ToUpperInvariant() -ne 'GET') {
        throw 'SMS ayarı: parola / mesaj yalnızca GET yönteminde Url içinde olabilir; POST için Body kullanın.'
    }
}
function global:New-SmsPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][ValidateRange(10, 64)][int]$Length = 14, [Parameter()][string]$Symbols = '.')
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789')
    if ($Symbols) { $sets += $Symbols }
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buffer = New-Object -TypeName byte[] -ArgumentList 4
        $next = { param([int]$Max) $rng.GetBytes($buffer); return [int]([BitConverter]::ToUInt32($buffer, 0) % [uint32]$Max) }
        $chars = New-Object -TypeName 'System.Collections.Generic.List[char]'
        foreach ($set in $sets) { $chars.Add($set[(& $next $set.Length)]) }
        while ($chars.Count -lt $Length) { $chars.Add($all[(& $next $all.Length)]) }
        for ($i = $chars.Count - 1; $i -gt 0; $i--) { $j = & $next ($i + 1); $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp }
        return -join $chars
    }
    finally { $rng.Dispose() }
}
function global:Get-ExceptionDetail {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)
    $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $current = $Exception
    while ($current) {
        $text = [string]$current.Message
        if ($current -is [System.Management.Automation.MethodInvocationException] -and $current.InnerException) { $current = $current.InnerException; continue }
        if ($current -is [System.Net.Mail.SmtpException] -and $current.StatusCode) { $text = "$text (SMTP durumu: $($current.StatusCode))" }
        if ($current -is [System.Net.Sockets.SocketException]) { $text = "$text (soket hatası: $($current.SocketErrorCode))" }
        if ($text -and -not ($parts | Where-Object { $_ -eq $text })) { $parts.Add($text) }
        $current = $current.InnerException
    }
    return ($parts -join ' -> ')
}
function global:Test-TcpPort {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$ComputerName,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter()][int]$TimeoutMs = 1500
    )
    $client = New-Object -TypeName System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($ComputerName, $Port)
        if ($task.Wait($TimeoutMs)) { return [bool]$client.Connected }
        return $false
    }
    catch { return $false }
    finally { $client.Close() }
}
function global:Get-ConnectivityHint {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$HostName, [Parameter(Mandatory = $true)][int]$Port, [Parameter()][string]$Purpose = '')
    try { $addresses = @([System.Net.Dns]::GetHostAddresses($HostName) | ForEach-Object { $_.IPAddressToString }) }
    catch { return "$HostName DNS'te çözülemedi ($($_.Exception.Message))." }
    $open = Test-TcpPort -ComputerName $HostName -Port $Port -TimeoutMs 3000
    $where = "$HostName ($($addresses -join ', ')):$Port"
    if ($open) { return "$where bu bilgisayardan erişilebiliyor; sorun sunucu tarafında (kimlik, relay izni veya yanıt)." }
    $hint = "$where bu bilgisayardan ($env:COMPUTERNAME) erişilemiyor; güvenlik duvarı veya ağ kuralı engelliyor olabilir."
    if ($Purpose -eq 'Smtp' -and $Port -eq 25) { $hint += " Antivirüs (ör. McAfee 'mass mailing' kuralı) powershell.exe'nin 25. porta çıkışını engelliyor olabilir." }
    if ($Purpose -eq 'Http') { $hint += ' Sunucu internete proxy ile çıkıyorsa sms-config.json içine "Proxy": "http://proxy:port" ekleyin.' }
    return $hint
}
function global:Invoke-SmsTestMessage {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter()][hashtable]$Secrets = @{}, [Parameter(Mandatory = $true)][string]$Number, [Parameter(Mandatory = $true)][string]$Message)
    Test-SmsConfiguration -Config $Config -ForTest
    $phone = Format-SmsPhone -Number $Number -CountryCode $(if ($null -ne $Config.CountryCode) { [string]$Config.CountryCode } else { '90' }) `
        -Format $(if ($Config.PhoneFormat) { [string]$Config.PhoneFormat } else { 'International' }) -NationalLength $(if ($null -ne $Config.NationalLength) { [int]$Config.NationalLength } else { 10 })
    Set-WorkerProgress -Status "Test SMS gönderiliyor: $(Get-MaskedPhone -Number $phone)..."
    $send = Send-SmsMessage -Config $Config -Secrets $Secrets -PhoneNumber $phone -Message $Message
    return [pscustomobject]@{ Success = [bool]$send.Success; To = (Get-MaskedPhone -Number $phone); Detail = [string]$send.Detail }
}
function global:Send-SmsMessage {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter()][hashtable]$Secrets = @{},
        [Parameter(Mandatory = $true)][string]$PhoneNumber,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter()][string[]]$Scrub = @()
    )
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    $values = @{ PhoneNumber = $PhoneNumber; Message = $Message; MessageId = [guid]::NewGuid().ToString('N'); Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    $method = ([string]$Config.Method).ToUpperInvariant()
    $request = @{
        Uri             = Expand-SmsTemplate -Template ([string]$Config.Url) -Values $values -Secrets $Secrets -Encoding Url
        Method          = $method
        UseBasicParsing = $true
        TimeoutSec      = if ($Config.TimeoutSeconds) { [int]$Config.TimeoutSeconds } else { 20 }
        ErrorAction     = 'Stop'
    }
    if ($Config.Headers) {
        $headers = @{}
        foreach ($key in $Config.Headers.Keys) { $headers[$key] = Expand-SmsTemplate -Template ([string]$Config.Headers[$key]) -Values $values -Secrets $Secrets -Encoding Text }
        $request.Headers = $headers
    }
    if ($method -ne 'GET' -and $Config.Body) {
        $format = if ($Config.BodyFormat) { [string]$Config.BodyFormat } else { 'Json' }
        $body = Expand-SmsTemplate -Template ([string]$Config.Body) -Values $values -Secrets $Secrets -Encoding $format
        $request.Body = [System.Text.Encoding]::UTF8.GetBytes($body)
        $request.ContentType = if ($Config.ContentType) { [string]$Config.ContentType } else { 'application/json; charset=utf-8' }
    }
    if ($Config.UseDefaultCredentials) { $request.UseDefaultCredentials = $true }
    if ($Config.Proxy) {
        $request.Proxy = [string]$Config.Proxy
        if ($Config.ProxyUseDefaultCredentials -ne $false) { $request.ProxyUseDefaultCredentials = $true }
    }
    $scrubList = @($Scrub + $Message | Where-Object { $_ })
    $clean = {
        param([string]$Text)
        foreach ($item in $scrubList) { $Text = $Text.Replace($item, '***').Replace([System.Uri]::EscapeDataString($item), '***') }
        $Text = $Text.Replace($PhoneNumber, (Get-MaskedPhone -Number $PhoneNumber))
        foreach ($key in $Secrets.Keys) { try { $plain = ConvertTo-PlainSecret -Secret $Secrets[$key]; if ($plain) { $Text = $Text.Replace($plain, '***').Replace([System.Uri]::EscapeDataString($plain), '***') } } catch { Write-Verbose $_.Exception.Message } }
        if ($Text.Length -gt 160) { $Text = $Text.Substring(0, 160) + '...' }
        return ($Text -replace '\s+', ' ').Trim()
    }
    $attempts = 1 + $(if ($null -ne $Config.RetryCount) { [int]$Config.RetryCount } else { 2 })
    $last = $null
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            $response = Invoke-WebRequest @request
            # Metin dışı veya Content-Type'sız yanıtta Content bayt dizisidir; kalıplar metne uygulanmalı.
            $content = if ($response.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($response.Content) } else { [string]$response.Content }
            $ok = $true
            if ($Config.SuccessPattern -and $content -notmatch [string]$Config.SuccessPattern) { $ok = $false }
            if ($Config.FailurePattern -and $content -match [string]$Config.FailurePattern) { $ok = $false }
            if ($ok) { return [pscustomobject]@{ Success = $true; StatusCode = [int]$response.StatusCode; Detail = "HTTP $([int]$response.StatusCode)"; Attempts = $attempt } }
            return [pscustomobject]@{ Success = $false; StatusCode = [int]$response.StatusCode; Detail = "HTTP $([int]$response.StatusCode), yanıt başarı kalıbına uymadı: $(& $clean $content)"; Attempts = $attempt }
        }
        catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
            $last = [pscustomobject]@{ Success = $false; StatusCode = $status; Detail = (& $clean ([string](Get-ExceptionDetail -Exception $_.Exception))); Attempts = $attempt }
            if ($status -and $status -ge 400 -and $status -lt 500) { break }
            if ($attempt -lt $attempts) { Start-Sleep -Seconds 2 }
        }
    }
    if ($last -and -not $last.StatusCode) {
        try {
            $uri = [uri]$request.Uri
            $last.Detail = "$($last.Detail) [$attempts deneme] $(Get-ConnectivityHint -HostName $uri.Host -Port $uri.Port -Purpose Http)"
        }
        catch { Write-Verbose "Bağlantı tanısı yapılamadı: $($_.Exception.Message)" }
    }
    return $last
}
function global:Send-WelcomeMail {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][hashtable]$Mail)
    $message = New-Object -TypeName System.Net.Mail.MailMessage
    $client = $null
    try {
        $message.From = New-Object -TypeName System.Net.Mail.MailAddress -ArgumentList ([string]$Mail.From), ([string]$Mail.FromName)
        foreach ($address in @($Mail.To | Where-Object { $_ })) { $message.To.Add([string]$address) }
        foreach ($address in @($Mail.Cc | Where-Object { $_ })) { $message.CC.Add([string]$address) }
        $message.Subject = [string]$Mail.Subject
        $message.SubjectEncoding = [System.Text.Encoding]::UTF8
        $message.Body = [string]$Mail.Html
        $message.BodyEncoding = [System.Text.Encoding]::UTF8
        $message.IsBodyHtml = $true
        foreach ($file in @($Mail.Attachments | Where-Object { $_ })) {
            if (-not (Test-Path -LiteralPath $file)) { throw "Ek dosyası bulunamadı: $file" }
            $message.Attachments.Add((New-Object -TypeName System.Net.Mail.Attachment -ArgumentList ([string]$file)))
        }
        $client = New-Object -TypeName System.Net.Mail.SmtpClient -ArgumentList ([string]$Mail.SmtpServer), ([int]$Mail.Port)
        $client.EnableSsl = [bool]$Mail.UseSsl
        $client.Timeout = 60000
        switch ([string]$Mail.Authentication) {
            'Windows' { $client.UseDefaultCredentials = $true }
            'Credential' {
                if (-not (Test-Path -LiteralPath ([string]$Mail.CredentialFile))) { throw "SMTP kimlik dosyası yok: $($Mail.CredentialFile)" }
                $credential = Import-Clixml -LiteralPath ([string]$Mail.CredentialFile)
                $client.UseDefaultCredentials = $false
                $client.Credentials = $credential.GetNetworkCredential()
            }
            default { $client.UseDefaultCredentials = $false }
        }
        $target = (@($Mail.To) -join ', ')
        if (-not $PSCmdlet.ShouldProcess($target, 'Bilgilendirme e-postası gönder')) { return }
        $client.Send($message)
        return [pscustomobject]@{ Success = $true; To = $target; Cc = (@($Mail.Cc) -join ', '); Subject = [string]$Mail.Subject; Detail = "$(@($Mail.Attachments).Count) ek" }
    }
    finally {
        $message.Dispose()
        if ($client) { $client.Dispose() }
    }
}
function Split-MailAddressList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Text)
    return [string[]]@(([string]$Text) -split '[;,\s]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
}
function Expand-MailTemplate {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Template, [Parameter(Mandatory = $true)][hashtable]$Values, [Parameter()][switch]$Html)
    return [regex]::Replace($Template, '\{\{\s*(\w+)\s*\}\}', {
            param($match)
            $key = $match.Groups[1].Value
            if (-not $Values.ContainsKey($key)) { return $match.Value }
            $value = [string]$Values[$key]
            if ($Html) { [System.Net.WebUtility]::HtmlEncode($value) } else { $value }
        })
}
function ConvertTo-WelcomeMailHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][hashtable]$Values)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ($Path -match '\.html?$') { return (Expand-MailTemplate -Template $raw -Values $Values -Html) }
    $text = [System.Net.WebUtility]::HtmlEncode((Expand-MailTemplate -Template $raw -Values $Values))
    $text = [regex]::Replace($text, 'https?://[^\s<]+', { param($m) "<a href=`"$($m.Value)`" style=`"color:#005FB8;`">$($m.Value)</a>" })
    $text = ($text -replace "`r`n", "`n") -replace "`n", "<br>`n"
    return "<!DOCTYPE html><html><head><meta charset=`"utf-8`"></head><body style=`"font-family:'Segoe UI',Arial,sans-serif;font-size:14px;line-height:1.5;color:#1B1B1B;`">$text</body></html>"
}
function Invoke-SmsTest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PhoneNumber)
    $sms = Get-SmsConfiguration
    if (-not $sms.Available) { throw "SMS servisi kullanılamıyor: $($sms.Reason)" }
    $config = $sms.Config
    Test-SmsConfiguration -Config $config -ForTest
    $secrets = Resolve-SmsSecret -Config $config
    $phone = Format-SmsPhone -Number $PhoneNumber -CountryCode $(if ($null -ne $config.CountryCode) { [string]$config.CountryCode } else { '90' }) `
        -Format $(if ($config.PhoneFormat) { [string]$config.PhoneFormat } else { 'International' }) -NationalLength $(if ($null -ne $config.NationalLength) { [int]$config.NationalLength } else { 10 })
    $template = if ($config.TestMessageTemplate) { [string]$config.TestMessageTemplate } else { 'AD Kullanici Yoneticisi SMS testi ({{Time}}). Bu mesaj parola icermez.' }
    $message = Expand-SmsTemplate -Template $template -Values @{ Time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Domain = $env:USERDOMAIN; DomainDns = $env:USERDNSDOMAIN } -Encoding Text
    Write-Host "Test SMS gönderiliyor: $(Get-MaskedPhone -Number $phone) ($($config.Provider))..."
    $send = Send-SmsMessage -Config $config -Secrets $secrets -PhoneNumber $phone -Message $message
    [void](Write-AuditEvent -Action 'sms.test' -Result $(if ($send.Success) { 'success' } else { 'failure' }) -Fields ([ordered]@{ sms_to = (Get-MaskedPhone -Number $phone); sms_provider = [string]$config.Provider; sms_status = $send.StatusCode; message = $send.Detail }))
    if ($send.Success) {
        Write-Host "Başarılı: $($send.Detail) (deneme: $($send.Attempts))" -ForegroundColor Green
        return 0
    }
    Write-Host "Başarısız: $($send.Detail)" -ForegroundColor Red
    return 1
}
function Invoke-MailTest {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][string]$To)
    $config = (Get-MailConfiguration).Config
    if (-not $config) { throw "E-posta ayar dosyası okunamadı: $script:MailConfigPath" }
    if (-not $config.SmtpServer -or -not $config.From) { throw 'mail-config.json içinde SmtpServer / From doldurulmamış.' }
    $port = if ($config.Port) { [int]$config.Port } else { 25 }
    if ($config.Authentication -eq 'Credential' -and -not $config.UseSsl) { Write-Warning 'SMTP kimliği şifresiz bağlantıyla gönderilecek. mail-config.json içinde UseSsl = true yapın.' }
    $mail = @{
        SmtpServer     = [string]$config.SmtpServer
        Port           = $port
        UseSsl         = [bool]$config.UseSsl
        Authentication = [string]$config.Authentication
        CredentialFile = Resolve-AppPath -Path ([string]$config.CredentialFile)
        From           = [string]$config.From
        FromName       = [string]$config.FromName
        To             = @($To)
        Cc             = @()
        Subject        = 'AD-IDM SMTP testi'
        Html           = "<p>AD-IDM SMTP testi: $(Get-Date -Format 'yyyy-MM-dd HH:mm') ($env:COMPUTERNAME). Bu e-postayı yanıtlamayın.</p>"
    }
    try {
        $sent = Send-WelcomeMail -Mail $mail -Confirm:$false
        [void](Write-AuditEvent -Action 'mail.test' -Result 'success' -Fields ([ordered]@{ mail_to = $sent.To; smtp_server = $mail.SmtpServer }))
        Write-Host "Başarılı: $($sent.To) adresine gönderildi." -ForegroundColor Green
        return 0
    }
    catch {
        $detail = "$(Get-ExceptionDetail -Exception $_.Exception) $(Get-ConnectivityHint -HostName $mail.SmtpServer -Port $port -Purpose Smtp)"
        [void](Write-AuditEvent -Action 'mail.test' -Result 'failure' -Fields ([ordered]@{ mail_to = $To; smtp_server = $mail.SmtpServer; message = $detail }))
        Write-Host "Başarısız: $detail" -ForegroundColor Red
        return 1
    }
}
