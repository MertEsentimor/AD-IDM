# Çalıştırma: pwsh -NoProfile -File Tests/Test-Devices.ps1  (veya Windows'ta powershell.exe). AD komutları sahtedir.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0
$temporaryFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("adidm-dev-" + [guid]::NewGuid().ToString('N'))
[void](New-Item -Path $temporaryFolder -ItemType Directory -Force)

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}
function Get-ThrownMessage {
    param([scriptblock]$Action)
    try { [void](& $Action); return $null } catch { return $_.Exception.Message }
}

$global:Sync = [hashtable]::Synchronized(@{
        LogQueue = New-Object -TypeName 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
        Pdc = 'dc01.test.local'; DefaultDc = 'dc01.test.local'
        PreviousOuAttribute = 'adminDescription'; DisabledUsersOu = 'OU=DisabledUsers,DC=test,DC=local'
        DeviceNamePattern = 'NB-{sam}'
    })
$script:AppRoot = $temporaryFolder
$script:Ui = @{}
$script:Audit = @{ Operator = 'TEST\admin' }
foreach ($relativePath in 'Core/WorkerBootstrap.ps1', 'Modules/AD/Search.ps1', 'Modules/AD/Devices.ps1', 'Modules/AD/DisabledUsers.ps1', 'Core/Audit.ps1') {
    . (Join-Path -Path $projectRoot -ChildPath $relativePath)
}
$ErrorActionPreference = 'Stop'
$script:Calls = New-Object -TypeName System.Collections.ArrayList
$script:Filters = New-Object -TypeName System.Collections.ArrayList

# ---- Ad kuralı
Assert-True ((Test-DeviceNameMatch -Pattern 'NB-{sam}' -SamAccountName 'ME9533' -Name 'NB-ME9533')) 'NB-ME9533 eşleşir'
Assert-True ((Test-DeviceNameMatch -Pattern 'NB-{sam}' -SamAccountName 'me9533' -Name 'NB-ME9533-2')) 'Ek ve harf farkı eşleşir'
Assert-True (-not (Test-DeviceNameMatch -Pattern 'NB-{sam}' -SamAccountName 'ME9533' -Name 'FNB-ME9533')) 'FNB eşleşmez'
Assert-True (-not (Test-DeviceNameMatch -Pattern 'NB-{sam}' -SamAccountName 'ME9533' -Name 'NB-ME95331')) 'Uzun ad eşleşmez'
Assert-True (-not (Test-DeviceNameMatch -Pattern 'NB-{sam}' -SamAccountName 'ME953' -Name 'NB-ME9533')) 'Kısa sam eşleşmez'
Assert-True (-not (Test-DeviceNameMatch -Pattern '' -SamAccountName 'ME9533' -Name 'NB-ME9533')) 'Boş kural kapalı'
Assert-True ((ConvertTo-DeviceNameFilter -Pattern 'NB-{sam}' -SamAccountName 'ME9533') -eq '(&(objectClass=computer)(|(name=NB-ME9533)(name=NB-ME9533-*)))') 'LDAP filtresi'
Assert-True ((ConvertTo-DeviceNameFilter -Pattern 'NB-{sam}' -SamAccountName 'a*(b)') -eq '(&(objectClass=computer)(|(name=NB-a\2a\28b\29)(name=NB-a\2a\28b\29-*)))') 'LDAP kaçışlama'
Assert-True ($null -eq (ConvertTo-DeviceNameFilter -Pattern '' -SamAccountName 'ME9533')) 'Boş kuralda filtre yok'
Assert-True ((Test-DeviceNamePattern -Pattern 'NB-') -match '\{sam\}') '{sam} zorunlu'
Assert-True ((Test-DeviceNamePattern -Pattern 'NB-{sam}*') -match '\*') 'Joker reddedilir'
Assert-True ($null -eq (Test-DeviceNamePattern -Pattern '')) 'Boş kural geçerli'
Assert-True ((ConvertFrom-DeviceName -Pattern 'NB-{sam}' -Name 'NB-ME9533-2') -eq 'ME9533') 'Addan sam çıkarılır'
Assert-True ($null -eq (ConvertFrom-DeviceName -Pattern 'NB-{sam}' -Name 'TNB-SA0042')) 'Kurala uymayan ad'

