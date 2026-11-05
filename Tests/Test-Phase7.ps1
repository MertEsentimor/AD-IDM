# Çalıştırma: pwsh -NoProfile -File Tests/Test-Phase7.ps1  (veya Windows'ta powershell.exe). AD komutları sahtedir; dizine yazmaz.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0
$temporaryFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("adidm-p7-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -Path $temporaryFolder -ItemType Directory -Force)

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}

$global:Sync = [hashtable]::Synchronized(@{
        LogQueue = New-Object -TypeName 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
        ExchangeMode = 'None'; Pdc = 'dc01.test.local'; DefaultDc = 'dc01.test.local'
        PreviousOuAttribute = 'adminDescription'; LeaveAttribute = 'extensionAttribute1'; LegacyLeaveEndAttribute = 'extensionAttribute2'; DisabledUsersOu = 'OU=DisabledUsers,DC=test,DC=local'
        LeaveTaskPath = '\ADEUM\'; LeaveTaskName = 'Izin Kontrolu'
    })
$script:Sync = $global:Sync
$script:AppRoot = $temporaryFolder
$script:Ui = @{}
$script:MailConfigPath = Join-Path -Path $temporaryFolder -ChildPath 'mail-config.json'
foreach ($relativePath in 'Core/WorkerBootstrap.ps1', 'Core/Audit.ps1', 'Core/Config.ps1', 'Core/Notify.ps1', 'Modules/AD/Search.ps1', 'Modules/AD/Users.ps1', 'Modules/Leave/LeaveParser.ps1', 'Modules/Leave/LeaveEngine.ps1', 'Modules/Leave/LeaveTask.ps1', 'UI/Handlers/Leave.ps1', 'UI/Shell.ps1') {
    . (Join-Path -Path $projectRoot -ChildPath $relativePath)
}
$ErrorActionPreference = 'Stop'

# ---- Sahte dizin
function New-FakeUser { param($Sam, $Value, $Enabled = $true, $Dn = $null, $Marker = '') [pscustomobject]@{ ObjectGUID = [guid]::NewGuid(); SamAccountName = $Sam; Name = $Sam; DisplayName = $Sam; Enabled = $Enabled; DistinguishedName = $(if ($Dn) { $Dn } else { "CN=$Sam,OU=IT,DC=test,DC=local" }); extensionAttribute1 = $Value; extensionAttribute2 = $null; adminDescription = $Marker } }
$script:Directory = @(
    (New-FakeUser -Sam 'basliyor' -Value 'ADEUM-LEAVE;2026-12-01..2026-12-05')
    (New-FakeUser -Sam 'biten' -Value 'ADEUM-LEAVE;2026-11-20..2026-11-25;OFF=2026-11-20' -Enabled $false)
    (New-FakeUser -Sam 'baskanedenle' -Value 'ADEUM-LEAVE;2026-12-01..2026-12-05' -Enabled $false)
    (New-FakeUser -Sam 'cikmis' -Value 'ADEUM-LEAVE;2026-12-01..2026-12-05' -Dn 'CN=cikmis,OU=DisabledUsers,DC=test,DC=local')
    (New-FakeUser -Sam 'cikmismarker' -Value 'ADEUM-LEAVE;2026-11-20..2026-11-25;OFF=2026-11-20' -Enabled $false -Marker 'ADEUM-PreviousOU=OU=IT,DC=test')
    (New-FakeUser -Sam 'saatli' -Value 'ADEUM-LEAVE;2026-12-01@13:00..2026-12-01@18:00')
    (New-FakeUser -Sam 'bozuk' -Value 'ADEUM-LEAVE;tarih-degil')
    (New-FakeUser -Sam 'ilgisiz' -Value '2')
)
function global:Get-ADUser { param($LDAPFilter, $Properties, $ResultPageSize, $Server, $ErrorAction, $Identity) $script:Directory }
$script:Writes = New-Object -TypeName System.Collections.ArrayList
foreach ($command in 'Set-ADUser', 'Add-ADGroupMember', 'Remove-ADGroupMember', 'Move-ADObject') {
    Set-Item -Path "function:global:$command" -Value ([scriptblock]::Create("[void]`$script:Writes.Add('$command')"))
}

$midnight = [datetime]'2026-12-01'
$summary = Invoke-LeaveEnforcement -Date $midnight -Confirm:$false -WhatIf
$byName = @{}
foreach ($item in @($summary.Results)) { $byName[$item.SamAccountName] = $item }
Assert-True ($script:Writes.Count -eq 0 -and $summary.Simulated) 'Önizleme dizine yazmaz'
Assert-True ($byName.basliyor.Action -eq 'Disable' -and $byName.basliyor.NewValue -match 'OFF=2026-12-01') 'İzin başlayınca hesap kapanır ve OFF işareti yazılır'
Assert-True ($byName.biten.Action -eq 'Enable' -and -not $byName.biten.NewValue) 'Motorun kapattığı hesap izin bitince açılır, kayıt temizlenir'
Assert-True (-not $byName.ContainsKey('baskanedenle') -or $byName.baskanedenle.Action -notin 'Enable', 'Disable') 'Başka nedenle kapalı hesaba dokunulmaz'
Assert-True (-not $byName.ContainsKey('cikmis') -or $byName.cikmis.Action -notin 'Enable', 'Disable') 'DisabledUsers altındaki hesaba dokunulmaz'
Assert-True (-not $byName.ContainsKey('cikmismarker') -or $byName.cikmismarker.Action -notin 'Enable', 'Disable') 'Offboarding işaretli hesap açılmaz'
Assert-True (-not $byName.ContainsKey('saatli')) '13:00''da başlayan izin 00:00''da uygulanmaz'
Assert-True (-not $byName.ContainsKey('ilgisiz')) 'İzin dışı değer yok sayılır'
Assert-True (@($summary.Problems | Where-Object { $_ -match 'bozuk' }).Count -eq 1) 'Bozuk izin kaydı rapora girer'

