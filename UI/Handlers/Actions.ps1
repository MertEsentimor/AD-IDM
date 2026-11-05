function Confirm-Action {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter()][string]$Title = 'İşlemi Onayla',
        [Parameter()][System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Question
    )
    $warning = $Icon -eq [System.Windows.MessageBoxImage]::Warning
    if (-not (Show-ConfirmDialog -Message $Message -Title $Title -Warning:$warning)) {
        Write-UiLog -Message 'İşlem kullanıcı tarafından iptal edildi.' -Level Info
        return $false
    }
    return $true
}
function Get-ActionArgument {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][hashtable]$Arguments = @{})
    $result = @{ Confirm = $false }
    foreach ($key in $Arguments.Keys) { $result[$key] = $Arguments[$key] }
    if ($script:State.Options.WhatIf) { $result.WhatIf = $true }
    return $result
}
function Complete-SingleAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter()][AllowNull()][object]$Results,
        [Parameter()][bool]$Simulated
    )
    $items = @($Results | Where-Object { $_ -and $_.PSObject.Properties['Step'] })
    $failed = @($items | Where-Object { -not $_.Success })
    foreach ($item in $items) { Write-UiLog -Message ("{0}: {1}" -f $item.Step, $item.Message) -Level $(if ($item.Success) { 'Success' } else { 'Error' }) }
    if ($Simulated) {
        [void](Show-MessageDialog -Message "$Title simüle edildi. Hiçbir değişiklik yapılmadı; yapılacak işlem günlükte listelendi." -Icon Information)
        return
    }
    if ($failed.Count -gt 0) {
        $lines = $failed | ForEach-Object { "| $($_.Step): $($_.Message)" }
        [void](Show-MessageDialog -Message ("$Title kısmen başarısız oldu:`n`n" + ($lines -join "`n")) -Icon Warning)
    }
    else {
        Write-UiLog -Message "$Title tamamlandı." -Level Success
    }
    if ($script:State.CurrentData) { Complete-ChangeCycle -ObjectGuid $script:State.CurrentData.Ad.ObjectGuid }
}
function Test-ActionBlockedByChange {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($script:State.PendingCount -le 0) { return $false }
    $answer = Show-MessageDialog -Message "Kaydedilmemiş $($script:State.PendingCount) değişiklik var. İşlem sonrası kullanıcı yeniden yükleneceği için bu değişiklikler kaybolacak.`n`nÖnce sepeti uygulamanız önerilir. Yine de devam edilsin mi?" -Button YesNo -Icon Warning
    return ($answer -ne [System.Windows.MessageBoxResult]::Yes)
}
function Start-UnlockAccount {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data -or -not $data.Ad.LockedOut) { return }
    if (Test-ActionBlockedByChange) { return }
    if (-not (Confirm-Action -Message "'$($data.Ad.SamAccountName)' hesabının kilidi açılacak (PDC Emulator üzerinde Unlock-ADAccount).")) { return }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf }
    [void](Invoke-BackgroundTask -Name 'Hesap kilidi açılıyor' -Command 'Unlock-UserAccount' -Arguments (Get-ActionArgument @{ Identity = $data.Ad.ObjectGuid }) -OnSuccess {
            param($Result)
            Complete-SingleAction -Title 'Hesap kilidini açma' -Results $null -Simulated $script:State.ActionContext.Simulate
        })
}
function New-RandomPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][ValidateRange(12, 64)][int]$Length = 16)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#$%*+-=?@_')
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $buffer = New-Object -TypeName byte[] -ArgumentList 4
        $next = {
            param([int]$Max)
            $rng.GetBytes($buffer)
            return [int]([BitConverter]::ToUInt32($buffer, 0) % [uint32]$Max)
        }
        $chars = New-Object -TypeName 'System.Collections.Generic.List[char]'
        foreach ($set in $sets) { $chars.Add($set[(& $next $set.Length)]) }
        while ($chars.Count -lt $Length) { $chars.Add($all[(& $next $all.Length)]) }
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = & $next ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        return -join $chars
    }
    finally {
        $rng.Dispose()
    }
}
function Show-PasswordResetDialog {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][psobject]$Data)
    $dialog = New-MainWindow -Xaml $script:PasswordXaml
    $script:State.PasswordDialog = @{ Window = $dialog.Window; Controls = $dialog.Controls; Result = $null }
    try {
        $controls = $dialog.Controls
        $dialog.Window.Owner = $script:Window
        $ad = $Data.Ad
        $controls.txtPwdUser.Text = "$($ad.DisplayName)  |  $($ad.SamAccountName)"
        $sms = Get-SmsConfiguration
        $allowManual = (-not $sms.Available) -or ($sms.Config.AllowManualPassword -ne $false)
        $phoneText = if ($ad.MobilePhone) { Get-MaskedPhone -Number (($ad.MobilePhone -replace '\D', '')) } else { $null }
        $smsReady = $sms.Available -and ($phoneText -or ($sms.Config.PhoneAttribute -and $sms.Config.PhoneAttribute -ne 'mobile'))
        $script:State.PasswordDialog.SmsReady = $smsReady
        $controls.chkPwdSms.IsChecked = [bool]$smsReady
        $controls.chkPwdSms.IsEnabled = $smsReady -and $allowManual
        $controls.txtPwdSmsInfo.Text = if (-not $sms.Available) { "SMS servisi kullanılamıyor: $($sms.Reason)" }
        elseif (-not $smsReady) { "Kullanıcının cep telefonu (Mobile Phone) boş; SMS gönderilemez." }
        else { "Rastgele $(if ($sms.Config.PasswordLength) { $sms.Config.PasswordLength } else { 14 }) karakterlik parola oluşturulur ve kimse görmeden $phoneText numarasına gönderilir ($($sms.Config.Provider))." }
        $script:State.PasswordDialog.AllowManual = $allowManual
        $updateMode = {
            $state = $script:State.PasswordDialog
            $c = $state.Controls
            $useSms = [bool]$c.chkPwdSms.IsChecked
            $c.pnlPwdManual.Visibility = if ($useSms) { 'Collapsed' } else { 'Visible' }
            $c.btnPwdOk.IsEnabled = $useSms -or $state.AllowManual
            $c.btnPwdOk.Content = if ($useSms) { 'Sıfırla ve SMS Gönder' } else { 'Parolayı Sıfırla' }
            if ($useSms -and $c.chkMustChange.IsEnabled) { $c.chkMustChange.IsChecked = $true }
            if (-not $useSms -and -not $state.AllowManual) {
                $c.txtPwdError.Text = 'Elle parola girişi kapalı (sms-config.json: AllowManualPassword = false).'
                $c.txtPwdError.Visibility = 'Visible'
            }
        }
        $script:State.PasswordDialog.UpdateMode = $updateMode
        $controls.chkPwdSms.Add_Click({ Invoke-UiAction { & $script:State.PasswordDialog.UpdateMode } })
        if ($ad.LockedOut) {
            $controls.chkPwdUnlock.IsChecked = $true
            $controls.chkPwdUnlock.Content = 'Hesap kilitli: sıfırlama sırasında kilidini aç'
        }
        else {
            $controls.chkPwdUnlock.IsChecked = $false
            $controls.chkPwdUnlock.IsEnabled = $false
            $controls.chkPwdUnlock.Content = 'Hesap kilitli değil (kilit açma gerekmiyor)'
        }
        $notes = @('Parola PDC Emulator üzerinde sıfırlanır; etki alanı parola politikası (uzunluk, karmaşıklık, geçmiş) uygulanır.')
        if ($ad.PasswordNeverExpires) {
            $controls.chkMustChange.IsChecked = $false
            $controls.chkMustChange.IsEnabled = $false
            $notes += 'Hesapta "Parola süresiz" (PasswordNeverExpires) etkin olduğu için "bir sonraki oturumda değiştir" ayarlanamaz.'
        }
        $controls.txtPwdNote.Text = $notes -join ' '
        & $updateMode
        $controls.btnPwdOk.Add_Click({
                Invoke-UiAction {
                    $c = $script:State.PasswordDialog.Controls
                    if ([bool]$c.chkPwdSms.IsChecked) {
                        $script:State.PasswordDialog.Result = @{ Mode = 'Sms'; MustChange = [bool]$c.chkMustChange.IsChecked; Unlock = [bool]$c.chkPwdUnlock.IsChecked }
                        $script:State.PasswordDialog.Window.DialogResult = $true
                        return
                    }
                    $message = $null
                    if ($c.pwdNew.SecurePassword.Length -eq 0) { $message = 'Lütfen yeni parolayı girin.' }
                    elseif ($c.pwdNew.Password -cne $c.pwdConfirm.Password) { $message = 'Parolalar eşleşmiyor.' }
                    elseif ($c.pwdNew.SecurePassword.Length -lt 8) { $message = 'Parola en az 8 karakter olmalıdır (etki alanı politikası daha uzun isteyebilir).' }
                    if ($message) {
                        $c.txtPwdError.Text = $message
                        $c.txtPwdError.Visibility = 'Visible'
                        return
                    }
                    $secure = $c.pwdNew.SecurePassword.Copy()
                    $secure.MakeReadOnly()
                    $script:State.PasswordDialog.Result = @{
                        Mode       = 'Manual'
                        Password   = $secure
                        MustChange = [bool]$c.chkMustChange.IsChecked
                        Unlock     = [bool]$c.chkPwdUnlock.IsChecked
                    }
                    $script:State.PasswordDialog.Window.DialogResult = $true
                }
            })
        $dialog.Window.Add_ContentRendered({ $c = $script:State.PasswordDialog.Controls; if (-not $c.chkPwdSms.IsChecked) { [void]$c.pwdNew.Focus() } })
        [void]$dialog.Window.ShowDialog()
        return $script:State.PasswordDialog.Result
    }
    finally {
        $controls = $script:State.PasswordDialog.Controls
        if ($controls) { $controls.pwdNew.Clear(); $controls.pwdConfirm.Clear() }
        $script:State.PasswordDialog = $null
    }
}
function Start-PasswordReset {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data) { return }
    if (Test-ActionBlockedByChange) { return }
    $request = Show-PasswordResetDialog -Data $data
    if (-not $request) { Write-UiLog -Message 'Parola sıfırlama iptal edildi.' -Level Info; return }
    $options = @()
    if ($request.MustChange) { $options += 'bir sonraki oturumda parola değiştirilmeli' }
    if ($request.Unlock) { $options += 'hesap kilidi açılacak' }
    $optionText = if ($options.Count -gt 0) { "`n`nEk işlemler: $($options -join ', ')." } else { '' }
    $smsArguments = @{}
    $smsText = ''
    if ($request.Mode -eq 'Sms') {
        $sms = Get-SmsConfiguration
        if (-not $sms.Available) { [void](Show-MessageDialog -Message "SMS servisi kullanılamıyor: $($sms.Reason)" -Icon Warning); return }
        try { $secrets = Resolve-SmsSecret -Config $sms.Config }
        catch { [void](Show-MessageDialog -Message "SMS servisinin gizli bilgileri okunamadı; parola değiştirilmedi.`n`n$($_.Exception.Message)" -Icon Error); return }
        $environment = $script:State.Environment
        $smsArguments = @{
            Sms        = $sms.Config
            SmsSecrets = $secrets
            SmsValues  = @{
                DisplayName       = [string]$data.Ad.DisplayName
                GivenName         = [string]$data.Ad.GivenName
                Surname           = [string]$data.Ad.Surname
                SamAccountName    = [string]$data.Ad.SamAccountName
                UserPrincipalName = [string]$data.Ad.UserPrincipalName
                Domain            = if ($environment) { [string]$environment.NetBiosName } else { [string]$env:USERDOMAIN }
                DomainDns         = if ($environment) { [string]$environment.DomainName } else { [string]$env:USERDNSDOMAIN }
            }
        }
        $smsText = " Yeni parola rastgele oluşturulacak, size gösterilmeyecek ve kullanıcının cep telefonuna SMS ile gönderilecek ($($sms.Config.Provider))."
    }
    if (-not (Confirm-Action -Message "'$($data.Ad.SamAccountName)' kullanıcısının parolası sıfırlanacak.$smsText$optionText" -Icon Warning)) { return }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf }
    $arguments = Get-ActionArgument @{
        Identity              = $data.Ad.ObjectGuid
        ChangePasswordAtLogon = [bool]$request.MustChange
        Unlock                = [bool]$request.Unlock
    }
    if ($request.Mode -eq 'Sms') { foreach ($key in $smsArguments.Keys) { $arguments[$key] = $smsArguments[$key] } }
    else { $arguments.NewPassword = $request.Password }
    Write-UiLog -Message "Parola sıfırlama isteği: $($data.Ad.SamAccountName) (Yöntem=$(if ($request.Mode -eq 'Sms') { 'SMS' } else { 'elle' }), ChangePasswordAtLogon=$($request.MustChange), Unlock=$($request.Unlock))" -Level Info
    [void](Invoke-BackgroundTask -Name 'Parola sıfırlanıyor' -Command 'Reset-UserPassword' -Arguments $arguments -OnSuccess {
            param($Result)
            Complete-SingleAction -Title 'Parola sıfırlama' -Results $Result -Simulated $script:State.ActionContext.Simulate
        } -OnFailure {
            param($Message)
            $hint = ''
            if ($Message -match 'password does not meet|complexity|length|history|parola gereksinim') { $hint = "`n`nParola, etki alanı parola politikasını karşılamıyor (uzunluk, karmaşıklık veya geçmiş)." }
            elseif ($Message -match 'Access is denied|Erişim engellendi|insufficient') { $hint = "`n`nHesabınızın bu kullanıcı için 'Reset password' yetkisi yok." }
            [void](Show-MessageDialog -Message "Parola sıfırlanamadı:`n`n$Message$hint" -Icon Error)
        })
}
function ConvertTo-SquareJpeg {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory = $true)][System.Windows.Media.Imaging.BitmapSource]$Source,
        [Parameter(Mandatory = $true)][int]$Size,
        [Parameter(Mandatory = $true)][int]$MaxBytes
    )
    $side = [math]::Min($Source.PixelWidth, $Source.PixelHeight)
    $rect = New-Object -TypeName System.Windows.Int32Rect -ArgumentList ([int](($Source.PixelWidth - $side) / 2)), ([int](($Source.PixelHeight - $side) / 2)), $side, $side
    $cropped = New-Object -TypeName System.Windows.Media.Imaging.CroppedBitmap -ArgumentList $Source, $rect
    $scale = [math]::Min(1.0, $Size / [double]$side)
    $scaled = New-Object -TypeName System.Windows.Media.Imaging.TransformedBitmap -ArgumentList $cropped, (New-Object -TypeName System.Windows.Media.ScaleTransform -ArgumentList $scale, $scale)
    $bytes = $null
    foreach ($quality in 92, 85, 75, 65, 55, 45, 35) {
        $encoder = New-Object -TypeName System.Windows.Media.Imaging.JpegBitmapEncoder
        $encoder.QualityLevel = $quality
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($scaled))
        $stream = New-Object -TypeName System.IO.MemoryStream
        try {
            $encoder.Save($stream)
            $bytes = $stream.ToArray()
        }
        finally {
            $stream.Dispose()
        }
        if ($bytes.Length -le $MaxBytes) { break }
    }
    return , $bytes
}
function Start-PhotoChange {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data) { return }
    $dialog = New-Object -TypeName Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Kullanıcı fotoğrafı seçin'
    $dialog.Filter = 'Resim dosyaları (*.jpg;*.jpeg;*.png;*.bmp)|*.jpg;*.jpeg;*.png;*.bmp'
    if (-not $dialog.ShowDialog($script:Window)) { return }
    if (Test-ActionBlockedByChange) { return }
    try {
        $image = New-Object -TypeName System.Windows.Media.Imaging.BitmapImage
        $image.BeginInit()
        $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $image.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreColorProfile
        $image.UriSource = New-Object -TypeName System.Uri -ArgumentList $dialog.FileName
        $image.EndInit()
        $image.Freeze()
        $thumbnail = ConvertTo-SquareJpeg -Source $image -Size 96 -MaxBytes 10KB
        $large = ConvertTo-SquareJpeg -Source $image -Size 648 -MaxBytes 240KB
    }
    catch {
        [void](Show-MessageDialog -Message "Resim okunamadı:`n`n$($_.Exception.Message)" -Icon Error)
        return
    }
    $exchange = $data.Exchange
    $useExchange = $exchange.HasMailbox -and $exchange.Identity -and ($exchange.Mode -ne 'None') -and ($exchange.Mode -eq $script:Sync.ExchangeMode) -and ($exchange.AddressSource -eq 'Mailbox')
    $targets = "| AD thumbnailPhoto: 96x96, $([math]::Round($thumbnail.Length / 1KB, 1)) KB"
    if ($useExchange) { $targets += "`n| Exchange posta kutusu (Set-UserPhoto): $($image.PixelWidth)x$($image.PixelHeight) -> en fazla 648x648, $([math]::Round($large.Length / 1KB, 1)) KB" }
    else { $targets += "`n| Exchange posta kutusu: atlanacak (bu bağlantıda posta kutusu yok)" }
    if (-not (Confirm-Action -Message "'$($data.Ad.SamAccountName)' kullanıcısının fotoğrafı değiştirilecek. Resim ortadan kare kırpılır.`n`n$targets")) { return }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf }
    $arguments = Get-ActionArgument @{ ObjectGuid = $data.Ad.ObjectGuid; ThumbnailBytes = $thumbnail; ExchangeBytes = $large }
    if ($useExchange) { $arguments.ExchangeIdentity = [string]$exchange.Identity }
    [void](Invoke-BackgroundTask -Name 'Kullanıcı fotoğrafı güncelleniyor' -Command 'Set-UserPhotoData' -Arguments $arguments -OnSuccess {
            param($Result)
            Complete-SingleAction -Title 'Fotoğraf güncelleme' -Results $Result -Simulated $script:State.ActionContext.Simulate
        })
}
function Start-PhotoRemove {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data -or -not $data.Photo.Bytes) { return }
    if (Test-ActionBlockedByChange) { return }
    $exchange = $data.Exchange
    $useExchange = $exchange.HasMailbox -and $exchange.Identity -and ($exchange.Mode -ne 'None') -and ($exchange.Mode -eq $script:Sync.ExchangeMode) -and ($exchange.AddressSource -eq 'Mailbox')
    $scope = if ($useExchange) { 'AD thumbnailPhoto ve Exchange posta kutusu' } else { 'AD thumbnailPhoto' }
    if (-not (Confirm-Action -Message "'$($data.Ad.SamAccountName)' kullanıcısının fotoğrafı kaldırılacak ($scope)." -Icon Warning)) { return }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf }
    $arguments = Get-ActionArgument @{ ObjectGuid = $data.Ad.ObjectGuid; Remove = $true }
    if ($useExchange) { $arguments.ExchangeIdentity = [string]$exchange.Identity }
    [void](Invoke-BackgroundTask -Name 'Kullanıcı fotoğrafı kaldırılıyor' -Command 'Set-UserPhotoData' -Arguments $arguments -OnSuccess {
            param($Result)
            Complete-SingleAction -Title 'Fotoğraf kaldırma' -Results $Result -Simulated $script:State.ActionContext.Simulate
        })
}
function Complete-ChangeCycle {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ObjectGuid)
    if ($script:State.Options.Replicate -and -not $script:State.Options.WhatIf) {
        Start-AdReplication -ReloadObjectGuid $ObjectGuid
        return
    }
    Start-UserLoad -ObjectGuid $ObjectGuid -Force
}
function Start-AdReplication {
    [CmdletBinding()]
    param([Parameter()][string]$ReloadObjectGuid)
    $script:State.ReplicationReload = $ReloadObjectGuid
    $arguments = @{}
    [void](Invoke-BackgroundTask -Name 'AD replikasyonu (repadmin /syncall /APed)' -Command 'Invoke-AdReplication' -Arguments $arguments -OnSuccess {
            param($Result)
            if ($script:State.ReplicationReload) { Start-UserLoad -ObjectGuid $script:State.ReplicationReload -Force }
        } -OnFailure {
            param($Message)
            Write-UiLog -Message "Replikasyon başlatılamadı: $Message" -Level Error
            [void](Show-MessageDialog -Message "AD replikasyonu başlatılamadı:`n`n$Message`n`nDeğişiklikler uygulandı; normal replikasyon aralığında diğer DC'lere ulaşır." -Icon Warning)
            if ($script:State.ReplicationReload) { Start-UserLoad -ObjectGuid $script:State.ReplicationReload -Force }
        })
}