# ---- Kullanıcı cihazları
$script:UserDn = 'CN=Mert,OU=U,DC=test,DC=local'
function New-FakeComputer {
    param([string]$Name, [string]$ManagedBy = $null, [string]$Ou = 'OU=C,DC=test,DC=local')
    [pscustomobject]@{
        Name = $Name; DistinguishedName = "CN=$Name,$Ou"; ObjectGUID = [guid]::NewGuid(); Enabled = $true
        managedBy = $ManagedBy; lastLogonTimestamp = (Get-Date '2026-11-01').ToFileTime(); 'ms-Mcs-AdmPwdExpirationTime' = 1
    }
}
$script:NameComputers = @(
    (New-FakeComputer -Name 'NB-ME9533'),
    (New-FakeComputer -Name 'NB-ME9533-2' -ManagedBy 'CN=Other,OU=X,DC=test,DC=local'),
    (New-FakeComputer -Name 'NB-ME95331')
)
$script:ManagedComputers = @((New-FakeComputer -Name 'PC-ELLE' -ManagedBy $script:UserDn))
function global:Get-ADComputer {
    param($Identity, $LDAPFilter, $Properties, $Server, $ErrorAction, $SearchBase, $ResultSetSize)
    [void]$script:Filters.Add($LDAPFilter)
    if ($LDAPFilter -match 'managedBy=') { return $script:ManagedComputers }
    return $script:NameComputers
}
function global:Get-ADObject {
    param($Identity, $LDAPFilter, $Properties, $Server, $ErrorAction, $SearchBase, $SearchScope, [switch]$IncludeDeletedObjects)
    if ($LDAPFilter -match 'msFVE-RecoveryInformation' -and $SearchBase -like 'CN=NB-ME9533,*') { return @([pscustomobject]@{ Name = 'k1' }, [pscustomobject]@{ Name = 'k2' }) }
    return @()
}
$devices = @(Get-UserDevice -SamAccountName 'ME9533' -DistinguishedName $script:UserDn)
Assert-True ((@($devices.Name) -join ',') -eq 'NB-ME9533,NB-ME9533-2,PC-ELLE') 'Ad kuralı + managedBy birleşir, NB-ME95331 elenir'
Assert-True (($devices | Where-Object Name -eq 'NB-ME9533-2').Conflict -match 'Other') 'Çakışma işaretlenir'
Assert-True (($devices | Where-Object Name -eq 'PC-ELLE').Source -eq 'Elle') 'Elle kaynağı'
Assert-True (($devices | Where-Object Name -eq 'NB-ME9533').Source -eq 'Ad kuralı') 'Ad kuralı kaynağı'
Assert-True (($devices | Where-Object Name -eq 'NB-ME9533').BitLockerCount -eq 2) 'BitLocker sayısı'
Assert-True (($devices | Where-Object Name -eq 'NB-ME9533').LapsPresent) 'LAPS var'
Assert-True (($devices | Where-Object Name -eq 'NB-ME9533').Ou -eq 'OU=C,DC=test,DC=local') 'OU'
$script:ManagedComputers = @($script:NameComputers[0] | Select-Object *)
$script:ManagedComputers[0].managedBy = $script:UserDn
$both = @(Get-UserDevice -SamAccountName 'ME9533' -DistinguishedName $script:UserDn)
Assert-True (($both | Where-Object Name -eq 'NB-ME9533').Source -eq 'İkisi' -and @($both | Where-Object Name -eq 'NB-ME9533').Count -eq 1) 'İki kaynaktan gelen tek kez listelenir'
$script:ManagedComputers = @()

