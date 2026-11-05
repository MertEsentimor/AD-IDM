function global:Get-LeaveCandidate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][string]$Server)
    $attribute = $Sync.LeaveAttribute
    $legacy = $Sync.LegacyLeaveEndAttribute
    $properties = @($attribute, 'DisplayName', $Sync.PreviousOuAttribute)
    if ($legacy) { $properties += $legacy }
    $parameters = @{
        LDAPFilter     = "(&(objectCategory=person)(objectClass=user)(|($attribute=ADEUM-LEAVE*)($attribute=2*)))"
        Properties     = $properties
        ResultPageSize = 500
        ErrorAction    = 'Stop'
    }
    if ($Server) { $parameters.Server = $Server }
    $disabledOu = try { Get-DisabledUsersOu } catch { '' }
    foreach ($user in @(Get-ADUser @parameters)) {
        $record = ConvertFrom-LeaveValue -Value ([string]$user.$attribute) -LegacyEnd $(if ($legacy) { [string]$user.$legacy } else { '' })
        if (-not $record.Owned) { continue }
        [pscustomobject]@{
            ObjectGuid        = $user.ObjectGUID.ToString()
            Name              = if ($user.DisplayName) { [string]$user.DisplayName } else { [string]$user.Name }
            SamAccountName    = [string]$user.SamAccountName
            DistinguishedName = [string]$user.DistinguishedName
            Enabled           = [bool]$user.Enabled
            Protected         = Test-LeaveProtected -DistinguishedName ([string]$user.DistinguishedName) -Marker ([string]$user.($Sync.PreviousOuAttribute)) -DisabledOu $disabledOu
            Record            = $record
        }
    }
}
function global:Get-LeaveTaskInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $info = [pscustomobject]@{ Installed = $false; Enabled = $false; Healthy = $false; Intraday = $false; Account = ''; NextRun = $null; LastRun = $null; LastResult = $null; Text = '' }
    try {
        $task = Get-ScheduledTask -TaskPath $Sync.LeaveTaskPath -TaskName $Sync.LeaveTaskName -ErrorAction Stop
        $details = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
    }
    catch {
        $info.Text = "Gece görevi bu bilgisayarda ($env:COMPUTERNAME) kurulu değil: izin günlerinde hesaplar kendiliğinden kapanıp açılmaz."
        return $info
    }
    $info.Installed = $true
    $info.Enabled = [string]$task.State -ne 'Disabled'
    $info.Account = [string]$task.Principal.UserId
    $info.NextRun = $details.NextRunTime
    $info.LastRun = if ($details.LastRunTime -and $details.LastRunTime.Year -gt 2000) { $details.LastRunTime } else { $null }
    $info.LastResult = [int64]$details.LastTaskResult
    $resultText = switch ($info.LastResult) {
        0 { 'başarılı' }
        1 { 'bazı işlemler başarısız' }
        2 { 'hata' }
        267009 { 'şu an çalışıyor (gün içinde saatli izinleri izler)' }
        267011 { 'henüz çalışmadı' }
        default { "sonuç kodu $($info.LastResult)" }
    }
    $limit = [string]$task.Settings.ExecutionTimeLimit
    $info.Intraday = try { (-not $limit) -or $limit -eq 'PT0S' -or [System.Xml.XmlConvert]::ToTimeSpan($limit).TotalHours -ge 20 } catch { $false }
    $info.Healthy = $info.Enabled -and $info.Intraday -and @(0, 267009, 267011) -contains $info.LastResult
    $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $parts.Add("Gece görevi kurulu ($env:COMPUTERNAME, hesap: $($info.Account))")
    if (-not $info.Enabled) { $parts.Add('GÖREV DEVRE DIŞI') }
    if (-not $info.Intraday) { $parts.Add('ESKİ KURULUM: yarım gün (saatli) izinler için görevi yeniden kurun') }
    if ($info.LastRun) { $parts.Add("son çalışma: $($info.LastRun.ToString('dd.MM.yyyy HH:mm')) ($resultText)") } else { $parts.Add('henüz çalışmadı') }
    if ($info.NextRun) { $parts.Add("sonraki: $(([datetime]$info.NextRun).ToString('dd.MM.yyyy HH:mm')) (hazırlanır, 00:00:00'da uygular)") }
    $info.Text = $parts -join '  |  '
    return $info
}
function global:Get-LeaveOverview {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    Set-WorkerProgress -Status 'İzin kayıtları okunuyor...'
    $moment = Get-Date
    $today = $moment.Date
    $tomorrow = $today.AddDays(1)
    $items = foreach ($user in @(Get-LeaveCandidate)) {
        $now = Get-LeaveState -Record $user.Record -Enabled $user.Enabled -Protected $user.Protected -Date $moment
        $timed = @(foreach ($p in @($user.Record.Periods)) { $p.Start; $p.Until }) | Where-Object { $_.Date -eq $today -and $_.TimeOfDay.Ticks -gt 0 -and $_ -gt $moment } | Sort-Object | Select-Object -First 1
        $nextMoment = if ($timed) { [datetime]$timed } else { $tomorrow }
        $tonight = Get-LeaveState -Record $user.Record -Enabled $(if ($now.Action -eq 'Disable') { $false } elseif ($now.Action -eq 'Enable') { $true } else { $user.Enabled }) -Protected $user.Protected -Date $nextMoment
        $first = @($now.Periods) | Select-Object -First 1
        [pscustomobject]@{
            ObjectGuid     = $user.ObjectGuid
            Name           = $user.Name
            SamAccountName = $user.SamAccountName
            Enabled        = $user.Enabled
            AccountText    = if ($user.Enabled) { 'Açık' } else { 'Kapalı' }
            PeriodsText    = if (@($now.Periods).Count -gt 0) { (@($now.Periods | ForEach-Object { Format-LeaveSpan -Period $_ }) -join ';  ') } else { '-' }
            PeriodsRaw     = $user.Record.Raw
            StatusText     = $now.Text
            Kind           = $now.Kind
            Problem        = ($now.Kind -eq 'Invalid') -or (@('Disable', 'Enable') -contains $now.Action)
            TonightText    = switch ($tonight.Action) { 'Disable' { "$($nextMoment.ToString('HH:mm')) kapanacak" } 'Enable' { "$($nextMoment.ToString('HH:mm')) açılacak" } default { '' } }
            SortKey        = if ($first) { $first.Start } else { [datetime]::MaxValue }
        }
    }
    $task = try { Get-LeaveTaskInfo } catch { $null }
    Write-WorkerLog -Message "İzin planı okundu: $(@($items).Count) kayıt." -Level Info
    return [pscustomobject]@{
        Attribute = $Sync.LeaveAttribute
        Today     = $today
        Task      = $task
        Users     = @($items | Sort-Object -Property SortKey, Name)
    }
}
function global:Wait-LeaveMoment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][datetime]$Until)
    while ($true) {
        $remaining = ($Until - [datetime]::Now).TotalMilliseconds
        if ($remaining -le 0) { return }
        if ($remaining -gt 1500) { Start-Sleep -Milliseconds ([int][math]::Min($remaining - 1000, 30000)) }
        elseif ($remaining -gt 40) { Start-Sleep -Milliseconds 20 }
        else { [System.Threading.Thread]::Sleep(0) }
    }
}
function global:Invoke-LeaveEnforcement {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][datetime]$Date = (Get-Date).Date,
        [Parameter()][switch]$WaitForDate,
        [Parameter()][switch]$TimedOnly,
        [Parameter()][bool]$Replicate = $true,
        [Parameter()][ValidateRange(1, 32)][int]$Throttle = 8
    )
    $moment = $Date
    $day = $Date.Date
    $at = $moment.ToString('HH:mm:ss')
    $pdc = Get-PdcEmulator
    Set-WorkerProgress -Status 'İzin kayıtları okunuyor...'
    $users = @(Get-LeaveCandidate -Server $pdc)
    $plan = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $problems = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($user in $users) {
        $state = Get-LeaveState -Record $user.Record -Enabled $user.Enabled -Protected $user.Protected -Date $moment
        if ($TimedOnly) {
            $timedStart = $state.Action -eq 'Disable' -and $state.Active.Start.Date -eq $day -and $state.Active.Start.TimeOfDay.Ticks -gt 0
            $timedEnd = $state.Action -eq 'Enable' -and @($user.Record.Periods | Where-Object { $_.Until.Date -eq $day -and $_.Until.TimeOfDay.Ticks -gt 0 -and $_.Until -le $moment }).Count -gt 0
            if (-not ($timedStart -or $timedEnd)) { continue }
        }
        if ($state.Kind -eq 'Invalid') { $problems.Add("$($user.SamAccountName): $($state.Text)") }
        if ($state.Action -eq 'None') { continue }
        $reportPeriod = if ($state.Action -eq 'Disable') { $state.Active } elseif ($state.Action -eq 'Enable') { @($user.Record.Periods | Where-Object { $_.Until -le $moment }) | Select-Object -Last 1 } else { $null }
        $plan.Add([pscustomobject]@{
                Period            = if ($reportPeriod) { Format-LeaveSpan -Period $reportPeriod } else { '' }
                ReturnDate        = if ($reportPeriod) { $reportPeriod.Until.ToString($(if ($reportPeriod.Until.TimeOfDay.Ticks -gt 0) { 'dd.MM.yyyy ddd HH:mm' } else { 'dd.MM.yyyy ddd' }), [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')) } else { '' }
                ObjectGuid        = $user.ObjectGuid
                Name              = $user.Name
                SamAccountName    = $user.SamAccountName
                DistinguishedName = $user.DistinguishedName
                Action            = $state.Action
                OldValue          = $user.Record.Raw
                NewValue          = $state.NewValue
                ClearLegacy       = $state.ClearLegacy
            })
    }
    $count = { param([string]$Action) @($plan | Where-Object { $_.Action -eq $Action }).Count }
    Write-WorkerLog -Message ("İzin kontrolü{6} - hedef: {0}, DC: {1}. {2} izin kaydı; kapatılacak: {3}, açılacak: {4}, kayıt düzeltme: {5}." -f $moment.ToString('dd.MM.yyyy dddd HH:mm'), $pdc, $users.Count, (& $count 'Disable'), (& $count 'Enable'), (& $count 'Update'), $(if ($TimedOnly) { ' (saatli izin)' } else { '' })) -Level Info
    foreach ($problem in $problems) { Write-WorkerLog -Message "Hatalı izin kaydı atlandı: $problem" -Level Warning }
    $summary = [pscustomobject]@{ Date = $day; Moment = $moment; TimedOnly = [bool]$TimedOnly; Server = $pdc; Users = $users.Count; Simulated = [bool]$WhatIfPreference; StartedAt = $null; Problems = $problems.ToArray(); Results = @() }
    if ($plan.Count -eq 0) { return $summary }
    if ($WhatIfPreference) {
        $summary.Results = @(foreach ($item in $plan) {
                Write-WorkerLog -Message "[WhatIf] $($item.SamAccountName): $(Get-LeaveActionText -Action $item.Action)  ('$($item.OldValue)' -> '$($item.NewValue)')" -Level Warning
                [pscustomobject]@{
                    ObjectGuid = $item.ObjectGuid; Name = $item.Name; SamAccountName = $item.SamAccountName; DistinguishedName = $item.DistinguishedName; Period = $item.Period; ReturnDate = $item.ReturnDate
                    Action = $item.Action; OldValue = $item.OldValue; NewValue = $item.NewValue; Success = $true; Message = 'Simülasyon'
                    AppliedAt = $null; Replicated = 0; ReplicationErrors = ''
                }
            })
        return $summary
    }
    if (-not $PSCmdlet.ShouldProcess("$($plan.Count) hesap", 'İzin planını uygula')) { return $summary }
    $laneScript = {
        param($Items, $Server, $Attribute, $LegacyAttribute)
        $done = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($item in $Items) {
            $result = [pscustomobject]@{
                ObjectGuid = $item.ObjectGuid; Name = $item.Name; SamAccountName = $item.SamAccountName; DistinguishedName = $item.DistinguishedName; Period = $item.Period; ReturnDate = $item.ReturnDate
                Action = $item.Action; OldValue = $item.OldValue; NewValue = $item.NewValue; Success = $false; Message = ''
                AppliedAt = $null; Replicated = 0; ReplicationErrors = ''
            }
            try {
                $parameters = @{ Identity = $item.ObjectGuid; Server = $Server; ErrorAction = 'Stop'; Confirm = $false }
                $clear = New-Object -TypeName 'System.Collections.Generic.List[string]'
                if ($item.NewValue) { $parameters.Replace = @{ $Attribute = [string]$item.NewValue } } else { $clear.Add($Attribute) }
                if ($item.ClearLegacy -and $LegacyAttribute) { $clear.Add($LegacyAttribute) }
                if ($clear.Count -gt 0) { $parameters.Clear = $clear.ToArray() }
                if ($item.Action -eq 'Disable') { $parameters.Enabled = $false }
                elseif ($item.Action -eq 'Enable') { $parameters.Enabled = $true }
                Set-ADUser @parameters
                $result.Success = $true
                $result.Message = 'Başarılı'
            }
            catch { $result.Message = $_.Exception.Message }
            $result.AppliedAt = [datetime]::Now
            $done.Add($result)
        }
        $done.ToArray()
    }
    $laneCount = [math]::Min($Throttle, $plan.Count)
    $lanes = @(for ($i = 0; $i -lt $laneCount; $i++) { @{ Items = (New-Object -TypeName 'System.Collections.Generic.List[object]'); Runspace = $null; PowerShell = $null; Handle = $null } })
    for ($i = 0; $i -lt $plan.Count; $i++) { $lanes[$i % $laneCount].Items.Add($plan[$i]) }
    $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
    try {
        Set-WorkerProgress -Status "AD bağlantıları hazırlanıyor ($laneCount kanal)..."
        foreach ($lane in $lanes) {
            $initial = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            [void]$initial.ImportPSModule('ActiveDirectory')
            $lane.Runspace = [runspacefactory]::CreateRunspace($initial)
            $lane.Runspace.Open()
            $warm = [powershell]::Create()
            try {
                $warm.Runspace = $lane.Runspace
                [void]$warm.AddScript('param($Server, $Guid) $null = Get-ADUser -Identity $Guid -Server $Server -ErrorAction Stop').AddArgument($pdc).AddArgument($lane.Items[0].ObjectGuid)
                [void]$warm.Invoke()
            }
            catch { Write-WorkerLog -Message "Isınma sorgusu başarısız: $($_.Exception.Message)" -Level Warning }
            finally { $warm.Dispose() }
            $lane.PowerShell = [powershell]::Create()
            $lane.PowerShell.Runspace = $lane.Runspace
            [void]$lane.PowerShell.AddScript($laneScript.ToString()).AddArgument($lane.Items.ToArray()).AddArgument($pdc).AddArgument($Sync.LeaveAttribute).AddArgument($Sync.LegacyLeaveEndAttribute)
        }
        if ($WaitForDate -and [datetime]::Now -lt $moment) {
            Write-WorkerLog -Message ("Hazır: {0} işlem {1} {2} anında uygulanacak." -f $plan.Count, $day.ToString('dd.MM.yyyy'), $at) -Level Info
            Set-WorkerProgress -Status ("{0} işlem {1} {2} anını bekliyor..." -f $plan.Count, $day.ToString('dd.MM.yyyy'), $at)
            Wait-LeaveMoment -Until $moment
        }
        $summary.StartedAt = [datetime]::Now
        foreach ($lane in $lanes) { $lane.Handle = $lane.PowerShell.BeginInvoke() }
        foreach ($lane in $lanes) {
            try { foreach ($item in $lane.PowerShell.EndInvoke($lane.Handle)) { $results.Add($item) } }
            catch {
                $message = $_.Exception.Message
                foreach ($item in $lane.Items) {
                    $results.Add([pscustomobject]@{
                            ObjectGuid = $item.ObjectGuid; Name = $item.Name; SamAccountName = $item.SamAccountName; DistinguishedName = $item.DistinguishedName; Period = $item.Period; ReturnDate = $item.ReturnDate
                            Action = $item.Action; OldValue = $item.OldValue; NewValue = $item.NewValue; Success = $false; Message = $message
                            AppliedAt = [datetime]::Now; Replicated = 0; ReplicationErrors = ''
                        })
                }
            }
        }
    }
    finally {
        foreach ($lane in $lanes) {
            if ($lane.PowerShell) { $lane.PowerShell.Dispose() }
            if ($lane.Runspace) { try { $lane.Runspace.Close(); $lane.Runspace.Dispose() } catch { Write-Verbose $_.Exception.Message } }
        }
    }
    $summary.Results = $results.ToArray()
    foreach ($result in $summary.Results) {
        $time = if ($result.AppliedAt) { ([datetime]$result.AppliedAt).ToString('HH:mm:ss.fff') } else { '-' }
        if ($result.Success) {
            Write-WorkerLog -Message "$($result.SamAccountName): $(Get-LeaveActionText -Action $result.Action -Done) ($time, DC: $pdc)" -Level Success
        }
        else { Write-WorkerLog -Message "$($result.SamAccountName): $(Get-LeaveActionText -Action $result.Action) BAŞARISIZ ($time): $($result.Message)" -Level Error }
    }
    if ($Replicate -and @($summary.Results | Where-Object { $_.Success -and @('Disable', 'Enable') -contains $_.Action }).Count -gt 0) {
        try { Invoke-AdReplication -Confirm:$false }
        catch { Write-WorkerLog -Message "Replikasyon uyarısı (değişiklik $pdc üzerinde uygulandı, normal replikasyonla yayılacak): $($_.Exception.Message)" -Level Warning }
    }
    return $summary
}
function global:Get-LeaveTimedMoment {
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter()][datetime]$After = (Get-Date),
        [Parameter(Mandatory = $true)][datetime]$Before
    )
    $found = foreach ($user in @(Get-LeaveCandidate -Server (Get-PdcEmulator))) {
        if ($user.Protected -or $user.Record.Problem) { continue }
        foreach ($period in @($user.Record.Periods)) {
            $moment = if ($user.Enabled) { $period.Start } elseif ($user.Record.Off -or $user.Record.Legacy) { $period.Until } else { $null }
            if ($moment -and $moment.TimeOfDay.Ticks -gt 0 -and $moment -gt $After -and $moment -lt $Before) { $moment }
        }
    }
    @($found | Sort-Object) | Select-Object -First 1
}
function global:Get-LeaveActionText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Action, [Parameter()][switch]$Done)
    switch ($Action) {
        'Disable' { if ($Done) { 'hesap kapatıldı (izin başladı)' } else { 'hesap kapatılacak (izin başladı)' } }
        'Enable' { if ($Done) { 'hesap açıldı (izin bitti)' } else { 'hesap açılacak (izin bitti)' } }
        default { if ($Done) { 'izin kaydı güncellendi' } else { 'izin kaydı güncellenecek (geçmiş dönem / eski biçim)' } }
    }
}
function global:Remove-LeaveRange {
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][AllowNull()][object[]]$Periods = @(),
        [Parameter(Mandatory = $true)][datetime]$Start,
        [Parameter(Mandatory = $true)][datetime]$End
    )
    $from = $Start.Date
    $to = $End.Date.AddDays(1)
    $result = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($period in @($Periods | Where-Object { $_ })) {
        $pStart = [datetime]$period.Start
        $pUntil = Get-LeaveUntil -Period $period
        if ($pUntil -le $from -or $pStart -ge $to) { $result.Add((New-LeavePeriod -Start $pStart -Until $pUntil)); continue }
        if ($pStart -lt $from) { $result.Add((New-LeavePeriod -Start $pStart -Until $from)) }
        if ($pUntil -gt $to) { $result.Add((New-LeavePeriod -Start $to -Until $pUntil)) }
    }
    return @(Merge-LeavePeriod -Periods $result.ToArray())
}
function global:Get-BulkLeaveCandidate {
    [CmdletBinding(DefaultParameterSetName = 'Ou')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Ou')][string[]]$SearchBase,
        [Parameter(ParameterSetName = 'Ou')][bool]$Subtree = $true,
        [Parameter(Mandatory = $true, ParameterSetName = 'Group')][string]$Group,
        [Parameter(Mandatory = $true, ParameterSetName = 'Search')][string]$Query
    )
    $server = Get-PdcEmulator
    $attribute = $Sync.LeaveAttribute
    $legacy = $Sync.LegacyLeaveEndAttribute
    $properties = @('DisplayName', 'Department', 'Title', 'Enabled', $attribute, $Sync.PreviousOuAttribute) + $(if ($legacy) { @($legacy) } else { @() })
    $base = '(&(objectCategory=person)(objectClass=user)'
    $parameters = @{ Server = $server; Properties = $properties; ResultPageSize = 500; ErrorAction = 'Stop' }
    switch ($PSCmdlet.ParameterSetName) {
        'Ou' {
            Set-WorkerProgress -Status "OU'daki kullanıcılar okunuyor..."
            $parameters.LDAPFilter = "$base)"
            $parameters.SearchScope = if ($Subtree) { 'Subtree' } else { 'OneLevel' }
            $source = "OU: $($SearchBase -join ' | ')"
        }
        'Group' {
            $value = ConvertTo-LdapFilterValue -Value $Group.Trim()
            $found = @(Get-ADGroup -LDAPFilter "(|(sAMAccountName=$value)(name=$value)(distinguishedName=$value))" -Server $server -ErrorAction Stop)
            if ($found.Count -eq 0) { throw "Grup bulunamadı: $Group" }
            if ($found.Count -gt 1) { throw "Birden fazla grup eşleşti: $(($found | ForEach-Object { $_.Name }) -join ', '). SamAccountName yazın." }
            Set-WorkerProgress -Status "'$($found[0].Name)' grubunun üyeleri okunuyor (iç içe gruplar dahil)..."
            $parameters.LDAPFilter = "$base(memberOf:1.2.840.113556.1.4.1941:=$(ConvertTo-LdapFilterValue -Value ([string]$found[0].DistinguishedName))))"
            $source = "Grup: $($found[0].Name)"
        }
        'Search' {
            $value = ConvertTo-LdapFilterValue -Value $Query.Trim()
            $parameters.LDAPFilter = "$base(|(sAMAccountName=$value*)(displayName=*$value*)(userPrincipalName=$value*)))"
            $parameters.ResultSetSize = 200
            $source = "Arama: $Query"
        }
    }
    $users = if ($PSCmdlet.ParameterSetName -eq 'Ou') {
        $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
        @(foreach ($ou in @($SearchBase | Where-Object { $_ })) {
                $parameters.SearchBase = $ou
                foreach ($user in @(Get-ADUser @parameters)) { if ($seen.Add($user.ObjectGUID.ToString())) { $user } }
            })
    }
    else { @(Get-ADUser @parameters) }
    Write-WorkerLog -Message "$source -> $($users.Count) kullanıcı" -Level Info
    foreach ($user in $users) {
        $record = ConvertFrom-LeaveValue -Value ([string]$user.$attribute) -LegacyEnd $(if ($legacy) { [string]$user.$legacy } else { '' })
        $protected = Test-LeaveProtected -DistinguishedName ([string]$user.DistinguishedName) -Marker ([string]$user.($Sync.PreviousOuAttribute)) -DisabledOu (Get-DisabledUsersOu)
        $block = if ($record.Raw -and -not $record.Owned) { "$attribute başka amaçla kullanılıyor ('$($record.Raw)')" }
        elseif ($record.Problem) { "Hatalı izin kaydı: $($record.Problem)" }
        elseif ($protected) { "DisabledUsers OU'sunda (devre dışı bırakılmış)" }
        else { '' }
        [pscustomobject]@{
            ObjectGuid     = $user.ObjectGUID.ToString()
            Name           = if ($user.DisplayName) { [string]$user.DisplayName } else { [string]$user.Name }
            SamAccountName = [string]$user.SamAccountName
            Department     = [string]$user.Department
            Title          = [string]$user.Title
            Enabled        = [bool]$user.Enabled
            Off            = [string]$record.Off
            Periods        = @($record.Periods | ForEach-Object { [pscustomobject]@{ Start = $_.Start; End = $_.End; Until = $_.Until } })
            Block          = $block
        }
    }
}
function global:Invoke-BulkLeave {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string[]]$ObjectGuid,
        [Parameter(Mandatory = $true)][datetime]$Start,
        [Parameter(Mandatory = $true)][datetime]$End,
        [Parameter()][ValidateSet('Add', 'Remove')][string]$Mode = 'Add',
        [Parameter()][bool]$ApplyNow = $true
    )
    if ($End.Date -lt $Start.Date) { throw 'Son izin günü ilk günden önce olamaz.' }
    $addUntil = if ($End.TimeOfDay.Ticks -gt 0) { $End } else { $End.Date.AddDays(1) }
    if ($Mode -eq 'Add' -and $addUntil -le $Start) { throw 'Açılış saati kapanış saatinden sonra olmalı.' }
    $server = Get-PdcEmulator
    $attribute = $Sync.LeaveAttribute
    $legacy = $Sync.LegacyLeaveEndAttribute
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $now = Get-Date
    $today = $now.Date
    $properties = @('DisplayName', 'Enabled', $attribute, $Sync.PreviousOuAttribute) + $(if ($legacy) { @($legacy) } else { @() })
    $disabledOu = Get-DisabledUsersOu
    $index = 0
    foreach ($guid in $ObjectGuid) {
        $index++
        Set-WorkerProgress -Percent ([int](($index - 1) * 100 / $ObjectGuid.Count)) -Status "Toplu izin: $index / $($ObjectGuid.Count)"
        $item = [ordered]@{ ObjectGuid = $guid; Name = ''; SamAccountName = ''; DistinguishedName = ''; Success = $false; Skipped = $false; Account = 'None'; OldValue = ''; NewValue = ''; Message = '' }
        try {
            $user = Get-ADUser -Identity $guid -Server $server -Properties $properties -ErrorAction Stop
            $item.Name = if ($user.DisplayName) { [string]$user.DisplayName } else { [string]$user.Name }
            $item.SamAccountName = [string]$user.SamAccountName
            $item.DistinguishedName = [string]$user.DistinguishedName
            $record = ConvertFrom-LeaveValue -Value ([string]$user.$attribute) -LegacyEnd $(if ($legacy) { [string]$user.$legacy } else { '' })
            $item.OldValue = $record.Raw
            if ($record.Raw -and -not $record.Owned) { throw "$attribute başka amaçla kullanılıyor ('$($record.Raw)'); dokunulmadı." }
            if ($record.Problem) { throw "Hatalı izin kaydı ($($record.Problem)); önce kullanıcı ekranından düzeltin." }
            $protected = Test-LeaveProtected -DistinguishedName ([string]$user.DistinguishedName) -Marker ([string]$user.($Sync.PreviousOuAttribute)) -DisabledOu $disabledOu
            if ($protected) { throw "DisabledUsers OU'sunda (devre dışı bırakılmış hesap); dokunulmadı." }
            $periods = if ($Mode -eq 'Add') { @(Merge-LeavePeriod -Periods (@($record.Periods) + (New-LeavePeriod -Start $Start -Until $addUntil))) }
            else { @(Remove-LeaveRange -Periods $record.Periods -Start $Start -End $End) }
            $periods = @($periods | Where-Object { $_.Until -gt $now })
            $off = [string]$record.Off
            if ($record.Legacy -and -not $user.Enabled -and -not $off -and @($record.Periods).Count -gt 0) { $off = $record.Periods[0].Start.ToString('yyyy-MM-dd', $culture) }
            $activeNow = @($periods | Where-Object { $_.Start -le $now -and $_.Until -gt $now }).Count -gt 0
            if ($ApplyNow) {
                if ($activeNow -and $user.Enabled) { $item.Account = 'Disable'; $off = $today.ToString('yyyy-MM-dd', $culture) }
                elseif (-not $activeNow -and $off -and -not $user.Enabled) { $item.Account = 'Enable'; $off = '' }
            }
            if (-not $activeNow -and $off -and $user.Enabled) { $off = '' }
            $value = ConvertTo-LeaveValue -Periods $periods -Off $off
            $item.NewValue = $value
            if ([string]::Equals($value, $record.Raw, [System.StringComparison]::Ordinal) -and $item.Account -eq 'None' -and -not $record.Legacy) {
                $item.Success = $true; $item.Skipped = $true
                $item.Message = if ($Mode -eq 'Add') { 'Bu tarihler zaten izinli' } else { 'Bu tarihlerde izni yoktu' }
            }
            else {
                $parameters = @{ Identity = $user.ObjectGUID; Server = $server; ErrorAction = 'Stop'; Confirm = $false }
                $clear = New-Object -TypeName 'System.Collections.Generic.List[string]'
                if ($value) { $parameters.Replace = @{ $attribute = $value } } else { $clear.Add($attribute) }
                if ($record.Legacy -and $legacy) { $clear.Add($legacy) }
                if ($clear.Count -gt 0) { $parameters.Clear = $clear.ToArray() }
                if ($item.Account -ne 'None') { $parameters.Enabled = ($item.Account -eq 'Enable') }
                $accountText = switch ($item.Account) { 'Disable' { '; hesap hemen kapatıldı' } 'Enable' { '; hesap hemen açıldı' } default { '' } }
                if ($WhatIfPreference) {
                    Write-WorkerLog -Message "[WhatIf] $($item.SamAccountName): '$($record.Raw)' -> '$value'$accountText" -Level Warning
                    $item.Success = $true; $item.Message = "Simüle edildi$accountText"
                }
                elseif ($PSCmdlet.ShouldProcess($item.SamAccountName, 'Set-ADUser (toplu izin)')) {
                    Set-ADUser @parameters
                    $item.Success = $true
                    $item.Message = $(if ($Mode -eq 'Add') { 'İzin eklendi' } else { 'İzin kaldırıldı' }) + $accountText
                    Write-WorkerLog -Message "$($item.SamAccountName): $($item.Message) ($attribute = '$value')" -Level Success
                }
            }
        }
        catch {
            $item.Message = $_.Exception.Message
            Write-WorkerLog -Message "$(if ($item.SamAccountName) { $item.SamAccountName } else { $guid }): $($_.Exception.Message)" -Level Error
        }
        [pscustomobject]$item
    }
    Set-WorkerProgress -Percent 100 -Status 'Toplu izin tamamlandı.'
}
function global:Set-UserLeave {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter()][AllowEmptyString()][string]$Value = '',
        [Parameter()][ValidateSet('None', 'Disable', 'Enable')][string]$Account = 'None',
        [Parameter()][bool]$ClearLegacy = $false
    )
    if ($Value.Length -gt 1024) { throw 'İzin planı 1024 karakteri aşıyor; bazı dönemleri silin.' }
    $attribute = $Sync.LeaveAttribute
    $parameters = @{ Identity = $Identity; Server = (Get-PdcEmulator); ErrorAction = 'Stop'; Confirm = $false }
    $clear = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($Value) { $parameters.Replace = @{ $attribute = $Value } } else { $clear.Add($attribute) }
    if ($ClearLegacy -and $Sync.LegacyLeaveEndAttribute) { $clear.Add($Sync.LegacyLeaveEndAttribute) }
    if ($clear.Count -gt 0) { $parameters.Clear = $clear.ToArray() }
    if ($Account -ne 'None') { $parameters.Enabled = ($Account -eq 'Enable') }
    $accountText = switch ($Account) { 'Disable' { '; hesap kapatıldı (OU değişmedi)' } 'Enable' { '; hesap açıldı' } default { '' } }
    if ($WhatIfPreference) {
        Write-WorkerLog -Message "[WhatIf] Set-ADUser -Identity $Identity $(if ($Value) { "-Replace @{ $attribute = '$Value' }" } else { "-Clear $attribute" })$(if ($Account -ne 'None') { " -Enabled `$$($Account -eq 'Enable')" })" -Level Warning
        return
    }
    if ($PSCmdlet.ShouldProcess($Identity, 'Set-ADUser (izin planı)')) {
        Set-ADUser @parameters
        Write-WorkerLog -Message "İzin planı kaydedildi ($attribute = '$Value')$accountText." -Level Success
    }
}
