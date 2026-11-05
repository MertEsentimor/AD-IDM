# Çalıştırma: pwsh -NoProfile -File Tests/Test-Phase4.ps1  (veya Windows'ta powershell.exe). Exchange gerektirmez; Exchange komutları sahtedir.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Name)
    $message = $null
    try { [void](& $Action) } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "$Name ($message)"
}

$global:Sync = [hashtable]::Synchronized(@{
        LogQueue = New-Object -TypeName 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
        ExchangeMode = 'OnPremises'; ExchangeServer = 'ex01.test.local'; Pdc = 'dc01.test.local'; DefaultDc = 'dc01.test.local'
    })
$script:Ui = @{}
foreach ($relativePath in 'Core/WorkerBootstrap.ps1', 'Modules/Exchange/Mailbox.ps1', 'UI/Handlers/UserProfile.ps1', 'UI/Handlers/Exchange.ps1', 'UI/Handlers/Leave.ps1', 'UI/Shell.ps1') {
    . (Join-Path -Path $projectRoot -ChildPath $relativePath)
}
$ErrorActionPreference = 'Stop'

# ---- Boyut dönüşümleri
Assert-True ((ConvertTo-ByteCount -Value '1.5 GB (1,610,612,736 bytes)') -eq 1610612736) 'Exchange boyut metni bayta çevrilir'
Assert-True ((ConvertTo-ByteCount -Value 'Unlimited') -eq -1) 'Sınırsız kota -1 döner'
Assert-True ((Format-ByteSize -Bytes 1610612736) -match '^1[.,]50? GB$') "Bayt okunur biçime çevrilir: $(Format-ByteSize -Bytes 1610612736)"

# ---- Adres güncelleme
$script:Captured = @{}
function global:Set-Mailbox { param($Identity, $EmailAddresses, $EmailAddressPolicyEnabled, $ErrorAction) $script:Captured.Mailbox = @{ Addresses = $EmailAddresses; Policy = $EmailAddressPolicyEnabled; HasPolicy = $PSBoundParameters.ContainsKey('EmailAddressPolicyEnabled') } }
function global:Set-RemoteMailbox { param($Identity, $EmailAddresses, $EmailAddressPolicyEnabled, $ErrorAction) $script:Captured.Remote = @{ Addresses = $EmailAddresses } }
function global:Set-ADUser { param($Identity, $Replace, $Clear, $ErrorAction) $script:Captured.Ad = @{ Replace = $Replace; Clear = $Clear } }
$originalAddresses = @('SMTP:eski@test.local', 'smtp:takma@test.local', 'X500:/o=Org/ou=Eski', 'SIP:ayse@test.local')
$newAddresses = @('smtp:eski@test.local', 'SMTP:yeni@test.local')

Set-UserEmailAddress -Source Mailbox -Identity 'ayse' -SmtpAddresses $newAddresses -OriginalAddresses $originalAddresses -PrimaryChanged $true -Confirm:$false
Assert-True (@($script:Captured.Mailbox.Addresses) -contains 'X500:/o=Org/ou=Eski' -and @($script:Captured.Mailbox.Addresses) -contains 'SIP:ayse@test.local') 'X500 ve SIP adresleri korunur'
Assert-True (@($script:Captured.Mailbox.Addresses | Where-Object { $_ -match 'takma' }).Count -eq 0 -and @($script:Captured.Mailbox.Addresses) -ccontains 'SMTP:yeni@test.local') 'SMTP listesi formdakiyle değişir'
Assert-True ($script:Captured.Mailbox.HasPolicy -and $script:Captured.Mailbox.Policy -eq $false) 'Birincil değişince adres politikası kapatılır'
Set-UserEmailAddress -Source Mailbox -Identity 'ayse' -SmtpAddresses $newAddresses -OriginalAddresses $originalAddresses -PrimaryChanged $false -Confirm:$false
Assert-True (-not $script:Captured.Mailbox.HasPolicy) 'Birincil değişmezse politikaya dokunulmaz'
Assert-Throws { Set-UserEmailAddress -Source Mailbox -Identity 'ayse' -SmtpAddresses @('smtp:a@test.local') -Confirm:$false } 'birincil SMTP' 'Birincilsiz Exchange adres listesi reddedilir'
$script:Captured.Clear()
Set-UserEmailAddress -Source Mailbox -Identity 'ayse' -SmtpAddresses $newAddresses -OriginalAddresses $originalAddresses -PrimaryChanged $true -Confirm:$false -WhatIf
Assert-True ($script:Captured.Count -eq 0) 'Simülasyon adresleri yazmaz'
Set-UserEmailAddress -Source AD -Identity 'guid' -SmtpAddresses $newAddresses -OriginalAddresses $originalAddresses -PrimaryChanged $true -UpdateMailAttribute $true -Confirm:$false
Assert-True ($script:Captured.Ad.Replace.mail -eq 'yeni@test.local' -and @($script:Captured.Ad.Replace.proxyAddresses) -contains 'X500:/o=Org/ou=Eski') 'AD kaynağında mail ve proxyAddresses yazılır'
$script:Captured.Clear()
Set-UserEmailAddress -Source AD -Identity 'guid' -SmtpAddresses @() -Confirm:$false
Assert-True (@($script:Captured.Ad.Clear) -contains 'proxyAddresses') 'Boş adres listesi özniteliği temizler'

