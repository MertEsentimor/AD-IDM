# Çalıştırma: pwsh -NoProfile -File Tests/Test-Offboard.ps1  (veya Windows'ta powershell.exe). AD/Exchange gerektirmez.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}
$global:Sync = @{ OffboardAttribute = 'extensionAttribute3' }
function global:Write-WorkerLog { param([string]$Message, [string]$Level) }
. ([scriptblock]::Create([System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'Modules/Offboard/Offboard.ps1'), [System.Text.Encoding]::UTF8)))

# --- Kayıt biçimi ---
$value = ConvertTo-OffboardValue -Date ([datetime]'2026-11-30') -PstFolder '\\srv\PST$\' -By 'CONTOSO\op;x'
Assert-True ($value -eq 'ADEUM-OFFBOARD;2026-11-30;PST=\\srv\PST$;BY=CONTOSO\opx') "Değer yazılır, sondaki \ ve ; temizlenir: $value"
$record = ConvertFrom-OffboardValue -Value $value
Assert-True ($record.Owned -and $record.Date -eq [datetime]'2026-11-30' -and $record.PstFolder -eq '\\srv\PST$' -and $record.By -eq 'CONTOSO\opx' -and -not $record.PstRetry) 'Değer geri okunur'
$retry = ConvertFrom-OffboardValue -Value (ConvertTo-OffboardValue -Date ([datetime]'2026-11-30') -PstFolder '\\srv\PST$' -PstRetry $true)
Assert-True ($retry.PstRetry) 'STATE=PSTRETRY okunur'
Assert-True ([bool](ConvertFrom-OffboardValue -Value 'ADEUM-OFFBOARD;30.11.2026').Problem) 'Hatalı tarih sorun olarak işaretlenir'
Assert-True (-not (ConvertFrom-OffboardValue -Value 'baska bir deger').Owned) 'Araca ait olmayan değer sahiplenilmez'

# --- Durum ---
$planned = ConvertFrom-OffboardValue -Value 'ADEUM-OFFBOARD;2026-11-30;PST=\\srv\PST$'
Assert-True ((Get-OffboardState -Record $planned -Enabled $true -Date ([datetime]'2026-11-29 23:59')).Kind -eq 'Planned') 'Bir gün önce 23:59: planlı'
Assert-True ((Get-OffboardState -Record $planned -Enabled $true -Date ([datetime]'2026-11-30 00:00')).Kind -eq 'Due') 'Gün 00:00: işlenir'
Assert-True ((Get-OffboardState -Record $planned -Enabled $true -Date ([datetime]'2026-12-02 00:05')).Kind -eq 'Due') 'Kaçırılan gün sonradan işlenir'
Assert-True ((Get-OffboardState -Record $planned -Enabled $false -Date ([datetime]'2026-11-30')).Kind -eq 'AlreadyDisabled') 'Hesap zaten kapalıysa dokunulmaz'
Assert-True ((Get-OffboardState -Record $retry -Enabled $false -Date ([datetime]'2026-11-30')).Kind -eq 'PstRetry') 'Kapalı hesapta PST yeniden denenir'
Assert-True ((Get-OffboardState -Record $retry -Enabled $true -Date ([datetime]'2026-11-30')).Kind -eq 'Invalid') 'Açık hesapta PST yeniden deneme kaydı hatalıdır'