# ---- Geri Dönüşüm Kutusu
$script:BinScopes = @('DC=test,DC=local')
$script:Lifetime = @{ 'msDS-deletedObjectLifetime' = 90; tombstoneLifetime = $null }
function global:Get-ADOptionalFeature { param($Identity, $Server, $ErrorAction) [pscustomobject]@{ Name = 'Recycle Bin Feature'; EnabledScopes = $script:BinScopes } }
function global:Get-ADRootDSE { param($Server, $ErrorAction) [pscustomobject]@{ configurationNamingContext = 'CN=Configuration,DC=test,DC=local' } }
$script:DeviceGetADObject = ${function:Get-ADObject}
function global:Get-ADObject {
    param($Identity, $LDAPFilter, $Properties, $Server, $ErrorAction, $SearchBase, $SearchScope, [switch]$IncludeDeletedObjects)
    if ($Identity -eq 'CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,DC=test,DC=local') { return [pscustomobject]$script:Lifetime }
    & $script:DeviceGetADObject @PSBoundParameters
}
$bin = Get-RecycleBinState
Assert-True ($bin.Enabled -and $bin.LifetimeDays -eq 90) 'Açık, 90 gün'
$script:Lifetime = @{ 'msDS-deletedObjectLifetime' = $null; tombstoneLifetime = 60 }
Assert-True ((Get-RecycleBinState).LifetimeDays -eq 60) 'tombstoneLifetime yedeği'
$script:Lifetime = @{ 'msDS-deletedObjectLifetime' = $null; tombstoneLifetime = $null }
Assert-True ((Get-RecycleBinState).LifetimeDays -eq 180) 'Varsayılan 180'
$script:BinScopes = @()
Assert-True (-not (Get-RecycleBinState).Enabled) 'Kapalı algılanır'
$script:BinScopes = @('DC=test,DC=local')
$script:Lifetime = @{ 'msDS-deletedObjectLifetime' = 180; tombstoneLifetime = $null }