# ---- Bekleyen adres, CAS ve politika değişiklikleri
Assert-True ((Get-PrimarySmtp -Addresses @('smtp:a@x', 'SMTP:b@x')) -ceq 'b@x') 'Birincil SMTP büyük harften bulunur'
Assert-True ((ConvertTo-AddressKey -Addresses @('SMTP:a@x', 'smtp:b@x')) -ceq (ConvertTo-AddressKey -Addresses @('smtp:b@x', 'SMTP:a@x'))) 'Adres sırası değişiklik sayılmaz'
function New-FakeControl { param($Text = '', $IsChecked = $false) [pscustomobject]@{ Text = $Text; IsChecked = $IsChecked; SelectedItem = $null; SelectedValue = $null } }
foreach ($key in $script:FieldMap.Keys) { $script:Ui[$script:FieldMap[$key].Control] = New-FakeControl }
foreach ($key in $script:AccountFlagMap.Keys) { $script:Ui[$script:AccountFlagMap[$key].Check] = New-FakeControl }
foreach ($key in $script:CasMap.Keys) { $script:Ui[$script:CasMap[$key].Check] = New-FakeControl -IsChecked $true }
$script:Ui.chkLeaveNow = New-FakeControl
$script:State.CurrentData = [pscustomobject]@{
    Ad       = [pscustomobject]@{ SamAccountName = 'ayse'; Leave = [pscustomobject]@{ State = [pscustomobject]@{ Active = $null } } }
    Exchange = [pscustomobject]@{ AddressSource = 'Mailbox'; Mode = 'OnPremises' }
    Password = [pscustomobject]@{ State = 'Ok' }
}
$script:State.OriginalSmtp = @('SMTP:eski@test.local', 'smtp:takma@test.local')
$script:State.SmtpList = New-Object -TypeName 'System.Collections.Generic.List[string]'
$script:State.SmtpList.Add('smtp:eski@test.local')
$script:State.SmtpList.Add('SMTP:yeni@test.local')
$script:State.OriginalCas = @{ OWAEnabled = $true; ActiveSyncEnabled = $true; ImapEnabled = $true; PopEnabled = $true; MAPIEnabled = $true }
$script:Ui.chkOWA.IsChecked = $false
$pending = Get-PendingChange
Assert-True ($pending.AddressChanged -and $pending.PrimaryChanged) 'Adres ve birincil değişikliği algılanır'
Assert-True (@($pending.Summary | Where-Object { $_ -match 'Eklenecek: yeni@test\.local' }).Count -eq 1 -and @($pending.Summary | Where-Object { $_ -match 'Kaldırılacak: takma@test\.local' }).Count -eq 1) 'Adres özeti eklenen ve kaldırılanı yazar'
Assert-True ($pending.CasChanges.ContainsKey('OWAEnabled') -and $pending.CasChanges.OWAEnabled -eq $false) 'CAS değişikliği algılanır'
Assert-True (@($pending.AuditItems | Where-Object { $_.Action -eq 'mailbox.cas.change' }).Count -eq 1) 'CAS değişikliği audit kaydı üretir'
$connected = Test-PendingChange -Changes $pending
Assert-True ($connected.Errors.Count -eq 0) "Bağlıyken doğrulama geçer: $($connected.Errors -join ';')"
$script:Sync.ExchangeMode = 'None'
$disconnected = Test-PendingChange -Changes $pending
Assert-True (@($disconnected.Errors | Where-Object { $_ -match 'Exchange bağlantısı' }).Count -ge 2) 'Bağlantı yokken Exchange değişikliği reddedilir'
$script:Sync.ExchangeMode = 'OnPremises'
$script:State.CurrentData.Exchange.Mode = 'None'
$stale = Test-PendingChange -Changes $pending
Assert-True (@($stale.Errors | Where-Object { $_ -match 'yenileyin' }).Count -eq 1) 'Bağlantı sonradan değiştiyse yenileme istenir'
$script:State.CurrentData.Exchange.Mode = 'OnPremises'
$script:State.SmtpList.Clear()
$script:State.SmtpList.Add('smtp:eski@test.local')
Assert-True (@((Test-PendingChange -Changes (Get-PendingChange)).Errors | Where-Object { $_ -match 'birincil SMTP' }).Count -eq 1) 'Birincilsiz adres listesi kaydedilemez'

# ---- Taşıma durumu
Assert-True ((Get-MoveStatusText -Status 'InProgress') -notmatch 'InProgress' -and (Get-MoveStatusText -Status 'Bilinmeyen') -eq 'Bilinmeyen') 'Taşıma durumu Türkçeleşir, bilinmeyen korunur'

Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
