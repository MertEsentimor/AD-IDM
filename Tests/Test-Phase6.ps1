# Çalıştırma: pwsh -NoProfile -File Tests/Test-Phase6.ps1  (veya Windows'ta powershell.exe). AD ve Exchange komutları sahtedir.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0
$temporaryFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("adidm-p6-" + [guid]::NewGuid().ToString('N'))
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
        ExchangeMode = 'OnPremises'; PstExportReady = $true; Pdc = 'dc01.test.local'; DefaultDc = 'dc01.test.local'
        PreviousOuAttribute = 'adminDescription'; DisabledUsersOu = 'OU=DisabledUsers,DC=test,DC=local'
    })
$script:AppRoot = $temporaryFolder
$script:Ui = @{}
$script:Audit = @{ Operator = 'TEST\admin' }
foreach ($relativePath in 'Core/WorkerBootstrap.ps1', 'Core/Notify.ps1', 'Modules/AD/Search.ps1', 'Modules/AD/Users.ps1', 'Modules/AD/Groups.ps1', 'Modules/AD/DisabledUsers.ps1', 'Modules/Exchange/Mailbox.ps1', 'Modules/Exchange/PstExport.ps1', 'UI/Handlers/Offboarding.ps1', 'UI/Shell.ps1') {
    . (Join-Path -Path $projectRoot -ChildPath $relativePath)
}
$ErrorActionPreference = 'Stop'
function Write-UiLog { param($Message, $Level) $script:UiLogs.Add($Message) | Out-Null }
$script:UiLogs = New-Object -TypeName System.Collections.ArrayList
$script:Calls = New-Object -TypeName System.Collections.ArrayList

# ---- PST: posta kutusu silme güvenliği
$pstPath = Join-Path -Path $temporaryFolder -ChildPath 'ayse.pst'
[System.IO.File]::WriteAllText($pstPath, 'pst')
$script:Requests = @()
$script:StatPath = $pstPath
function global:New-MailboxExportRequest { [void]$script:Calls.Add('New-MailboxExportRequest') }
function global:Get-MailboxExportRequest { param($Mailbox, $ErrorAction) $script:Requests }
function global:Get-MailboxExportRequestStatistics { param([Parameter(ValueFromPipeline = $true)]$InputObject) process { [pscustomobject]@{ FilePath = $script:StatPath } } }
function global:Remove-MailboxExportRequest { param([Parameter(ValueFromPipeline = $true)]$InputObject, $Confirm) process { [void]$script:Calls.Add('Remove-MailboxExportRequest') } }
function global:Get-Mailbox { param($Identity, $ErrorAction) [pscustomobject]@{ DistinguishedName = 'CN=Ayse,DC=test'; ArchiveGuid = [guid]::Empty } }
function global:Disable-Mailbox { param($Identity, $Archive, $Confirm, $ErrorAction) [void]$script:Calls.Add('Disable-Mailbox') }
function New-Request { param($Status, $Name = 'ADEUM-PST-SIL-1') [pscustomobject]@{ Name = $Name; Status = $Status } }

