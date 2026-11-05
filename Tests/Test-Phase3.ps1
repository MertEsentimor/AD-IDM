# Çalıştırma: pwsh -NoProfile -File Tests/Test-Phase3.ps1  (veya Windows'ta powershell.exe). AD ve WPF gerektirmez; AD komutları sahtedir, dizine yazmaz.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}

$global:Sync = [hashtable]::Synchronized(@{
        LogQueue = New-Object -TypeName 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
        ExchangeMode = 'None'; Pdc = 'dc01.test.local'; DefaultDc = 'dc01.test.local'
        PreviousOuAttribute = 'adminDescription'; LeaveAttribute = 'extensionAttribute1'; LegacyLeaveEndAttribute = 'extensionAttribute2'; DisabledUsersOu = 'OU=DisabledUsers,DC=test,DC=local'
    })
$script:Ui = @{}
$script:AppRoot = [System.IO.Path]::GetTempPath()
foreach ($relativePath in 'Core/WorkerBootstrap.ps1', 'Core/Audit.ps1', 'Core/Notify.ps1', 'Modules/AD/Search.ps1', 'Modules/AD/Users.ps1', 'Modules/AD/Groups.ps1', 'Modules/Leave/LeaveParser.ps1', 'Modules/Exchange/Mailbox.ps1', 'UI/Handlers/UserProfile.ps1', 'UI/Handlers/Exchange.ps1', 'UI/Handlers/Offboarding.ps1', 'UI/Handlers/Leave.ps1', 'UI/Shell.ps1') {
    . (Join-Path -Path $projectRoot -ChildPath $relativePath)
}
$ErrorActionPreference = 'Stop'

# ---- LDAP
Assert-True ((ConvertTo-LdapFilterValue -Value 'a*(b)\c') -eq 'a\2a\28b\29\5cc') 'LDAP filtresi: özel karakterler kaçırılır'

# ---- Önceki OU kaydı (V1 ile uyumlu)
$storedInfo = Get-StoredDisableInfo -Value 'ADEUM-PreviousOU=OU=IT,DC=test,DC=local|By=TEST\admin|At=2026-11-05T10:00:00Z'
Assert-True ($storedInfo.PreviousOu -eq 'OU=IT,DC=test,DC=local' -and $storedInfo.By -eq 'TEST\admin' -and $storedInfo.At) 'Önceki OU, kapatan ve zaman okunur'
Assert-True ((Get-StoredPreviousOu -Value 'başka değer') -eq '') 'ADEUM önekisiz değer yok sayılır'

# ---- İzin biçimi (V1 ile uyumlu)
$leaveText = 'ADEUM-LEAVE;2026-12-01..2026-12-05;2026-12-10@13:00..2026-12-10@18:00;OFF=2026-12-01'
$leaveRecord = ConvertFrom-LeaveValue -Value $leaveText
Assert-True ($leaveRecord.Owned -and @($leaveRecord.Periods).Count -eq 2 -and $leaveRecord.Off -eq '2026-12-01' -and -not $leaveRecord.Problem) 'İzin kaydı ayrıştırılır'
Assert-True ((ConvertTo-LeaveValue -Periods $leaveRecord.Periods -Off $leaveRecord.Off) -ceq $leaveText) 'İzin kaydı aynı metne geri yazılır'
Assert-True ((ConvertFrom-LeaveValue -Value 'ADEUM-LEAVE;bozuk').Problem -match 'hatalı dönem') 'Bozuk izin dönemi raporlanır'
Assert-True (-not (ConvertFrom-LeaveValue -Value 'başka amaçlı değer').Owned) 'İzin dışı değer sahiplenilmez'
$onLeaveMoment = [datetime]'2026-12-03'
$afterLeaveMoment = [datetime]'2026-12-07'
$plainRecord = ConvertFrom-LeaveValue -Value 'ADEUM-LEAVE;2026-12-01..2026-12-05'
$closedByEngine = ConvertFrom-LeaveValue -Value 'ADEUM-LEAVE;2026-12-01..2026-12-05;OFF=2026-12-01'
Assert-True ((Get-LeaveState -Record $plainRecord -Enabled $true -Date $onLeaveMoment).Action -eq 'Disable') 'İzin başlayınca açık hesap kapatılır'
Assert-True ((Get-LeaveState -Record $closedByEngine -Enabled $false -Date $afterLeaveMoment).Action -eq 'Enable') 'Motorun kapattığı hesap izin bitince açılır'
Assert-True ((Get-LeaveState -Record $plainRecord -Enabled $false -Date $onLeaveMoment).Kind -eq 'DisabledOther') 'Başka nedenle kapalı hesap işaretlenir'
Assert-True ((Get-LeaveState -Record $plainRecord -Enabled $false -Date $afterLeaveMoment).Action -ne 'Enable') 'Başka nedenle kapalı hesap açılmaz'
Assert-True ((Get-LeaveState -Record $plainRecord -Enabled $true -Protected $true -Date $onLeaveMoment).Action -eq 'None') 'Korumalı hesap kapatılmaz'
Assert-True (Test-LeaveProtected -DistinguishedName 'CN=a,OU=DisabledUsers,DC=test,DC=local' -Marker '' -DisabledOu 'OU=DisabledUsers,DC=test,DC=local') 'DisabledUsers altındaki hesap korunur'

