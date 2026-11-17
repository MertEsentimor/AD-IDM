function Initialize-Audit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][ValidateSet('KeyValue', 'Json')][string]$Format = 'KeyValue',
        [Parameter()][ValidateRange(1, 2048)][int]$MaxSizeMB = 50
    )
    $script:Audit = @{
        Path      = $Path
        Format    = $Format
        MaxBytes  = [long]$MaxSizeMB * 1MB
        SessionId = [guid]::NewGuid().ToString()
        Operator  = "$env:USERDOMAIN\$env:USERNAME"
        Sid       = $null
        Failed    = $false
    }
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $script:Audit.Operator = $identity.Name
        $script:Audit.Sid = $identity.User.Value
    }
    catch { Write-Verbose "Windows kimliği okunamadı: $($_.Exception.Message)" }
}
function ConvertTo-AuditValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $text = if ($Value -is [bool]) { $Value.ToString().ToLowerInvariant() } elseif ($Value -is [datetime]) { $Value.ToString('o') } else { [string]$Value }
    $text = ($text -replace "`r?`n", ' | ') -replace "[`r`t]", ' '
    if ($text.Length -gt 2000) { $text = $text.Substring(0, 2000) + '...' }
    return $text
}
function Write-AuditEvent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('success', 'failure', 'simulated', 'info')][string]$Result,
        [Parameter()][System.Collections.IDictionary]$Fields = @{}
    )
    $record = [ordered]@{
        time         = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        app          = 'ADExchangeUserManager'
        event_id     = [guid]::NewGuid().ToString()
        session_id   = $script:Audit.SessionId
        host         = [System.Environment]::MachineName
        operator     = $script:Audit.Operator
        operator_sid = $script:Audit.Sid
        domain       = if ($script:State.Environment -and $script:State.Environment.DomainName) { [string]$script:State.Environment.DomainName } else { [string]$env:USERDNSDOMAIN }
        action       = $Action
        result       = $Result
    }
    foreach ($key in $Fields.Keys) {
        if ($key -match '(?i)secret|token|credential' -or ($key -match '(?i)password' -and $key -notmatch '(?i)AtLogon|NeverExpires')) { continue }
        $record[$key] = ConvertTo-AuditValue -Value $Fields[$key]
    }
    $line = if ($script:Audit.Format -eq 'Json') { ConvertTo-Json -InputObject $record -Compress }
    else {
        $parts = foreach ($key in $record.Keys) {
            $value = ConvertTo-AuditValue -Value $record[$key]
            if ($key -eq 'time') { "time=$value" } else { '{0}="{1}"' -f $key, ($value -replace '"', "'") }
        }
        $parts -join ' '
    }
    $path = $script:Audit.Path
    try {
        $folder = Split-Path -Path $path -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop) }
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge $script:Audit.MaxBytes) {
            $archive = Join-Path -Path $folder -ChildPath ('{0}.{1:yyyyMMdd-HHmmss-fff}{2}' -f [System.IO.Path]::GetFileNameWithoutExtension($path), (Get-Date), [System.IO.Path]::GetExtension($path))
            try { Move-Item -LiteralPath $path -Destination $archive -ErrorAction Stop } catch { Write-Verbose "Değişiklik günlüğü arşivlenemedi: $($_.Exception.Message)" }
        }
        # Agent dosyayı açık tutarken de yazılabilsin diye paylaşımlı açılır; BOM'suz UTF-8, satır başına bir kayıt.
        $stream = New-Object -TypeName System.IO.FileStream -ArgumentList $path, ([System.IO.FileMode]::Append), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::ReadWrite)
        try {
            $bytes = (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false).GetBytes($line + "`r`n")
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally { $stream.Dispose() }
        if ($script:Audit.Failed) {
            $script:Audit.Failed = $false
            if ($script:Ui.ContainsKey('lstLog')) { Write-UiLog -Message "Değişiklik günlüğü yeniden yazılabiliyor: $path" -Level Success }
        }
        return $true
    }
    catch {
        if (-not $script:Audit.Failed -and $script:Ui.ContainsKey('lstLog')) { Write-UiLog -Message "Değişiklik günlüğü (SIEM) yazılamadı: $path ($($_.Exception.Message))" -Level Error }
        $script:Audit.Failed = $true
        Write-Verbose "Değişiklik günlüğü yazılamadı: $($_.Exception.Message)"
        return $false
    }
}
function ConvertTo-AuditArgument {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][hashtable]$Arguments = @{}, [Parameter()][string]$Prefix = '')
    $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($key in ($Arguments.Keys | Sort-Object)) {
        if (@('Confirm', 'WhatIf', 'Identity', 'ObjectGuid', 'Sms', 'SmsSecrets', 'SmsValues', 'WelcomeMail') -contains $key) { continue }
        if ($key -match '(?i)secret|token|bytes|photo' -or ($key -match '(?i)password' -and $key -notmatch '(?i)AtLogon|NeverExpires')) { continue }
        $value = $Arguments[$key]
        if ($value -is [System.Management.Automation.PSCredential]) { $parts.Add("$Prefix$key.UserName=$($value.UserName)"); continue }
        if ($value -is [System.Security.SecureString] -or $value -is [byte[]]) { continue }
        if ($value -is [hashtable]) { $nested = ConvertTo-AuditArgument -Arguments $value -Prefix "$Prefix$key."; if ($nested) { $parts.Add($nested) }; continue }
        $parts.Add("$Prefix$key=$(@($value) -join ',')")
    }
    return ($parts -join '; ')
}
function Get-AuditTaskContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter()][hashtable]$Arguments = @{},
        [Parameter()][object[]]$Changes = @()
    )
    $action = switch ($Command) {
        'Invoke-UserUpdate' { 'user.update' }
        'Unlock-UserAccount' { 'account.unlock' }
        'Reset-UserPassword' { 'password.reset' }
        'Set-UserPhotoData' { if ($Arguments.Remove) { 'photo.remove' } else { 'photo.change' } }
        'Set-UserArchiveState' { if ($Arguments.Enable) { 'mailbox.archive.enable' } else { 'mailbox.archive.disable' } }
        'Start-MailboxMove' { 'mailbox.move.start' }
        'Remove-MailboxMove' { 'mailbox.move.remove' }
        'Invoke-AdReplication' { 'ad.replication' }
        'New-DirectoryUser' { 'user.create' }
        'Enable-UserMailbox' { 'mailbox.create' }
        'Remove-DisabledUser' { 'user.delete' }
        'Get-DeletedDeviceSecret' { 'device.deleted.secrets_view' }
        'Get-DeviceSecret' { 'device.secrets_view' }
        'Set-DeviceOwnerBulk' { if ($Arguments.OwnerDn) { 'device.link' } else { 'device.unlink' } }
        'Set-DeviceOwner' { if ($Arguments.OwnerDn) { 'device.link' } else { 'device.unlink' } }
        'Connect-ExchangeEnvironment' { 'exchange.connect' }
        'Start-MailboxPstExport' { 'mailbox.pst.export' }
        'Complete-MailboxPstExport' { if ($Arguments.Action -eq 'Remove') { 'mailbox.pst.remove_mailbox' } else { 'mailbox.pst.clear_request' } }
        'Disconnect-ExchangeEnvironment' { 'exchange.disconnect' }
        default { $null }
    }
    if (-not $action) { return $null }
    $context = @{
        Action    = $action
        Simulated = [bool]$Arguments.WhatIf
        Params    = ConvertTo-AuditArgument -Arguments $Arguments
        Changes   = @($Changes | Where-Object { $_ })
        Target    = [ordered]@{}
    }
    if ($Arguments.Sms) { $context.Params = ("method=sms; provider=$($Arguments.Sms.Provider); " + $context.Params).TrimEnd('; ') }
    elseif ($Command -in 'Reset-UserPassword', 'New-DirectoryUser') { $context.Params = ('method=manual; ' + $context.Params).TrimEnd('; ') }
    if ($Command -eq 'Complete-MailboxPstExport') { $context.Target.target_user = [string]$Arguments.Alias }
    elseif ($Command -eq 'New-DirectoryUser') {
        $context.Target.target_user = [string]$Arguments.Attributes.SamAccountName
        $context.Target.target_dn = "CN=$([string]$Arguments.Attributes.Name),$([string]$Arguments.Path)"
    }
    elseif ($Command -eq 'Get-DeletedDeviceSecret') { $context.Target.target_device = [string]$Arguments.DeviceName }
    elseif ($Command -eq 'Get-DeviceSecret') {
        $context.Target.target_device = [string]$Arguments.DeviceName
        $context.Target.target_dn = [string]$Arguments.ComputerDn
    }
    elseif ($Command -eq 'Set-DeviceOwnerBulk') {
        $context.Target.target_owner = [string]$Arguments.OwnerDn
        $context.Target.target_device = (@($Arguments.ComputerDn) | ForEach-Object { Get-DnCommonName -DistinguishedName $_ }) -join ', '
    }
    elseif ($Command -notmatch 'Exchange|Replication|Remove-DisabledUser' -and $script:State.CurrentData) {
        $ad = $script:State.CurrentData.Ad
        $context.Target.target_user = [string]$ad.SamAccountName
        $context.Target.target_upn = [string]$ad.UserPrincipalName
        $context.Target.target_guid = [string]$ad.ObjectGuid
        $context.Target.target_dn = [string]$ad.DistinguishedName
    }
    return $context
}
function Write-AuditTaskResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter()][AllowNull()][object]$Result,
        [Parameter()][AllowNull()][string]$Failure
    )
    $items = @($Result | Where-Object { $_ -and $_.PSObject -and $_.PSObject.Properties['Step'] -and $_.PSObject.Properties['Success'] })
    $outcome = {
        param([bool]$Success)
        if ($Context.Simulated) { 'simulated' } elseif ($Success) { 'success' } else { 'failure' }
    }
    if ($Context.Changes.Count -gt 0) {
        $stepNames = @{
            AD = 'Active Directory öznitelikleri'; Groups = 'Grup üyelikleri'; AccountFlags = 'Hesap seçenekleri'; Leave = 'İzin planı'
            GroupCleanup = 'Grup temizliği'; PstExport = 'PST dışa aktarma'
            Addresses = 'E-posta adresleri'; Cas = 'Posta kutusu özellikleri (CAS)'; Policies = 'Posta kutusu politikaları'
        }
        foreach ($change in $Context.Changes) {
            $stepResult = $items | Where-Object { $_.Step -eq $stepNames[$change.Step] } | Select-Object -First 1
            $success = if ($Failure) { $false } elseif ($stepResult) { [bool]$stepResult.Success } else { $false }
            $message = if ($Failure) { $Failure } elseif ($stepResult) { [string]$stepResult.Message } else { 'adım sonucu alınamadı' }
            if ($change.Step -eq 'Groups' -and $stepResult -and -not $stepResult.Success -and -not $Failure) {
                $dn = if ($change.New) { [string]$change.New } else { [string]$change.Old }
                $success = -not $message.Contains($dn)
                if ($success) { $message = 'Başarılı' }
            }
            $fields = [ordered]@{}
            foreach ($key in $Context.Target.Keys) { $fields[$key] = $Context.Target[$key] }
            $fields.category = $change.Category
            $fields.field = $change.Field
            $fields.operation = $change.Operation
            $fields.old_value = $change.Old
            $fields.new_value = $change.New
            if ($change.Label) { $fields.label = $change.Label }
            $fields.message = $message
            [void](Write-AuditEvent -Action $change.Action -Result (& $outcome $success) -Fields $fields)
        }
        return
    }
    if ($items.Count -eq 0) {
        $fields = [ordered]@{}
        foreach ($key in $Context.Target.Keys) { $fields[$key] = $Context.Target[$key] }
        if ($Context.Params) { $fields.params = $Context.Params }
        $fields.message = if ($Failure) { $Failure } else { 'Başarılı' }
        [void](Write-AuditEvent -Action $Context.Action -Result (& $outcome (-not $Failure)) -Fields $fields)
        return
    }
    foreach ($item in $items) {
        $fields = [ordered]@{}
        foreach ($key in $Context.Target.Keys) { $fields[$key] = $Context.Target[$key] }
        if ($item.PSObject.Properties['ObjectGuid']) { $fields.target_user = [string]$item.Step; $fields.target_guid = [string]$item.ObjectGuid }
        else { $fields.step = [string]$item.Step }
        foreach ($extra in 'SmsTo', 'SmsProvider', 'SmsStatus') {
            if ($item.PSObject.Properties[$extra]) { $fields[('sms_' + $extra.Substring(3).ToLowerInvariant())] = $item.$extra }
        }
        if ($Context.Params) { $fields.params = $Context.Params }
        $fields.message = [string]$item.Message
        $action = if ($item.Step -eq 'SMS gönderimi') { 'password.sms' } else { $Context.Action }
        [void](Write-AuditEvent -Action $action -Result (& $outcome ([bool]$item.Success)) -Fields $fields)
        foreach ($device in @($item.PSObject.Properties['Devices'] | ForEach-Object { $_.Value } | Where-Object { $_ -and -not $_.Skipped })) {
            $deviceFields = [ordered]@{
                device_name = [string]$device.Name; device_dn = [string]$device.DistinguishedName; device_guid = [string]$device.ObjectGuid
                owner_sam = [string]$item.OwnerSam; match_source = [string]$device.Source
                bitlocker_count = [int]$device.BitLockerCount; laps_present = [bool]$device.LapsPresent; message = [string]$device.Message
            }
            [void](Write-AuditEvent -Action 'device.delete' -Result (& $outcome ([bool]$device.Success)) -Fields $deviceFields)
        }
    }
}