$script:Requests = @(New-Request -Status 'InProgress')
Assert-True ((Get-ThrownMessage { Complete-MailboxPstExport -Alias 'ayse' -Action Remove -Confirm:$false }) -match 'tamamlanmadı' -and $script:Calls -notcontains 'Disable-Mailbox') 'Süren dışa aktarmada posta kutusu silinmez'
$script:Requests = @(New-Request -Status 'Failed')
Assert-True ((Get-ThrownMessage { Complete-MailboxPstExport -Alias 'ayse' -Action Remove -Confirm:$false }) -match 'tamamlanmadı' -and $script:Calls -notcontains 'Disable-Mailbox') 'Başarısız dışa aktarmada posta kutusu silinmez'
$script:Requests = @(New-Request -Status 'CompletedWithWarning')
Assert-True ((Get-ThrownMessage { Complete-MailboxPstExport -Alias 'ayse' -Action Remove -Confirm:$false }) -match 'tamamlanmadı' -and $script:Calls -notcontains 'Disable-Mailbox') 'Uyarılı dışa aktarmada otomatik silme yapılmaz'
$script:Requests = @()
Assert-True ((Get-ThrownMessage { Complete-MailboxPstExport -Alias 'ayse' -Action Remove -Confirm:$false }) -match 'bulunamadı' -and $script:Calls -notcontains 'Disable-Mailbox') 'İstek yoksa posta kutusu silinmez'
$script:Requests = @(New-Request -Status 'Completed')
$script:StatPath = Join-Path -Path $temporaryFolder -ChildPath 'yok.pst'
Assert-True ((Get-ThrownMessage { Complete-MailboxPstExport -Alias 'ayse' -Action Remove -Confirm:$false }) -match 'doğrulanamadı' -and $script:Calls -notcontains 'Disable-Mailbox') 'PST dosyası yoksa posta kutusu silinmez'
$emptyPst = Join-Path -Path $temporaryFolder -ChildPath 'bos.pst'
[System.IO.File]::WriteAllText($emptyPst, '')
$script:StatPath = $emptyPst
Assert-True ((Get-ThrownMessage { Complete-MailboxPstExport -Alias 'ayse' -Action Remove -Confirm:$false }) -match 'doğrulanamadı' -and $script:Calls -notcontains 'Disable-Mailbox') 'Boş PST dosyasında posta kutusu silinmez'
$script:StatPath = $pstPath
[void](Complete-MailboxPstExport -Alias 'ayse' -Action Remove -Confirm:$false -WhatIf)
Assert-True ($script:Calls -notcontains 'Disable-Mailbox') 'Simülasyon posta kutusunu silmez'
$removed = Complete-MailboxPstExport -Alias 'ayse' -Action Remove -Confirm:$false
Assert-True ($script:Calls -contains 'Disable-Mailbox' -and @($removed)[-1].MailboxRemoved) 'Tamamlanan ve doğrulanan PST sonrası posta kutusu silinir'
$script:Calls.Clear()
$script:Requests = @(New-Request -Status 'CompletedWithWarning')
[void](Complete-MailboxPstExport -Alias 'ayse' -Action Remove -AllowWarning $true -Confirm:$false)
Assert-True ($script:Calls -contains 'Disable-Mailbox') 'Uyarılı dışa aktarma yalnızca açık onayla silinir'
$script:Calls.Clear()
$script:Requests = @(New-Request -Status 'InProgress')
[void](Complete-MailboxPstExport -Alias 'ayse' -Action Clear -Confirm:$false)
Assert-True ($script:Calls -contains 'Remove-MailboxExportRequest' -and $script:Calls -notcontains 'Disable-Mailbox') 'İstek kaldırma posta kutusuna dokunmaz'

