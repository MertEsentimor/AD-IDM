function global:New-LeavePeriod {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][datetime]$Start, [Parameter(Mandatory = $true)][datetime]$Until)
    [pscustomobject]@{ Start = $Start; End = $(if ($Until.TimeOfDay.Ticks -gt 0) { $Until.Date } else { $Until.Date.AddDays(-1) }); Until = $Until }
}
function global:Get-LeaveUntil {
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory = $true)][psobject]$Period)
    if ($Period.PSObject.Properties['Until'] -and $null -ne $Period.Until) { return [datetime]$Period.Until }
    $end = [datetime]$Period.End
    if ($end.TimeOfDay.Ticks -gt 0) { return $end }
    return $end.Date.AddDays(1)
}
function global:Merge-LeavePeriod {
    [CmdletBinding()]
    param([Parameter()][AllowEmptyCollection()][AllowNull()][object[]]$Periods = @())
    $merged = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($period in @($Periods | Where-Object { $_ } | Sort-Object -Property { [datetime]$_.Start })) {
        $start = [datetime]$period.Start
        $until = Get-LeaveUntil -Period $period
        $last = if ($merged.Count -gt 0) { $merged[$merged.Count - 1] } else { $null }
        if ($last -and $start -le $last.Until) { if ($until -gt $last.Until) { $merged[$merged.Count - 1] = New-LeavePeriod -Start $last.Start -Until $until } }
        else { $merged.Add((New-LeavePeriod -Start $start -Until $until)) }
    }
    return $merged.ToArray()
}
function global:Format-LeaveSpan {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][psobject]$Period)
    $start = [datetime]$Period.Start
    $until = Get-LeaveUntil -Period $Period
    $endText = if ($until.TimeOfDay.Ticks -gt 0) { $until.ToString('dd.MM.yyyy HH:mm') + ' (açılış)' } else { $until.AddDays(-1).ToString('dd.MM.yyyy') }
    return '{0} - {1}' -f $start.ToString($(if ($start.TimeOfDay.Ticks -gt 0) { 'dd.MM.yyyy HH:mm' } else { 'dd.MM.yyyy' })), $endText
}
function global:Format-LeaveMoment {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][datetime]$Moment)
    if ($Moment.TimeOfDay.Ticks -gt 0) { return "$($Moment.ToString('dd.MM.yyyy')) saat $($Moment.ToString('HH:mm')) itibarıyla" }
    return "$($Moment.ToString('dd.MM.yyyy')) 00:00'da"
}
function global:ConvertFrom-LeaveValue {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$LegacyEnd
    )
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $parse = {
        param([string]$Text)
        $date = [datetime]::MinValue
        if ([datetime]::TryParseExact(([string]$Text).Trim(), [string[]]@('yyyy-MM-dd', 'yyyy-MM-dd@HH:mm'), $culture, [System.Globalization.DateTimeStyles]::None, [ref]$date)) { $date } else { $null }
    }
    $record = [pscustomobject]@{ Raw = ([string]$Value).Trim(); Owned = $false; Legacy = $false; Periods = @(); Off = ''; Problem = '' }
    if (-not $record.Raw) { return $record }
    $periods = New-Object -TypeName 'System.Collections.Generic.List[object]'
    if ($record.Raw.StartsWith('ADEUM-LEAVE', [System.StringComparison]::OrdinalIgnoreCase)) {
        $record.Owned = $true
        foreach ($item in @($record.Raw.Split(';') | Select-Object -Skip 1)) {
            $item = $item.Trim()
            if (-not $item) { continue }
            if ($item -match '^(?i)OFF=(.*)$') { $record.Off = if ($Matches[1].Trim()) { $Matches[1].Trim() } else { 'yes' }; continue }
            $bounds = @($item -split '\.\.')
            $start = if ($bounds.Count -eq 2) { & $parse $bounds[0] } else { $null }
            $end = if ($bounds.Count -eq 2) { & $parse $bounds[1] } else { $null }
            $until = if (-not $end) { $null } elseif ($end.TimeOfDay.Ticks -gt 0) { $end } else { $end.AddDays(1) }
            if (-not $start -or -not $until -or $until -le $start) { $record.Problem = "hatalı dönem '$item' (beklenen yyyy-MM-dd[@SS:dd]..yyyy-MM-dd[@SS:dd])"; continue }
            $periods.Add((New-LeavePeriod -Start $start -Until $until))
        }
    }
    elseif ($record.Raw -match '^\d{4}-\d{2}-\d{2}$') {
        $start = & $parse $record.Raw
        if (-not $start) { return $record }
        $record.Owned = $true
        $record.Legacy = $true
        $return = & $parse $LegacyEnd
        if (-not $return) { $record.Problem = 'eski kayıtta işe dönüş tarihi yok' }
        elseif ($return -le $start) { $record.Problem = 'eski kayıtta işe dönüş tarihi başlangıçtan önce' }
        else { $periods.Add((New-LeavePeriod -Start $start -Until $return)) }
    }
    $record.Periods = @(Merge-LeavePeriod -Periods $periods.ToArray())
    return $record
}
function global:ConvertTo-LeaveValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyCollection()][AllowNull()][object[]]$Periods = @(),
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Off = ''
    )
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $parts = @(foreach ($period in @(Merge-LeavePeriod -Periods $Periods)) {
            '{0}..{1}' -f $period.Start.ToString($(if ($period.Start.TimeOfDay.Ticks -gt 0) { 'yyyy-MM-dd@HH:mm' } else { 'yyyy-MM-dd' }), $culture),
            $(if ($period.Until.TimeOfDay.Ticks -gt 0) { $period.Until.ToString('yyyy-MM-dd@HH:mm', $culture) } else { $period.End.ToString('yyyy-MM-dd', $culture) })
        })
    if ($Off) { $parts += "OFF=$Off" }
    if ($parts.Count -eq 0) { return '' }
    return 'ADEUM-LEAVE;' + ($parts -join ';')
}
function global:Test-LeaveProtected {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowEmptyString()][string]$DistinguishedName,
        [Parameter()][AllowEmptyString()][string]$Marker,
        [Parameter()][AllowEmptyString()][string]$DisabledOu
    )
    if ($Marker -and $Marker.StartsWith('ADEUM-PreviousOU=', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return [bool]($DisabledOu -and $DistinguishedName -and $DistinguishedName.EndsWith(",$DisabledOu", [System.StringComparison]::OrdinalIgnoreCase))
}
function global:Get-LeaveState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][psobject]$Record,
        [Parameter()][bool]$Enabled = $true,
        [Parameter()][bool]$Protected = $false,
        [Parameter()][datetime]$Date = (Get-Date)
    )
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $moment = $Date
    $day = $Date.Date
    $future = @($Record.Periods | Where-Object { $_ -and $_.Until -gt $moment })
    $active = @($future | Where-Object { $_.Start -le $moment }) | Select-Object -First 1
    $next = @($future | Where-Object { $_.Start -gt $moment }) | Select-Object -First 1
    $off = [string]$Record.Off
    if ($Record.Legacy -and -not $Enabled -and -not $off -and @($Record.Periods).Count -gt 0) { $off = $Record.Periods[0].Start.ToString('yyyy-MM-dd', $culture) }
    $kind = 'None'
    $action = 'None'
    if (-not $Record.Owned) { $kind = 'None' }
    elseif ($Record.Problem) { $kind = 'Invalid' }
    elseif ($active) {
        if ($Protected) { $kind = 'Protected' }
        elseif ($Enabled) { $kind = 'Starting'; $action = 'Disable'; $off = $day.ToString('yyyy-MM-dd', $culture) }
        elseif ($off) { $kind = 'OnLeave' }
        else { $kind = 'DisabledOther' }
    }
    elseif ($off) {
        if ($Protected -or $Enabled) { $kind = if ($next) { 'Planned' } else { 'Ended' } }
        else { $kind = 'Ending'; $action = 'Enable' }
        $off = ''
    }
    elseif ($next) { $kind = 'Planned' }
    else { $kind = 'Ended' }
    $newValue = $Record.Raw
    if ($Record.Owned -and $kind -ne 'Invalid') {
        $newValue = ConvertTo-LeaveValue -Periods $future -Off $off
        if ($action -eq 'None' -and ($Record.Legacy -or -not [string]::Equals($newValue, $Record.Raw, [System.StringComparison]::Ordinal))) { $action = 'Update' }
    }
    $text = switch ($kind) {
        'Invalid' { "Hatalı izin kaydı: $($Record.Problem)" }
        'Protected' { "İzin süresinde, ancak hesap DisabledUsers OU'sunda: gece görevi bu hesabı açıp kapatmaz" }
        'Starting' { "İzin başladı ($($active.Start.ToString($(if ($active.Start.TimeOfDay.Ticks -gt 0) { 'dd.MM.yyyy HH:mm' } else { 'dd.MM.yyyy' })))) ama hesap açık" }
        'OnLeave' { "İzinde: hesap kapalı, $(Format-LeaveMoment -Moment $active.Until) açılacak" }
        'DisabledOther' { 'İzin süresinde; hesap başka bir nedenle zaten kapalı, izin bitince açılmayacak' }
        'Ending' { 'İzin bitti ama hesap hâlâ kapalı' }
        'Planned' { "Planlı izin: $(Format-LeaveSpan -Period $next), hesap $(Format-LeaveMoment -Moment $next.Start) kapanacak" }
        'Ended' { if ($action -eq 'Update') { 'Biten izin kaydı temizlenecek' } else { 'İzin kaydı yok' } }
        default { 'İzin kaydı yok' }
    }
    [pscustomobject]@{
        Date        = $day
        Kind        = $kind
        Action      = $action
        Text        = $text
        NewValue    = $newValue
        Off         = $off
        Active      = $active
        Next        = $next
        Periods     = $future
        ClearLegacy = [bool]$Record.Legacy -and $action -ne 'None'
    }
}
function global:Get-UserLeaveInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][psobject]$User,
        [Parameter()][bool]$Enabled = $true,
        [Parameter()][bool]$Protected = $false
    )
    $legacy = $Sync.LegacyLeaveEndAttribute
    $record = ConvertFrom-LeaveValue -Value ([string]$User.($Sync.LeaveAttribute)) -LegacyEnd $(if ($legacy) { [string]$User.$legacy } else { '' })
    [pscustomobject]@{
        Attribute = $Sync.LeaveAttribute
        Raw       = $record.Raw
        Owned     = $record.Owned
        Legacy    = $record.Legacy
        Off       = $record.Off
        Problem   = $record.Problem
        Periods   = $record.Periods
        Protected = $Protected
        State     = Get-LeaveState -Record $record -Enabled $Enabled -Protected $Protected
    }
}
