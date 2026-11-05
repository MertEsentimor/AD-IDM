function Write-LeaveAuditResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Summary,
        [Parameter()][ValidateSet('schedule', 'manual')][string]$Trigger = 'schedule'
    )
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $failed = 0
    foreach ($item in @($Summary.Results | Where-Object { $_ })) {
        $action = switch ($item.Action) { 'Disable' { 'leave.account.disable' } 'Enable' { 'leave.account.enable' } default { 'leave.record.update' } }
        $outcome = if ($Summary.Simulated) { 'simulated' } elseif ($item.Success) { 'success' } else { 'failure' }
        if (-not $item.Success) { $failed++ }
        $fields = [ordered]@{
            target_user  = [string]$item.SamAccountName
            target_guid  = [string]$item.ObjectGuid
            target_dn    = [string]$item.DistinguishedName
            category     = 'leave'
            field        = [string]$script:Sync.LeaveAttribute
            operation    = if ($item.Action -eq 'Update') { 'set' } else { 'enabled' }
            old_value    = [string]$item.OldValue
            new_value    = [string]$item.NewValue
            leave_date   = ([datetime]$Summary.Date).ToString('yyyy-MM-dd', $culture)
            applied_at   = if ($item.AppliedAt) { ([datetime]$item.AppliedAt).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', $culture) } else { '' }
            dc           = [string]$Summary.Server
            replicated   = [int]$item.Replicated
            trigger      = $Trigger
            message      = if ($item.ReplicationErrors) { "$($item.Message); replikasyon: $($item.ReplicationErrors)" } else { [string]$item.Message }
        }
        [void](Write-AuditEvent -Action $action -Result $outcome -Fields $fields)
    }
    $result = if ($Summary.Simulated) { 'simulated' } elseif ($failed -gt 0) { 'failure' } else { 'success' }
    [void](Write-AuditEvent -Action 'leave.check' -Result $result -Fields ([ordered]@{
                category   = 'leave'
                leave_date = ([datetime]$Summary.Date).ToString('yyyy-MM-dd', $culture)
                started_at = if ($Summary.StartedAt) { ([datetime]$Summary.StartedAt).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz', $culture) } else { '' }
                dc         = [string]$Summary.Server
                records    = [int]$Summary.Users
                actions    = @($Summary.Results).Count
                failed     = $failed
                problems   = @($Summary.Problems).Count
                trigger    = $Trigger
            }))
}
function Invoke-LeaveCheck {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()][Nullable[datetime]]$Date,
        [Parameter()][switch]$Preview,
        [Parameter()][switch]$NoReplicate
    )
    $runLog = Join-Path -Path $script:AppRoot -ChildPath ('Logs\LeaveCheck_{0:yyyyMM}.log' -f (Get-Date))
    $write = {
        param([string]$Level, [string]$Message, [datetime]$Time = (Get-Date))
        $line = '{0} [{1}] {2}' -f $Time.ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level.ToUpperInvariant(), $Message
        $color = switch ($Level) { 'Error' { 'Red' } 'Warning' { 'Yellow' } 'Success' { 'Green' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
        try {
            $folder = Split-Path -Path $runLog -Parent
            if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force -WhatIf:$false) }
            Add-Content -LiteralPath $runLog -Value $line -Encoding UTF8 -WhatIf:$false
        }
        catch { Write-Verbose "Çalışma günlüğü yazılamadı: $($_.Exception.Message)" }
    }
    $drain = {
        $entry = $null
        while ($script:Sync.LogQueue.TryDequeue([ref]$entry)) { if ($entry.Kind -eq 'Log') { & $write $entry.Level $entry.Message $entry.Time } }
    }
    try {
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { throw 'ActiveDirectory modülü bulunamadı (RSAT AD araçları gerekli).' }
        Import-Module -Name ActiveDirectory -ErrorAction Stop -Verbose:$false
        $global:Sync = $script:Sync
        foreach ($relativePath in $script:WorkerScripts) { . ([scriptblock]::Create((Read-AppFile -RelativePath $relativePath))) }
        $now = Get-Date
        $wait = $false
        $target = if ($Date) { ([datetime]$Date).Date }
        elseif ($now.Hour -eq 23 -and $now.Minute -ge 30) { $wait = $true; $now.Date.AddDays(1) }
        else { $now }
        $runOnce = {
            param([datetime]$Target, [bool]$Wait, [bool]$TimedOnly, [bool]$Nightly)
            $summary = @(Invoke-LeaveEnforcement -Date $Target -WaitForDate:$Wait -TimedOnly:$TimedOnly -Replicate (-not $NoReplicate) -WhatIf:$Preview -Confirm:$false) | Select-Object -Last 1
            & $drain
            Write-LeaveAuditResult -Summary $summary -Trigger schedule
            $mailFailed = $false
            $earlier = @()
            if (-not $Preview -and -not $Nightly) {
                try { Save-LeaveDayResult -Summary $summary }
                catch { & $write 'Warning' "Gün içi sonuçlar gece raporu için kaydedilemedi: $($_.Exception.Message)" }
            }
            if (-not $Preview -and $Nightly) {
                try { $earlier = @(Get-LeaveDayResult -Date $Target.Date.AddDays(-1)) }
                catch { & $write 'Warning' "Gün içi sonuçlar okunamadı: $($_.Exception.Message)" }
            }
            if (-not $Preview -and $Nightly -and (Test-LeaveReportDue -Summary $summary -Earlier $earlier)) {
                try {
                    $sent = Send-LeaveReport -Summary $summary -Earlier $earlier -Confirm:$false
                    & $write 'Success' "İzin raporu e-postayla gönderildi: $($sent.To)"
                    [void](Write-AuditEvent -Action 'leave.mail' -Result 'success' -Fields ([ordered]@{ category = 'leave'; mail_to = $sent.To; leave_date = $Target.ToString('yyyy-MM-dd') }))
                }
                catch {
                    $mailFailed = $true
                    & $write 'Error' "İzin raporu e-postası gönderilemedi: $($_.Exception.Message)"
                    [void](Write-AuditEvent -Action 'leave.mail' -Result 'failure' -Fields ([ordered]@{ category = 'leave'; message = $_.Exception.Message }))
                }
            }
            $failedCount = @($summary.Results | Where-Object { -not $_.Success }).Count
            $started = if ($summary.StartedAt) { " (uygulama başlangıcı $(([datetime]$summary.StartedAt).ToString('HH:mm:ss.fff')))" } else { '' }
            & $write $(if ($failedCount -gt 0) { 'Warning' } else { 'Success' }) ("{0}: {1} işlem, {2} hata{3}." -f $(if ($TimedOnly) { "Saatli izin ($($Target.ToString('HH:mm'))) uygulandı" } else { 'İzin kontrolü bitti' }), @($summary.Results).Count, $failedCount, $started)
            [pscustomobject]@{ Failed = $failedCount; MailFailed = $mailFailed }
        }
        & $write 'Info' ("İzin kontrolü başladı ({0}, hesap: {1}, hedef: {2}{3}{4})." -f $env:COMPUTERNAME, $script:Audit.Operator, $target.ToString('dd.MM.yyyy HH:mm'), $(if ($wait) { ', 00:00:00 beklenecek' } else { ', hemen' }), $(if ($Preview) { ', ÖNİZLEME' } else { '' }))
        $run = @(& $runOnce $target $wait $false $wait) | Select-Object -Last 1
        $failed = [int]$run.Failed
        $mailFailed = [bool]$run.MailFailed
        if (-not $Preview -and -not $Date) {
            $cutoff = (Get-Date).Date.AddHours(23).AddMinutes(30)
            & $write 'Info' ("Gün içi saatli izinler {0} saatine kadar izleniyor." -f $cutoff.ToString('dd.MM.yyyy HH:mm'))
            while ((Get-Date) -lt $cutoff) {
                $next = $null
                try { $next = @(Get-LeaveTimedMoment -After (Get-Date) -Before $cutoff) | Select-Object -First 1 }
                catch { & $write 'Warning' "Saatli izinler okunamadı: $($_.Exception.Message)" }
                & $drain
                $now = Get-Date
                if ($next -and ([datetime]$next - $now).TotalMinutes -le 12) {
                    & $write 'Info' ("Saatli izin: {0} işlemleri hazırlanıyor." -f ([datetime]$next).ToString('dd.MM.yyyy HH:mm'))
                    try {
                        $timed = @(& $runOnce ([datetime]$next) $true $true $false) | Select-Object -Last 1
                        $failed += [int]$timed.Failed
                        if ($timed.MailFailed) { $mailFailed = $true }
                    }
                    catch {
                        & $drain
                        $failed++
                        & $write 'Error' "Saatli izin uygulanamadı: $($_.Exception.Message)"
                        [void](Write-AuditEvent -Action 'leave.check' -Result 'failure' -Fields ([ordered]@{ category = 'leave'; trigger = 'schedule'; message = $_.Exception.Message }))
                        Start-Sleep -Seconds 60
                    }
                    continue
                }
                $wake = $now.AddMinutes(10)
                if ($next -and ([datetime]$next).AddMinutes(-11) -lt $wake) { $wake = ([datetime]$next).AddMinutes(-11) }
                if ($wake -gt $cutoff) { $wake = $cutoff }
                Start-Sleep -Seconds ([int][math]::Max(30, ($wake - (Get-Date)).TotalSeconds))
            }
            & $write 'Info' 'Gün içi izleme bitti.'
        }
        if ($failed -gt 0 -or $mailFailed) { return 1 }
        return 0
    }
    catch {
        & $drain
        & $write 'Error' "İzin kontrolü başarısız: $($_.Exception.Message)"
        [void](Write-AuditEvent -Action 'leave.check' -Result 'failure' -Fields ([ordered]@{ category = 'leave'; trigger = 'schedule'; message = $_.Exception.Message }))
        return 2
    }
}
function ConvertTo-LeaveReportHtml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][psobject]$Summary,
        [Parameter()][object[]]$Earlier = @(),
        [Parameter()][switch]$Preview,
        [Parameter()][string]$Company = ''
    )
    $enc = { param($Value) [System.Net.WebUtility]::HtmlEncode([string]$Value) }
    $results = @($Summary.Results | Where-Object { $_ })
    $closed = @($results | Where-Object { $_.Action -eq 'Disable' })
    $opened = @($results | Where-Object { $_.Action -eq 'Enable' })
    $failed = @($results | Where-Object { -not $_.Success })
    $day = [datetime]$Summary.Date
    $font = "font-family:'Segoe UI',Arial,sans-serif;"
    $cell = "padding:10px 12px;border-bottom:1px solid #EDEDED;font-size:13px;color:#1B1B1B;$font"
    $head = "padding:8px 12px;border-bottom:1px solid #E0E0E0;font-size:11px;color:#707070;text-transform:uppercase;letter-spacing:.4px;text-align:left;font-weight:600;$font"
    $kpi = {
        param([string]$Label, [int]$Count, [string]$Color)
        "<td width=`"33%`" style=`"padding:14px 16px;background:#FAFAFA;border:1px solid #EDEDED;border-radius:6px;$font`">" +
        "<div style=`"font-size:24px;font-weight:600;color:$Color;line-height:1.1;`">$Count</div>" +
        "<div style=`"font-size:12px;color:#707070;margin-top:4px;`">$Label</div></td>"
    }
    $time = {
        param($Item)
        if ($Item.AppliedAt) { ([datetime]$Item.AppliedAt).ToString('HH:mm:ss') } elseif ($Preview) { '00:00' } else { '-' }
    }
    $status = {
        param($Item)
        if (-not $Item.Success) { "<span style=`"color:#C42B1C;font-weight:600;`">Hata</span><div style=`"font-size:11px;color:#C42B1C;`">$(& $enc $Item.Message)</div>" }
        elseif ($Preview) { '<span style="color:#005FB8;">Planlı</span>' }
        elseif ($Item.ReplicationErrors) { '<span style="color:#9D5D00;">Tamam</span><div style="font-size:11px;color:#9D5D00;">Bazı DC''lere kopyalanamadı</div>' }
        else { '<span style="color:#0F7B0F;">Tamam</span>' }
    }
    $table = {
        param([string]$Title, [string]$Accent, [object[]]$Items, [string]$PeriodHeader, [string]$DateHeader, [string]$TimeHeader, [string]$Empty)
        $html = "<tr><td style=`"padding:26px 0 8px 0;$font`"><span style=`"display:inline-block;width:8px;height:8px;border-radius:4px;background:$Accent;margin-right:8px;`"></span>" +
        "<span style=`"font-size:15px;font-weight:600;color:#1B1B1B;`">$Title</span><span style=`"font-size:13px;color:#909090;margin-left:6px;`">$(@($Items).Count)</span></td></tr>"
        if (@($Items).Count -eq 0) {
            return $html + "<tr><td style=`"padding:12px 14px;background:#FAFAFA;border-radius:6px;font-size:13px;color:#909090;$font`">$Empty</td></tr>"
        }
        $html += "<tr><td><table width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" style=`"border-collapse:collapse;`"><tr>" +
        "<th style=`"$head`">Ad Soyad</th><th style=`"$head`">Kullanıcı</th><th style=`"$head`">$PeriodHeader</th><th style=`"$head`">$DateHeader</th><th style=`"$head`">$TimeHeader</th><th style=`"$head`">Durum</th></tr>"
        foreach ($item in $Items) {
            $html += "<tr><td style=`"$cell font-weight:600;`">$(& $enc $item.Name)</td><td style=`"$cell color:#505050;`">$(& $enc $item.SamAccountName)</td>" +
            "<td style=`"$cell`">$(& $enc $item.Period)</td><td style=`"$cell`">$(& $enc $item.ReturnDate)</td><td style=`"$cell color:#505050;`">$(& $time $item)</td><td style=`"$cell`">$(& $status $item)</td></tr>"
        }
        return $html + '</table></td></tr>'
    }
    $moment = if ($Summary.PSObject.Properties['Moment'] -and $Summary.Moment) { [datetime]$Summary.Moment } else { $day }
    $title = if ($Preview) { "Bu gece 00:00'da yapılacaklar" } elseif ($moment.TimeOfDay.Ticks -gt 0) { "Saatli izin raporu ($($moment.ToString('HH:mm')))" } else { 'Gece izin raporu' }
    $banner = if ($Preview) { "<tr><td style=`"padding:10px 14px;background:#EFF6FC;color:#005FB8;border-radius:6px;font-size:12px;$font`">Önizleme / test e-postası: hiçbir hesap değiştirilmedi. Liste, $($day.ToString('dd.MM.yyyy')) 00:00'da gece görevinin yapacağı işlemleri gösterir.</td></tr><tr><td style=`"height:14px;`"></td></tr>" } else { '' }
    $body = New-Object -TypeName System.Text.StringBuilder
    [void]$body.Append("<!DOCTYPE html><html><head><meta charset=`"utf-8`"></head><body style=`"margin:0;padding:0;background:#F3F3F3;`">")
    [void]$body.Append("<table width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" style=`"background:#F3F3F3;`"><tr><td align=`"center`" style=`"padding:28px 12px;`">")
    [void]$body.Append("<table width=`"680`" cellpadding=`"0`" cellspacing=`"0`" style=`"max-width:680px;width:100%;background:#FFFFFF;border:1px solid #E5E5E5;border-radius:8px;`"><tr><td style=`"padding:28px 32px;`">")
    [void]$body.Append("<table width=`"100%`" cellpadding=`"0`" cellspacing=`"0`">")
    [void]$body.Append("<tr><td style=`"font-size:12px;color:#909090;$font`">$(if ($Company) { "$(& $enc $Company) &middot; " } else { '' })Personel izni</td></tr>")
    [void]$body.Append("<tr><td style=`"padding:4px 0 2px 0;font-size:22px;font-weight:600;color:#1B1B1B;$font`">$title</td></tr>")
    [void]$body.Append("<tr><td style=`"padding:0 0 20px 0;font-size:13px;color:#707070;$font`">$(& $enc $day.ToString('d MMMM yyyy, dddd', [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR'))) &middot; $($moment.ToString('HH:mm'))</td></tr>")
    [void]$body.Append($banner)
    [void]$body.Append("<tr><td><table width=`"100%`" cellpadding=`"0`" cellspacing=`"8`" style=`"margin:0 -8px;`"><tr>")
    [void]$body.Append((& $kpi $(if ($Preview) { 'Kapanacak hesap' } else { 'İzne çıkan (hesap kapatıldı)' }) $closed.Count '#1B1B1B'))
    [void]$body.Append((& $kpi $(if ($Preview) { 'Açılacak hesap' } else { 'İşe dönen (hesap açıldı)' }) $opened.Count '#0F7B0F'))
    [void]$body.Append((& $kpi 'Hata' $failed.Count $(if ($failed.Count -gt 0) { '#C42B1C' } else { '#909090' })))
    [void]$body.Append('</tr></table></td></tr>')
    [void]$body.Append((& $table 'İzni başlayanlar' '#D9822B' $closed 'İzin dönemi' 'İşe dönüş' 'Kapanış' 'Bu gece izni başlayan kullanıcı yok.'))
    [void]$body.Append((& $table 'İşe dönenler' '#0F7B0F' $opened 'Biten izin' 'Dönüş' 'Açılış' 'Bu gece izinden dönen kullanıcı yok.'))
    $earlierItems = @($Earlier | Where-Object { $_ })
    if ($earlierItems.Count -gt 0) {
        $earlierDay = ($day.AddDays(-1)).ToString('dd.MM.yyyy')
        $earlierClosed = @($earlierItems | Where-Object { $_.Action -eq 'Disable' })
        $earlierOpened = @($earlierItems | Where-Object { $_.Action -eq 'Enable' })
        if ($earlierClosed.Count -gt 0) { [void]$body.Append((& $table "$earlierDay gün içinde izne çıkanlar" '#D9822B' $earlierClosed 'İzin dönemi' 'İşe dönüş' 'Kapanış' '')) }
        if ($earlierOpened.Count -gt 0) { [void]$body.Append((& $table "$earlierDay gün içinde işe dönenler" '#0F7B0F' $earlierOpened 'Biten izin' 'Dönüş' 'Açılış' '')) }
    }
    $problems = @($Summary.Problems | Where-Object { $_ })
    if ($problems.Count -gt 0) {
        [void]$body.Append("<tr><td style=`"padding:26px 0 8px 0;font-size:15px;font-weight:600;color:#9D5D00;$font`">Kontrol edilmesi gereken kayıtlar <span style=`"font-size:13px;color:#909090;font-weight:400;`">$($problems.Count)</span></td></tr>")
        [void]$body.Append("<tr><td style=`"padding:12px 14px;background:#FFF8EC;border-radius:6px;font-size:12px;color:#5C4400;line-height:1.6;$font`">$(($problems | ForEach-Object { & $enc $_ }) -join '<br>')</td></tr>")
    }
    $started = if ($Summary.StartedAt) { "Uygulama: $(([datetime]$Summary.StartedAt).ToString('HH:mm:ss.fff')) &middot; " } else { '' }
    [void]$body.Append("<tr><td style=`"padding:28px 0 0 0;border-bottom:1px solid #EDEDED;`"></td></tr>")
    [void]$body.Append("<tr><td style=`"padding:14px 0 0 0;font-size:11px;color:#909090;line-height:1.6;$font`">$started" + "DC: $(& $enc $Summary.Server) &middot; $(if ($env:COMPUTERNAME) { 'Sunucu: ' + (& $enc $env:COMPUTERNAME) + ' &middot; ' })İzin kaydı: $([int]$Summary.Users)<br>" +
        "Hesaplar izin günlerinde 00:00'da kapatılır, izin bitince 00:00'da açılır; saat girilmiş izinlerde o saatte. Bu e-posta AD &amp; Exchange Kullanıcı Yöneticisi tarafından otomatik gönderildi.</td></tr>")
    [void]$body.Append('</table></td></tr></table></td></tr></table></body></html>')
    return $body.ToString()
}
function Send-LeaveReport {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][psobject]$Summary,
        [Parameter()][object[]]$Earlier = @(),
        [Parameter()][switch]$Preview
    )
    $mail = Get-MailConfiguration
    if (-not $mail.Available) { throw "E-posta gönderilemiyor: $($mail.Reason)" }
    $config = $mail.Config
    $results = @($Summary.Results | Where-Object { $_ })
    $closed = @($results | Where-Object { $_.Action -eq 'Disable' }).Count
    $opened = @($results | Where-Object { $_.Action -eq 'Enable' }).Count
    $failed = @(@($results) + @($Earlier) | Where-Object { $_ -and -not $_.Success }).Count
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $subjectTemplate = if ($config.Subject) { [string]$config.Subject } else { 'İzin raporu {{Date}}: {{Closed}} izne çıkan, {{Opened}} işe dönen' }
    $subject = $subjectTemplate.Replace('{{Date}}', ([datetime]$Summary.Date).ToString('dd.MM.yyyy')).Replace('{{Closed}}', [string]$closed).Replace('{{Opened}}', [string]$opened).Replace('{{Failed}}', [string]$failed)
    if ($failed -gt 0) { $subject = "[HATA] $subject" }
    if ($Preview) { $subject = "[ÖNİZLEME] $subject" }
    $html = ConvertTo-LeaveReportHtml -Summary $Summary -Earlier $Earlier -Preview:$Preview -Company ([string]$config.CompanyName)
    $message = New-Object -TypeName System.Net.Mail.MailMessage
    $client = $null
    try {
        $message.From = New-Object -TypeName System.Net.Mail.MailAddress -ArgumentList ([string]$config.From), $(if ($config.FromName) { [string]$config.FromName } else { 'Izin Kontrol' })
        foreach ($address in @($config.To | Where-Object { $_ })) { $message.To.Add([string]$address) }
        foreach ($address in @($config.Cc | Where-Object { $_ })) { $message.CC.Add([string]$address) }
        $message.Subject = $subject
        $message.SubjectEncoding = [System.Text.Encoding]::UTF8
        $message.Body = $html
        $message.BodyEncoding = [System.Text.Encoding]::UTF8
        $message.IsBodyHtml = $true
        $client = New-Object -TypeName System.Net.Mail.SmtpClient -ArgumentList ([string]$config.SmtpServer), $(if ($config.Port) { [int]$config.Port } else { 25 })
        $client.EnableSsl = [bool]$config.UseSsl
        $client.Timeout = 30000
        switch ([string]$config.Authentication) {
            'Windows' { $client.UseDefaultCredentials = $true }
            'Credential' {
                $file = if ($config.CredentialFile) { [string]$config.CredentialFile } else { 'Secrets\smtp-credential.xml' }
                if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path -Path $script:AppRoot -ChildPath $file }
                if (-not (Test-Path -LiteralPath $file)) { throw "SMTP kimlik dosyası yok: $file. Görev hesabıyla oluşturun: .\$script:ScriptFileName -SetMailCredential" }
                $credential = Import-Clixml -LiteralPath $file
                $client.UseDefaultCredentials = $false
                $client.Credentials = $credential.GetNetworkCredential()
            }
            default { $client.UseDefaultCredentials = $false }
        }
        if (-not $PSCmdlet.ShouldProcess(($config.To -join ', '), 'İzin raporunu e-postayla gönder')) { return }
        $client.Send($message)
        return [pscustomobject]@{ Subject = $subject; To = (@($config.To) -join ', ') }
    }
    finally {
        $message.Dispose()
        if ($client) { $client.Dispose() }
    }
}
function Test-LeaveReportDue {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][psobject]$Summary, [Parameter()][object[]]$Earlier = @())
    $mail = Get-MailConfiguration
    if (-not $mail.Config -or $mail.Config.Enabled -ne $true) { return $false }
    $results = @(@($Summary.Results) + @($Earlier) | Where-Object { $_ })
    $failed = @($results | Where-Object { -not $_.Success }).Count
    switch ([string]$mail.Config.SendWhen) {
        'Changes' { return $results.Count -gt 0 }
        'Failures' { return ($failed -gt 0) -or (@($Summary.Problems).Count -gt 0) }
        default { return $true }
    }
}
function Get-LeaveDayResultPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][datetime]$Date)
    return (Join-Path -Path $script:AppRoot -ChildPath ('Logs\LeaveDay_{0:yyyyMMdd}.xml' -f $Date))
}
function Save-LeaveDayResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Summary)
    $results = @($Summary.Results | Where-Object { $_ -and @('Disable', 'Enable') -contains $_.Action })
    if ($results.Count -eq 0) { return }
    $path = Get-LeaveDayResultPath -Date ([datetime]$Summary.Date)
    $folder = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force -WhatIf:$false) }
    $all = @(Get-LeaveDayResult -Date ([datetime]$Summary.Date)) + @(foreach ($result in $results) {
            [pscustomobject]@{
                Name = [string]$result.Name; SamAccountName = [string]$result.SamAccountName; Action = [string]$result.Action
                Period = [string]$result.Period; ReturnDate = [string]$result.ReturnDate; Success = [bool]$result.Success
                Message = [string]$result.Message; AppliedAt = $result.AppliedAt; ReplicationErrors = ''
            }
        })
    Export-Clixml -LiteralPath $path -InputObject $all -WhatIf:$false
    try {
        Get-ChildItem -LiteralPath $folder -Filter 'LeaveDay_*.xml' -File -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-31) } | Remove-Item -Force -WhatIf:$false -ErrorAction SilentlyContinue
    }
    catch { Write-Verbose $_.Exception.Message }
}
function Get-LeaveDayResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][datetime]$Date)
    $path = Get-LeaveDayResultPath -Date $Date
    if (-not (Test-Path -LiteralPath $path)) { return }
    @(Import-Clixml -LiteralPath $path) | Where-Object { $_ }
}
function Invoke-LeaveMailTest {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    try {
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { throw 'ActiveDirectory modülü bulunamadı.' }
        Import-Module -Name ActiveDirectory -ErrorAction Stop -Verbose:$false
        $global:Sync = $script:Sync
        foreach ($relativePath in $script:WorkerScripts) { . ([scriptblock]::Create((Read-AppFile -RelativePath $relativePath))) }
        $summary = Invoke-LeaveEnforcement -Date ((Get-Date).Date.AddDays(1)) -WhatIf -Confirm:$false
        $sent = Send-LeaveReport -Summary $summary -Preview -Confirm:$false
        Write-Host "Önizleme e-postası gönderildi: $($sent.To) ($($sent.Subject))" -ForegroundColor Green
        [void](Write-AuditEvent -Action 'leave.mail.test' -Result 'success' -Fields ([ordered]@{ category = 'leave'; mail_to = $sent.To }))
        return 0
    }
    catch {
        Write-Host "E-posta gönderilemedi: $($_.Exception.Message)" -ForegroundColor Red
        [void](Write-AuditEvent -Action 'leave.mail.test' -Result 'failure' -Fields ([ordered]@{ category = 'leave'; message = $_.Exception.Message }))
        return 2
    }
}
function Install-LeaveTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter()][string]$Account)
    $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList ([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Görev kurmak için PowerShell''i "Yönetici olarak çalıştır" ile açın.' }
    if (-not (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)) { throw 'ScheduledTasks modülü bulunamadı (Windows Server 2012 / Windows 8 veya üstü gerekir).' }
    $path = $script:ScriptFullPath
    if (-not $path) { throw 'Betik yolu belirlenemedi; betiği dosya olarak çalıştırın (.\<betik>.ps1 -InstallLeaveTask).' }
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { Write-Warning 'ActiveDirectory modülü bu bilgisayarda yok; görev çalışamaz (RSAT AD araçlarını kurun).' }
    $taskFullName = "$($script:Sync.LeaveTaskPath)$($script:Sync.LeaveTaskName)"
    $exe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argument = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RunLeaveCheck {1}' -f $path, ($script:LeaveTaskArgs -join ' ')).Trim()
    $action = New-ScheduledTaskAction -Execute $exe -Argument $argument -WorkingDirectory $script:AppRoot
    $daily = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours(23).AddMinutes(58))
    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT5M'
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 23 -Minutes 45) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $credential = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (-not $Account) {
            $credential = Get-Credential -Message 'Gece izin görevinin çalışacağı HİZMET hesabı (kendi hesabınızı girmeyin). gMSA için kullanıcı adının sonuna $ koyun (ör. DOMAIN\gmsa-izin$), parola alanını boş bırakın. Parola yalnızca Görev Zamanlayıcısı''na verilir, dosyaya yazılmaz.'
            if (-not $credential) { throw 'Görev hesabı girilmedi; kurulum iptal edildi.' }
            $Account = [string]$credential.UserName
        }
        $Account = $Account.Trim()
        $short = ($Account -split '\\')[-1] -replace '@.*$', ''
        $self = ($script:Audit.Operator -split '\\')[-1]
        if ($Account -and -not [string]::Equals($short, $self, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        Write-Warning "Görev kurulumu yapan hesapla ($($script:Audit.Operator)) kurulamaz: bu hesap kapanır veya parolası değişirse gece görevi durur. Ayrı bir hizmet hesabı ya da gMSA girin."
        $Account = $null
        $credential = $null
        if ($attempt -eq 3) { throw 'Geçerli bir hizmet hesabı girilmedi; kurulum iptal edildi.' }
    }
    $register = @{
        TaskName    = $script:Sync.LeaveTaskName
        TaskPath    = $script:Sync.LeaveTaskPath
        Action      = $action
        Trigger     = @($daily, $startup)
        Settings    = $settings
        Description = "AD & Exchange Kullanıcı Yöneticisi: personel izni. İzin günlerinde hesapları tam 00:00'da (yarım gün izinlerde izin saatinde) kapatır, izin bitince 00:00'da açar ($($script:Sync.LeaveAttribute)). Kurulum: $($script:Audit.Operator), $((Get-Date).ToString('yyyy-MM-dd HH:mm'))."
        Force       = $true
        ErrorAction = 'Stop'
    }
    if ($Account.EndsWith('$')) {
        $register.Principal = New-ScheduledTaskPrincipal -UserId $Account -LogonType Password -RunLevel Limited
    }
    else {
        if (-not $credential -or $credential.GetNetworkCredential().Password.Length -eq 0) {
            $credential = Get-Credential -UserName $Account -Message 'Gece izin görevinin hizmet hesabının parolası. Parola yalnızca Görev Zamanlayıcısı''na verilir, dosyaya yazılmaz.'
        }
        if (-not $credential) { throw 'Kimlik bilgisi girilmedi.' }
        $register.User = $credential.UserName
        $register.Password = $credential.GetNetworkCredential().Password
        $register.RunLevel = 'Limited'
    }
    if (-not $PSCmdlet.ShouldProcess("$taskFullName ($Account)", 'Register-ScheduledTask')) { return }
    try {
        $task = Register-ScheduledTask @register
    }
    finally {
        $register.Password = $null
    }
    $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction SilentlyContinue
    Write-Host "Gece izin görevi kuruldu: $taskFullName (hesap: $Account)" -ForegroundColor Green
    Write-Host "  Komut     : $exe $argument"
    Write-Host "  Çalışma   : her gün 23:58 (işlemler 00:00:00'da), açılışta +5 dk telafi; sonraki: $(if ($info -and $info.NextRunTime) { ([datetime]$info.NextRunTime).ToString('dd.MM.yyyy HH:mm') } else { '-' })"
    Write-Host "  Günlükler : $(Join-Path -Path $script:AppRoot -ChildPath 'Logs')  (LeaveCheck_yyyyMM.log + değişiklik günlüğü)"
    [void](Write-AuditEvent -Action 'leave.task.install' -Result 'success' -Fields ([ordered]@{ category = 'leave'; task = $taskFullName; task_account = $Account; command = "$exe $argument" }))
    $old = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.State -ne 'Disabled' -and (@($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -match '(?i)izin_kontrol').Count -gt 0
        })
    if ($old.Count -gt 0) {
        Write-Warning ("Eski izin görevi bulundu: " + (($old | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" }) -join ', '))
        $answer = Read-Host -Prompt 'Yeni görevle çakışmaması için bu eski görev(ler) devre dışı bırakılsın mı? (E/H)'
        if ($answer -match '^(?i)(e|evet|y|yes)$') {
            foreach ($item in $old) {
                if ($PSCmdlet.ShouldProcess("$($item.TaskPath)$($item.TaskName)", 'Disable-ScheduledTask')) {
                    [void](Disable-ScheduledTask -TaskName $item.TaskName -TaskPath $item.TaskPath -ErrorAction Stop)
                    Write-Host "Devre dışı bırakıldı: $($item.TaskPath)$($item.TaskName)" -ForegroundColor Green
                    [void](Write-AuditEvent -Action 'leave.task.legacy.disable' -Result 'success' -Fields ([ordered]@{ category = 'leave'; task = "$($item.TaskPath)$($item.TaskName)" }))
                }
            }
        }
    }
    Write-Host ''
    Write-Host 'Değişiklik yapmadan deneme (görevin hesabıyla aynı yetkiyle):' -ForegroundColor Cyan
    Write-Host "  & '$path' -RunLeaveCheck -LeavePreview"
}
function Uninstall-LeaveTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $taskFullName = "$($script:Sync.LeaveTaskPath)$($script:Sync.LeaveTaskName)"
    $task = Get-ScheduledTask -TaskPath $script:Sync.LeaveTaskPath -TaskName $script:Sync.LeaveTaskName -ErrorAction SilentlyContinue
    if (-not $task) { Write-Host "Gece izin görevi kurulu değil: $taskFullName" -ForegroundColor Yellow; return }
    if ($PSCmdlet.ShouldProcess($taskFullName, 'Unregister-ScheduledTask')) {
        Unregister-ScheduledTask -TaskName $script:Sync.LeaveTaskName -TaskPath $script:Sync.LeaveTaskPath -Confirm:$false -ErrorAction Stop
        Write-Host "Gece izin görevi kaldırıldı: $taskFullName" -ForegroundColor Green
        [void](Write-AuditEvent -Action 'leave.task.uninstall' -Result 'success' -Fields ([ordered]@{ category = 'leave'; task = $taskFullName }))
    }
}