# ---- Offboarding adım sırası
$script:Calls.Clear()
$script:FailFlag = $false
function global:Set-UserAccountFlag { [CmdletBinding()] param($Identity, $Flags, $Confirm) [void]$script:Calls.Add('AccountFlags'); if ($script:FailFlag) { throw 'taşınamadı' } }
function global:Clear-UserGroupMembership { [CmdletBinding()] param($Identity, $Confirm) [void]$script:Calls.Add('GroupCleanup'); [pscustomobject]@{ Removed = [string[]]@('G1'); Failed = [string[]]@(); RemovedDn = [string[]]@('CN=G1,DC=test') } }
function global:Start-MailboxPstExport { [CmdletBinding()] param($Identity, $FilePath, $RemoveMailbox, $Confirm) [void]$script:Calls.Add("Pst:$RemoveMailbox"); [pscustomobject]@{ Alias = 'ayse'; FilePath = $FilePath; Archive = $false; RemoveMailbox = $RemoveMailbox } }
$offboard = @{
    ObjectGuid = 'g'; AccountFlags = @{ Enabled = $false }; ExchangeIdentity = 'ayse'; Confirm = $false
    DisableCleanup = @{ RemoveGroups = $true; Pst = @{ FilePath = '\\fs\pst\ayse.pst'; RemoveMailbox = $true } }
}
$results = @(Invoke-UserUpdate @offboard)
Assert-True (($script:Calls -join ',') -eq 'AccountFlags,GroupCleanup,Pst:True') "Sıra: hesap, gruplar, PST ($($script:Calls -join ','))"
Assert-True (@($results | Where-Object { -not $_.Success }).Count -eq 0 -and ($results | Where-Object { $_.Step -eq 'Grup temizliği' }).Data.RemovedDn[0] -eq 'CN=G1,DC=test') 'Çıkarılan gruplar sonuçta döner'
$script:Calls.Clear()
$script:FailFlag = $true
$failed = @(Invoke-UserUpdate @offboard)
$script:FailFlag = $false
Assert-True (($script:Calls -join ',') -eq 'AccountFlags') 'Hesap kapatılamazsa gruplara ve PST''ye dokunulmaz'
Assert-True (@($failed | Where-Object { -not $_.Success }).Count -eq 3 -and @($failed | Where-Object { $_.Message -match 'devre dışı bırakılamadığı' }).Count -eq 2) 'Atlanan adımlar başarısız raporlanır'
$script:Calls.Clear()
[void](Invoke-UserUpdate -ObjectGuid 'g' -DisableCleanup $offboard.DisableCleanup -ExchangeIdentity 'ayse' -Confirm:$false)
Assert-True ($script:Calls.Count -eq 0) 'Hesap kapatılmıyorsa temizlik seçenekleri yok sayılır'

# ---- Etkinleştirme + OU taşıma
function global:Move-UserToOu { [CmdletBinding()] param($Identity, $TargetOu, $Confirm) [void]$script:Calls.Add("Move:$TargetOu") }
$script:Calls.Clear()
$moved = @(Invoke-UserUpdate -ObjectGuid 'g' -AccountFlags @{ Enabled = $true } -MoveToOu 'OU=Yeni,DC=test' -Confirm:$false)
Assert-True (($script:Calls -join ',') -eq 'AccountFlags,Move:OU=Yeni,DC=test' -and @($moved | Where-Object { -not $_.Success }).Count -eq 0) "Sıra: hesap açılır, sonra OU taşınır ($($script:Calls -join ','))"
$script:Calls.Clear()
$script:FailFlag = $true
$moveFailed = @(Invoke-UserUpdate -ObjectGuid 'g' -AccountFlags @{ Enabled = $true } -MoveToOu 'OU=Yeni,DC=test' -Confirm:$false)
$script:FailFlag = $false
Assert-True (($script:Calls -join ',') -eq 'AccountFlags' -and @($moveFailed | Where-Object { $_.Step -eq 'OU taşıma' -and -not $_.Success }).Count -eq 1) 'Hesap açılamazsa OU taşınmaz'

# ---- Geri alma kaydı (günlük rotasyonu dışında)
Save-RemovedGroupList -SamAccountName 'ayse' -GroupDn @('CN=G1,DC=test', 'CN=G2,DC=test')
$saved = @(Get-ChildItem -LiteralPath (Join-Path -Path $temporaryFolder -ChildPath 'Logs/RemovedGroups') -ErrorAction SilentlyContinue)
if ($saved.Count -eq 0) { $saved = @(Get-ChildItem -LiteralPath $temporaryFolder -Filter 'ayse_*' -Recurse) }
$savedText = if ($saved.Count -gt 0) { [System.IO.File]::ReadAllText($saved[0].FullName) } else { '' }
Assert-True ($savedText -match 'Add-ADGroupMember' -and $savedText -match 'CN=G1,DC=test' -and $savedText -match 'CN=G2,DC=test' -and $savedText -match 'TEST\\admin') 'Geri alma dosyası komutu, grupları ve işlemi yapanı içerir'
Assert-True ($saved.Count -gt 0 -and $saved[0].Name -match '^ayse_\d{8}_\d{6}\.txt$') 'Her işlem için ayrı dosya'