# ---- Bekleyen değişiklikler
function New-FakeControl { param($Text = '', $IsChecked = $false) [pscustomobject]@{ Text = $Text; IsChecked = $IsChecked } }
foreach ($key in $script:FieldMap.Keys) { $script:Ui[$script:FieldMap[$key].Control] = New-FakeControl }
foreach ($key in $script:AccountFlagMap.Keys) { $script:Ui[$script:AccountFlagMap[$key].Check] = New-FakeControl }
foreach ($name in 'chkDisableGroups', 'chkDisablePst', 'chkLeaveNow') { $script:Ui[$name] = New-FakeControl }
$script:State.CurrentData = [pscustomobject]@{
    Ad       = [pscustomobject]@{ ObjectGuid = '11111111-1111-1111-1111-111111111111'; SamAccountName = 'ayse'; UserPrincipalName = 'ayse@test.local'; DistinguishedName = 'CN=Ayse,OU=IT,DC=test,DC=local'; PreviousOu = ''; DisabledUsersOu = 'OU=DisabledUsers,DC=test,DC=local'; Leave = [pscustomobject]@{ State = [pscustomobject]@{ Active = $null } } }
    Exchange = [pscustomobject]@{ AddressSource = 'AD' }
    Password = [pscustomobject]@{ State = 'Ok' }
}
$script:State.Original = @{ GivenName = 'Ayse'; Surname = 'Yilmaz'; DisplayName = 'Ayse Yilmaz'; Office = 'Merkez' }
$script:Ui.txtGivenName.Text = 'Ayse'
$script:Ui.txtSurname.Text = 'Yilmaz'
$script:Ui.txtDisplayName.Text = 'Ayse Yılmaz'
$script:Ui.txtOffice.Text = '   '
$script:State.OriginalFlags = @{ Enabled = $true; PasswordNeverExpires = $false }
$script:Ui.chkAccountEnabled.IsChecked = $false
$script:State.GroupList = New-Object -TypeName 'System.Collections.Generic.List[object]'
$script:State.GroupList.Add([pscustomobject]@{ State = 'Existing'; Group = [pscustomobject]@{ Name = 'G0'; DistinguishedName = 'CN=G0,DC=test' } })
$script:State.GroupList.Add([pscustomobject]@{ State = 'Added'; Group = [pscustomobject]@{ Name = 'G1'; DistinguishedName = 'CN=G1,DC=test' } })
$script:State.GroupList.Add([pscustomobject]@{ State = 'Removed'; Group = [pscustomobject]@{ Name = 'G2'; DistinguishedName = 'CN=G2,DC=test' } })
$pending = Get-PendingChange
Assert-True ($pending.AdReplace.displayName -ceq 'Ayse Yılmaz') 'Değişen alan AD değişikliği olur'
Assert-True (@($pending.AdClear) -contains 'physicalDeliveryOfficeName') 'Boşaltılan alan temizlenir'
Assert-True ($pending.AccountFlags.ContainsKey('Enabled') -and -not $pending.AccountFlags.Enabled) 'Hesap kapatma bekleyen değişikliktir'
Assert-True (($pending.GroupAdd -join ',') -eq 'CN=G1,DC=test' -and ($pending.GroupRemove -join ',') -eq 'CN=G2,DC=test') 'Grup ekleme ve çıkarma ayrılır'
Assert-True ($pending.Count -eq 5) "Sayaç: $($pending.Count)"
Assert-True (@($pending.AuditItems).Count -eq 5) 'Her değişiklik audit kaydı üretir'
Assert-True (@($pending.Summary | Where-Object { $_ -match 'DisabledUsers' }).Count -eq 1) 'Özet hedef OU''yu söyler'
$chips = Get-PendingChipModel -Summary @("AD  |  Ofis: 'a' -> 'b'", 'Grup  |  Eklenecek: G1')
Assert-True ($chips.Items[0].Title -eq 'Ofis' -and $chips.Items[0].Detail -match "'a' . 'b'" -and $chips.Items[1].Title -eq 'Eklenecek') 'Bekleyen değişiklik kartları'