# ---- Silme
$script:DisabledDn = 'CN=Mert,OU=DisabledUsers,DC=test,DC=local'
function global:Get-ADUser { param($Identity, $Server, $Properties, $ErrorAction) [pscustomobject]@{ Enabled = $false; SamAccountName = 'ME9533'; DistinguishedName = $script:DisabledDn; ObjectGUID = [guid]'11111111-1111-1111-1111-111111111111' } }
$script:FailOn = $null
function global:Remove-ADObject {
    param($Identity, [switch]$Recursive, $Server, $Confirm, $ErrorAction)
    if ($script:FailOn -and ([string]$Identity).StartsWith($script:FailOn)) { throw 'Access is denied' }
    [void]$script:Calls.Add([string]$Identity)
}
$allComputers = $script:NameComputers
$script:Calls.Clear()
$r = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True ($script:Calls[0] -like 'CN=NB-ME9533,*' -and $script:Calls[-1] -eq $script:DisabledDn -and $r[0].Success) 'Önce cihazlar sonra kullanıcı'
Assert-True (@(@($r[0].Devices | Where-Object Skipped).Name) -contains 'NB-ME9533-2' -and -not ($script:Calls -like 'CN=NB-ME9533-2,*')) 'Çakışmalı cihaz atlanır'
Assert-True ((@($r[0].Devices | Where-Object Name -eq 'NB-ME9533-2').Conflict) -match 'Other') 'Silme sonucunda çakışma metni'
$deleteResult = $r
$script:Calls.Clear(); $script:FailOn = 'CN=NB-ME9533,'
$r = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True (-not $r[0].Success -and $r[0].Message -match 'NB-ME9533' -and $script:Calls -notcontains $script:DisabledDn) 'Cihaz silinemezse kullanıcı silinmez'
$script:Calls.Clear(); $script:FailOn = $null; $script:BinScopes = @()
$r = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True (-not $r[0].Success -and $r[0].Message -match 'Geri Dönüşüm' -and $script:Calls.Count -eq 0) 'Geri Dönüşüm Kutusu kapalıyken hiçbir şey silinmez'
$script:BinScopes = @('DC=test,DC=local')
$script:Calls.Clear()
$r = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false -WhatIf)
Assert-True ($r[0].Success -and $script:Calls.Count -eq 0 -and @($r[0].Devices).Count -ge 1) 'Simülasyon cihaz silmez'
$script:NameComputers = @()
$r = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True ($r[0].Success -and @($r[0].Devices).Count -eq 0 -and $script:Calls -contains $script:DisabledDn) 'Cihazsız kullanıcı eskisi gibi silinir'
$script:NameComputers = $allComputers
$script:Calls.Clear(); $global:Sync.DeviceNamePattern = 'XX-{sam}'
[void](Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True (-not ($script:Calls -like 'CN=NB-ME9533*')) 'Silmede cihazlar yeniden çözülür'
$global:Sync.DeviceNamePattern = 'NB-{sam}'
$preview = Get-RemovalDevicePreview -ObjectGuid 'g'
Assert-True (@($preview['g']).Count -eq 2) 'Onay önizlemesi cihazları döner'

$auditPath = Join-Path -Path $temporaryFolder -ChildPath 'audit.log'
Initialize-Audit -Path $auditPath
Write-AuditTaskResult -Context (Get-AuditTaskContext -Command 'Remove-DisabledUser' -Arguments @{ ObjectGuid = @('g') }) -Result $deleteResult
$log = Get-Content -LiteralPath $auditPath -Raw
Assert-True ((@($log -split "`n" | Where-Object { $_ -match 'device\.delete' })).Count -eq 1 -and $log -match 'device_guid' -and $log -match 'owner_sam="ME9533"') 'Cihaz başına denetim kaydı'
Assert-True ($log -notmatch 'msFVE|AdmPwd') 'Denetimde sır alanı yok'

# ---- Elle bağlama
function global:Set-ADComputer {
    param($Identity, [hashtable]$Replace, $Clear, $Server, $ErrorAction)
    if ($Replace) { [void]$script:Calls.Add("Replace managedBy=$($Replace.managedBy)") }
    if ($Clear) { [void]$script:Calls.Add("Clear $Clear") }
}
$script:Calls.Clear()
$link = Set-DeviceOwner -ComputerDn 'CN=PC1,OU=C,DC=test,DC=local' -OwnerDn 'CN=Mert,OU=U,DC=test,DC=local' -Confirm:$false
Assert-True ($script:Calls[-1] -eq 'Replace managedBy=CN=Mert,OU=U,DC=test,DC=local' -and $link.Success) 'Bağlama managedBy yazar'
[void](Set-DeviceOwner -ComputerDn 'CN=PC1,OU=C,DC=test,DC=local' -OwnerDn '' -Confirm:$false)
Assert-True ($script:Calls[-1] -eq 'Clear managedBy') 'Bağ kaldırma temizler'
$script:Calls.Clear()
$simulatedLink = Set-DeviceOwner -ComputerDn 'CN=PC1,OU=C,DC=test,DC=local' -OwnerDn 'x' -Confirm:$false -WhatIf
Assert-True ($script:Calls.Count -eq 0 -and $simulatedLink.Success) 'Simülasyon yazmaz'
$script:NameComputers = @((New-FakeComputer -Name 'a*(1' -ManagedBy 'CN=Ali Veli,OU=U,DC=test,DC=local'))
$foundComputers = @(Find-DirectoryComputer -Query 'a*(')
Assert-True ($script:Filters[-1] -eq '(&(objectClass=computer)(name=a\2a\28*))') 'Arama kaçışlanır'
Assert-True ($foundComputers[0].ManagedByName -eq 'Ali Veli' -and $foundComputers[0].DistinguishedName) 'Arama sonucu sahibi gösterir'
$script:NameComputers = $allComputers
Assert-True ((Get-AuditTaskContext -Command 'Set-DeviceOwner' -Arguments @{ ComputerDn = 'x'; OwnerDn = 'y' }).Action -eq 'device.link') 'Bağlama denetim eylemi'
Assert-True ((Get-AuditTaskContext -Command 'Set-DeviceOwner' -Arguments @{ ComputerDn = 'x'; OwnerDn = '' }).Action -eq 'device.unlink') 'Bağ kaldırma denetim eylemi'

Remove-Item -LiteralPath $temporaryFolder -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
