function Get-SettingsFieldList {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    @(
        @('Smtp', 'Mail', 'SmtpServer', 'Text', 'SMTP sunucusu', '', $null),
        @('Smtp', 'Mail', 'Port', 'Int', 'Port', 'Genellikle 25 (relay) veya 587 (TLS).', $null),
        @('Smtp', 'Mail', 'UseSsl', 'Bool', 'SSL / TLS kullan', '', $null),
        @('Smtp', 'Mail', 'Authentication', 'Choice', 'Kimlik doğrulama', 'Anonymous: kimliksiz relay. Windows: oturum açan / görev hesabı. Credential: CredentialFile içindeki şifreli kimlik (.\AD-IDM.ps1 -SetMailCredential).', ([string[]]@('Anonymous', 'Windows', 'Credential'))),
        @('Smtp', 'Mail', 'CredentialFile', 'Text', 'Kimlik dosyası (Credential için)', 'Varsayılan: Secrets\smtp-credential.xml', $null),
        @('Smtp', 'Mail', 'From', 'Text', 'Gönderen adresi', 'Hem gece raporu hem outsource e-postası bu adresten gider.', $null),
        @('Smtp', 'Mail', 'FromName', 'Text', 'Gönderen adı (gece raporu)', '', $null),
        @('Outsource', 'Mail', 'OutsourceMail.Enabled', 'Bool', 'Outsource bilgilendirme e-postası açık', 'Kapalıysa Kullanıcı Ekle ekranındaki Outsource anahtarı kullanılamaz.', $null),
        @('Outsource', 'Mail', 'OutsourceMail.FromName', 'Text', 'Gönderen adı', '', $null),
        @('Outsource', 'Mail', 'OutsourceMail.Subject', 'Text', 'Konu', 'Alanlar kullanılabilir, ör. {{SamAccountName}}.', $null),
        @('Outsource', 'Mail', 'OutsourceMail.Cc', 'List', 'CC adresleri', 'Noktalı virgülle ayırın. Kullanıcı Ekle ekranında bu liste hazır gelir.', $null),
        @('Outsource', 'Mail', 'OutsourceMail.BodyFile', 'Text', 'Metin dosyası', 'Aşağıdaki metin bu dosyaya kaydedilir (.txt düz metin veya .html). Boş bırakırsanız outsource-mail.txt kullanılır.', $null),
        @('Leave', 'Mail', 'Enabled', 'Bool', 'Gece izin raporu e-postası açık', '', $null),
        @('Leave', 'Mail', 'CompanyName', 'Text', 'Şirket adı (rapor başlığı)', '', $null),
        @('Leave', 'Mail', 'To', 'List', 'Alıcılar', 'Noktalı virgülle ayırın.', $null),
        @('Leave', 'Mail', 'Cc', 'List', 'CC', 'Noktalı virgülle ayırın.', $null),
        @('Leave', 'Mail', 'Subject', 'Text', 'Konu', 'Alanlar: {{Date}} {{Closed}} {{Opened}} {{Failed}}', $null),
        @('Leave', 'Mail', 'SendWhen', 'Choice', 'Ne zaman gönderilsin', 'Always: her gece. Changes: yalnız hesap kapanan / açılan gecelerde. Failures: yalnız hata veya sorunlu kayıt varsa.', ([string[]]@('Always', 'Changes', 'Failures'))),
        @('SmsService', 'Sms', 'Enabled', 'Bool', 'SMS servisi açık', '', $null),
        @('SmsService', 'Sms', 'Provider', 'Text', 'Servis adı', '', $null),
        @('SmsService', 'Sms', 'Url', 'Text', 'Url', 'http:// veya https:// ile başlamalı.', $null),
        @('SmsService', 'Sms', 'Method', 'Choice', 'Yöntem', '', ([string[]]@('POST', 'GET', 'PUT'))),
        @('SmsService', 'Sms', 'ContentType', 'Text', 'Content-Type', '', $null),
        @('SmsService', 'Sms', 'BodyFormat', 'Choice', 'Body biçimi', '', ([string[]]@('Json', 'Form', 'Xml', 'Text'))),
        @('SmsService', 'Sms', 'Body', 'Multiline', 'Body', 'Alanlar: {{PhoneNumber}} (numara) {{Message}} (mesaj) {{MessageId}} {{Time}}. ADSelfService Plus''tan kopyaladığınız %mobNo% ve %message% de otomatik tanınır. Örnek: {"phoneNumber":"{{PhoneNumber}}","freeText":"{{Message}}"}', $null),
        @('SmsService', 'Sms', 'SuccessPattern', 'Text', 'Başarı kalıbı (regex)', 'Boşsa HTTP 2xx başarı sayılır.', $null),
        @('SmsService', 'Sms', 'FailurePattern', 'Text', 'Hata kalıbı (regex)', '', $null),
        @('SmsService', 'Sms', 'TimeoutSeconds', 'Int', 'Zaman aşımı (sn)', '', $null),
        @('SmsService', 'Sms', 'RetryCount', 'Int', 'Yeniden deneme sayısı', '', $null),
        @('SmsService', 'Sms', 'Proxy', 'Text', 'Proxy', 'Sunucu internete proxy ile çıkıyorsa, ör. http://proxy.contoso.com:8080. Boşsa sistem ayarı kullanılır.', $null),
        @('SmsMessages', 'Sms', 'WelcomeMessageTemplate', 'Multiline', 'Hoş geldiniz mesajı (yeni kullanıcı)', '{{Password}} içermeli. Alanlar: {{DisplayName}} {{SamAccountName}} {{UserPrincipalName}} {{Password}}', $null),
        @('SmsMessages', 'Sms', 'MessageTemplate', 'Multiline', 'Parola sıfırlama mesajı', '{{Password}} içermeli.', $null),
        @('SmsMessages', 'Sms', 'TestMessageTemplate', 'Multiline', 'Test mesajı', 'Parola içermez. Alan: {{Time}}', $null),
        @('SmsPhone', 'Sms', 'PhoneAttribute', 'Text', 'Telefon özniteliği', '', $null),
        @('SmsPhone', 'Sms', 'PhoneFormat', 'Choice', 'Telefon biçimi', 'Raw: AD''de nasılsa öyle. International: 905321234567. E164: +905321234567. National0: 05321234567. National: 5321234567.', ([string[]]@('Raw', 'International', 'E164', 'National0', 'National'))),
        @('SmsPhone', 'Sms', 'CountryCode', 'Text', 'Ülke kodu', '', $null),
        @('SmsPhone', 'Sms', 'NationalLength', 'Int', 'Ulusal numara uzunluğu', '', $null),
        @('Password', 'Sms', 'PasswordLength', 'Int', 'Üretilen parola uzunluğu', '10 ile 64 arası.', $null),
        @('Password', 'Sms', 'PasswordSymbols', 'Text', 'Parolada kullanılacak semboller', '', $null),
        @('Password', 'Sms', 'AllowManualPassword', 'Bool', 'Elle parola girişine izin ver', '', $null)
    ) | ForEach-Object { [pscustomobject]@{ Tab = $_[0]; File = $_[1]; Path = $_[2]; Type = $_[3]; Label = $_[4]; Hint = $_[5]; Choices = $_[6] } }
}
function Read-SettingsDocument {
    [CmdletBinding()]
    [OutputType([psobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{} }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
}
function Get-SettingsValue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][psobject]$Document, [Parameter(Mandatory = $true)][string]$Path)
    $current = $Document
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current -or -not $current.PSObject.Properties[$part]) { return $null }
        $current = $current.$part
    }
    return , $current
}
function Set-SettingsValue {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory = $true)][psobject]$Document, [Parameter(Mandatory = $true)][string]$Path, [Parameter()][AllowNull()][object]$Value)
    $parts = $Path.Split('.')
    $current = $Document
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if (-not $current.PSObject.Properties[$parts[$i]] -or $null -eq $current.($parts[$i])) { $current | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([pscustomobject]@{}) -Force }
        $current = $current.($parts[$i])
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Ayarı değiştir')) { $current | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Value -Force }
}
function Save-SettingsDocument {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory = $true)][psobject]$Document, [Parameter(Mandatory = $true)][string]$Path)
    $json = $Document | ConvertTo-Json -Depth 20
    $null = $json | ConvertFrom-Json -ErrorAction Stop
    if (-not $PSCmdlet.ShouldProcess($Path, 'Ayar dosyasını kaydet')) { return }
    if (Test-Path -LiteralPath $Path) { Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force -ErrorAction Stop }
    [System.IO.File]::WriteAllText($Path, $json, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
}
function Get-SettingsFormDocument {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $state = $script:State.Settings
    $docs = @{ Mail = ($state.Original.Mail | ConvertTo-Json -Depth 20 | ConvertFrom-Json); Sms = ($state.Original.Sms | ConvertTo-Json -Depth 20 | ConvertFrom-Json) }
    $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($field in $state.Fields) {
        $control = $state.Controls[$field.Path + '|' + $field.File]
        $value = switch ($field.Type) {
            'Bool' { [bool]$control.IsChecked }
            'Choice' { [string]$control.SelectedItem }
            'List' { [object[]]@(Split-MailAddressList -Text $control.Text) }
            'Int' {
                $text = ([string]$control.Text).Trim()
                $number = 0
                if (-not $text) { $null }
                elseif ([int]::TryParse($text, [ref]$number)) { $number }
                else { $errors.Add("$($field.Label): sayı olmalı."); $null }
            }
            default { [string]$control.Text }
        }
        if ($field.Type -eq 'List') {
            $bad = @($value | Where-Object { $_ -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' })
            if ($bad.Count) { $errors.Add("$($field.Label): geçersiz adres $($bad -join ', ').") }
        }
        Set-SettingsValue -Document $docs[$field.File] -Path $field.Path -Value $value -Confirm:$false
    }
    $attachments = [object[]]@(([string]$state.Ui.txtSetAttachments.Text) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($file in $attachments) { if (-not (Test-Path -LiteralPath (Resolve-AppPath -Path $file))) { $errors.Add("Ek dosyası bulunamadı: $file") } }
    Set-SettingsValue -Document $docs.Mail -Path 'OutsourceMail.Attachments' -Value $attachments -Confirm:$false
    $url = [string](Get-SettingsValue -Document $docs.Sms -Path 'Url')
    if ($url -and $url -notmatch '^https?://') { $errors.Add('SMS Url http:// veya https:// ile başlamalı.') }
    foreach ($name in 'WelcomeMessageTemplate', 'MessageTemplate') {
        $template = [string](Get-SettingsValue -Document $docs.Sms -Path $name)
        if ($template -and $template -notmatch '\{\{\s*Password\s*\}\}') { $errors.Add("SMS $name {{Password}} içermeli.") }
    }
    return @{ Mail = $docs.Mail; Sms = $docs.Sms; Errors = $errors }
}
function Save-SettingsForm {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $state = $script:State.Settings
    $c = $state.Ui
    $form = Get-SettingsFormDocument
    if ($form.Errors.Count -gt 0) { $c.txtSetMessage.Text = 'Kaydedilmedi: ' + ($form.Errors -join ' '); return $false }
    try {
        Save-SettingsDocument -Document $form.Mail -Path $script:MailConfigPath -Confirm:$false
        Save-SettingsDocument -Document $form.Sms -Path $script:SmsConfigPath -Confirm:$false
        if (-not [string](Get-SettingsValue -Document $form.Mail -Path 'OutsourceMail.BodyFile') -and ([string]$c.txtSetBody.Text).Trim()) {
            Set-SettingsValue -Document $form.Mail -Path 'OutsourceMail.BodyFile' -Value 'Configs\outsource-mail.txt' -Confirm:$false
            $state.Controls['OutsourceMail.BodyFile|Mail'].Text = 'Configs\outsource-mail.txt'
            Save-SettingsDocument -Document $form.Mail -Path $script:MailConfigPath -Confirm:$false
        }
        $bodyFile = Resolve-AppPath -Path ([string](Get-SettingsValue -Document $form.Mail -Path 'OutsourceMail.BodyFile'))
        if ($bodyFile) {
            if (Test-Path -LiteralPath $bodyFile) { Copy-Item -LiteralPath $bodyFile -Destination "$bodyFile.bak" -Force -ErrorAction Stop }
            $text = ([string]$c.txtSetBody.Text) -replace "(?<!`r)`n", "`r`n"
            [System.IO.File]::WriteAllText($bodyFile, $text, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
        }
        $state.Original = @{ Mail = $form.Mail; Sms = $form.Sms }
        $state.Dirty = $false
        $c.txtSetMessage.Text = "Kaydedildi ($((Get-Date).ToString('HH:mm:ss'))). Önceki sürümler .bak dosyası olarak saklandı."
        [void](Write-AuditEvent -Action 'settings.change' -Result 'success' -Fields ([ordered]@{ category = 'settings'; message = "mail-config.json, sms-config.json$(if ($bodyFile) { ', ' + (Split-Path -Path $bodyFile -Leaf) })" }))
        Write-UiLog -Message 'Ayarlar kaydedildi.' -Level Success
        return $true
    }
    catch {
        $c.txtSetMessage.Text = "Kaydedilemedi: $($_.Exception.Message)"
        Write-UiLog -Message "Ayarlar kaydedilemedi: $($_.Exception.Message)" -Level Error
        return $false
    }
}
function Get-SettingsSampleValue {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $environment = $script:State.Environment
    $dns = if ($environment -and $environment.DomainName) { [string]$environment.DomainName } else { [string]$env:USERDNSDOMAIN }
    return @{
        SamAccountName = 'ot9999'; UserPrincipalName = "ot9999@$dns"; DisplayName = 'Örnek Kullanıcı'; GivenName = 'Örnek'; Surname = 'Kullanıcı'; EmailAddress = 'ornek@firma.com'
        Domain = $(if ($environment -and $environment.NetBiosName) { [string]$environment.NetBiosName } else { [string]$env:USERDOMAIN }); DomainDns = $dns
    }
}
function Get-SettingsPreviewHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $state = $script:State.Settings
    $bodyFile = Resolve-AppPath -Path ([string]$state.Controls['OutsourceMail.BodyFile|Mail'].Text)
    $temp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("adidm-body-{0}{1}" -f [guid]::NewGuid().ToString('N'), $(if ($bodyFile -match '\.html?$') { '.html' } else { '.txt' }))
    try {
        [System.IO.File]::WriteAllText($temp, [string]$state.Ui.txtSetBody.Text, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
        return (ConvertTo-WelcomeMailHtml -Path $temp -Values (Get-SettingsSampleValue))
    }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}
function Start-SettingsTestMail {
    [CmdletBinding()]
    param()
    $state = $script:State.Settings
    $c = $state.Ui
    $to = @(Split-MailAddressList -Text $c.txtSetTestMail.Text)
    if ($to.Count -eq 0 -or @($to | Where-Object { $_ -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' }).Count) { $c.txtSetMessage.Text = 'Test alıcısı için geçerli bir e-posta adresi yazın.'; return }
    $form = Get-SettingsFormDocument
    if ($form.Errors.Count -gt 0) { $c.txtSetMessage.Text = 'Test yapılamadı: ' + ($form.Errors -join ' '); return }
    $mail = $form.Mail
    $values = Get-SettingsSampleValue
    $credential = Resolve-AppPath -Path $(if ($mail.CredentialFile) { [string]$mail.CredentialFile } else { 'Secrets\smtp-credential.xml' })
    $argument = @{
        SmtpServer = [string]$mail.SmtpServer; Port = $(if ($mail.Port) { [int]$mail.Port } else { 25 }); UseSsl = [bool]$mail.UseSsl
        Authentication = [string]$mail.Authentication; CredentialFile = $credential
        From = [string]$mail.From; FromName = [string](Get-SettingsValue -Document $mail -Path 'OutsourceMail.FromName')
        To = [string[]]$to; Cc = [string[]]@()
        Subject = '[TEST] ' + (Expand-MailTemplate -Template ([string](Get-SettingsValue -Document $mail -Path 'OutsourceMail.Subject')) -Values $values)
        Html = (Get-SettingsPreviewHtml)
        Attachments = [string[]]@(@(Get-SettingsValue -Document $mail -Path 'OutsourceMail.Attachments') | Where-Object { $_ } | ForEach-Object { Resolve-AppPath -Path ([string]$_) })
    }
    if (-not $argument.SmtpServer -or -not $argument.From) { $c.txtSetMessage.Text = 'SMTP sunucusu ve gönderen adresi dolu olmalı.'; return }
    $c.txtSetMessage.Text = "Test e-postası gönderiliyor: $($to -join ', ')..."
    $started = Invoke-BackgroundTask -Name 'Test e-postası gönderiliyor' -Command 'Send-WelcomeMail' -Arguments @{ Mail = $argument; Confirm = $false } -OnSuccess {
        param($Result)
        if ($script:State.Settings) { $script:State.Settings.Ui.txtSetMessage.Text = "Test e-postası gönderildi: $($Result.To) ($($Result.Detail))." }
        Write-UiLog -Message "Test e-postası gönderildi: $($Result.To)" -Level Success
    } -OnFailure {
        param($Message)
        if ($script:State.Settings) { $script:State.Settings.Ui.txtSetMessage.Text = "Test e-postası gönderilemedi: $Message" }
    }
    if (-not $started) { $c.txtSetMessage.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' }
}
function Start-SettingsTestSms {
    [CmdletBinding()]
    param()
    $state = $script:State.Settings
    $c = $state.Ui
    $number = ([string]$c.txtSetTestSms.Text).Trim()
    if (($number -replace '\D', '').Length -lt 10) { $c.txtSetMessage.Text = 'Test için geçerli bir cep telefonu numarası yazın.'; return }
    $form = Get-SettingsFormDocument
    if ($form.Errors.Count -gt 0) { $c.txtSetMessage.Text = 'Test yapılamadı: ' + ($form.Errors -join ' '); return }
    try {
        $config = ConvertTo-PlainHashtable -InputObject $form.Sms
        $secrets = Resolve-SmsSecret -Config $config
        $template = if ($config.TestMessageTemplate) { [string]$config.TestMessageTemplate } else { 'AD Kullanici Yoneticisi SMS testi ({{Time}}). Bu mesaj parola icermez.' }
        $message = $template.Replace('{{Time}}', (Get-Date).ToString('yyyy-MM-dd HH:mm'))
    }
    catch { $c.txtSetMessage.Text = "Test yapılamadı: $($_.Exception.Message)"; return }
    $c.txtSetMessage.Text = 'Test SMS gönderiliyor...'
    $started = Invoke-BackgroundTask -Name 'Test SMS gönderiliyor' -Command 'Invoke-SmsTestMessage' -Arguments @{ Config = $config; Secrets = $secrets; Number = $number; Message = $message } -OnSuccess {
        param($Result)
        $text = if ($Result.Success) { "Test SMS gönderildi: $($Result.To) ($($Result.Detail))." } else { "Test SMS gönderilemedi ($($Result.To)): $($Result.Detail)" }
        if ($script:State.Settings) { $script:State.Settings.Ui.txtSetMessage.Text = $text }
        Write-UiLog -Message $text -Level $(if ($Result.Success) { 'Success' } else { 'Error' })
    } -OnFailure {
        param($Message)
        if ($script:State.Settings) { $script:State.Settings.Ui.txtSetMessage.Text = "Test SMS gönderilemedi: $Message" }
    }
    if (-not $started) { $c.txtSetMessage.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' }
}
function Initialize-SettingsPage {
    [CmdletBinding()]
    param()
    try {
        $original = @{ Mail = (Read-SettingsDocument -Path $script:MailConfigPath); Sms = (Read-SettingsDocument -Path $script:SmsConfigPath) }
    }
    catch {
        $script:Ui.txtSetMessage.Text = "Ayar dosyaları okunamadı: $($_.Exception.Message). Dosyayı Not Defteri ile açıp JSON hatasını düzeltin."
        $script:State.Settings = $null
        return
    }
    $fields = @(Get-SettingsFieldList)
    $script:State.Settings = @{ Window = $script:Window; Ui = $script:Ui; Fields = $fields; Controls = @{}; Original = $original; Dirty = $false }
    $c = $script:Ui
    foreach ($panelName in 'pnlSetSmtp', 'pnlSetOutsource', 'pnlSetLeave', 'pnlSetSmsService', 'pnlSetSmsPhone', 'pnlSetSmsMessages', 'pnlSetPassword') { $c[$panelName].Children.Clear() }
        $state = $script:State.Settings
        $c.txtSetInfo.Text = "Dosyalar: $script:MailConfigPath  |  $script:SmsConfigPath"
        $markDirty = { if ($script:State.Settings) { $script:State.Settings.Dirty = $true } }
        $panels = @{ Smtp = $c.pnlSetSmtp; Outsource = $c.pnlSetOutsource; Leave = $c.pnlSetLeave; SmsService = $c.pnlSetSmsService; SmsPhone = $c.pnlSetSmsPhone; SmsMessages = $c.pnlSetSmsMessages; Password = $c.pnlSetPassword }
        $labelStyle = $script:Window.TryFindResource('FieldLabel')
        $hintStyle = $script:Window.TryFindResource('HintText')
        foreach ($field in $fields) {
            $panel = $panels[$field.Tab]
            $value = Get-SettingsValue -Document $original[$field.File] -Path $field.Path
            if ($field.Type -ne 'Bool') {
                $label = New-Object -TypeName System.Windows.Controls.TextBlock
                $label.Text = $field.Label
                $label.Style = $labelStyle
                [void]$panel.Children.Add($label)
            }
            switch ($field.Type) {
                'Bool' {
                    $control = New-Object -TypeName System.Windows.Controls.CheckBox
                    $control.Content = $field.Label
                    $control.IsChecked = [bool]$value
                    $control.Add_Click($markDirty)
                }
                'Choice' {
                    $control = New-Object -TypeName System.Windows.Controls.ComboBox
                    foreach ($item in $field.Choices) { [void]$control.Items.Add($item) }
                    if ($value -and $field.Choices -notcontains [string]$value) { [void]$control.Items.Add([string]$value) }
                    $control.SelectedItem = if ($value) { [string]$value } else { $field.Choices[0] }
                    $control.Add_SelectionChanged($markDirty)
                }
                default {
                    $control = New-Object -TypeName System.Windows.Controls.TextBox
                    $control.Text = if ($field.Type -eq 'List') { (@($value | Where-Object { $_ }) -join '; ') } elseif ($null -ne $value) { [string]$value } else { '' }
                    if ($field.Type -eq 'Multiline') {
                        $control.AcceptsReturn = $true
                        $control.TextWrapping = 'Wrap'
                        $control.MinHeight = 70
                        $control.VerticalContentAlignment = 'Top'
                    }
                    $control.Add_TextChanged($markDirty)
                }
            }
            # Açıklama ait olduğu kutuya yapışık kalır; alanlar arası boşluk açıklamanın altında olur.
            $controlTop = if ($field.Type -eq 'Bool') { 6 } else { 0 }
            $control.Margin = [System.Windows.Thickness]::new(0, $controlTop, 0, $(if ($field.Hint) { 3 } else { 14 }))
            [System.Windows.Automation.AutomationProperties]::SetName($control, $field.Label)
            [void]$panel.Children.Add($control)
            if ($field.Hint) {
                $hint = New-Object -TypeName System.Windows.Controls.TextBlock
                $hint.Text = $field.Hint
                $hint.Style = $hintStyle
                $hint.TextWrapping = 'Wrap'
                $hint.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
                [void]$panel.Children.Add($hint)
            }
            $state.Controls[$field.Path + '|' + $field.File] = $control
        }
        $c.txtSetAttachments.Text = (@(Get-SettingsValue -Document $original.Mail -Path 'OutsourceMail.Attachments') | Where-Object { $_ }) -join "`r`n"
        $bodyFile = Resolve-AppPath -Path ([string](Get-SettingsValue -Document $original.Mail -Path 'OutsourceMail.BodyFile'))
        if (-not $bodyFile) { $bodyFile = Resolve-AppPath -Path 'Configs\outsource-mail.txt' }
        if ($bodyFile -and (Test-Path -LiteralPath $bodyFile)) { $c.txtSetBody.Text = Get-Content -LiteralPath $bodyFile -Raw -Encoding UTF8 }
        $state.Dirty = $false
}
function Start-DesktopShortcutInstall {
    [CmdletBinding()]
    param()
    try {
        $shortcutPath = Install-DesktopShortcut
        $script:Ui.txtSetMessage.Text = "Kısayol oluşturuldu: $shortcutPath"
        Write-UiLog -Message "Masaüstü kısayolu oluşturuldu: $shortcutPath" -Level Success
    }
    catch {
        $script:Ui.txtSetMessage.Text = "Kısayol oluşturulamadı: $($_.Exception.Message)"
        Write-UiLog -Message "Masaüstü kısayolu oluşturulamadı: $($_.Exception.Message)" -Level Error
    }
}
function Register-SettingsPageEvent {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $markDirty = { if ($script:State.Settings) { $script:State.Settings.Dirty = $true } }
    $c.btnSetShortcut.Add_Click({ Invoke-UiAction { Start-DesktopShortcutInstall } })
    $c.txtSetAttachments.Add_TextChanged($markDirty)
    $c.txtSetBody.Add_TextChanged($markDirty)
    $c.btnSetAttachAdd.Add_Click({
            Invoke-UiAction {
                $picker = New-Object -TypeName Microsoft.Win32.OpenFileDialog
                $picker.Filter = 'Tüm dosyalar (*.*)|*.*|PDF (*.pdf)|*.pdf'
                if (-not $picker.ShowDialog($script:Window)) { return }
                $folder = Join-Path -Path $script:AppRoot -ChildPath 'Ekler'
                if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force) }
                $target = Join-Path -Path $folder -ChildPath ([System.IO.Path]::GetFileName($picker.FileName))
                if (-not [string]::Equals($picker.FileName, $target, [System.StringComparison]::OrdinalIgnoreCase)) { Copy-Item -LiteralPath $picker.FileName -Destination $target -Force -ErrorAction Stop }
                $box = $script:State.Settings.Ui.txtSetAttachments
                $line = "Ekler\$([System.IO.Path]::GetFileName($picker.FileName))"
                $existing = @(([string]$box.Text) -split "`r?`n" | Where-Object { $_.Trim() })
                if ($existing -notcontains $line) { $box.Text = (@($existing) + $line) -join "`r`n" }
            }
        })
    $c.btnSetPreview.Add_Click({
            Invoke-UiAction {
                $file = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'ADIDM_OutsourceMail_Onizleme.html'
                [System.IO.File]::WriteAllText($file, (Get-SettingsPreviewHtml), (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true))
                Start-Process -FilePath $file
            }
        })
    $c.btnSetTestMail.Add_Click({ Invoke-UiAction { Start-SettingsTestMail } })
    $c.btnSetTestSms.Add_Click({ Invoke-UiAction { Start-SettingsTestSms } })
    $c.btnSetSave.Add_Click({ Invoke-UiAction { [void](Save-SettingsForm) } })
}
function Test-SettingsLeave {
    # Kaydedilmemiş ayar varsa sorar; sayfadan veya uygulamadan çıkılabilirse $true döner.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $settings = $script:State.Settings
    if (-not $settings -or -not $settings.Dirty) { return $true }
    $answer = [System.Windows.MessageBox]::Show($script:Window, 'Kaydedilmemiş ayar değişiklikleri var. Kaydedilsin mi?', 'Ayarlar', [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Question)
    if ($answer -eq [System.Windows.MessageBoxResult]::Cancel) { return $false }
    if ($answer -eq [System.Windows.MessageBoxResult]::Yes) { return [bool](Save-SettingsForm) }
    $settings.Dirty = $false
    return $true
}