$validation = Test-PendingChange -Changes $pending
Assert-True ($validation.Errors.Count -eq 0 -and @($validation.Warnings | Where-Object { $_ -match 'oturum açamaz' }).Count -eq 1) 'Hesap kapatma uyarısı'
$script:Ui.txtSamAccountName.Text = 'bu-ad-yirmi-karakterden-uzun'
$script:State.Original.SamAccountName = 'ayse'
$script:Ui.txtUpn.Text = 'hatali'
$script:State.Original.UserPrincipalName = 'ayse@test.local'
$script:Ui.txtEmail.Text = 'hatali'
$invalid = Test-PendingChange -Changes (Get-PendingChange)
Assert-True (@($invalid.Errors | Where-Object { $_ -match '20 karakter' }).Count -eq 1) 'Uzun SamAccountName reddedilir'
Assert-True (@($invalid.Errors | Where-Object { $_ -match 'UserPrincipalName' }).Count -eq 1) 'Hatalı UPN reddedilir'
Assert-True (@($invalid.Errors | Where-Object { $_ -match 'E-Mail' }).Count -eq 1) 'Hatalı e-posta reddedilir'
$originalUser = $env:USERNAME
$env:USERNAME = 'ayse'
$selfDisable = Test-PendingChange -Changes (Get-PendingChange)
$env:USERNAME = $originalUser
Assert-True (@($selfDisable.Errors | Where-Object { $_ -match 'Kendi hesabınızı' }).Count -eq 1) 'Kendi hesabını kapatma engellenir'
$script:Ui.chkAccountEnabled.IsChecked = $true
$script:State.OriginalFlags.Enabled = $false
$script:State.LeaveEdit.Add((New-LeavePeriodUi -Start (Get-Date).Date.AddDays(-1) -Until (Get-Date).Date.AddDays(2)))
$activeLeave = Test-PendingChange -Changes (Get-PendingChange)
Assert-True (@($activeLeave.Warnings | Where-Object { $_ -match 'izni bugün sürüyor' }).Count -eq 1) 'İzindeki hesabı açma uyarısı'

