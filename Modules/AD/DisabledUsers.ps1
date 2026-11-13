function global:Get-AttributeChangeTime {
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter()][AllowNull()][object]$MetaData,
        [Parameter(Mandatory = $true)][string]$Attribute
    )
    foreach ($entry in @($MetaData)) {
        $text = ([string]$entry).Trim([char]0)
        if ($text.IndexOf("<pszAttributeName>$Attribute</pszAttributeName>", [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        try {
            $xml = [xml]$text
            $raw = [string]$xml.DS_REPL_ATTR_META_DATA.ftimeLastOriginatingChange
            $parsed = [datetime]::MinValue
            $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
            if ([datetime]::TryParse($raw, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed.ToLocalTime() }
        }
        catch { Write-WorkerLog -Message "Meta veri okunamadı: $($_.Exception.Message)" -Level Verbose }
    }
    return $null
}
function global:Find-AccountDisableEvent {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][string[]]$Sid)
    $result = @{}
    $wanted = @{}
    foreach ($value in $Sid) { if ($value) { $wanted[$value] = $true } }
    if ($wanted.Count -eq 0) { return $result }
    try { $controllers = @(Get-PdcEmulator) }
    catch { Write-WorkerLog -Message "DC belirlenemedi: $($_.Exception.Message)" -Level Warning; return $result }
    $index = 0
    foreach ($dc in $controllers) {
        $index++
        Set-WorkerProgress -Percent ([int](40 + $index / $controllers.Count * 55)) -Status "Devre dışı bırakma olayları aranıyor ($index/$($controllers.Count)): $dc"
        try { $events = @(Get-WinEvent -ComputerName $dc -FilterHashtable @{ LogName = 'Security'; Id = 4725 } -MaxEvents 5000 -ErrorAction Stop) }
        catch {
            if ($_.Exception.Message -notmatch 'No events were found|eşleşen.*olay|bulunamadı') { Write-WorkerLog -Message "$dc güvenlik günlüğü okunamadı (Event Log Readers yetkisi / güvenlik duvarı): $($_.Exception.Message)" -Level Warning }
            continue
        }
        foreach ($event in $events) {
            try {
                $data = @{}
                foreach ($node in ([xml]$event.ToXml()).Event.EventData.Data) { $data[[string]$node.Name] = [string]$node.'#text' }
                $target = $data['TargetSid']
                if (-not $target -or -not $wanted.ContainsKey($target)) { continue }
                if (-not $result.ContainsKey($target) -or $event.TimeCreated -gt $result[$target].Time) {
                    $result[$target] = @{ By = '{0}\{1}' -f $data['SubjectDomainName'], $data['SubjectUserName']; Time = $event.TimeCreated; Dc = $dc }
                }
            }
            catch { Write-WorkerLog -Message "Olay okunamadı: $($_.Exception.Message)" -Level Verbose }
        }
    }
    return $result
}
function global:Get-DisabledUserList {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][switch]$SkipEventLog)
    $server = Get-PdcEmulator
    $ou = Get-DisabledUsersOu
    $attribute = $Sync.PreviousOuAttribute
    Set-WorkerProgress -Percent 10 -Status "Devre dışı kullanıcılar okunuyor: $ou"
    try { $null = Get-ADOrganizationalUnit -Identity $ou -Server $server -ErrorAction Stop }
    catch { throw "Devre dışı kullanıcılar OU'su bulunamadı: $ou (-DisabledUsersOu parametresiyle belirtebilirsiniz)." }
    $properties = @('DisplayName', $attribute, 'msDS-ReplAttributeMetaData', 'objectSid')
    $users = @(Get-ADUser -SearchBase $ou -SearchScope Subtree -LDAPFilter '(userAccountControl:1.2.840.113556.1.4.803:=2)' -Server $server -Properties $properties -ErrorAction Stop)
    $items = foreach ($user in $users) {
        $info = Get-StoredDisableInfo -Value ([string]$user.$attribute)
        $at = $info.At
        $source = if ($at) { 'Bu araç tarafından kaydedildi' } else { '' }
        if (-not $at) {
            $at = Get-AttributeChangeTime -MetaData $user.'msDS-ReplAttributeMetaData' -Attribute 'userAccountControl'
            if ($at) { $source = 'AD meta verisi (userAccountControl son değişiklik zamanı)' }
        }
        [pscustomobject]@{
            ObjectGuid        = $user.ObjectGUID.ToString()
            Name              = if ($user.DisplayName) { [string]$user.DisplayName } else { [string]$user.Name }
            SamAccountName    = [string]$user.SamAccountName
            DistinguishedName = [string]$user.DistinguishedName
            Sid               = [string]$user.SID.Value
            DisabledAt        = $at
            DisabledBy        = $info.By
            PreviousOu        = $info.PreviousOu
            Source            = $source
        }
    }
    $items = @($items)
    $missing = @($items | Where-Object { -not $_.DisabledBy })
    if ($missing.Count -gt 0 -and -not $SkipEventLog) {
        $events = Find-AccountDisableEvent -Sid ([string[]]@($missing | ForEach-Object { $_.Sid }))
        foreach ($item in $missing) {
            if (-not $events.ContainsKey($item.Sid)) { continue }
            $found = $events[$item.Sid]
            $item.DisabledBy = "$($found.By) (olay günlüğü)"
            if (-not $item.DisabledAt) { $item.DisabledAt = $found.Time; $item.Source = "Güvenlik günlüğü (4725, $($found.Dc))" }
        }
    }
    $now = Get-Date
    $limit = $now.AddMonths(-1)
    foreach ($item in $items) {
        $days = if ($item.DisabledAt) { [int][math]::Floor(($now - $item.DisabledAt).TotalDays) } else { $null }
        $item | Add-Member -NotePropertyName Overdue -NotePropertyValue ([bool]($item.DisabledAt -and $item.DisabledAt -le $limit))
        $item | Add-Member -NotePropertyName DisabledText -NotePropertyValue $(if ($item.DisabledAt) { $item.DisabledAt.ToString('dd.MM.yyyy HH:mm') } else { 'Bilinmiyor' })
        $item | Add-Member -NotePropertyName DaysText -NotePropertyValue $(if ($null -ne $days) { "$days gün" } else { '?' })
        $item | Add-Member -NotePropertyName ByText -NotePropertyValue $(if ($item.DisabledBy) { $item.DisabledBy } else { 'Bilinmiyor' })
        $item | Add-Member -NotePropertyName PreviousOuText -NotePropertyValue $(if ($item.PreviousOu) { $item.PreviousOu } else { '-' })
        $item | Add-Member -NotePropertyName SourceText -NotePropertyValue $(if ($item.Source) { "Kaynak: $($item.Source)" } else { 'Devre dışı bırakma zamanı belirlenemedi' })
    }
    Set-WorkerProgress -Percent 100 -Status "$($items.Count) devre dışı kullanıcı okundu."
    $sorted = @($items | Sort-Object -Property @{ Expression = { if ($_.DisabledAt) { $_.DisabledAt } else { [datetime]::MaxValue } } })
    return @{ Ou = $ou; Users = $sorted }
}
function global:Remove-DisabledUser {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string[]]$ObjectGuid)
    $server = Get-PdcEmulator
    $ou = Get-DisabledUsersOu
    $recycleBin = $null
    $index = 0
    foreach ($guid in $ObjectGuid) {
        $index++
        $result = [ordered]@{ ObjectGuid = $guid; Step = $guid; OwnerSam = ''; Success = $false; Message = ''; Devices = @() }
        try {
            $user = Get-ADUser -Identity $guid -Server $server -ErrorAction Stop
            $dn = [string]$user.DistinguishedName
            $result.Step = [string]$user.SamAccountName
            $result.OwnerSam = [string]$user.SamAccountName
            Set-WorkerProgress -Percent ([int]($index / $ObjectGuid.Count * 100)) -Status "Kullanıcı siliniyor ($index/$($ObjectGuid.Count)): $($user.SamAccountName)"
            if ($user.Enabled) { throw 'Hesap etkin; yalnızca devre dışı hesaplar silinebilir.' }
            if (-not $dn.EndsWith(",$ou", [System.StringComparison]::OrdinalIgnoreCase)) { throw "Kullanıcı $ou altında değil." }
            if (-not $recycleBin) { $recycleBin = Get-RecycleBinState -Server $server }
            if (-not $recycleBin.Enabled) { throw 'AD Geri Dönüşüm Kutusu kapalı; kullanıcı ve cihazları silinmedi.' }
            # Onay penceresindeki liste bayatlamış olabilir; cihazlar silmeden hemen önce yeniden çözülür.
            $devices = @(Get-UserDevice -SamAccountName ([string]$user.SamAccountName) -DistinguishedName $dn -Server $server)
            $deviceResults = foreach ($device in $devices) {
                $entry = [ordered]@{
                    Name = $device.Name; DistinguishedName = $device.DistinguishedName; ObjectGuid = $device.ObjectGuid; Source = $device.Source
                    BitLockerCount = $device.BitLockerCount; LapsPresent = $device.LapsPresent; Conflict = $device.Conflict
                    Success = $false; Skipped = [bool]$device.Conflict; Message = if ($device.Conflict) { "atlandı: $($device.Conflict)" } else { '' }
                }
                if (-not $entry.Skipped) {
                    try {
                        if ($WhatIfPreference) {
                            Write-WorkerLog -Message "[WhatIf] Remove-ADObject -Identity '$($device.DistinguishedName)' -Recursive -Server $server" -Level Warning
                            $entry.Message = 'simüle edildi'
                        }
                        else {
                            Remove-ADObject -Identity $device.DistinguishedName -Recursive -Server $server -Confirm:$false -ErrorAction Stop
                            $entry.Message = 'silindi'
                            Write-WorkerLog -Message "Cihaz silindi: $($device.DistinguishedName) (GUID: $($device.ObjectGuid), PDC: $server)" -Level Success
                        }
                        $entry.Success = $true
                    }
                    catch { $entry.Message = $_.Exception.Message }
                }
                [pscustomobject]$entry
            }
            $result.Devices = @($deviceResults)
            $failedDevices = @($result.Devices | Where-Object { -not $_.Skipped -and -not $_.Success })
            if ($failedDevices.Count -gt 0) {
                throw ('Cihaz silinemedi: ' + (($failedDevices | ForEach-Object { "$($_.Name) ($($_.Message))" }) -join '; ') + '; kullanıcı silinmedi.')
            }
            if ($WhatIfPreference) {
                Write-WorkerLog -Message "[WhatIf] Remove-ADObject -Identity '$dn' -Recursive -Server $server" -Level Warning
                $result.Success = $true
                $result.Message = 'simüle edildi'
            }
            elseif ($PSCmdlet.ShouldProcess($dn, 'Remove-ADObject -Recursive')) {
                Remove-ADObject -Identity $dn -Recursive -Server $server -Confirm:$false -ErrorAction Stop
                $result.Success = $true
                $result.Message = 'silindi'
                Write-WorkerLog -Message "Kullanıcı silindi: $dn (PDC: $server)" -Level Success
            }
        }
        catch {
            $message = $_.Exception.Message
            if ($message -match 'Access is denied|Erişim engellendi') { $message += ' (Nesne "yanlışlıkla silinmeye karşı koru" ile korunuyor olabilir veya silme yetkiniz yok.)' }
            $result.Message = $message
            Write-WorkerLog -Message "Kullanıcı silinemedi ($($result.Step)): $message" -Level Error
        }
        [pscustomobject]$result
    }
}
