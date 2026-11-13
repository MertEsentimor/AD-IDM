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
if ($script:FailureCount -gt 0) { Write-Host "$script:FailureCount test başarısız."; exit 1 }
Write-Host 'Tüm testler geçti.'