# --- Gece işlemi (mock) ---
function global:Get-PdcEmulator { 'dc1' }
function global:Get-ADUser {
    param($LDAPFilter, $Properties, $ResultPageSize, $Server, $ErrorAction)
    foreach ($user in $global:MockUsers) {
        [pscustomobject]@{ ObjectGUID = [guid]$user.Guid; DisplayName = $user.Sam; Name = $user.Sam; SamAccountName = $user.Sam; DistinguishedName = "CN=$($user.Sam),DC=x"; Enabled = $user.Enabled; extensionAttribute3 = $user.Value }
    }
}
function global:Set-ADUser {
    param($Identity, $Server, $Replace, $Clear, $ErrorAction, [switch]$Confirm)
    $global:AdWrites[[string]$Identity] = if ($Replace) { [string]$Replace['extensionAttribute3'] } else { '<clear>' }
}
function global:Test-PstExportAvailable { if ($global:ExchangeUp) { '' } else { 'Exchange yok' } }
function global:Get-Mailbox { param($Identity, $ErrorAction) if ($global:NoMailbox -contains [string]$Identity) { throw 'yok' } [pscustomobject]@{ Alias = 'x' } }
function global:Start-MailboxPstExport { param($Identity, $FilePath, $RemoveMailbox, [switch]$Confirm) $global:PstStarts += , @{ Identity = $Identity; FilePath = $FilePath; Remove = $RemoveMailbox }; [pscustomobject]@{ FilePath = $FilePath } }
function global:Invoke-UserUpdate {
    param($ObjectGuid, $AccountFlags, $DisableCleanup, $ExchangeIdentity, [switch]$Confirm)
    $global:Updates += , @{ Guid = $ObjectGuid; Flags = $AccountFlags; Cleanup = $DisableCleanup }
    $disableOk = $global:DisableFails -notcontains $ObjectGuid
    [pscustomobject]@{ Step = 'Hesap seçenekleri'; Success = $disableOk; Message = $(if ($disableOk) { 'Başarılı' } else { 'erişim reddedildi' }); Data = $null }
    if ($DisableCleanup.RemoveGroups) { [pscustomobject]@{ Step = 'Grup temizliği'; Success = $disableOk; Message = ''; Data = $(if ($disableOk) { [pscustomobject]@{ RemovedDn = @('CN=VPN,DC=x') } }) } }
    if ($DisableCleanup.Pst) { [pscustomobject]@{ Step = 'PST dışa aktarma'; Success = $disableOk; Message = ''; Data = $null } }
    [pscustomobject]@{ Step = 'OU taşıma (devre dışı kullanıcılar)'; Success = $disableOk; Message = ''; Data = $null }
}
$guids = @{}
foreach ($name in 'ali', 'veli', 'ayse', 'fatma', 'can', 'ece') { $guids[$name] = [guid]::NewGuid().ToString() }
$folder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('adidm-off-' + [guid]::NewGuid().ToString('N'))
$global:MockUsers = @(
    @{ Guid = $guids.ali; Sam = 'ali'; Enabled = $true; Value = 'ADEUM-OFFBOARD;2026-11-30;PST=\\srv\PST$;BY=op' },
    @{ Guid = $guids.veli; Sam = 'veli'; Enabled = $true; Value = 'ADEUM-OFFBOARD;2026-12-15;PST=\\srv\PST$' },
    @{ Guid = $guids.ayse; Sam = 'ayse'; Enabled = $false; Value = 'ADEUM-OFFBOARD;2026-11-30;PST=\\srv\PST$' },
    @{ Guid = $guids.fatma; Sam = 'fatma'; Enabled = $false; Value = 'ADEUM-OFFBOARD;2026-11-29;PST=\\srv\PST$;STATE=PSTRETRY' },
    @{ Guid = $guids.can; Sam = 'can'; Enabled = $true; Value = 'ADEUM-OFFBOARD;2026-11-30;PST=\\srv\PST$' },
    @{ Guid = $guids.ece; Sam = 'ece'; Enabled = $true; Value = 'ADEUM-OFFBOARD;2026-11-30;PST=\\srv\PST$' }
)
try {
    $global:AdWrites = @{}; $global:Updates = @(); $global:PstStarts = @(); $global:ExchangeUp = $true; $global:DisableFails = @($guids.can); $global:NoMailbox = @($guids.ece)
    $connects = @{ Count = 0 }
    $summary = Invoke-OffboardEnforcement -Date ([datetime]'2026-11-30') -RemovedGroupFolder $folder -Operator 'svc' -ConnectExchange { $connects.Count++; $true } -Confirm:$false
    $byUser = @{}; foreach ($r in $summary.Results) { $byUser[$r.SamAccountName] = $r }
    $aliUpdate = @($global:Updates | Where-Object { $_.Guid -eq $guids.ali })[0]
    Assert-True ($aliUpdate.Flags.Enabled -eq $false -and $aliUpdate.Cleanup.RemoveGroups -and $aliUpdate.Cleanup.Pst.RemoveMailbox) 'Klasik offboarding: kapat, grupları temizle, PST + posta kutusu silme'
    Assert-True ($aliUpdate.Cleanup.Pst.FilePath -eq '\\srv\PST$\ali_20261130.pst') "PST yolu: $($aliUpdate.Cleanup.Pst.FilePath)"
    Assert-True ($global:AdWrites[$guids.ali] -eq '<clear>' -and $byUser.ali.Success) 'Başarılı offboarding sonrası plan temizlenir'
    Assert-True (@(Get-ChildItem -LiteralPath $folder -Filter 'ali_*.txt').Count -eq 1) 'Çıkarılan gruplar Logs\RemovedGroups biçiminde kaydedilir'
    Assert-True (-not $byUser.ContainsKey('veli') -and -not $global:AdWrites.ContainsKey($guids.veli)) 'Gelecek tarihli plana dokunulmaz'
    Assert-True ($global:AdWrites[$guids.ayse] -eq '<clear>' -and @($global:Updates | Where-Object { $_.Guid -eq $guids.ayse }).Count -eq 0) 'Zaten kapalı hesapta yalnız plan temizlenir'
    Assert-True (@($global:PstStarts | Where-Object { $_.Identity -eq $guids.fatma -and $_.Remove }).Count -eq 1 -and $global:AdWrites[$guids.fatma] -eq '<clear>') 'PST yeniden deneme başlatılır ve kayıt temizlenir'
    Assert-True (-not $global:AdWrites.ContainsKey($guids.can) -and -not $byUser.can.Success) 'Hesap kapanmazsa plan korunur (sonraki gece yeniden denenir)'
    $eceUpdate = @($global:Updates | Where-Object { $_.Guid -eq $guids.ece })[0]
    Assert-True (-not $eceUpdate.Cleanup.Pst -and $global:AdWrites[$guids.ece] -eq '<clear>' -and $byUser.ece.Success) 'Posta kutusu yoksa PST atlanır, plan temizlenir'
    Assert-True ($connects.Count -eq 1) 'Exchange bağlantısı bir kez kurulur'

    $global:AdWrites = @{}; $global:Updates = @(); $global:PstStarts = @(); $global:ExchangeUp = $false; $global:DisableFails = @(); $global:NoMailbox = @()
    $global:MockUsers = @($global:MockUsers[0])
    $summary = Invoke-OffboardEnforcement -Date ([datetime]'2026-11-30') -RemovedGroupFolder $folder -ConnectExchange { $false } -Confirm:$false
    $aliUpdate = @($global:Updates)[0]
    Assert-True ($aliUpdate.Flags.Enabled -eq $false -and -not $aliUpdate.Cleanup.Pst) 'Exchange yokken hesap yine kapatılır, PST atlanır'
    Assert-True ($global:AdWrites[$guids.ali] -like '*;STATE=PSTRETRY' -and -not $summary.Results[0].Success) "Exchange yokken PST yeniden denemeye bırakılır: $($global:AdWrites[$guids.ali])"

    $global:AdWrites = @{}; $global:Updates = @()
    $null = Invoke-OffboardEnforcement -Date ([datetime]'2026-11-30') -RemovedGroupFolder $folder -ConnectExchange { $true } -WhatIf
    Assert-True ($global:AdWrites.Count -eq 0) 'Önizlemede öznitelik yazılmaz'
}
finally { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }

