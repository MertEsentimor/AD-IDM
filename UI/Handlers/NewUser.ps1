function ConvertFrom-NewAdUserCommand {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $values = @{}
    $skipped = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $notes = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    $command = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and [string]::Equals($node.GetCommandName(), 'New-ADUser', [System.StringComparison]::OrdinalIgnoreCase) }, $true) | Select-Object -First 1
    if (-not $command) {
        $reason = if (@($parseErrors).Count -gt 0) { "Komut ayrıştırılamadı: $($parseErrors[0].Message)" } else { 'Metinde New-ADUser komutu bulunamadı.' }
        return [pscustomobject]@{ Values = $values; Skipped = @(); Notes = @(); Error = $reason }
    }
    $known = @($script:NewUserFieldMap.Keys) + @('Path', 'ChangePasswordAtLogon', 'Enabled', 'AccountPassword')
    $elements = $command.CommandElements
    for ($i = 1; $i -lt $elements.Count; $i++) {
        $element = $elements[$i]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
        $argument = $element.Argument
        if (-not $argument -and ($i + 1) -lt $elements.Count -and $elements[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            $i++
            $argument = $elements[$i]
        }
        $name = $known | Where-Object { [string]::Equals($_, $element.ParameterName, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if (-not $name) { $skipped.Add($element.ParameterName); continue }
        if ($name -eq 'AccountPassword') { $notes.Add('Parola güvenlik nedeniyle komuttan alınmaz; aşağıdaki parola alanına girin veya oluşturun.'); continue }
        $value = $null
        if ($null -eq $argument) { $value = $true }
        elseif ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $value = $argument.Value }
        elseif ($argument -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { $value = $argument.Value }
        elseif ($argument -is [System.Management.Automation.Language.ConstantExpressionAst]) { $value = $argument.Value }
        elseif ($argument -is [System.Management.Automation.Language.VariableExpressionAst] -and $argument.VariablePath.UserPath -in @('true', 'false')) { $value = $argument.VariablePath.UserPath -eq 'true' }
        else { $skipped.Add("$name (sabit olmayan değer)"); continue }
        $values[$name] = $value
    }
    return [pscustomobject]@{ Values = $values; Skipped = $skipped.ToArray(); Notes = $notes.ToArray(); Error = $null }
}
function Set-NewUserMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter()][ValidateSet('Info', 'Error', 'Success')][string]$Kind = 'Info'
    )
    $c = $script:State.NewUserDialog.Controls
    $c.txtNuMessage.Text = $Text
    $c.txtNuMessage.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(switch ($Kind) { 'Error' { 'DangerBrush' } 'Success' { 'SuccessBrush' } default { 'TextMutedBrush' } }))
}
function Import-NewUserCommand {
    [CmdletBinding()]
    param()
    $c = $script:State.NewUserDialog.Controls
    $parsed = ConvertFrom-NewAdUserCommand -Text ([string]$c.txtNuScript.Text)
    if ($parsed.Error) { Set-NewUserMessage -Text $parsed.Error -Kind Error; return }
    $filled = 0
    foreach ($key in $script:NewUserFieldMap.Keys) {
        if ($parsed.Values.ContainsKey($key)) { $c[$script:NewUserFieldMap[$key]].Text = [string]$parsed.Values[$key]; $filled++ }
    }
    if ($parsed.Values.ContainsKey('Path')) { $c.txtNuPath.Text = [string]$parsed.Values.Path; $filled++ }
    if ($parsed.Values.ContainsKey('ChangePasswordAtLogon')) { $c.chkNuMustChange.IsChecked = [bool]$parsed.Values.ChangePasswordAtLogon }
    if ($parsed.Values.ContainsKey('Enabled')) { $c.chkNuEnabled.IsChecked = [bool]$parsed.Values.Enabled }
    $message = "$filled alan komuttan dolduruldu."
    if ($parsed.Skipped.Count -gt 0) { $message += " Atlanan parametreler: $($parsed.Skipped -join ', ')." }
    if ($parsed.Notes.Count -gt 0) { $message += ' ' + ($parsed.Notes -join ' ') }
    Set-NewUserMessage -Text $message -Kind Success
    Write-UiLog -Message "Kullanıcı ekle: $message" -Level Info
}
function Clear-NewUserForm {
    [CmdletBinding()]
    param()
    $c = $script:State.NewUserDialog.Controls
    $c.txtNuScript.Text = ''
    foreach ($control in $script:NewUserFieldMap.Values) { $c[$control].Text = '' }
    $c.txtNuPath.Text = ''
    $c.pwdNu.Clear()
    $c.pwdNuConfirm.Clear()
    $c.txtNuGenerated.Text = ''
    $c.txtNuGenerated.Visibility = 'Collapsed'
    $c.btnNuCopy.Visibility = 'Collapsed'
    $c.chkNuMustChange.IsChecked = $true
    $c.chkNuEnabled.IsChecked = $true
    $c.chkNuOutsource.IsChecked = $false
    $outsource = $script:State.NewUserDialog.Outsource
    $c.txtNuOutsourceCc.Text = if ($outsource -and $outsource.Available) { (@($outsource.Section.Cc | Where-Object { $_ }) -join '; ') } else { '' }
    if ($script:State.NewUserDialog.UpdateOutsource) { & $script:State.NewUserDialog.UpdateOutsource }
    $script:State.NewUserDraft = $null
    Set-NewUserMessage -Text 'Form temizlendi.'
    [void]$c.txtNuScript.Focus()
}
function Save-NewUserDraft {
    [CmdletBinding()]
    param()
    $c = $script:State.NewUserDialog.Controls
    $values = @{}
    foreach ($key in $script:NewUserFieldMap.Keys) { $values[$key] = [string]$c[$script:NewUserFieldMap[$key]].Text }
    $script:State.NewUserDraft = @{
        Script     = [string]$c.txtNuScript.Text
        Values     = $values
        Path       = [string]$c.txtNuPath.Text
        MustChange = [bool]$c.chkNuMustChange.IsChecked
        Enabled    = [bool]$c.chkNuEnabled.IsChecked
        Outsource  = [bool]$c.chkNuOutsource.IsChecked
        OutsourceCc = [string]$c.txtNuOutsourceCc.Text
    }
}
function Restore-NewUserDraft {
    [CmdletBinding()]
    param()
    $draft = $script:State.NewUserDraft
    if (-not $draft) { return }
    $c = $script:State.NewUserDialog.Controls
    $c.txtNuScript.Text = $draft.Script
    foreach ($key in $script:NewUserFieldMap.Keys) { $c[$script:NewUserFieldMap[$key]].Text = [string]$draft.Values[$key] }
    $c.txtNuPath.Text = $draft.Path
    $c.chkNuMustChange.IsChecked = $draft.MustChange
    $c.chkNuEnabled.IsChecked = $draft.Enabled
    if ($draft.ContainsKey('Outsource')) {
        $c.chkNuOutsource.IsChecked = [bool]$draft.Outsource
        $c.txtNuOutsourceCc.Text = [string]$draft.OutsourceCc
    }
}
function Submit-NewUserForm {
    [CmdletBinding()]
    param()
    $dialogState = $script:State.NewUserDialog
    $c = $dialogState.Controls
    $values = @{}
    foreach ($key in $script:NewUserFieldMap.Keys) { $values[$key] = ([string]$c[$script:NewUserFieldMap[$key]].Text).Trim() }
    if (-not $values.Name -and ($values.GivenName -or $values.Surname)) {
        $values.Name = ("$($values.GivenName) $($values.Surname)").Trim()
        $c.txtNuName.Text = $values.Name
    }
    if (-not $values.DisplayName -and $values.Name) { $values.DisplayName = $values.Name; $c.txtNuDisplayName.Text = $values.Name }
    $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if (-not $values.Name) { $errors.Add('Name zorunlu.') }
    if (-not $values.SamAccountName) { $errors.Add('SamAccountName zorunlu.') }
    elseif ($values.SamAccountName.Length -gt 20) { $errors.Add('SamAccountName en fazla 20 karakter olabilir.') }
    elseif ($values.SamAccountName -match '["/\\\[\]:;|=,+*?<>@\s]') { $errors.Add('SamAccountName geçersiz karakter içeriyor.') }
    if ($values.UserPrincipalName -notmatch '^[^@\s]+@[^@\s]+$') { $errors.Add('UserPrincipalName "kullanici@sonek" biçiminde olmalı.') }
    if ($values.EmailAddress -and $values.EmailAddress -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $errors.Add('E-posta adresi geçerli değil.') }
    $useSms = [bool]$c.chkNuSms.IsChecked
    if ($useSms) {
        if (-not $values.MobilePhone) { $errors.Add('Parola SMS ile gönderileceği için cep telefonu (MobilePhone) zorunlu.') }
        elseif (($values.MobilePhone -replace '\D', '').Length -lt 10) { $errors.Add('Cep telefonu numarası eksik görünüyor.') }
    }
    elseif (-not $dialogState.AllowManual) { $errors.Add('Elle parola girişi kapalı (sms-config.json: AllowManualPassword = false); SMS seçeneğini açın.') }
    elseif ($c.pwdNu.SecurePassword.Length -eq 0) { $errors.Add('Parola zorunlu.') }
    elseif ($c.pwdNu.Password -cne $c.pwdNuConfirm.Password) { $errors.Add('Parolalar eşleşmiyor.') }
    $outsourceMail = $null
    if ([bool]$c.chkNuOutsource.IsChecked) {
        $mailTo = @(Split-MailAddressList -Text $values.EmailAddress)
        $mailCc = @(Split-MailAddressList -Text $c.txtNuOutsourceCc.Text)
        $badAddress = @(@($mailCc) | Where-Object { $_ -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' })
        if ($mailTo.Count -eq 0) { $errors.Add('Outsource bilgilendirme e-postası formdaki E-posta (EmailAddress) adresine gider; bu alan boş.') }
        elseif ($badAddress.Count -gt 0) { $errors.Add("Geçersiz e-posta adresi: $($badAddress -join ', ').") }
        elseif (-not $dialogState.Outsource.Available) { $errors.Add("Bilgilendirme e-postası gönderilemiyor: $($dialogState.Outsource.Reason).") }
        else { $outsourceMail = @{ To = [string[]]$mailTo; Cc = [string[]]$mailCc } }
    }
    if ($errors.Count -gt 0) { Set-NewUserMessage -Text ($errors -join ' ') -Kind Error; return }
    $ou = [string](@(Show-OuPicker -Owner $dialogState.Window -Selected ([string]$c.txtNuPath.Text).Trim() -UserText $values.Name) | Select-Object -First 1)
    if (-not $ou) { Set-NewUserMessage -Text 'OU seçilmedi; kullanıcı oluşturulmadı.'; return }
    $c.txtNuPath.Text = $ou
    $mailbox = @{ Create = $false; Database = '' }
    $mailboxText = 'Oluşturulmayacak (Exchange On-Premises bağlantısı yok)'
    if ($script:Sync.ExchangeMode -eq 'OnPremises') {
        $mailbox = Show-DatabasePicker -Owner $dialogState.Window -Databases $script:State.NewUserDatabases -UserText $values.Name -AllowSkip
        if (-not $mailbox) { Set-NewUserMessage -Text 'Veritabanı seçimi iptal edildi; kullanıcı oluşturulmadı.'; return }
        $mailboxText = if (-not $mailbox.Create) { 'Oluşturulmayacak' } elseif ($mailbox.Database) { "Oluşturulacak, veritabanı: $($mailbox.Database)" } else { 'Oluşturulacak, veritabanı: otomatik' }
    }
    $mustChange = [bool]$c.chkNuMustChange.IsChecked
    $enabled = [bool]$c.chkNuEnabled.IsChecked
    $lines = @("| Name: $($values.Name)", "| SamAccountName: $($values.SamAccountName)", "| UPN: $($values.UserPrincipalName)", "| OU: $ou",
        "| Etkin: $(if ($enabled) { 'Evet' } else { 'Hayır' })  |  İlk oturumda parola değiştirmeli: $(if ($mustChange) { 'Evet' } else { 'Hayır' })",
        "| Posta kutusu: $mailboxText",
        "| Parola: $(if ($useSms) { "rastgele oluşturulacak, size gösterilmeyecek; hoş geldiniz SMS'iyle $(Get-MaskedPhone -Number ($values.MobilePhone -replace '\D', '')) numarasına gönderilecek" } else { 'formda girilen parola' })")
    if ($outsourceMail) {
        $lines += "| Bilgilendirme e-postası: $($outsourceMail.To -join ', ')$(if ($outsourceMail.Cc.Count) { "  (CC: $($outsourceMail.Cc -join ', '))" }), $($dialogState.Outsource.Attachments.Count) ek"
        if (-not $useSms) { $lines += "| Uyarı: e-posta metni parolanın SMS ile gönderildiğini söylüyor, ancak SMS seçili değil." }
    }
    $text = "Aşağıdaki kullanıcı oluşturulacak:`n`n" + ($lines -join "`n")
    if (-not (Show-ConfirmDialog -Message $text -Title 'Kullanıcı Oluştur' -Owner $dialogState.Window)) { return }
    $secure = $null
    if (-not $useSms) {
        $secure = $c.pwdNu.SecurePassword.Copy()
        $secure.MakeReadOnly()
    }
    $attributes = @{}
    foreach ($key in $values.Keys) { if ($values[$key]) { $attributes[$key] = $values[$key] } }
    $dialogState.Result = @{ Mode = $(if ($useSms) { 'Sms' } else { 'Manual' }); Attributes = $attributes; Path = $ou; Password = $secure; MustChange = $mustChange; Enabled = $enabled; MailboxCreate = [bool]$mailbox.Create; MailboxDatabase = [string]$mailbox.Database; OutsourceMail = $outsourceMail }
    $dialogState.Window.DialogResult = $true
}
function Show-NewUserDialog {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][string]$Message)
    $dialog = New-MainWindow -Xaml $script:NewUserXaml
    $script:State.NewUserDialog = @{ Window = $dialog.Window; Controls = $dialog.Controls; Result = $null }
    try {
        $c = $dialog.Controls
        $dialog.Window.Owner = $script:Window
        $c.txtNuGenerated.IsReadOnly = $true
        Restore-NewUserDraft
        if ($Message) { Set-NewUserMessage -Text $Message -Kind Error }
        $sms = Get-SmsConfiguration
        $script:State.NewUserDialog.AllowManual = (-not $sms.Available) -or ($sms.Config.AllowManualPassword -ne $false)
        $c.chkNuSms.IsChecked = [bool]$sms.Available
        $c.chkNuSms.IsEnabled = $sms.Available -and $script:State.NewUserDialog.AllowManual
        $c.txtNuSmsInfo.Text = if (-not $sms.Available) { "SMS servisi kullanılamıyor: $($sms.Reason)" }
        else { "Rastgele $(if ($sms.Config.PasswordLength) { $sms.Config.PasswordLength } else { 14 }) karakterlik parola oluşturulur; kimse görmeden, 'Cep telefonu' alanındaki numaraya hoş geldiniz mesajı ve kullanıcı bilgileriyle gönderilir ($($sms.Config.Provider))." }
        $script:State.NewUserDialog.UpdateMode = {
            $dc = $script:State.NewUserDialog.Controls
            $useSms = [bool]$dc.chkNuSms.IsChecked
            $dc.pnlNuManual.Visibility = if ($useSms) { 'Collapsed' } else { 'Visible' }
            $dc.btnNuCreate.Content = if ($useSms) { 'Oluştur ve SMS Gönder' } else { 'Kullanıcı Oluştur' }
            if ($useSms) { $dc.chkNuMustChange.IsChecked = $true }
        }
        & $script:State.NewUserDialog.UpdateMode
        $c.chkNuSms.Add_Click({ Invoke-UiAction { & $script:State.NewUserDialog.UpdateMode } })
        $outsource = Get-OutsourceMailConfiguration
        $script:State.NewUserDialog.Outsource = $outsource
        $c.chkNuOutsource.IsEnabled = [bool]$outsource.Available
        if (-not $outsource.Available) { $c.chkNuOutsource.IsChecked = $false }
        $c.txtNuOutsourceInfo.Text = if (-not $outsource.Available) { "Kullanılamıyor: $($outsource.Reason)" }
        else { "Kullanıcı oluşturulunca kurulum yönergeleri (AD Self Service, SSL VPN) formdaki E-posta adresine gönderilir. Parola e-postada yer almaz, SMS ile gider." }
        if ($outsource.Available) {
            if (-not ([string]$c.txtNuOutsourceCc.Text).Trim()) { $c.txtNuOutsourceCc.Text = (@($outsource.Section.Cc | Where-Object { $_ }) -join '; ') }
            $c.txtNuOutsourceAttach.Text = if ($outsource.Attachments.Count) { "Ek: " + (@($outsource.Attachments | ForEach-Object { Split-Path -Path $_ -Leaf }) -join ', ') + "  |  Metin: $(Split-Path -Path $outsource.BodyFile -Leaf)" } else { "Ek yok  |  Metin: $(Split-Path -Path $outsource.BodyFile -Leaf)" }
        }
        $script:State.NewUserDialog.UpdateOutsource = {
            $dc = $script:State.NewUserDialog.Controls
            $dc.pnlNuOutsource.Visibility = if ([bool]$dc.chkNuOutsource.IsChecked) { 'Visible' } else { 'Collapsed' }
            $address = ([string]$dc.txtNuEmail.Text).Trim()
            $dc.txtNuOutsourceTo.Text = if ($address) { "Alıcı: $address (formdaki E-posta alanı)" } else { "Alıcı: formdaki E-posta (EmailAddress) alanı - henüz boş" }
        }
        $c.txtNuEmail.Add_TextChanged({ Invoke-UiAction { if ($script:State.NewUserDialog -and $script:State.NewUserDialog.UpdateOutsource) { & $script:State.NewUserDialog.UpdateOutsource } } })
        & $script:State.NewUserDialog.UpdateOutsource
        $c.chkNuOutsource.Add_Click({ Invoke-UiAction { & $script:State.NewUserDialog.UpdateOutsource } })
        $c.btnNuParse.Add_Click({ Invoke-UiAction { Import-NewUserCommand } })
        $c.btnNuClear.Add_Click({ Invoke-UiAction { Clear-NewUserForm } })
        $c.btnNuCreate.Add_Click({ Invoke-UiAction { Submit-NewUserForm } })
        $c.btnNuGenerate.Add_Click({
                Invoke-UiAction {
                    $dc = $script:State.NewUserDialog.Controls
                    $generated = New-RandomPassword -Length 16
                    $dc.pwdNu.Password = $generated
                    $dc.pwdNuConfirm.Password = $generated
                    $dc.txtNuGenerated.Text = $generated
                    $dc.txtNuGenerated.Visibility = 'Visible'
                    $dc.btnNuCopy.Visibility = 'Visible'
                }
            })
        $c.btnNuCopy.Add_Click({ Invoke-UiAction { [System.Windows.Clipboard]::SetText([string]$script:State.NewUserDialog.Controls.txtNuGenerated.Text) } })
        $dialog.Window.Add_Closing({ Invoke-UiAction { Save-NewUserDraft } })
        $dialog.Window.Add_ContentRendered({ [void]$script:State.NewUserDialog.Controls.txtNuScript.Focus() })
        [void]$dialog.Window.ShowDialog()
        return $script:State.NewUserDialog.Result
    }
    finally {
        $c = $script:State.NewUserDialog.Controls
        if ($c) { $c.pwdNu.Clear(); $c.pwdNuConfirm.Clear(); $c.txtNuGenerated.Text = '' }
        $script:State.NewUserDialog = $null
    }
}
function Start-NewUserCreation {
    [CmdletBinding()]
    param()
    if (-not (Confirm-DiscardChange)) { return }
    [void](Invoke-BackgroundTask -Name 'OU ve veritabanı listeleri okunuyor' -Command 'Get-NewUserContext' -OnSuccess {
            param($Result)
            $script:State.OuList = @($Result.OuList | Where-Object { $_ })
            $script:State.NewUserDatabases = @($Result.Databases | Where-Object { $_ })
            Invoke-Deferred { Open-NewUserDialog }
        })
}
function Open-NewUserDialog {
    [CmdletBinding()]
    param([Parameter()][string]$Message)
    $request = Show-NewUserDialog -Message $Message
    if (-not $request) { return }
    $smsArguments = @{}
    if ($request.Mode -eq 'Sms') {
        $sms = Get-SmsConfiguration
        if (-not $sms.Available) { [void](Show-MessageDialog -Message "SMS servisi kullanılamıyor: $($sms.Reason)" -Icon Warning); return }
        try { $secrets = Resolve-SmsSecret -Config $sms.Config }
        catch { [void](Show-MessageDialog -Message "SMS servisinin gizli bilgileri okunamadı; kullanıcı oluşturulmadı.`n`n$($_.Exception.Message)" -Icon Error); return }
        $environment = $script:State.Environment
        $values = @{
            DisplayName = ''; GivenName = ''; Surname = ''; SamAccountName = ''; UserPrincipalName = ''; EmailAddress = ''; Company = ''; Department = ''; Title = ''; Office = ''
            Domain    = if ($environment) { [string]$environment.NetBiosName } else { [string]$env:USERDOMAIN }
            DomainDns = if ($environment) { [string]$environment.DomainName } else { [string]$env:USERDNSDOMAIN }
        }
        foreach ($key in $request.Attributes.Keys) { $values[$key] = [string]$request.Attributes[$key] }
        if (-not $values.DisplayName) { $values.DisplayName = [string]$request.Attributes.Name }
        $smsArguments = @{ Sms = $sms.Config; SmsSecrets = $secrets; SmsValues = $values }
    }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf; Sam = $request.Attributes.SamAccountName }
    $arguments = Get-ActionArgument @{
        Attributes            = $request.Attributes
        Path                  = $request.Path
        ChangePasswordAtLogon = [bool]$request.MustChange
        Enabled               = [bool]$request.Enabled
        CreateMailbox         = [bool]$request.MailboxCreate
        MailboxDatabase       = [string]$request.MailboxDatabase
    }
    if ($request.Mode -eq 'Sms') { foreach ($key in $smsArguments.Keys) { $arguments[$key] = $smsArguments[$key] } }
    else { $arguments.AccountPassword = $request.Password }
    if ($request.OutsourceMail) {
        $outsource = Get-OutsourceMailConfiguration
        if (-not $outsource.Available) { [void](Show-MessageDialog -Message "Bilgilendirme e-postası gönderilemiyor: $($outsource.Reason)`n`nKullanıcı oluşturulmadı." -Icon Warning); return }
        $environment = $script:State.Environment
        $mailValues = @{
            SamAccountName = [string]$request.Attributes.SamAccountName; UserPrincipalName = [string]$request.Attributes.UserPrincipalName
            DisplayName = $(if ($request.Attributes.DisplayName) { [string]$request.Attributes.DisplayName } else { [string]$request.Attributes.Name })
            GivenName = [string]$request.Attributes.GivenName; Surname = [string]$request.Attributes.Surname; EmailAddress = [string]$request.Attributes.EmailAddress
            Domain = $(if ($environment) { [string]$environment.NetBiosName } else { [string]$env:USERDOMAIN })
            DomainDns = $(if ($environment) { [string]$environment.DomainName } else { [string]$env:USERDNSDOMAIN })
        }
        try { $html = ConvertTo-WelcomeMailHtml -Path $outsource.BodyFile -Values $mailValues }
        catch { [void](Show-MessageDialog -Message "E-posta metni okunamadı ($($outsource.BodyFile)): $($_.Exception.Message)`n`nKullanıcı oluşturulmadı." -Icon Error); return }
        $config = $outsource.Config
        $section = $outsource.Section
        $credentialFile = if ($config.CredentialFile) { [string]$config.CredentialFile } else { 'Secrets\smtp-credential.xml' }
        if (-not [System.IO.Path]::IsPathRooted($credentialFile)) { $credentialFile = Join-Path -Path $script:AppRoot -ChildPath $credentialFile }
        $arguments.WelcomeMail = @{
            SmtpServer = [string]$config.SmtpServer; Port = $(if ($config.Port) { [int]$config.Port } else { 25 }); UseSsl = [bool]$config.UseSsl
            Authentication = [string]$config.Authentication; CredentialFile = $credentialFile
            From = $(if ($section.From) { [string]$section.From } else { [string]$config.From })
            FromName = $(if ($section.FromName) { [string]$section.FromName } elseif ($config.FromName) { [string]$config.FromName } else { '' })
            To = [string[]]$request.OutsourceMail.To; Cc = [string[]]$request.OutsourceMail.Cc
            Subject = Expand-MailTemplate -Template $(if ($section.Subject) { [string]$section.Subject } else { 'Kullanıcınız hazır: {{SamAccountName}}' }) -Values $mailValues
            Html = $html; Attachments = [string[]]@($outsource.Attachments)
        }
    }
    Write-UiLog -Message "Kullanıcı oluşturma isteği: $($request.Attributes.SamAccountName) -> $($request.Path)" -Level Info
    [void](Invoke-BackgroundTask -Name "Kullanıcı oluşturuluyor: $($request.Attributes.SamAccountName)" -Command 'New-DirectoryUser' -Arguments $arguments -OnSuccess {
            param($Result)
            Complete-NewUser -Result $Result
        } -OnFailure {
            param($Message)
            $hint = ''
            if ($Message -match 'password does not meet|complexity|length|history') { $hint = ' Parola, etki alanı parola politikasını karşılamıyor.' }
            elseif ($Message -match 'Access is denied|Erişim engellendi') { $hint = ' Seçilen OU''da kullanıcı oluşturma yetkiniz yok.' }
            Write-UiLog -Message "Kullanıcı oluşturulamadı: $Message" -Level Error
            $script:State.NewUserError = "Kullanıcı oluşturulamadı: $Message$hint"
            Invoke-Deferred { Open-NewUserDialog -Message $script:State.NewUserError }
        })
}
function Complete-NewUser {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Result)
    if ($script:State.ActionContext.Simulate) {
        [void](Show-MessageDialog -Message 'Kullanıcı oluşturma simüle edildi. Hiçbir değişiklik yapılmadı; komut günlükte listelendi.' -Icon Information)
        return
    }
    $created = @($Result | Where-Object { $_ -and $_.PSObject.Properties['ObjectGuid'] }) | Select-Object -First 1
    if (-not $created) { return }
    $script:State.NewUserDraft = $null
    if ($created.Sms) {
        [void](Write-AuditEvent -Action 'user.create.sms' -Result $(if ($created.Sms.Success) { 'success' } else { 'failure' }) -Fields ([ordered]@{
                    target_user = [string]$script:State.ActionContext.Sam; target_guid = [string]$created.ObjectGuid; target_dn = [string]$created.DistinguishedName
                    sms_to = [string]$created.Sms.To; sms_provider = [string]$created.Sms.Provider; sms_status = $created.Sms.Status; message = [string]$created.Sms.Detail
                }))
    }
    $mailSent = $created.PSObject.Properties['Mail'] -and $created.Mail
    if ($mailSent) {
        [void](Write-AuditEvent -Action 'user.create.mail' -Result $(if ($created.Mail.Success) { 'success' } else { 'failure' }) -Fields ([ordered]@{
                    target_user = [string]$script:State.ActionContext.Sam; target_guid = [string]$created.ObjectGuid; target_dn = [string]$created.DistinguishedName
                    mail_to = [string]$created.Mail.To; mail_cc = [string]$created.Mail.Cc; mail_subject = [string]$created.Mail.Subject; message = [string]$created.Mail.Detail
                }))
    }
    if ($created.Warning) { [void](Show-MessageDialog -Message $created.Warning -Icon Warning) }
    else {
        Write-UiLog -Message "Yeni kullanıcı oluşturuldu: $($created.DistinguishedName)" -Level Success
        $notes = @()
        if ($created.Sms -and $created.Sms.Success) { $notes += "Parola size gösterilmeden hoş geldiniz SMS'iyle $($created.Sms.To) numarasına gönderildi." }
        if ($mailSent -and $created.Mail.Success) { $notes += "Bilgilendirme e-postası $($created.Mail.To) adresine gönderildi$(if ($created.Mail.Cc) { " (CC: $($created.Mail.Cc))" })." }
        if ($notes.Count -gt 0) { [void](Show-MessageDialog -Message ("Kullanıcı oluşturuldu.`n`n" + ($notes -join "`n"))) }
    }
    $script:Ui.txtSearch.Text = [string]$script:State.ActionContext.Sam
    Complete-ChangeCycle -ObjectGuid $created.ObjectGuid
}
