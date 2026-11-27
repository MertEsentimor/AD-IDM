# Çalıştırma: pwsh -NoProfile -File Tests/Test-Dashboard.ps1  (veya Windows'ta powershell.exe). AD komutları sahtedir.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}
$global:Sync = [hashtable]::Synchronized(@{ LeaveAttribute = 'extensionAttribute1'; LegacyLeaveEndAttribute = '' })
. (Join-Path -Path $projectRoot -ChildPath 'Modules/AD/Reports.ps1')
function global:Get-PdcEmulator { 'dc01' }
function global:Set-WorkerProgress { param($Percent, $Status) }
$now = Get-Date
function New-FakeUser { param($Sam, $Extra) $u = [pscustomobject]@{ ObjectGUID = [guid]::NewGuid(); Name = $Sam; DisplayName = "Ad $Sam"; SamAccountName = $Sam }; foreach ($k in $Extra.Keys) { $u | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] }; $u }
$script:LockedUsers = @(
    (New-FakeUser 'kilitli' @{ LockedOut = $true; lockoutTime = $now.AddMinutes(-5).ToFileTime() })
    (New-FakeUser 'suresidolmus' @{ LockedOut = $false; lockoutTime = $now.AddDays(-2).ToFileTime() })
)
$script:PwdUsers = @(
    (New-FakeUser 'yarin' @{ 'msDS-UserPasswordExpiryTimeComputed' = $now.AddDays(1).AddHours(2).ToFileTime() })
    (New-FakeUser 'bugun' @{ 'msDS-UserPasswordExpiryTimeComputed' = $now.AddHours(3).ToFileTime() })
    (New-FakeUser 'uzak' @{ 'msDS-UserPasswordExpiryTimeComputed' = $now.AddDays(30).ToFileTime() })
    (New-FakeUser 'gecmis' @{ 'msDS-UserPasswordExpiryTimeComputed' = $now.AddDays(-1).ToFileTime() })
    (New-FakeUser 'suresiz' @{ 'msDS-UserPasswordExpiryTimeComputed' = [long]::MaxValue })
)
function global:Get-ADUser { param($LDAPFilter, $Properties, $Server, $ResultPageSize) if ($LDAPFilter -match 'lockoutTime') { $script:LockedUsers } else { $script:PwdUsers } }
$script:DisabledFails = $false
function global:Get-DisabledUserList { param([switch]$SkipEventLog) if ($script:DisabledFails) { throw 'OU yok' }; $script:SkippedEvents = [bool]$SkipEventLog; @{ Ou = 'OU=Disabled'; Users = @([pscustomobject]@{ Overdue = $true; DisabledAt = $now.AddDays(-40) }, [pscustomobject]@{ Overdue = $false; DisabledAt = $null }) } }

$summary = Get-DashboardSummary
Assert-True ($summary.LockedCount -eq 1 -and $summary.Locked[0].SamAccountName -eq 'kilitli') 'Kilit süresi dolan hesap kilitli sayılmaz'
Assert-True ($summary.ExpiringCount -eq 2 -and $summary.Expiring[0].SamAccountName -eq 'bugun' -and $summary.Expiring[1].SamAccountName -eq 'yarin') "7 gün içinde dolanlar en yakın önce: $($summary.Expiring.SamAccountName -join ',')"
Assert-True ($summary.Expiring[0].DetailText -like 'Bugün*' -and $summary.Expiring[1].DetailText -like '1 gün*') "Kalan süre metni: $($summary.Expiring.DetailText -join ' / ')"
Assert-True ($summary.DisabledCount -eq 2 -and $summary.DisabledOverdue -eq 1 -and $summary.DisabledUnknown -eq 1 -and $script:SkippedEvents) 'Devre dışı sayıları olay günlüğü taranmadan hesaplanır'
Assert-True ($summary.Errors.Count -eq 0) 'Hata yok'
$script:DisabledFails = $true
$partial = Get-DashboardSummary
Assert-True ($null -eq $partial.DisabledCount -and $partial.LockedCount -eq 1 -and $partial.Errors.Count -eq 1) 'Bir kart okunamazsa diğerleri yine gelir'
$ortak = New-FakeUser 'ortak' @{ lastLogonTimestamp = $now.AddDays(-45).ToFileTime() }
$script:InactiveByOu = @{
    'OU=A,DC=x' = @((New-FakeUser 'eski' @{ lastLogonTimestamp = $now.AddDays(-90).ToFileTime() }), $ortak, (New-FakeUser 'hic' @{ lastLogonTimestamp = $null }))
    'OU=B,OU=A,DC=x' = @($ortak)
    'OU=Bozuk,DC=x' = 'throw'
}
$script:InactiveCalls = @()
function global:Get-ADUser { param($LDAPFilter, $SearchBase, $SearchScope, $Properties, $Server, $ResultPageSize) $script:InactiveCalls += [pscustomobject]@{ Filter = $LDAPFilter; Scope = $SearchScope }; if ($script:InactiveByOu[$SearchBase] -eq 'throw') { throw 'erişim yok' }; $script:InactiveByOu[$SearchBase] }
$inactive = Get-InactiveUserList -SearchBase 'OU=A,DC=x', 'OU=B,OU=A,DC=x', 'OU=Bozuk,DC=x'
Assert-True ($inactive.Count -eq 3) "İç içe OU'larda aynı kullanıcı bir kez sayılır: $($inactive.Users.SamAccountName -join ',')"
Assert-True (($inactive.Users.SamAccountName -join ',') -eq 'hic,eski,ortak') "Hiç açmayan önce, sonra en eski: $($inactive.Users.SamAccountName -join ',')"
Assert-True ($inactive.Users[0].DetailText -eq 'Hiç oturum açmadı' -and $inactive.Users[1].DetailText -like '90 gün*') "Detay metni: $($inactive.Users.DetailText -join ' / ')"
Assert-True (@($script:InactiveCalls | Where-Object { $_.Scope -ne 'Subtree' }).Count -eq 0) 'Alt OU''lar her zaman dahil (Subtree)'
Assert-True ($script:InactiveCalls[0].Filter -match 'lastLogonTimestamp<=\d+' -and $script:InactiveCalls[0].Filter -match '!\(userAccountControl') 'Filtre: eşik tarihi ve yalnız etkin hesaplar'
Assert-True ($inactive.Errors.Count -eq 1) 'Okunamayan OU diğerlerini durdurmaz'
if ($script:FailureCount -gt 0) { Write-Host "$script:FailureCount test başarısız."; exit 1 }
Write-Host 'Tüm testler geçti.'