# --- PST bitince posta kutusu silme ---
function global:Get-PstExportStatus { $global:MockJobs }
function global:Complete-MailboxPstExport { param($Alias, $Action, [switch]$Confirm) $global:Removed += $Alias; [pscustomobject]@{ MailboxRemoved = $true } }
$global:Removed = @()
$global:MockJobs = @(
    [pscustomobject]@{ Owned = $true; RemoveMailbox = $true; Archive = $false; Alias = 'ali'; Status = 'Completed' },
    [pscustomobject]@{ Owned = $true; RemoveMailbox = $true; Archive = $false; Alias = 'veli'; Status = 'Completed' },
    [pscustomobject]@{ Owned = $true; RemoveMailbox = $true; Archive = $true; Alias = 'veli'; Status = 'InProgress' },
    [pscustomobject]@{ Owned = $true; RemoveMailbox = $true; Archive = $false; Alias = 'ayse'; Status = 'CompletedWithWarning' },
    [pscustomobject]@{ Owned = $true; RemoveMailbox = $false; Archive = $false; Alias = 'can'; Status = 'Completed' }
)
$reported = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
$first = @(Complete-OffboardMailboxRemoval -Reported $reported -Confirm:$false)
Assert-True ($global:Removed -contains 'ali') 'Tamamlanan PST sonrası posta kutusu silinir'
Assert-True ($global:Removed -notcontains 'veli') 'Arşiv dışa aktarması sürerken silinmez'
Assert-True ($global:Removed -notcontains 'ayse' -and @($first | Where-Object { $_.Alias -eq 'ayse' }).Count -eq 1) 'Uyarılı PST silinmez, raporlanır'
Assert-True ($global:Removed -notcontains 'can') 'Silme işaretsiz PST isteğine dokunulmaz'
$second = @(Complete-OffboardMailboxRemoval -Reported $reported -Confirm:$false)
Assert-True (@($second | Where-Object { $_.Alias -eq 'ayse' }).Count -eq 0) 'Sorunlu PST aynı çalışmada bir kez raporlanır'

if ($script:FailureCount -gt 0) { Write-Host "$script:FailureCount test başarısız."; exit 1 }
Write-Host 'Tüm testler geçti.'