# ---- PST doğrulama
$errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
$warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'
Test-DisableCleanup -Cleanup @{ Pst = @{ Folder = 'C:\pst'; FileName = 'a.pst'; FilePath = 'C:\pst\a.pst' } } -Errors $errors -Warnings $warnings
Assert-True (@($errors | Where-Object { $_ -match 'UNC' }).Count -eq 1) 'Yerel PST yolu reddedilir'
$errors.Clear()
Test-DisableCleanup -Cleanup @{ Pst = @{ Folder = '\\fs\pst'; FileName = 'a:b.pst'; FilePath = '\\fs\pst\a:b.pst' } } -Errors $errors -Warnings $warnings
Assert-True (@($errors | Where-Object { $_ -match 'geçersiz' }).Count -eq 1) 'Geçersiz dosya adı reddedilir'
$errors.Clear()
$global:Sync.PstExportReady = $false
$script:Sync = $global:Sync
Test-DisableCleanup -Cleanup @{ Pst = @{ Folder = '\\fs\pst'; FileName = 'a.pst'; FilePath = '\\fs\pst\a.pst' } } -Errors $errors -Warnings $warnings
Assert-True (@($errors | Where-Object { $_ -match 'Mailbox Import Export' }).Count -eq 1) 'Rol yoksa PST başlatılamaz'
$errors.Clear()
$global:Sync.PstExportReady = $true
Test-DisableCleanup -Cleanup @{ Pst = @{ Folder = '\\fs\pst'; FileName = 'a.pst'; FilePath = '\\fs\pst\a.pst' } } -Errors $errors -Warnings $warnings
Assert-True ($errors.Count -eq 0 -and @($warnings | Where-Object { $_ -match 'Exchange Trusted Subsystem' }).Count -eq 1) 'Geçerli yol kabul edilir, izin uyarısı verilir'

# ---- Kalıcı silme güvenliği
$script:DisabledUser = [pscustomobject]@{ Enabled = $false; SamAccountName = 'ayse'; DistinguishedName = 'CN=Ayse,OU=DisabledUsers,DC=test,DC=local' }
function global:Get-ADUser { param($Identity, $Server, $ErrorAction) $script:DisabledUser }
function global:Remove-ADObject { param($Identity, [switch]$Recursive, $Server, $Confirm, $ErrorAction) [void]$script:Calls.Add('Remove-ADObject') }
$script:Calls.Clear()
$script:DisabledUser.Enabled = $true
$enabledResult = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True (-not $enabledResult[0].Success -and $enabledResult[0].Message -match 'etkin' -and $script:Calls.Count -eq 0) 'Etkin hesap silinmez'
$script:DisabledUser.Enabled = $false
$script:DisabledUser.DistinguishedName = 'CN=Ayse,OU=IT,DC=test,DC=local'
$outsideResult = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True (-not $outsideResult[0].Success -and $script:Calls.Count -eq 0) 'DisabledUsers dışındaki hesap silinmez'
$script:DisabledUser.DistinguishedName = 'CN=Ayse,OU=DisabledUsers,DC=test,DC=local'
$simulatedRemove = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false -WhatIf)
Assert-True ($simulatedRemove[0].Success -and $script:Calls.Count -eq 0) 'Simülasyon hesabı silmez'
$realRemove = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True ($realRemove[0].Success -and $script:Calls -contains 'Remove-ADObject') 'Koşullar sağlanınca hesap silinir'

Remove-Item -LiteralPath $temporaryFolder -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
