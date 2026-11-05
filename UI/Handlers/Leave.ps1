function Merge-LeavePeriodUi {
    [CmdletBinding()]
    param([Parameter()][AllowEmptyCollection()][AllowNull()][object[]]$Periods = @())
    $merged = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($period in @($Periods | Where-Object { $_ } | Sort-Object -Property { [datetime]$_.Start })) {
        $start = [datetime]$period.Start
        $until = Get-LeaveUntilUi -Period $period
        $last = if ($merged.Count -gt 0) { $merged[$merged.Count - 1] } else { $null }
        if ($last -and $start -le $last.Until) { if ($until -gt $last.Until) { $merged[$merged.Count - 1] = New-LeavePeriodUi -Start $last.Start -Until $until } }
        else { $merged.Add((New-LeavePeriodUi -Start $start -Until $until)) }
    }
    return $merged.ToArray()
}
function New-LeavePeriodUi {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][datetime]$Start, [Parameter(Mandatory = $true)][datetime]$Until)
    [pscustomobject]@{ Start = $Start; End = $(if ($Until.TimeOfDay.Ticks -gt 0) { $Until.Date } else { $Until.Date.AddDays(-1) }); Until = $Until }
}
function Get-LeaveUntilUi {
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory = $true)][psobject]$Period)
    if ($Period.PSObject.Properties['Until'] -and $null -ne $Period.Until) { return [datetime]$Period.Until }
    $end = [datetime]$Period.End
    if ($end.TimeOfDay.Ticks -gt 0) { return $end }
    return $end.Date.AddDays(1)
}
function ConvertTo-LeaveValueUi {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyCollection()][AllowNull()][object[]]$Periods = @(),
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Off = ''
    )
    $parts = @(foreach ($period in @(Merge-LeavePeriodUi -Periods $Periods)) { Get-LeavePeriodKey -Period $period })
    if ($Off) { $parts += "OFF=$Off" }
    if ($parts.Count -eq 0) { return '' }
    return 'ADEUM-LEAVE;' + ($parts -join ';')
}
function Get-LeavePeriodKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][psobject]$Period)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $start = [datetime]$Period.Start
    $until = Get-LeaveUntilUi -Period $Period
    return '{0}..{1}' -f $start.ToString($(if ($start.TimeOfDay.Ticks -gt 0) { 'yyyy-MM-dd@HH:mm' } else { 'yyyy-MM-dd' }), $culture),
    $(if ($until.TimeOfDay.Ticks -gt 0) { $until.ToString('yyyy-MM-dd@HH:mm', $culture) } else { $until.AddDays(-1).ToString('yyyy-MM-dd', $culture) })
}
function ConvertFrom-LeaveStartTime {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Text)
    $value = ([string]$Text).Trim()
    if (-not $value -or $value.StartsWith('Tam', [System.StringComparison]::OrdinalIgnoreCase) -or $value.StartsWith('Ertesi', [System.StringComparison]::OrdinalIgnoreCase)) { return [timespan]::Zero }
    if ($value -notmatch '^(\d{1,2})[:.](\d{2})$') { return $null }
    $time = New-TimeSpan -Hours ([int]$Matches[1]) -Minutes ([int]$Matches[2])
    if ([int]$Matches[2] -gt 59 -or $time.TotalMinutes -ge (23 * 60 + 30)) { return $null }
    return $time
}
function Get-LeaveStartText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][datetime]$Start, [Parameter()][string]$DayFormat = 'dd.MM.yyyy')
    if ($Start.TimeOfDay.Ticks -gt 0) { return "$($Start.ToString($DayFormat)) saat $($Start.ToString('HH:mm')) itibarıyla" }
    return "$($Start.ToString($DayFormat)) 00:00'da"
}
function Format-LeaveDuration {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][datetime]$Start, [Parameter(Mandatory = $true)][datetime]$Until)
    $tr = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
    $days = 0.0
    $work = 0.0
    for ($day = $Start.Date; $day -lt $Until; $day = $day.AddDays(1)) {
        $from = if ($Start -gt $day) { $Start } else { $day }
        $to = if ($Until -lt $day.AddDays(1)) { $Until } else { $day.AddDays(1) }
        $part = ($to - $from).TotalHours / 24
        $days += $part
        if ($day.DayOfWeek -ne [DayOfWeek]::Saturday -and $day.DayOfWeek -ne [DayOfWeek]::Sunday) { $work += $part }
    }
    $round = { param([double]$Value) ([math]::Round($Value * 2, [System.MidpointRounding]::AwayFromZero) / 2).ToString('0.#', $tr) }
    return '{0} gün ({1} iş günü)' -f (& $round $days), (& $round $work)
}
function Format-LeavePeriod {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][psobject]$Period)
    $start = [datetime]$Period.Start
    $until = Get-LeaveUntilUi -Period $Period
    $endText = if ($until.TimeOfDay.Ticks -gt 0) { $until.ToString('dd.MM.yyyy ddd HH:mm') + ' (açılış)' } else { $until.AddDays(-1).ToString('dd.MM.yyyy ddd') }
    return '{0} - {1}' -f $start.ToString($(if ($start.TimeOfDay.Ticks -gt 0) { 'dd.MM.yyyy ddd HH:mm' } else { 'dd.MM.yyyy ddd' })), $endText
}
function Get-LeaveChange {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $result = [pscustomobject]@{ Changed = $false; Value = ''; Account = ''; Candidate = ''; ClearLegacy = $false; Active = $false; Summary = @(); Audit = @() }
    $data = $script:State.CurrentData
    if (-not $data -or -not $data.Ad.Leave) { return $result }
    $leave = $data.Ad.Leave
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $now = Get-Date
    $today = $now.Date
    $enabled = [bool]$data.Ad.Enabled
    $originalPeriods = @(Merge-LeavePeriodUi -Periods @($leave.Periods | Where-Object { $_ -and (Get-LeaveUntilUi -Period $_) -gt $today }))
    $periods = @(Merge-LeavePeriodUi -Periods $script:State.LeaveEdit.ToArray())
    $result.Active = @($periods | Where-Object { $_.Start -le $now -and $_.Until -gt $now }).Count -gt 0
    $off = [string]$leave.Off
    if ($leave.Legacy -and -not $enabled -and -not $off -and @($leave.Periods).Count -gt 0) { $off = ([datetime]@($leave.Periods)[0].Start).ToString('yyyy-MM-dd', $culture) }
    $result.Candidate = if ($leave.Protected) { '' } elseif ($result.Active -and $enabled) { 'Disable' } elseif (-not $result.Active -and $off -and -not $enabled) { 'Enable' } else { '' }
    $result.Account = if ($result.Candidate -and [bool]$script:Ui.chkLeaveNow.IsChecked -and $script:State.LeaveNowCandidate -eq $result.Candidate) { $result.Candidate } else { '' }
    $currentOff = if (-not $enabled) { $off } else { '' }
    $newOff = switch ($result.Account) { 'Disable' { $today.ToString('yyyy-MM-dd', $culture) } 'Enable' { '' } default { $currentOff } }
    $result.Value = ConvertTo-LeaveValueUi -Periods $periods -Off $newOff
    $originalValue = ConvertTo-LeaveValueUi -Periods $originalPeriods -Off $currentOff
    $result.ClearLegacy = [bool]$leave.Legacy
    $result.Changed = [bool]$result.Account -or -not [string]::Equals($result.Value, $originalValue, [System.StringComparison]::Ordinal)
    if (-not $result.Changed) { return $result }
    $key = { param($Period) Get-LeavePeriodKey -Period $Period }
    $originalKeys = @($originalPeriods | ForEach-Object { & $key $_ })
    $newKeys = @($periods | ForEach-Object { & $key $_ })
    $summary = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $audit = New-Object -TypeName 'System.Collections.Generic.List[hashtable]'
    $attribute = [string]$leave.Attribute
    foreach ($period in $periods) {
        $text = & $key $period
        if ($originalKeys -contains $text) { continue }
        $summary.Add("İzin  |  Eklenecek: $(Format-LeavePeriod -Period $period)  (hesap $(Get-LeaveStartText -Start $period.Start) kapanır, $(Get-LeaveStartText -Start $period.Until) açılır)")
        $audit.Add(@{ Step = 'Leave'; Action = 'user.leave.add'; Category = 'leave'; Field = $attribute; Label = 'İzin dönemi'; Operation = 'add'; Old = ''; New = $text })
    }
    foreach ($period in $originalPeriods) {
        $text = & $key $period
        if ($newKeys -contains $text) { continue }
        $summary.Add("İzin  |  Kaldırılacak: $(Format-LeavePeriod -Period $period)")
        $audit.Add(@{ Step = 'Leave'; Action = 'user.leave.remove'; Category = 'leave'; Field = $attribute; Label = 'İzin dönemi'; Operation = 'remove'; Old = $text; New = '' })
    }
    if ($result.Account -eq 'Disable') {
        $summary.Add('İzin  |  Hesap şimdi devre dışı bırakılacak (OU değişmez; izin bitince açılır)')
        $audit.Add(@{ Step = 'Leave'; Action = 'leave.account.disable'; Category = 'leave'; Field = 'Enabled'; Operation = 'set'; Old = $true; New = $false })
    }
    elseif ($result.Account -eq 'Enable') {
        $summary.Add('İzin  |  Hesap şimdi etkinleştirilecek (sürmekte olan izin yok)')
        $audit.Add(@{ Step = 'Leave'; Action = 'leave.account.enable'; Category = 'leave'; Field = 'Enabled'; Operation = 'set'; Old = $false; New = $true })
    }
    if ($summary.Count -eq 0) {
        $summary.Add("İzin  |  Kayıt güncellenecek: '$originalValue' -> '$($result.Value)'")
        $audit.Add(@{ Step = 'Leave'; Action = 'user.leave.change'; Category = 'leave'; Field = $attribute; Operation = 'set'; Old = $originalValue; New = $result.Value })
    }
    $result.Summary = $summary.ToArray()
    $result.Audit = $audit.ToArray()
    return $result
}
function Show-LeaveStatus {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    $ui = $script:Ui
    if (-not $data -or -not $data.Ad.Leave) {
        Set-Badge -BorderName bdLeaveStatus -TextName txtLeaveStatus -Text 'Kullanıcı seçilmedi.' -Kind Neutral
        $ui.txtLeaveAttributes.Text = ''
        return
    }
    $leave = $data.Ad.Leave
    $state = $leave.State
    $ui.txtLeaveAttributes.Text = "Hesaplar Manager'ın gece görevi tarafından tam 00:00'da kapatılıp açılır (kurulum ve durum: İzin Planı penceresi). " +
    "Kayıt '$($leave.Attribute)' özniteliğinde tutulur. İzin nedeniyle kapatılan hesabın OU'su değişmez; başka bir nedenle kapalı olan hesaplar izin bitince açılmaz."
    if ($leave.Raw -and -not $leave.Owned) {
        Set-Badge -BorderName bdLeaveStatus -TextName txtLeaveStatus -Kind Warning -Text "'$($leave.Attribute)' özniteliğinde izin dışı bir değer var ('$($leave.Raw)'). İzin eklerseniz bu değer silinir."
        return
    }
    $legacy = if ($leave.Legacy) { ' Bu kayıt eski personel izin sisteminden geliyor; ilk kayıtta veya gece görevinde yeni biçime çevrilir.' } else { '' }
    switch ([string]$state.Kind) {
        'Planned' { Set-Badge -BorderName bdLeaveStatus -TextName txtLeaveStatus -Kind Accent -Text "$($state.Text).$legacy" }
        'OnLeave' { Set-Badge -BorderName bdLeaveStatus -TextName txtLeaveStatus -Kind Success -Text "$($state.Text).$legacy" }
        'Starting' { Set-Badge -BorderName bdLeaveStatus -TextName txtLeaveStatus -Kind Warning -Text "$($state.Text): gece görevi çalışmamış ya da izin sonradan girilmiş olabilir. Aşağıdaki 'Hesabı şimdi kapat' ile hemen kapatabilirsiniz; aksi halde bu gece 00:00'da kapanır.$legacy" }
        'Ending' { Set-Badge -BorderName bdLeaveStatus -TextName txtLeaveStatus -Kind Warning -Text "$($state.Text): gece görevi çalışmamış olabilir. Aşağıdaki 'Hesabı şimdi aç' ile hemen açabilirsiniz; aksi halde bu gece 00:00'da açılır.$legacy" }
        'DisabledOther' { Set-Badge -BorderName bdLeaveStatus -TextName txtLeaveStatus -Kind Neutral -Text "$($state.Text).$legacy" }
        'Protected' { Set-Badge -BorderName bdLeaveStatus -TextName txtLeaveStatus -Kind Neutral -Text "$($state.Text).$legacy" }
        'Invalid' { Set-Badge -BorderName bdLeaveStatus -TextName txtLeaveStatus -Kind Error -Text "$($state.Text). Kayıtlı değer: '$($leave.Raw)'. Dönemleri yeniden girip kaydedin; hatalı kısım silinir." }
        default { Set-Badge -BorderName bdLeaveStatus -TextName txtLeaveStatus -Kind Neutral -Text "Bu kullanıcı için planlı izin yok.$legacy" }
    }
}
function Update-LeaveView {
    [CmdletBinding()]
    param()
    $ui = $script:Ui
    $data = $script:State.CurrentData
    $loaded = [bool]$data
    $now = Get-Date
    $today = $now.Date
    $originalKeys = @(if ($loaded -and $data.Ad.Leave) { @($data.Ad.Leave.Periods | Where-Object { $_ }) | ForEach-Object { Get-LeavePeriodKey -Period $_ } })
    $items = @(foreach ($period in @(Merge-LeavePeriodUi -Periods $script:State.LeaveEdit.ToArray())) {
            $key = Get-LeavePeriodKey -Period $period
            $kind = if ($originalKeys -notcontains $key) { 'New' } elseif ($period.Start -le $now) { 'Active' } else { 'Planned' }
            [pscustomobject]@{
                Start  = $period.Start
                End    = $period.End
                Until  = $period.Until
                Kind   = $kind
                Status = switch ($kind) { 'New' { 'Yeni (kaydedilmedi)' } 'Active' { 'Devam ediyor' } default { 'Planlı' } }
                Text   = Format-LeavePeriod -Period $period
                Detail = "$(Format-LeaveDuration -Start $period.Start -Until $period.Until)  |  kapanış $($period.Start.ToString('dd.MM.yyyy HH:mm')), açılış $($period.Until.ToString('dd.MM.yyyy HH:mm'))"
            }
        })
    $ui.lstLeave.ItemsSource = $items
    $ui.txtLeaveEmpty.Visibility = if ($items.Count -gt 0) { 'Collapsed' } else { 'Visible' }
    $summary = ''
    $warning = ''
    $start = $ui.dpLeaveStart.SelectedDate
    $end = $ui.dpLeaveEnd.SelectedDate
    $time = ConvertFrom-LeaveStartTime -Text $ui.cmbLeaveStartTime.Text
    $endTime = ConvertFrom-LeaveStartTime -Text $ui.cmbLeaveEndTime.Text
    if ($null -eq $time -or $null -eq $endTime) { $warning = "Saatler SS:dd biçiminde olmalı (ör. 13:00) ve 23:30'dan önce olmalı. Saat girmezseniz hesap ilk gün 00:00'da kapanır, işe başlangıç günü 00:00'da açılır." }
    elseif ($start -and $end) {
        $first = ([datetime]$start).Date.Add($time)
        $until = ([datetime]$end).Date.Add($endTime)
        if ($until.Date -le $first.Date -and $endTime.Ticks -eq 0) { $warning = 'İşe başlangıç tarihi, ilk izin gününden sonra olmalı.' }
        elseif ($until -le $first) { $warning = 'Açılış saati kapanış saatinden sonra olmalı.' }
        elseif ($until -le $now) { $warning = 'Tamamı geçmişte kalan bir izin eklenemez.' }
        else {
            $summary = "$(Format-LeaveDuration -Start $first -Until $until). Hesap $(Get-LeaveStartText -Start $first -DayFormat 'dd.MM.yyyy dddd') kapanır, $(Get-LeaveStartText -Start $until -DayFormat 'dd.MM.yyyy dddd') açılır."
            if ($first -le $now) { $summary += ' İzin başlamış olduğu için kaydederken hesabı hemen kapatabilirsiniz.' }
        }
    }
    elseif ($start -or $end) { $summary = 'İlk izin gününü ve işe başlangıç tarihini seçin.' }
    $ui.txtLeaveSummary.Text = $summary
    $ui.txtLeaveSummary.Visibility = if ($summary) { 'Visible' } else { 'Collapsed' }
    $ui.txtLeaveWarning.Text = $warning
    $ui.txtLeaveWarning.Visibility = if ($warning) { 'Visible' } else { 'Collapsed' }
    $ui.btnLeaveAdd.IsEnabled = $loaded -and [bool]$start -and [bool]$end -and -not $warning
    $change = Get-LeaveChange
    if ($change.Candidate -ne $script:State.LeaveNowCandidate) {
        $script:State.LeaveNowCandidate = [string]$change.Candidate
        $ui.chkLeaveNow.IsChecked = [bool]$change.Candidate
    }
    $ui.bdLeaveNow.Visibility = if ($change.Candidate) { 'Visible' } else { 'Collapsed' }
    if ($change.Candidate -eq 'Disable') {
        $ui.txtLeaveNowGlyph.Text = [string][char]0xE72E
        $ui.txtLeaveNowTitle.Text = 'Hesabı şimdi kapat'
        $ui.txtLeaveNowText.Text = "İzin şu an sürüyor ve hesap açık. Açıksa sepet uygulanınca hesap hemen devre dışı bırakılır (OU değişmez) ve izin bitince açılır; kapalıysa gece görevi bu gece 00:00'da kapatır."
    }
    elseif ($change.Candidate -eq 'Enable') {
        $ui.txtLeaveNowGlyph.Text = [string][char]0xE785
        $ui.txtLeaveNowTitle.Text = 'Hesabı şimdi aç'
        $ui.txtLeaveNowText.Text = "Hesap izin nedeniyle kapatılmıştı ve artık sürmekte olan izin yok. Açıksa sepet uygulanınca hesap hemen etkinleştirilir; kapalıysa gece görevi bu gece 00:00'da açar."
    }
}
function Set-LeaveDuration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateRange(1, 366)][int]$Days)
    $ui = $script:Ui
    if (-not $ui.dpLeaveStart.SelectedDate) { $ui.dpLeaveStart.SelectedDate = (Get-Date).Date.AddDays(1) }
    $ui.dpLeaveEnd.SelectedDate = ([datetime]$ui.dpLeaveStart.SelectedDate).Date.AddDays($Days)
}
function Set-LeaveEditList {
    [CmdletBinding()]
    param([Parameter()][AllowEmptyCollection()][object[]]$Periods = @())
    $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($period in @(Merge-LeavePeriodUi -Periods $Periods)) { $list.Add($period) }
    $script:State.LeaveEdit = $list
    Update-LeaveView
    Update-ChangeIndicator
}
function Add-LeavePeriod {
    [CmdletBinding()]
    param()
    $ui = $script:Ui
    if (-not $script:State.CurrentData -or -not $ui.dpLeaveStart.SelectedDate -or -not $ui.dpLeaveEnd.SelectedDate) { return }
    $time = ConvertFrom-LeaveStartTime -Text $ui.cmbLeaveStartTime.Text
    $endTime = ConvertFrom-LeaveStartTime -Text $ui.cmbLeaveEndTime.Text
    if ($null -eq $time -or $null -eq $endTime) { Update-LeaveView; return }
    $first = ([datetime]$ui.dpLeaveStart.SelectedDate).Date.Add($time)
    $until = ([datetime]$ui.dpLeaveEnd.SelectedDate).Date.Add($endTime)
    if ($until -le $first -or $until -le (Get-Date)) { Update-LeaveView; return }
    $target = $script:State.LeaveEditTarget
    $existing = @($script:State.LeaveEdit.ToArray())
    if ($target) { $existing = @($existing | Where-Object { -not ($_.Start -eq $target.Start -and (Get-LeaveUntilUi -Period $_) -eq $target.Until) }) }
    $before = $existing.Count
    $merged = @(Merge-LeavePeriodUi -Periods (@($existing) + @(New-LeavePeriodUi -Start $first -Until $until)))
    if ($merged.Count -le $before) { Write-UiLog -Message 'İzin mevcut bir dönemle çakıştığı veya bitiştiği için o dönemle birleştirildi.' -Level Info }
    if ($target) {
        Write-UiLog -Message "İzin dönemi güncellendi: $(Format-LeavePeriod -Period $target) -> $(Format-LeavePeriod -Period (New-LeavePeriodUi -Start $first -Until $until)). Kaydetmek için sepeti uygulayın." -Level Info
    }
    Set-LeaveEditTarget -Period $null
    Set-LeaveEditList -Periods $merged
}
function Set-LeaveEditTarget {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Period)
    $ui = $script:Ui
    $script:State.LeaveEditTarget = if ($Period) { [pscustomobject]@{ Start = [datetime]$Period.Start; End = $Period.End; Until = [datetime]$Period.Until } } else { $null }
    if (-not $Period) {
        $ui.txtLeaveNewTitle.Text = 'Yeni izin ekle'
        $ui.btnLeaveAdd.Content = 'Listeye Ekle'
        $ui.btnLeaveEditCancel.Visibility = 'Collapsed'
        $ui.dpLeaveStart.SelectedDate = $null
        $ui.dpLeaveEnd.SelectedDate = $null
        $ui.cmbLeaveStartTime.SelectedIndex = 0
        $ui.cmbLeaveEndTime.SelectedIndex = 0
        return
    }
    $start = [datetime]$Period.Start
    $until = [datetime]$Period.Until
    $ui.txtLeaveNewTitle.Text = "İzni düzenle: $(Format-LeavePeriod -Period $Period)"
    $ui.btnLeaveAdd.Content = 'Değişikliği Uygula'
    $ui.btnLeaveEditCancel.Visibility = 'Visible'
    $ui.dpLeaveStart.SelectedDate = $start.Date
    $ui.dpLeaveEnd.SelectedDate = $until.Date
    foreach ($pair in @(@('cmbLeaveStartTime', $start.TimeOfDay), @('cmbLeaveEndTime', $until.TimeOfDay))) {
        $combo = $ui[$pair[0]]
        if (([timespan]$pair[1]).Ticks -eq 0) { $combo.SelectedIndex = 0 }
        else { $combo.SelectedIndex = -1; $combo.Text = ([timespan]$pair[1]).ToString('hh\:mm') }
    }
    Update-LeaveView
}
function Edit-LeavePeriod {
    [CmdletBinding()]
    param()
    $item = $script:Ui.lstLeave.SelectedItem
    if (-not $item) { Write-UiLog -Message 'Düzenlemek için listeden bir izin dönemi seçin.' -Level Info; return }
    Set-LeaveEditTarget -Period $item
    [void]$script:Ui.dpLeaveStart.Focus()
}
function Remove-LeavePeriod {
    [CmdletBinding()]
    param()
    $item = $script:Ui.lstLeave.SelectedItem
    if (-not $item) { Write-UiLog -Message 'Kaldırmak için listeden bir izin dönemi seçin.' -Level Info; return }
    if ($script:State.LeaveEditTarget) { Set-LeaveEditTarget -Period $null }
    Set-LeaveEditList -Periods @($script:State.LeaveEdit | Where-Object { -not ($_.Start -eq $item.Start -and (Get-LeaveUntilUi -Period $_) -eq $item.Until) })
}
function Clear-LeavePeriod {
    [CmdletBinding()]
    param()
    if ($script:State.LeaveEdit.Count -eq 0) { return }
    if ($script:State.LeaveEditTarget) { Set-LeaveEditTarget -Period $null }
    Set-LeaveEditList -Periods @()
}
function Start-LeaveScheduleLoad {
    [CmdletBinding()]
    param()
    $script:Ui.txtLvSummary.Text = 'İzin kayıtları okunuyor...'
    $started = Invoke-BackgroundTask -Name 'İzin planı okunuyor' -Command 'Get-LeaveOverview' -OnSuccess {
        param($Result)
        $overview = @($Result | Where-Object { $_ -and $_.PSObject.Properties['Users'] }) | Select-Object -Last 1
        $script:State.LeaveList = @($overview.Users | Where-Object { $_ })
        $script:State.LeaveTask = $overview.Task
        Update-LeaveScheduleView
    } -OnFailure {
        param($Message)
        $script:Ui.txtLvSummary.Text = "Liste okunamadı: $Message"
    }
    if (-not $started) { $script:Ui.txtLvSummary.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' }
}
function Update-LeaveScheduleView {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $filter = ([string]$c.txtLvFilter.Text).Trim()
    $problemOnly = [bool]$c.chkLvProblem.IsChecked
    $activeOnly = [bool]$c.chkLvActive.IsChecked
    $tonightOnly = [bool]$c.chkLvTonight.IsChecked
    $all = @($script:State.LeaveList)
    $comparison = [System.StringComparison]::CurrentCultureIgnoreCase
    $items = @($all | Where-Object {
            (-not $problemOnly -or $_.Problem) -and (-not $activeOnly -or @('OnLeave', 'Starting') -contains $_.Kind) -and (-not $tonightOnly -or $_.TonightText) -and
            (-not $filter -or ("$($_.Name) $($_.SamAccountName)").IndexOf($filter, $comparison) -ge 0)
        })
    $c.lstLv.ItemsSource = $items
    $c.txtLvInfo.Text = "Öznitelik: $($script:Sync.LeaveAttribute)  |  Bugün: $((Get-Date).ToString('dd.MM.yyyy dddd'))  |  Hesaplar izin günlerinde 00:00'da kapanır, izin bitince 00:00'da açılır; saat girilmiş izinlerde o saatte."
    $onLeave = @($all | Where-Object { $_.Kind -eq 'OnLeave' }).Count
    $planned = @($all | Where-Object { $_.Kind -eq 'Planned' }).Count
    $problem = @($all | Where-Object { $_.Problem }).Count
    $closing = @($all | Where-Object { $_.TonightText -like '*kapanacak' }).Count
    $opening = @($all | Where-Object { $_.TonightText -like '*açılacak' }).Count
    $c.txtLvSummary.Text = "$($all.Count) kayıt: $onLeave izinde, $planned planlı, $problem sorunlu (sarı satırlar). Sıradaki işlemler (bugün izin saatinde / gece 00:00): $closing hesap kapanacak, $opening hesap açılacak. Gösterilen: $($items.Count)."
    $task = $script:State.LeaveTask
    $tokens = if ($task -and $task.Healthy) { 'SuccessBgBrush', 'SuccessBrush' } else { 'WarningBgBrush', 'WarningBrush' }
    $c.bdLvTask.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $tokens[0])
    $c.bdLvTask.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, $tokens[1])
    $c.txtLvTask.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $tokens[1])
    $c.txtLvTaskGlyph.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $tokens[1])
    $c.txtLvTask.Text = if ($task) { [string]$task.Text } else { 'Gece görevinin durumu okunamadı (ScheduledTasks modülü yok olabilir).' }
    $c.btnLvInstall.Content = if ($task -and $task.Installed) { 'Görevi Yeniden Kur' } else { 'Gece Görevini Kur' }
}
function Export-LeaveSchedule {
    [CmdletBinding()]
    param()
    $items = @($script:Ui.lstLv.ItemsSource)
    if ($items.Count -eq 0) { $script:Ui.txtLvSummary.Text = 'Kaydedilecek kayıt yok.'; return }
    $dialog = New-Object -TypeName Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'CSV dosyası (*.csv)|*.csv'
    $dialog.FileName = 'IzinPlani_{0:yyyyMMdd}.csv' -f (Get-Date)
    if (-not $dialog.ShowDialog($script:Window)) { return }
    $items | Select-Object -Property @{ n = 'Ad'; e = { $_.Name } }, SamAccountName, @{ n = 'İzin dönemleri'; e = { $_.PeriodsText } },
    @{ n = 'Hesap'; e = { $_.AccountText } }, @{ n = 'Sıradaki'; e = { $_.TonightText } }, @{ n = 'Durum'; e = { $_.StatusText } }, @{ n = 'Kayıt'; e = { $_.PeriodsRaw } } |
        Export-Csv -Path $dialog.FileName -NoTypeInformation -Encoding UTF8 -Delimiter ';' -ErrorAction Stop
    $script:Ui.txtLvSummary.Text = "Kaydedildi: $($dialog.FileName)"
    Write-UiLog -Message "İzin planı kaydedildi: $($dialog.FileName)" -Level Success
}
function Start-LeaveApply {
    [CmdletBinding()]
    param([Parameter()][switch]$Execute)
    $arguments = @{ Date = (Get-Date); Confirm = $false }
    if (-not $Execute -or $script:State.Options.WhatIf) { $arguments.WhatIf = $true }
    $script:State.LeaveApplyExecute = [bool]$Execute
    $name = if ($Execute) { 'İzin planı uygulanıyor' } else { 'Yapılacak izin işlemleri hesaplanıyor' }
    [void](Invoke-BackgroundTask -Name $name -Command 'Invoke-LeaveEnforcement' -Arguments $arguments -OnSuccess {
            param($Result)
            $summary = @($Result | Where-Object { $_ -and $_.PSObject.Properties['Results'] }) | Select-Object -Last 1
            if (-not $summary) { return }
            $items = @($summary.Results | Where-Object { $_ })
            if (-not $script:State.LeaveApplyExecute) {
                if ($items.Count -eq 0) { [void](Show-MessageDialog -Message 'Şu an yapılacak izin işlemi yok: tüm hesaplar bugünün izin planına uygun.'); return }
                $lines = @($items | Select-Object -First 15 | ForEach-Object { "- $($_.Name) ($($_.SamAccountName)): $(switch ($_.Action) { 'Disable' { 'hesap kapatılacak' } 'Enable' { 'hesap açılacak' } default { 'kayıt güncellenecek' } })" })
                if ($items.Count -gt 15) { $lines += "- ... ve $($items.Count - 15) işlem daha" }
                $message = "Bugünün izin planına göre aşağıdaki $($items.Count) işlem şimdi uygulanacak:`n`n$($lines -join "`n")`n`nDevam edilsin mi?"
                if (Confirm-Action -Message $message -Title 'İzin Planını Uygula') { Invoke-Deferred { Start-LeaveApply -Execute } }
                return
            }
            Write-LeaveAuditResult -Summary $summary -Trigger manual
            $failed = @($items | Where-Object { -not $_.Success }).Count
            $prefix = if ($summary.Simulated) { '[Simülasyon] ' } else { '' }
            Write-UiLog -Message "${prefix}İzin planı uygulandı: $($items.Count) işlem, $failed hata." -Level $(if ($failed -gt 0) { 'Warning' } else { 'Success' })
            if ($failed -gt 0) { [void](Show-MessageDialog -Message "$failed işlem başarısız oldu; ayrıntılar işlem günlüğünde." -Icon Warning) }
            Invoke-Deferred { Start-LeaveScheduleLoad }
        })
}
function Start-LeaveTaskInstall {
    [CmdletBinding()]
    param()
    $path = $script:ScriptFullPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { [void](Show-MessageDialog -Message 'Betik dosyasının yolu belirlenemedi. Görevi PowerShell''den kurun: .\<betik>.ps1 -InstallLeaveTask' -Icon Warning); return }
    $message = "Gece izin görevi bu bilgisayara ($env:COMPUTERNAME) kurulacak: her gün 23:58'de başlar ve işlemleri tam 00:00:00'da uygular.`n`n" +
    "Yönetici izni istenir; açılan pencerede görevin çalışacağı HİZMET hesabı sorulur (gMSA önerilir, ör. DOMAIN\gmsa-izin`$). Kendi hesabınız kabul edilmez: hesabınız kapanırsa gece görevi de durur. Bu bilgisayarın sürekli açık kalması gerekir.`n`nDevam edilsin mi?"
    if (-not (Confirm-Action -Message $message -Title 'Gece Görevini Kur')) { return }
    $exe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = ('-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" -InstallLeaveTask {1}' -f $path, ($script:LeaveTaskArgs -join ' ')).Trim()
    try {
        Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
        Write-UiLog -Message "Gece görevi kurulumu yönetici penceresinde başlatıldı. Bitince İzin Planı'nda 'Yenile' ile durumu kontrol edin." -Level Info
    }
    catch { [void](Show-MessageDialog -Message "Kurulum başlatılamadı (yönetici izni verilmemiş olabilir):`n`n$($_.Exception.Message)" -Icon Warning) }
}
function New-BulkLeaveTable {
    [CmdletBinding()]
    [OutputType([System.Data.DataTable])]
    param()
    $table = New-Object -TypeName System.Data.DataTable -ArgumentList 'BulkLeave'
    foreach ($column in @(@('Selected', [bool]), @('Wanted', [bool]), @('Selectable', [bool]), @('ObjectGuid', [string]), @('Name', [string]), @('SamAccountName', [string]),
            @('DeptText', [string]), @('PeriodsText', [string]), @('Note', [string]), @('Kind', [string]), @('Block', [string]), @('Enabled', [bool]),
            @('Off', [string]), @('Periods', [object]), @('Result', [string]), @('ResultKind', [string]))) {
        [void]$table.Columns.Add($column[0], $column[1])
    }
    $table.PrimaryKey = @($table.Columns['ObjectGuid'])
    $table.Add_ColumnChanged({
            param($sender, $e)
            if ($e.Column.ColumnName -ne 'Selected' -or $script:State.BulkLeave.Updating) { return }
            $script:State.BulkLeave.Updating = $true
            try { $e.Row['Wanted'] = [bool]$e.Row['Selected'] } finally { $script:State.BulkLeave.Updating = $false }
            Invoke-UiAction { Update-BulkLeaveSummary }
        })
    return , $table
}
function Get-BulkLeaveRange {
    [CmdletBinding()]
    param()
    $c = $script:State.BulkLeave.Controls
    $start = $c.dpBlStart.SelectedDate
    $end = $c.dpBlEnd.SelectedDate
    if (-not $start -or -not $end) { return $null }
    $remove = [bool]$c.rbBlRemove.IsChecked
    $time = if ($remove) { [timespan]::Zero } else { ConvertFrom-LeaveStartTime -Text $c.cmbBlStartTime.Text }
    $endTime = if ($remove) { [timespan]::Zero } else { ConvertFrom-LeaveStartTime -Text $c.cmbBlEndTime.Text }
    if ($null -eq $time -or $null -eq $endTime) { return $null }
    $start = ([datetime]$start).Date.Add($time)
    $until = ([datetime]$end).Date.Add($endTime)
    if ($until -le $start) { return $null }
    return [pscustomobject]@{ Start = $start; End = $(if ($endTime.Ticks -gt 0) { $until } else { $until.AddDays(-1) }); Until = $until; Days = Format-LeaveDuration -Start $start -Until $until }
}
function Format-BulkLeavePeriods {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyCollection()][AllowNull()][object[]]$Periods = @())
    $items = @($Periods | Where-Object { $_ })
    if ($items.Count -eq 0) { return '-' }
    return ($items | ForEach-Object {
            $until = Get-LeaveUntilUi -Period $_
            '{0} - {1}' -f ([datetime]$_.Start).ToString($(if (([datetime]$_.Start).TimeOfDay.Ticks -gt 0) { 'dd.MM HH:mm' } else { 'dd.MM' })),
            $(if ($until.TimeOfDay.Ticks -gt 0) { $until.ToString('dd.MM.yyyy HH:mm') } else { $until.AddDays(-1).ToString('dd.MM.yyyy') })
        }) -join ', '
}
function Update-BulkLeaveRows {
    [CmdletBinding()]
    param()
    $state = $script:State.BulkLeave
    $c = $state.Controls
    $range = Get-BulkLeaveRange
    $remove = [bool]$c.rbBlRemove.IsChecked
    $now = Get-Date
    $today = $now.Date
    $c.cmbBlStartTime.IsEnabled = -not $remove
    $c.cmbBlEndTime.IsEnabled = -not $remove
    $state.Updating = $true
    try {
        foreach ($row in $state.Table.Rows) {
            $periods = @($row['Periods'] | Where-Object { $_ })
            $selectable = $true
            $kind = ''
            $note = ''
            if ($row['Block']) { $selectable = $false; $kind = 'Blocked'; $note = [string]$row['Block'] }
            elseif ($range) {
                $overlap = @($periods | Where-Object { $_.Start -lt $range.Until -and (Get-LeaveUntilUi -Period $_) -gt $range.Start })
                $covered = @($overlap | Where-Object { $_.Start -le $range.Start -and (Get-LeaveUntilUi -Period $_) -ge $range.Until }).Count -gt 0
                if ($remove) {
                    if ($overlap.Count -eq 0) { $selectable = $false; $kind = 'Blocked'; $note = 'Bu tarihlerde izni yok' }
                    else { $note = 'Bu tarihler izinden çıkarılacak' + $(if (-not [bool]$row['Enabled'] -and $row['Off'] -and $range.Start -le $now -and $range.Until -gt $now) { '; hesap açılır' } else { '' }) }
                }
                elseif ($covered) { $note = 'Bu tarihler zaten izinli' }
                elseif (-not [bool]$row['Enabled'] -and -not $row['Off']) { $note = 'Hesap başka nedenle kapalı; izin kaydedilir, hesap açılmaz' }
                elseif ($overlap.Count -gt 0) { $note = 'Mevcut izinle birleştirilecek' }
            }
            if ($row['Result']) { $note = [string]$row['Result']; $kind = [string]$row['ResultKind'] }
            $row['Selectable'] = $selectable
            $row['Selected'] = $selectable -and [bool]$row['Wanted']
            $row['Kind'] = $kind
            $row['Note'] = $note
        }
    }
    finally { $state.Updating = $false }
    $c.chkBlNow.Visibility = if ($range -and $range.Start -le $now -and $range.Until -gt $now) { 'Visible' } else { 'Collapsed' }
    $badTime = -not $remove -and ($null -eq (ConvertFrom-LeaveStartTime -Text $c.cmbBlStartTime.Text) -or $null -eq (ConvertFrom-LeaveStartTime -Text $c.cmbBlEndTime.Text))
    $c.txtBlPeriod.Text = if ($badTime) { "Saatler SS:dd biçiminde (ör. 13:00) ve 23:30'dan önce olmalı." }
    elseif (-not $range -and $c.dpBlStart.SelectedDate -and $c.dpBlEnd.SelectedDate) { 'İşe başlangıç tarihi, ilk izin gününden sonra olmalı.' }
    elseif (-not $range) { 'İlk izin gününü ve işe başlangıç tarihini seçin.' }
    elseif ($range.Until -le $now) { 'Geçmiş bir tarih aralığı seçildi.' }
    elseif ($remove) { "$(Format-LeavePeriod -Period $range) ($($range.Days)) seçili kullanıcıların izninden çıkarılır. Başka izinleri kalmayan hesaplar izin nedeniyle kapalıysa açılır." }
    else { "$(Format-LeavePeriod -Period $range), $($range.Days). Hesaplar $(Get-LeaveStartText -Start $range.Start -DayFormat 'dd.MM.yyyy ddd') kapanır, $(Get-LeaveStartText -Start $range.Until -DayFormat 'dd.MM.yyyy ddd') açılır. Kişinin kendi izinleri korunur, çakışanlar birleştirilir." }
    Update-BulkLeaveSummary
}
function Update-BulkLeaveSummary {
    [CmdletBinding()]
    param()
    $state = $script:State.BulkLeave
    if (-not $state) { return }
    $rows = @($state.Table.Rows)
    $selected = @($rows | Where-Object { [bool]$_['Selected'] }).Count
    $blocked = @($rows | Where-Object { -not [bool]$_['Selectable'] }).Count
    $state.Controls.txtBlEmpty.Visibility = if ($rows.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $state.Controls.txtBlSummary.Text = if ($rows.Count -eq 0) { '' } else { "$($rows.Count) kullanıcı listede  |  $selected seçili$(if ($blocked) { "  |  $blocked uygun değil" })$(if ($state.LastMessage) { "  |  $($state.LastMessage)" })" }
    $state.Controls.btnBlApply.IsEnabled = $selected -gt 0 -and [bool](Get-BulkLeaveRange)
}
function Set-BulkLeaveFilter {
    [CmdletBinding()]
    param()
    $state = $script:State.BulkLeave
    $text = ([string]$state.Controls.txtBlFilter.Text).Trim().Replace("'", "''").Replace('[', '[[]').Replace('*', '[*]').Replace('%', '[%]')
    $state.Table.DefaultView.RowFilter = if ($text) { "Name LIKE '*$text*' OR SamAccountName LIKE '*$text*' OR DeptText LIKE '*$text*'" } else { '' }
}
function Add-BulkLeaveCandidate {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Results)
    $state = $script:State.BulkLeave
    if (-not $state) { return }
    $added = 0
    $state.Updating = $true
    try {
        foreach ($user in @($Results | Where-Object { $_ -and $_.PSObject.Properties['ObjectGuid'] })) {
            if ($state.Table.Rows.Find([string]$user.ObjectGuid)) { continue }
            $row = $state.Table.NewRow()
            $row['ObjectGuid'] = [string]$user.ObjectGuid
            $row['Name'] = [string]$user.Name
            $row['SamAccountName'] = [string]$user.SamAccountName
            $row['DeptText'] = (@([string]$user.Department, [string]$user.Title) | Where-Object { $_ }) -join ' / '
            $periods = @($user.Periods | Where-Object { $_ } | ForEach-Object { New-LeavePeriodUi -Start ([datetime]$_.Start) -Until (Get-LeaveUntilUi -Period $_) })
            $row['Periods'] = $periods
            $row['PeriodsText'] = Format-BulkLeavePeriods -Periods $periods
            $row['Enabled'] = [bool]$user.Enabled
            $row['Off'] = [string]$user.Off
            $row['Block'] = [string]$user.Block
            $row['Wanted'] = [bool]$user.Enabled -and -not $user.Block
            $row['Selected'] = $false
            $row['Selectable'] = $true
            foreach ($column in 'Note', 'Kind', 'Result', 'ResultKind') { $row[$column] = '' }
            $state.Table.Rows.Add($row)
            $added++
        }
    }
    finally { $state.Updating = $false }
    $state.LastMessage = "$added kullanıcı eklendi"
    Update-BulkLeaveRows
}
function Start-BulkLeaveLoad {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Arguments, [Parameter()][switch]$Exclude)
    $state = $script:State.BulkLeave
    $state.Controls.txtBlSummary.Text = 'Kullanıcılar okunuyor...'
    $state.ExcludeMode = [bool]$Exclude
    $started = Invoke-BackgroundTask -Name 'Toplu izin için kullanıcılar okunuyor' -Command 'Get-BulkLeaveCandidate' -Arguments $Arguments -OnSuccess {
        param($Result)
        $state = $script:State.BulkLeave
        if (-not $state) { return }
        if (-not $state.ExcludeMode) { Add-BulkLeaveCandidate -Results $Result; return }
        $count = 0
        $state.Updating = $true
        try {
            foreach ($user in @($Result | Where-Object { $_ -and $_.PSObject.Properties['ObjectGuid'] })) {
                $row = $state.Table.Rows.Find([string]$user.ObjectGuid)
                if ($row -and [bool]$row['Wanted']) { $row['Wanted'] = $false; $count++ }
            }
        }
        finally { $state.Updating = $false }
        $state.LastMessage = "gruptaki $count kişinin seçimi kaldırıldı"
        Update-BulkLeaveRows
    } -OnFailure {
        param($Message)
        if ($script:State.BulkLeave) { $script:State.BulkLeave.LastMessage = ''; $script:State.BulkLeave.Controls.txtBlSummary.Text = "Okunamadı: $Message" }
    }
    if (-not $started) { $state.Controls.txtBlSummary.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' }
}
function Select-BulkLeaveOu {
    [CmdletBinding()]
    param()
    $state = $script:State.BulkLeave
    if (-not $state) { return }
    if (@($script:State.OuList).Count -eq 0) {
        $state.Controls.txtBlSummary.Text = 'OU listesi okunuyor...'
        [void](Invoke-BackgroundTask -Name 'OU listesi okunuyor' -Command 'Get-OrganizationalUnitList' -OnSuccess {
                param($Result)
                $script:State.OuList = @($Result | Where-Object { $_ })
                if ($script:State.OuList.Count -gt 0) { Invoke-Deferred { Select-BulkLeaveOu } }
            })
        return
    }
    $ous = @(Show-OuPicker -Owner $state.Window -Selected @($state.LastOu | Where-Object { $_ }) -UserText 'Toplu izin' -Multiple | Where-Object { $_ })
    if ($ous.Count -eq 0) { Update-BulkLeaveSummary; return }
    $state.LastOu = $ous
    Start-BulkLeaveLoad -Arguments @{ SearchBase = [string[]]$ous; Subtree = [bool]$state.Controls.chkBlSubtree.IsChecked }
}
function Start-BulkLeaveApply {
    [CmdletBinding()]
    param()
    $state = $script:State.BulkLeave
    $c = $state.Controls
    $range = Get-BulkLeaveRange
    if (-not $range) { [void](Show-MessageDialog -Message 'İlk izin gününü ve işe başlangıç tarihini seçin (işe başlangıç ilk izin gününden sonra olmalı).' -Icon Warning); return }
    $now = Get-Date
    $today = $now.Date
    if ($range.Until -le $now) { [void](Show-MessageDialog -Message 'Seçilen tarihler geçmişte kaldı.' -Icon Warning); return }
    $rows = @($state.Table.Rows | Where-Object { [bool]$_['Selected'] -and [bool]$_['Selectable'] })
    if ($rows.Count -eq 0) { [void](Show-MessageDialog -Message 'Listeden en az bir kullanıcı seçin.' -Icon Warning); return }
    $remove = [bool]$c.rbBlRemove.IsChecked
    $touchesToday = $range.Start -le $now -and $range.Until -gt $now
    $applyNow = $touchesToday -and [bool]$c.chkBlNow.IsChecked
    $names = @($rows | Select-Object -First 12 | ForEach-Object { [string]$_['Name'] })
    $excluded = @($state.Table.Rows | Where-Object { [bool]$_['Selectable'] -and -not [bool]$_['Selected'] }).Count
    $message = "$($rows.Count) kullanıcı için izin $(if ($remove) { 'kaldırılacak' } else { 'eklenecek' }):`n`n| Dönem: $(Format-LeavePeriod -Period $range), $($range.Days)`n" +
        $(if ($remove) { "| Bu günler kişilerin izninden çıkarılır; diğer izinleri korunur.`n" }
            else { "| Hesaplar $(Get-LeaveStartText -Start $range.Start) kapanır, $(Get-LeaveStartText -Start $range.Until) açılır.`n" }) +
        $(if ($applyNow) { "| Dönem bugünü kapsadığı için hesaplar şimdi $(if ($remove) { 'açılır' } else { 'kapatılır' }).`n" } elseif ($touchesToday) { "| Bugünkü değişiklik gece görevine bırakıldı.`n" }) +
        $(if ($excluded) { "| Seçilmeyen $excluded kişiye (ör. nöbetçiler) dokunulmaz.`n" }) +
        "`n" + ($names -join ', ') + $(if ($rows.Count -gt $names.Count) { " ve $($rows.Count - $names.Count) kişi daha" })
    if (-not (Show-ConfirmDialog -Message $message -Title $(if ($remove) { 'Toplu İzni Kaldır' } else { 'Toplu İzin Gir' }))) { return }
    $state.Apply = @{ Mode = $(if ($remove) { 'Remove' } else { 'Add' }); Range = $range; ApplyNow = $applyNow; Simulate = [bool]$script:State.Options.WhatIf }
    $arguments = Get-ActionArgument @{ ObjectGuid = [string[]]@($rows | ForEach-Object { [string]$_['ObjectGuid'] }); Start = $range.Start; End = $range.End; Mode = $state.Apply.Mode; ApplyNow = $applyNow }
    $c.txtBlSummary.Text = "$($rows.Count) kullanıcı işleniyor..."
    $started = Invoke-BackgroundTask -Name 'Toplu izin uygulanıyor' -Command 'Invoke-BulkLeave' -Arguments $arguments -OnSuccess {
        param($Result)
        Receive-BulkLeaveResult -Results $Result
    }
    if (-not $started) { $c.txtBlSummary.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' }
}
function Receive-BulkLeaveResult {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Results)
    $state = $script:State.BulkLeave
    $apply = if ($state) { $state.Apply } else { $null }
    $items = @($Results | Where-Object { $_ -and $_.PSObject.Properties['Success'] })
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $simulate = $apply -and $apply.Simulate
    foreach ($item in $items) {
        if (-not $item.Skipped) {
            [void](Write-AuditEvent -Action $(if ($apply.Mode -eq 'Remove') { 'user.leave.bulk_remove' } else { 'user.leave.bulk_add' }) -Result $(if ($simulate) { 'simulated' } elseif ($item.Success) { 'success' } else { 'failure' }) -Fields ([ordered]@{
                        target_user = [string]$item.SamAccountName; target_guid = [string]$item.ObjectGuid; target_dn = [string]$item.DistinguishedName
                        category = 'leave'; field = [string]$script:Sync.LeaveAttribute; operation = $(if ($apply.Mode -eq 'Remove') { 'remove' } else { 'add' })
                        old_value = [string]$item.OldValue; new_value = [string]$item.NewValue
                        leave_start = $apply.Range.Start.ToString($(if ($apply.Range.Start.TimeOfDay.Ticks -gt 0) { 'yyyy-MM-dd HH:mm' } else { 'yyyy-MM-dd' }), $culture); leave_end = $apply.Range.End.ToString($(if ($apply.Range.End.TimeOfDay.Ticks -gt 0) { 'yyyy-MM-dd HH:mm' } else { 'yyyy-MM-dd' }), $culture)
                        account = [string]$item.Account; trigger = 'bulk'; message = [string]$item.Message
                    }))
        }
        if (-not $state) { continue }
        $row = $state.Table.Rows.Find([string]$item.ObjectGuid)
        if (-not $row) { continue }
        $row['Result'] = if ($item.Success) { [string]$item.Message } else { "Hata: $($item.Message)" }
        $row['ResultKind'] = if ($item.Success) { 'Done' } else { 'Failed' }
        if ($item.Success -and -not $simulate) {
            $row['Wanted'] = $false
            if ($item.Account -eq 'Disable') { $row['Enabled'] = $false }
            elseif ($item.Account -eq 'Enable') { $row['Enabled'] = $true }
            $periods = @()
            if ($item.NewValue -match '^ADEUM-LEAVE') {
                foreach ($part in ($item.NewValue -split ';')) {
                    if ($part -match '^(\d{4}-\d{2}-\d{2}(@\d{2}:\d{2})?)\.\.(\d{4}-\d{2}-\d{2}(@\d{2}:\d{2})?)$') {
                        $formats = [string[]]@('yyyy-MM-dd', 'yyyy-MM-dd@HH:mm')
                        $periods += [pscustomobject]@{ Start = [datetime]::ParseExact($Matches[1], $formats, $culture, [System.Globalization.DateTimeStyles]::None); End = [datetime]::ParseExact($Matches[3], $formats, $culture, [System.Globalization.DateTimeStyles]::None) }
                    }
                    elseif ($part -match '^OFF=(.*)$') { $row['Off'] = $Matches[1] }
                }
            }
            if ($item.NewValue -notmatch 'OFF=') { $row['Off'] = '' }
            $row['Periods'] = $periods
            $row['PeriodsText'] = Format-BulkLeavePeriods -Periods $periods
        }
    }
    $ok = @($items | Where-Object { $_.Success -and -not $_.Skipped }).Count
    $skipped = @($items | Where-Object { $_.Skipped }).Count
    $failed = @($items | Where-Object { -not $_.Success }).Count
    $text = if ($simulate) { "Simülasyon: $($items.Count) kullanıcı denendi, değişiklik yapılmadı" } else { "$ok kullanıcı güncellendi$(if ($skipped) { ", $skipped zaten uygundu" })$(if ($failed) { ", $failed hata" })" }
    Write-UiLog -Message "Toplu izin: $text." -Level $(if ($failed) { 'Warning' } else { 'Success' })
    if (-not $state) { return }
    if (-not $simulate -and $ok -gt 0) { $state.Changed = $true }
    $state.LastMessage = $text
    Update-BulkLeaveRows
    if ($failed) { [void](Show-MessageDialog -Message "Toplu izin: $text.`n`nHatalı satırlar listede kırmızı gösteriliyor." -Icon Warning) }
}
function Show-BulkLeaveDialog {
    [CmdletBinding()]
    param([Parameter()][System.Windows.Window]$Owner)
    $dialog = New-MainWindow -Xaml $script:BulkLeaveXaml
    $script:State.BulkLeave = @{ Window = $dialog.Window; Controls = $dialog.Controls; Table = $null; Updating = $false; LastMessage = ''; LastOu = @(); Changed = $false; Apply = $null; ExcludeMode = $false }
    try {
        $c = $dialog.Controls
        $dialog.Window.Owner = if ($Owner) { $Owner } else { $script:Window }
        $script:State.BulkLeave.Table = New-BulkLeaveTable
        Register-ListSort -Root $dialog.Window -List $c.lstBl
        $c.lstBl.ItemsSource = $script:State.BulkLeave.Table.DefaultView
        $c.dpBlStart.DisplayDateStart = (Get-Date).Date
        $c.dpBlEnd.DisplayDateStart = (Get-Date).Date
        $c.dpBlStart.Add_SelectedDateChanged({
                Invoke-UiAction {
                    $bc = $script:State.BulkLeave.Controls
                    if ($bc.dpBlStart.SelectedDate -and (-not $bc.dpBlEnd.SelectedDate -or $bc.dpBlEnd.SelectedDate -le $bc.dpBlStart.SelectedDate)) { $bc.dpBlEnd.SelectedDate = ([datetime]$bc.dpBlStart.SelectedDate).Date.AddDays(1) }
                    Update-BulkLeaveRows
                }
            })
        $c.dpBlEnd.Add_SelectedDateChanged({ Invoke-UiAction { Update-BulkLeaveRows } })
        foreach ($name in 'cmbBlStartTime', 'cmbBlEndTime') {
            $c[$name].AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.RoutedEventHandler]{ Invoke-UiAction { Update-BulkLeaveRows } })
        }
        foreach ($name in 'rbBlAdd', 'rbBlRemove') { $c[$name].Add_Click({ Invoke-UiAction { Update-BulkLeaveRows } }) }
        $c.txtBlFilter.Add_TextChanged({ Invoke-UiAction { Set-BulkLeaveFilter } })
        $c.btnBlOu.Add_Click({ Invoke-UiAction { Select-BulkLeaveOu } })
        $c.btnBlGroup.Add_Click({
                Invoke-UiAction {
                    $text = ([string]$script:State.BulkLeave.Controls.txtBlGroup.Text).Trim()
                    if ($text) { Start-BulkLeaveLoad -Arguments @{ Group = $text } }
                }
            })
        $c.btnBlSearch.Add_Click({
                Invoke-UiAction {
                    $text = ([string]$script:State.BulkLeave.Controls.txtBlSearch.Text).Trim()
                    if ($text.Length -ge 2) { Start-BulkLeaveLoad -Arguments @{ Query = $text } }
                }
            })
        $c.btnBlExclude.Add_Click({
                Invoke-UiAction {
                    $text = ([string]$script:State.BulkLeave.Controls.txtBlExclude.Text).Trim()
                    if ($text) { Start-BulkLeaveLoad -Arguments @{ Group = $text } -Exclude }
                }
            })
        $selectVisible = {
            param([bool]$Value)
            $state = $script:State.BulkLeave
            $state.Updating = $true
            try { foreach ($view in $state.Table.DefaultView) { if ([bool]$view.Row['Selectable']) { $view.Row['Wanted'] = $Value } } }
            finally { $state.Updating = $false }
            Update-BulkLeaveRows
        }
        $script:State.BulkLeave.SelectVisible = $selectVisible
        $c.btnBlAll.Add_Click({ Invoke-UiAction { & $script:State.BulkLeave.SelectVisible $true } })
        $c.btnBlNone.Add_Click({ Invoke-UiAction { & $script:State.BulkLeave.SelectVisible $false } })
        $c.btnBlClear.Add_Click({ Invoke-UiAction { $script:State.BulkLeave.Table.Clear(); $script:State.BulkLeave.LastMessage = ''; Update-BulkLeaveSummary } })
        $c.btnBlApply.Add_Click({ Invoke-UiAction { Start-BulkLeaveApply } })
        $c.btnBlClose.Add_Click({ $script:State.BulkLeave.Window.Close() })
        Update-BulkLeaveRows
        [void]$dialog.Window.ShowDialog()
        return [bool]$script:State.BulkLeave.Changed
    }
    finally {
        $script:State.BulkLeave = $null
    }
}
function Open-SelectedLeaveUser {
    [CmdletBinding()]
    param()
    $item = $script:Ui.lstLv.SelectedItem
    if (-not $item) { $script:Ui.txtLvSummary.Text = 'Açmak için listeden bir kullanıcı seçin.'; return }
    if (-not (Confirm-DiscardChange)) { return }
    $script:Ui.navUsers.IsChecked = $true
    $script:Ui.txtSearch.Text = [string]$item.SamAccountName
    $script:State.SelectTabAfterLoad = 'tabLeave'
    Start-UserLoad -ObjectGuid ([string]$item.ObjectGuid) -Force
}