# ---- Uygulama: sıralı adımlar, simülasyon, kısmi hata
$script:WriteCalls = New-Object -TypeName System.Collections.ArrayList
function global:Set-ADUser { param($Identity, $Replace, $Clear, $Server, $ErrorAction) [void]$script:WriteCalls.Add('Set-ADUser'); if ($script:FailSetAdUser) { throw 'erişim reddedildi' } }
function global:Add-ADGroupMember { param($Identity, $Members, $Server, $Confirm, $ErrorAction) [void]$script:WriteCalls.Add("Add:$Identity") }
function global:Remove-ADGroupMember { param($Identity, $Members, $Server, $Confirm, $ErrorAction) [void]$script:WriteCalls.Add("Remove:$Identity") }
$guid = '11111111-1111-1111-1111-111111111111'
$updateArguments = @{ ObjectGuid = $guid; AdReplace = @{ displayName = 'Yeni' }; GroupAdd = @('CN=G1,DC=test'); GroupRemove = @('CN=G2,DC=test'); Confirm = $false }

$simulated = @(Invoke-UserUpdate @updateArguments -WhatIf)
Assert-True ($script:WriteCalls.Count -eq 0) "Simülasyon dizine yazmaz ($($script:WriteCalls -join ','))"
Assert-True ($simulated.Count -eq 2 -and @($simulated | Where-Object { $_.Message -notmatch 'Simüle' }).Count -eq 0) 'Simülasyon her adımı raporlar'
$queuedLogs = New-Object -TypeName System.Collections.ArrayList
$logItem = $null
while ($global:Sync.LogQueue.TryDequeue([ref]$logItem)) { [void]$queuedLogs.Add($logItem) }
Assert-True (@($queuedLogs | Where-Object { $_.Message -like '`[WhatIf`] Set-ADUser*' }).Count -eq 1) 'Simülasyon yapılacak komutu günlüğe yazar'

$applied = @(Invoke-UserUpdate @updateArguments)
Assert-True (($script:WriteCalls -join ',') -eq 'Set-ADUser,Add:CN=G1,DC=test,Remove:CN=G2,DC=test') "Adımlar sırayla uygulanır ($($script:WriteCalls -join ','))"
Assert-True ($applied.Count -eq 2 -and @($applied | Where-Object { -not $_.Success }).Count -eq 0) 'Başarılı adımlar raporlanır'

$script:WriteCalls.Clear()
$script:FailSetAdUser = $true
$partial = @(Invoke-UserUpdate @updateArguments)
$script:FailSetAdUser = $false
Assert-True ($partial.Count -eq 2 -and -not $partial[0].Success -and $partial[0].Message -match 'erişim reddedildi' -and $partial[1].Success) 'Biri başarısız olunca diğeri yine işlenir ve ayrı raporlanır'
Assert-True (@($script:WriteCalls | Where-Object { $_ -like 'Add:*' }).Count -eq 1) 'Hatadan sonraki adım gerçekten çalışır'

# ---- Audit: değişiklik başına kayıt
$auditPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("adidm-audit-" + [guid]::NewGuid().ToString('N') + '.log')
try {
    Initialize-Audit -Path $auditPath
    $context = Get-AuditTaskContext -Command 'Invoke-UserUpdate' -Arguments @{ ObjectGuid = $guid } -Changes @(
        @{ Step = 'AD'; Action = 'user.attribute.change'; Category = 'ad'; Field = 'displayName'; Operation = 'set'; Old = 'Eski'; New = 'Yeni' }
        @{ Step = 'Groups'; Action = 'user.group.add'; Category = 'group'; Field = 'memberOf'; Operation = 'add'; Old = ''; New = 'CN=G1,DC=test' }
    )
    Write-AuditTaskResult -Context $context -Result $partial -Failure $null
    $auditLines = @(Get-Content -LiteralPath $auditPath -Encoding UTF8)
    Assert-True ($auditLines.Count -eq 2) 'Her değişiklik ayrı audit satırıdır'
    Assert-True ($auditLines[0] -match 'field="displayName"' -and $auditLines[0] -match 'old_value="Eski"' -and $auditLines[0] -match 'result="failure"' -and $auditLines[0] -match 'target_user="ayse"') 'Audit eski, yeni, hedef ve sonucu yazar'
    Assert-True ($auditLines[1] -match 'result="success"') 'Audit adım sonucunu ayrı yazar'
}
finally { Remove-Item -LiteralPath $auditPath -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