$oneOClock = Invoke-LeaveEnforcement -Date ([datetime]'2026-12-01 13:00') -TimedOnly -Confirm:$false -WhatIf
Assert-True ((@($oneOClock.Results).SamAccountName -join ',') -eq 'saatli' -and @($oneOClock.Results)[0].Action -eq 'Disable') 'Saatli izin yalnızca kendi saatinde işlenir'
$sixOClock = Invoke-LeaveEnforcement -Date ([datetime]'2026-12-01 18:00') -TimedOnly -Confirm:$false -WhatIf
Assert-True (@($sixOClock.Results).Count -eq 0) 'OFF işareti olmadan açma yapılmaz'
$script:Directory = @(New-FakeUser -Sam 'saatli' -Value 'ADEUM-LEAVE;2026-12-01@13:00..2026-12-01@18:00;OFF=2026-12-01' -Enabled $false)
$sixOClock = Invoke-LeaveEnforcement -Date ([datetime]'2026-12-01 18:00') -TimedOnly -Confirm:$false -WhatIf
Assert-True (@($sixOClock.Results)[0].Action -eq 'Enable') 'Saatli iznin bitişinde hesap açılır'
$moments = @(Get-LeaveTimedMoment -After ([datetime]'2026-12-01 09:00') -Before ([datetime]'2026-12-01 23:30'))
Assert-True ($moments.Count -ge 1 -and ([datetime]$moments[0]) -eq [datetime]'2026-12-01 18:00') 'Gün içi izlenecek an bulunur'

# ---- Rapor kuralı
$mailBase = '{"Enabled":true,"SmtpServer":"s","From":"a@x","To":["b@x"],"SendWhen":"__WHEN__"}'
function Set-SendWhen { param($When) Set-Content -LiteralPath $script:MailConfigPath -Value ($mailBase -replace '__WHEN__', $When) -Encoding UTF8 }
$quiet = [pscustomobject]@{ Results = @(); Problems = @() }
$changed = [pscustomobject]@{ Results = @([pscustomobject]@{ Success = $true }); Problems = @() }
$failing = [pscustomobject]@{ Results = @([pscustomobject]@{ Success = $false }); Problems = @() }
$problem = [pscustomobject]@{ Results = @(); Problems = @('x') }
Set-SendWhen 'Always'
Assert-True (Test-LeaveReportDue -Summary $quiet) 'Always: işlem yokken de gönderir'
Set-SendWhen 'Changes'
Assert-True ((-not (Test-LeaveReportDue -Summary $quiet)) -and (Test-LeaveReportDue -Summary $changed)) 'Changes: yalnızca işlem olunca gönderir'
Assert-True (Test-LeaveReportDue -Summary $quiet -Earlier @([pscustomobject]@{ Success = $true })) 'Changes: gün içi işlem sayılır'
Set-SendWhen 'Failures'
Assert-True ((-not (Test-LeaveReportDue -Summary $changed)) -and (Test-LeaveReportDue -Summary $failing) -and (Test-LeaveReportDue -Summary $problem)) 'Failures: yalnızca hata veya sorunlu kayıtta gönderir'
Set-Content -LiteralPath $script:MailConfigPath -Value '{"Enabled":false,"SendWhen":"Always"}' -Encoding UTF8
Assert-True (-not (Test-LeaveReportDue -Summary $failing)) 'Kapalı ayarda rapor gönderilmez'

# ---- Gün içi sonuç kaydı
$dayResult = [pscustomobject]@{ Moment = [datetime]'2026-12-01 13:00'; Date = [datetime]'2026-12-01'; Results = @([pscustomobject]@{ SamAccountName = 'saatli'; Action = 'Disable'; Success = $true }) }
Save-LeaveDayResult -Summary $dayResult
$loadedDay = @(Get-LeaveDayResult -Date ([datetime]'2026-12-01'))
Assert-True ($loadedDay.Count -eq 1 -and $loadedDay[0].SamAccountName -eq 'saatli') 'Gün içi sonuçlar gece raporu için saklanır'

# ---- Form tarafı izin değeri (V1 uyumlu)
$uiPeriods = @((New-LeavePeriodUi -Start ([datetime]'2026-12-01') -Until ([datetime]'2026-12-06')), (New-LeavePeriodUi -Start ([datetime]'2026-12-05') -Until ([datetime]'2026-12-08')))
Assert-True (@(Merge-LeavePeriodUi -Periods $uiPeriods).Count -eq 1) 'Çakışan dönemler birleşir'
Assert-True ((ConvertFrom-LeaveStartTime -Text '13:00') -eq [timespan]'13:00' -or (ConvertFrom-LeaveStartTime -Text '13:00').Hours -eq 13) 'Saat metni okunur'

Remove-Item -LiteralPath $temporaryFolder -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
