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

Remove-Item -LiteralPath $temporaryFolder -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
