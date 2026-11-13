# Kullanıcı–Cihaz Eşleştirme ve Silmede Cihaz Temizliği — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kullanıcının bilgisayarlarını (ad kuralı + `managedBy`) profilde göstermek, kullanıcı silinirken cihazlarını da silmek ve silinmiş cihazların LAPS/BitLocker sırlarını Geri Dönüşüm Kutusu'ndan okumak.

**Architecture:** Bütün AD mantığı yeni `Modules/AD/Devices.ps1` dosyasında, worker runspace'te çalışıyor. `Remove-DisabledUser` bu dosyadaki fonksiyonları çağırıyor. UI tarafı mevcut `Invoke-BackgroundTask` desenini kullanıyor. Denetim kayıtları mevcut `Write-AuditTaskResult` üzerinden yazılıyor. Ad kuralı yeni bir `Configs/app-config.json` dosyasında tutuluyor, `$Sync.DeviceNamePattern` ile worker'a ulaşıyor.

**Tech Stack:** PowerShell 5.1, ActiveDirectory modülü, WPF/XAML. Testler `pwsh` ile sahte AD cmdlet'leri kullanıyor.

**Spec:** `docs/superpowers/specs/2026-11-13-user-devices-design.md`

## Global Constraints

- Ad kuralı varsayılanı `NB-{sam}`. Eşleşen adlar: `<şablon>` ve `<şablon>-*`. Büyük/küçük harf fark etmez. Boş şablon = otomatik eşleştirme kapalı. `{sam}` yoksa veya `*` varsa şablon geçersiz.
- Silme ve silinmiş nesne okuma `Get-PdcEmulator` sunucusunda yapılır. Cihaz silme `Remove-ADObject -Recursive` ile yapılır.
- Bir cihaz silinemezse kullanıcı silinmez. Geri Dönüşüm Kutusu kapalıysa o kullanıcı için hiçbir şey silinmez. `managedBy` başka kullanıcıyı gösteren cihaz silinmez.
- Saklama süresi: `msDS-deletedObjectLifetime`, yoksa `tombstoneLifetime`, o da yoksa 180 gün.
- Sırlar (`ms-Mcs-AdmPwd`, `msFVE-RecoveryPassword`) `Write-WorkerLog`, `Write-UiLog`, denetim günlüğü, görev argümanları ve hata metinlerinde hiçbir koşulda yer almaz.
- Pano 60 saniye sonra, hâlâ aynı değeri tutuyorsa temizlenir.
- WhatIf açıkken `Remove-ADObject` ve `Set-ADComputer` çağrılmaz, `[WhatIf]` günlük satırı yazılır.
- Denetim eylem adları mevcut noktalı biçimde: `device.delete`, `device.link`, `device.unlink`, `device.deleted.secrets_view`. Spec'teki `DeviceDeleted` ve `DeletedDeviceSecretsViewed` adlarının yerine kod tabanının biçimi kullanılıyor.
- UI metinleri Türkçe. Stiller `Styles.xaml` içindeki mevcut kaynaklardan.

## Review Focus

1. `sAMAccountName` içinde LDAP özel karakteri (`(`, `)`, `*`, `\`) var. Filtre kaçışlanmalı ve joker karaktere dönüşmemeli. → Task 1 testi `LDAP kaçışlama`.
2. Ad kuralı, profil yüklendikten sonra ama silmeden önce değişiyor. Sunucu tarafı silme anındaki kuralla yeniden çözmeli. → Task 3 testi `Silmede cihazlar yeniden çözülür`.
3. Cihaz "yanlışlıkla silinmeye karşı koru" ile korunuyor ve `Access is denied` dönüyor. Kullanıcı silinmemeli, mesaj cihaz adını içermeli. → Task 3 testi `Cihaz silinemezse kullanıcı silinmez`.
4. Kullanıcının hiç cihazı yok. Silme eskisi gibi çalışmalı, `Devices` boş dizi olmalı. → Task 3 testi `Cihazsız kullanıcı eskisi gibi silinir`.
5. Silinmiş cihazın BitLocker kaydı ya da LAPS parolası yok. Sır sonucu boş liste veya `$null` dönmeli, hata vermemeli. → Task 5 testi `Sırsız silinmiş cihaz hata vermez`.

---

## Ön koşul

Çalışma ağacında bu işle ilgisiz, commit edilmemiş değişiklikler var (Ana Sayfa ve tema işi: `DisabledUsers.ps1`, `MainWindow.xaml` ve diğerleri). Task 1'den önce kullanıcı bunları commit etmeli veya commit etmeyi onaylamalı. Aksi hâlde bu planın commit'leri o değişiklikleri de içine alır.

Test komutu (tüm paket):

```bash
for f in Tests/Test-*.ps1; do pwsh -NoProfile -File "$f" >/dev/null 2>&1 || echo "FAIL $f"; done
```

Beklenen sonuç: çıktı yok.

---

### Task 1: Ad kuralı ve cihaz çözümleme

**Files:**
- Create: `Modules/AD/Devices.ps1`
- Modify: `Start-ADIDM.ps1:131` (`$script:WorkerScripts` listesine `'Modules\AD\Devices.ps1'` eklenir, `DisabledUsers.ps1`'den **önce**)
- Create: `Tests/Test-Devices.ps1` (iskelet `Tests/Test-Phase6.ps1` ile aynı. Yüklenecek dosyalar: `Core/WorkerBootstrap.ps1`, `Modules/AD/Search.ps1`, `Modules/AD/Devices.ps1`, `Modules/AD/DisabledUsers.ps1`, `Core/Audit.ps1`. `$global:Sync.DeviceNamePattern = 'NB-{sam}'`)

**Interfaces:**
- Produces:
  - `Test-DeviceNamePattern -Pattern [string] -> [string]`: hata metni veya `$null`. Boş şablon geçerli.
  - `Test-DeviceNameMatch -Pattern [string] -SamAccountName [string] -Name [string] -> [bool]`
  - `ConvertTo-DeviceNameFilter -Pattern [string] -SamAccountName [string] -> [string]`: tam LDAP filtresi veya şablon boşsa `$null`.
  - `ConvertFrom-DeviceName -Pattern [string] -Name [string] -> [string]`: `sam` veya `$null`.
  - `Get-UserDevice -SamAccountName [string] -DistinguishedName [string] [-Server [string]] -> [pscustomobject[]]`. Alanlar: `Name, DistinguishedName, ObjectGuid, Enabled [bool], Ou, LastLogon [datetime|null], Source ('Ad kuralı'|'Elle'|'İkisi'), ManagedBy [string], Conflict [string|null], BitLockerCount [int], LapsPresent [bool]`.

- [ ] **Step 1: Başarısız testleri yaz** (`Tests/Test-Devices.ps1`, bölüm `# ---- Ad kuralı`)

```powershell
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
```

`Get-UserDevice` için sahte `Get-ADComputer` hazırlanır. Bu sahte cmdlet `-LDAPFilter` değerini `$script:Filters` listesine ekler ve şu kayıtları döner:
- `NB-ME9533` (managedBy boş)
- `NB-ME9533-2` (managedBy = `CN=Other,OU=X,DC=test,DC=local`)
- `NB-ME95331`
- `PC-ELLE` (managedBy = kullanıcının DN'i; yalnızca managedBy filtresinde döner)

Sahte `Get-ADObject` (BitLocker sayımı) `NB-ME9533` için 2 kayıt döner. Testler:

```powershell
$devices = @(Get-UserDevice -SamAccountName 'ME9533' -DistinguishedName 'CN=Mert,OU=U,DC=test,DC=local')
Assert-True ((@($devices.Name) -join ',') -eq 'NB-ME9533,NB-ME9533-2,PC-ELLE') 'Ad kuralı + managedBy birleşir, NB-ME95331 elenir'
Assert-True (($devices | Where-Object Name -eq 'NB-ME9533-2').Conflict -match 'Other') 'Çakışma işaretlenir'
Assert-True (($devices | Where-Object Name -eq 'PC-ELLE').Source -eq 'Elle') 'Elle kaynağı'
Assert-True (($devices | Where-Object Name -eq 'NB-ME9533').BitLockerCount -eq 2) 'BitLocker sayısı'
```

- [ ] **Step 2: Testi çalıştır, başarısız olduğunu gör**

Run: `pwsh -NoProfile -File Tests/Test-Devices.ps1`
Expected: `The term 'Test-DeviceNameMatch' is not recognized` hatası.

- [ ] **Step 3: `Modules/AD/Devices.ps1` içinde beş fonksiyonu yaz**

- Fonksiyonlar `function global:` ile tanımlanır (`DisabledUsers.ps1` deseni).
- Kaçışlama `ConvertTo-LdapFilterValue` ile yapılır (`Modules/AD/Search.ps1:1`).
- `Test-DeviceNameMatch` regex ile çalışır: `^` + `[regex]::Escape(şablon)` (içinde `{sam}` yerine kaçışlanmış sam) + `(-.+)?$`, `IgnoreCase`.
- `ConvertFrom-DeviceName`: şablondaki `{sam}` yerine `(?<sam>[^-]+)` konur, sona `(-.+)?$` eklenir.
- `Get-UserDevice` iki sorgu yapar: ad filtresi ve `(&(objectClass=computer)(managedBy=<kaçışlanmış DN>))`. Ad sorgusundan gelen her kayıt `Test-DeviceNameMatch` ile yeniden doğrulanır. Sonuçlar `ObjectGuid` üzerinden birleştirilir ve ada göre sıralanır.
  - İstenen özellikler: `managedBy, lastLogonTimestamp, Enabled, ms-Mcs-AdmPwdExpirationTime`. `LapsPresent` = `ms-Mcs-AdmPwdExpirationTime` dolu.
  - `BitLockerCount` = `Get-ADObject -SearchBase <cihaz DN> -SearchScope OneLevel -LDAPFilter '(objectClass=msFVE-RecoveryInformation)'` sayısı. `msFVE-RecoveryPassword` **istenmez**.
  - `Conflict` = `managedBy` dolu ve kullanıcı DN'inden farklıysa `"managedBy başka kullanıcıyı gösteriyor: <managedBy içindeki CN>"`.

- [ ] **Step 4: Testi çalıştır, geçtiğini gör**

Run: `pwsh -NoProfile -File Tests/Test-Devices.ps1`
Expected: tüm satırlar `PASS`, son satır `Tüm testler geçti.`

- [ ] **Step 5: Commit**

```bash
git add Modules/AD/Devices.ps1 Tests/Test-Devices.ps1 Start-ADIDM.ps1
git commit -m "Cihaz ad kuralı ve kullanıcı cihazı çözümleme ekle"
```

---

### Task 2: Geri Dönüşüm Kutusu durumu

**Files:**
- Modify: `Modules/AD/Devices.ps1`
- Test: `Tests/Test-Devices.ps1` (bölüm `# ---- Geri Dönüşüm Kutusu`)

**Interfaces:**
- Produces: `Get-RecycleBinState [-Server [string]] -> [pscustomobject] @{ Enabled [bool]; LifetimeDays [int] }`

- [ ] **Step 1: Başarısız testleri yaz**
  - Sahte `Get-ADOptionalFeature` → `EnabledScopes` dolu.
  - Sahte `Get-ADRootDSE` → `configurationNamingContext = 'CN=Configuration,DC=test,DC=local'`.
  - Sahte `Get-ADObject` (Directory Service nesnesi) → `msDS-deletedObjectLifetime` sırayla 90 / `$null` + `tombstoneLifetime` 60 / ikisi de `$null`.

```powershell
Assert-True ((Get-RecycleBinState).Enabled -and (Get-RecycleBinState).LifetimeDays -eq 90) 'Açık, 90 gün'
# tombstoneLifetime=60, deletedObjectLifetime boş
Assert-True ((Get-RecycleBinState).LifetimeDays -eq 60) 'tombstoneLifetime yedeği'
# ikisi de boş
Assert-True ((Get-RecycleBinState).LifetimeDays -eq 180) 'Varsayılan 180'
# EnabledScopes boş
Assert-True (-not (Get-RecycleBinState).Enabled) 'Kapalı algılanır'
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör.** Expected: `Get-RecycleBinState` tanınmıyor.
- [ ] **Step 3: `Get-RecycleBinState` yaz.** Kullanılacak çağrılar: `Get-ADOptionalFeature -Identity 'Recycle Bin Feature'` ve `Get-ADObject -Identity "CN=Directory Service,CN=Windows NT,CN=Services,$configNC" -Properties msDS-deletedObjectLifetime, tombstoneLifetime`.
- [ ] **Step 4: Çalıştır, geçtiğini gör.**
- [ ] **Step 5: Commit** — `git commit -m "Geri Dönüşüm Kutusu durum ve saklama süresi okuması"`

---

### Task 3: Silmede cihazlar ve denetim

**Files:**
- Modify: `Modules/AD/DisabledUsers.ps1` (`Remove-DisabledUser`)
- Modify: `Core/Audit.ps1` (`Write-AuditTaskResult`, kullanıcı başına döngü)
- Test: `Tests/Test-Devices.ps1` (bölüm `# ---- Silme`)

**Interfaces:**
- Consumes: `Get-UserDevice`, `Get-RecycleBinState`
- Produces: `Remove-DisabledUser` sonuç nesnesine `Devices [pscustomobject[]]` eklenir: `Name, DistinguishedName, ObjectGuid, Source, BitLockerCount, LapsPresent, Success [bool], Skipped [bool], Message`. Ayrıca `OwnerSam` eklenir (= `$result.Step`). Var olan alanlar değişmez.
- Produces: `Get-RemovalDevicePreview -ObjectGuid [string[]] -> [hashtable]` (ObjectGuid → `Get-UserDevice` sonucu). Onay penceresi bunu kullanır.

- [ ] **Step 1: Başarısız testleri yaz.**
  - `Tests/Test-Phase6.ps1` silme bölümündeki sahte `Get-ADUser` / `Remove-ADObject` deseni kullanılır. `Remove-ADObject` çağrılan `Identity` değerini `$script:Calls` listesine ekler.
  - `$script:FailOn` değişkeni bir DN içeriyorsa sahte `Remove-ADObject` `'Access is denied'` hatası fırlatır.
  - Sahte `Get-RecycleBinState` → `$script:Bin`.

```powershell
$r = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True ($script:Calls[0] -like 'CN=NB-ME9533,*' -and $script:Calls[-1] -like 'CN=Mert,*' -and $r[0].Success) 'Önce cihazlar sonra kullanıcı'
Assert-True (@($r[0].Devices | Where-Object Skipped).Name -contains 'NB-ME9533-2' -and $script:Calls -notmatch 'NB-ME9533-2') 'Çakışmalı cihaz atlanır'
$script:FailOn = 'CN=NB-ME9533,'
$r = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True (-not $r[0].Success -and $r[0].Message -match 'NB-ME9533' -and $script:Calls -notmatch 'CN=Mert,') 'Cihaz silinemezse kullanıcı silinmez'
$script:Bin = [pscustomobject]@{ Enabled = $false; LifetimeDays = 180 }
$r = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false)
Assert-True (-not $r[0].Success -and $r[0].Message -match 'Geri Dönüşüm' -and $script:Calls.Count -eq 0) 'Geri Dönüşüm Kutusu kapalıyken hiçbir şey silinmez'
$r = @(Remove-DisabledUser -ObjectGuid 'g' -Confirm:$false -WhatIf)
Assert-True ($r[0].Success -and $script:Calls.Count -eq 0 -and @($r[0].Devices).Count -ge 1) 'Simülasyon cihaz silmez'
# kullanıcının hiç cihazı yok
Assert-True ($r[0].Success -and @($r[0].Devices).Count -eq 0) 'Cihazsız kullanıcı eskisi gibi silinir'
# $global:Sync.DeviceNamePattern = 'XX-{sam}' iken
Assert-True ($script:Calls -notmatch 'NB-ME9533') 'Silmede cihazlar yeniden çözülür'
```

  - Denetim testi: `Initialize-Audit` geçici bir klasörle başlatılır. `Write-AuditTaskResult -Context (Get-AuditTaskContext -Command 'Remove-DisabledUser' -Arguments @{ObjectGuid=@('g')}) -Result $r` çağrılır, ardından günlük dosyası okunur:

```powershell
Assert-True ((@($log -match 'device\.delete')).Count -eq 1 -and $log -match 'device_guid' -and $log -match 'owner_sam=ME9533') 'Cihaz başına denetim kaydı'
Assert-True ($log -notmatch 'msFVE|AdmPwd') 'Denetimde sır alanı yok'
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör.** Expected: `Önce cihazlar sonra kullanıcı` FAIL.
- [ ] **Step 3: `Remove-DisabledUser` ve `Write-AuditTaskResult` değiştir.**
  - Sıra (spec §Sunucu tarafı): mevcut kontroller → `Get-RecycleBinState` (fonksiyon başında bir kez) → `Get-UserDevice -Server $server` → çakışmalılar `Skipped=$true` → kalanlar `Remove-ADObject -Recursive` (WhatIf dalı mevcut desenle) → herhangi bir hata varsa `throw "Cihaz silinemedi: <ad> (<mesaj>); kullanıcı silinmedi."` → kullanıcı silinir.
  - `Write-AuditTaskResult`'ta kullanıcı olayı yazıldıktan sonra, `$item.Devices` içindeki `Skipped` olmayan her cihaz için `Write-AuditEvent -Action 'device.delete'` yazılır. Alanlar: `device_name, device_dn, device_guid, owner_sam, match_source, bitlocker_count, laps_present, message`.
  - `Get-RemovalDevicePreview`: her GUID için `Get-ADUser` ve `Get-UserDevice` çağrılır. Hata olursa o GUID'e `@()` konur ve `Write-WorkerLog` ile uyarı yazılır.
- [ ] **Step 4: Çalıştır: önce `Tests/Test-Devices.ps1`, sonra tüm paket.** Expected: hepsi PASS; `Test-Phase6` de geçer (sahte `Get-UserDevice` yoksa `Devices` boş olmalı, bu yüzden Test-Phase6'ya `function global:Get-UserDevice { @() }` ve `function global:Get-RecycleBinState { [pscustomobject]@{Enabled=$true;LifetimeDays=180} }` eklenir).
- [ ] **Step 5: Commit** — `git commit -m "Kullanıcı silinirken eşleşen cihazları sil, cihaz denetim kaydı yaz"`

---

### Task 4: Elle bağlama ve bilgisayar arama

**Files:**
- Modify: `Modules/AD/Devices.ps1`, `Core/Audit.ps1` (`Get-AuditTaskContext` eşlemesi)
- Test: `Tests/Test-Devices.ps1` (bölüm `# ---- Elle bağlama`)

**Interfaces:**
- Produces:
  - `Set-DeviceOwner -ComputerDn [string] -OwnerDn [string] -> [pscustomobject] @{ Step; Success; Message }`. `[CmdletBinding(SupportsShouldProcess)]`. `OwnerDn` boşsa bağ kaldırılır.
  - `Find-DirectoryComputer -Query [string] -> [pscustomobject[]] @{ Name; DistinguishedName; ManagedBy; ManagedByName }`. En fazla 50 sonuç; ad öneki ile arar (`name=<kaçışlanmış>*`).
- Audit: `'Set-DeviceOwner'` → argümanlarda `OwnerDn` doluysa `'device.link'`, değilse `'device.unlink'`. Hedef alanları `$script:State.CurrentData` üzerinden gelir (mevcut dal).

- [ ] **Step 1: Başarısız testleri yaz**

```powershell
[void](Set-DeviceOwner -ComputerDn 'CN=PC1,OU=C,DC=test,DC=local' -OwnerDn 'CN=Mert,OU=U,DC=test,DC=local' -Confirm:$false)
Assert-True ($script:Calls[-1] -eq 'Replace managedBy=CN=Mert,OU=U,DC=test,DC=local') 'Bağlama managedBy yazar'
[void](Set-DeviceOwner -ComputerDn 'CN=PC1,OU=C,DC=test,DC=local' -OwnerDn '' -Confirm:$false)
Assert-True ($script:Calls[-1] -eq 'Clear managedBy') 'Bağ kaldırma temizler'
$script:Calls.Clear(); [void](Set-DeviceOwner -ComputerDn 'CN=PC1,OU=C,DC=test,DC=local' -OwnerDn 'x' -Confirm:$false -WhatIf)
Assert-True ($script:Calls.Count -eq 0) 'Simülasyon yazmaz'
Assert-True ((Find-DirectoryComputer -Query 'a*(').Count -ge 0 -and $script:Filters[-1] -eq '(&(objectClass=computer)(name=a\2a\28*))') 'Arama kaçışlanır'
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör.**
- [ ] **Step 3: İki fonksiyonu ve audit eşlemesini yaz.** `Set-ADComputer -Identity <dn> -Replace @{managedBy=<owner>}` veya `-Clear managedBy`, ikisi de `-Server (Get-PdcEmulator)`.
- [ ] **Step 4: Çalıştır, geçtiğini gör.**
- [ ] **Step 5: Commit** — `git commit -m "Cihazı managedBy ile elle bağlama ve bilgisayar arama"`

---

### Task 5: Silinmiş cihazlar ve sırlar

**Files:**
- Modify: `Modules/AD/Devices.ps1`, `Core/Audit.ps1` (`Get-AuditTaskContext`: `'Get-DeletedDeviceSecret'` → `'device.deleted.secrets_view'`; `Target.target_device = $Arguments.DeviceName`, `CurrentData` dalına girmez)
- Test: `Tests/Test-Devices.ps1` (bölüm `# ---- Silinmiş cihazlar`)

**Interfaces:**
- Consumes: `Get-RecycleBinState`, `ConvertFrom-DeviceName`
- Produces:
  - `Get-DeletedDeviceList -> [pscustomobject[]]`: `Name, ObjectGuid, DistinguishedName, LastKnownParent, DeletedAt [datetime], DaysLeft [int], Owner [string], LapsPresent [bool], BitLockerCount [int]`. `DeletedAt`'e göre azalan sırada.
  - `Get-DeletedDeviceSecret -ObjectGuid [string] -DeviceName [string] -> [pscustomobject] @{ DeviceName; LapsPassword [string|null]; LapsExpiresAt [datetime|null]; BitLocker [pscustomobject[]] @{ Name; RecoveryPassword } }`. Sonuç nesnesinde `Step` alanı **olmamalı**; böylece `Write-AuditTaskResult` yalnızca argümanları yazar.

- [ ] **Step 1: Başarısız testleri yaz.**
  - Sahte `Get-ADObject -IncludeDeletedObjects` iki tür sorguya cevap verir:
    - bilgisayar filtresi: `NB-GG0043` (managedBy boş, `whenChanged` = bugün − 10 gün, `ms-Mcs-AdmPwd='S3cret!'`) ve `PriviaPC` (LAPS yok)
    - `msFVE-RecoveryInformation` filtresi: biri `lastKnownParent` = `NB-GG0043` DN'i, biri başka bir DN
  - `Get-RecycleBinState` → 180 gün.

```powershell
$list = @(Get-DeletedDeviceList)
$gg = $list | Where-Object Name -eq 'NB-GG0043'
Assert-True ($gg.DaysLeft -eq 170 -and $gg.Owner -eq 'GG0043' -and $gg.BitLockerCount -eq 1 -and $gg.LapsPresent) 'Liste alanları'
Assert-True (-not ($list | Get-Member -Name LapsPassword)) 'Listede parola yok'
$s = Get-DeletedDeviceSecret -ObjectGuid $gg.ObjectGuid -DeviceName 'NB-GG0043'
Assert-True ($s.LapsPassword -eq 'S3cret!' -and @($s.BitLocker).Count -eq 1) 'lastKnownParent ile BitLocker bulunur'
$p = Get-DeletedDeviceSecret -ObjectGuid ($list | Where-Object Name -eq 'PriviaPC').ObjectGuid -DeviceName 'PriviaPC'
Assert-True ($null -eq $p.LapsPassword -and @($p.BitLocker).Count -eq 0) 'Sırsız silinmiş cihaz hata vermez'
Assert-True (-not $s.PSObject.Properties['Step']) 'Sır sonucu denetime düşmez'
# Get-AuditTaskContext + Write-AuditTaskResult sonrası günlük
Assert-True ($log -match 'device\.deleted\.secrets_view' -and $log -match 'NB-GG0043' -and $log -notmatch 'S3cret') 'Görüntüleme denetlenir, değer yazılmaz'
# sahte Get-ADObject 'Access is denied' fırlatırsa
Assert-True ((Get-ThrownMessage { Get-DeletedDeviceList }) -match 'Silinmiş nesneleri okuma yetkiniz yok') 'Yetki mesajı'
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör.**
- [ ] **Step 3: İki fonksiyonu ve audit eşlemesini yaz.**
  - Sorgular PDC üzerinde çalışır.
  - Liste: bilgisayarlar `(&(objectClass=computer)(isDeleted=TRUE))` ile okunur. Özellikler: `msDS-LastKnownRDN, lastKnownParent, whenChanged, managedBy, ms-Mcs-AdmPwdExpirationTime`. Parola **istenmez**.
  - BitLocker sayısı için tek bir `msFVE-RecoveryInformation` sorgusu (`lastKnownParent` ile) yapılır ve DN'e göre gruplanır.
  - `Owner`: `managedBy` doluysa CN'i, değilse `ConvertFrom-DeviceName`, o da yoksa `-`.
  - `Access is denied` / `Erişim engellendi` hataları spec'teki Türkçe yetki mesajına çevrilir.
- [ ] **Step 4: Çalıştır, geçtiğini gör.**
- [ ] **Step 5: Commit** — `git commit -m "Silinmiş cihaz listesi ve Geri Dönüşüm Kutusu'ndan sır okuma"`

---

### Task 6: Ayarlar — cihaz ad kuralı

**Files:**
- Create: `Configs/app-config.template.json` → `{ "DeviceNamePattern": "NB-{sam}" }`
- Modify:
  - `Start-ADIDM.ps1`: `$script:AppConfigPath = Join-Path $script:AppRoot 'Configs\app-config.json'`. Açılışta dosya okunur; yoksa şablon kopyalanır. `$script:Sync.DeviceNamePattern` atanır. Değer geçersizse `''` atanır ve uyarı loglanır.
  - `UI/Handlers/Settings.ps1`: `File='App'` belge türü eklenir; `Get-SettingsFormDocument`, `Save-SettingsForm` ve yükleme (satır 90, 122, 133-146, 248) güncellenir. Alan: `@('Devices','App','DeviceNamePattern','Text','Cihaz ad kuralı','{sam} = kullanıcı adı. Ör. NB-{sam} hem NB-ME9533 hem NB-ME9533-2 ile eşleşir. Boş: otomatik eşleştirme kapalı.',$null)`. Doğrulama `Test-DeviceNamePattern` ile. Kayıttan sonra `$script:Sync.DeviceNamePattern` güncellenir.
  - `UI/MainWindow.xaml`: `grpSetDevices` ("Cihazlar") grup düğmesi; `tabSetDevices` sekmesi, içinde `pnlSetDevices`, onun altında önizleme `TextBlock x:Name="txtSetDevicePreview"`. Panel eşlemesine (`Settings.ps1:258,262`) `Devices` eklenir.
  - Önizleme: şablon değiştikçe `"ME9533 için: NB-ME9533, NB-ME9533-2"` gösterilir. Şablon geçersizse `Test-DeviceNamePattern` mesajı gösterilir.
- Test: `Tests/Test-Devices.ps1` (bölüm `# ---- Ayar`) ve var olan `Tests/Test-Theme.ps1` / `Tests/Test-Build.ps1` (XAML ayrıştırma)

**Interfaces:**
- Consumes: `Test-DeviceNamePattern`
- Produces: `$Sync.DeviceNamePattern [string]` (Task 1 bunu okur); `Get-DeviceNamePreview -Pattern [string] -SamAccountName [string] -> [string]` (`UI/Handlers/Settings.ps1`)

- [ ] **Step 1: Başarısız testleri yaz**

```powershell
Assert-True ((Get-DeviceNamePreview -Pattern 'NB-{sam}' -SamAccountName 'ME9533') -eq 'ME9533 için: NB-ME9533, NB-ME9533-2') 'Önizleme'
Assert-True ((Get-DeviceNamePreview -Pattern '' -SamAccountName 'ME9533') -eq 'Otomatik eşleştirme kapalı.') 'Boş önizleme'
Assert-True ((Get-DeviceNamePreview -Pattern 'NB-' -SamAccountName 'ME9533') -match '\{sam\}') 'Geçersiz önizleme'
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör.**
- [ ] **Step 3: Yukarıdaki dosya değişikliklerini yap.** `Test-Theme.ps1` sekme veya grup sayısı kontrol ediyorsa yeni grup için güncellenir (2026-11-06'daki sayfa sayısı düzeltmesi gibi).
- [ ] **Step 4: Tüm paketi çalıştır.** Expected: çıktı yok.
- [ ] **Step 5: Commit** — `git commit -m "Ayarlar'a cihaz ad kuralı ve önizleme ekle"`

---

### Task 7: Profil — Cihazlar bölümü

**Files:**
- Modify:
  - `Modules/AD/Users.ps1` (`Get-UserProfileData`): grup üyeliklerinden sonra `Set-WorkerProgress -Percent 68 -Status 'Cihazlar okunuyor...'` ve `try { $devices = @(Get-UserDevice ...) } catch { $deviceError = ... }`. Dönüş nesnesine `Devices = $devices; DevicesError = $deviceError` eklenir.
  - `UI/MainWindow.xaml`: Hesap sekmesinin sonuna (`</StackPanel>` öncesi, ~satır 486) yeni bir `Section` eklenir: başlık "Cihazlar", `ListView x:Name="lstDevices"` (sütunlar: Ad, Kaynak, OU, Etkin, Son oturum, BitLocker, LAPS, Uyarı), `TextBlock x:Name="txtDevicesStatus"`, `Button x:Name="btnDeviceLink"` ("Cihaz Bağla…"), `Button x:Name="btnDeviceUnlink"` ("Bağı Kaldır").
  - `UI/Handlers/UserProfile.ps1`: profil doldurulurken `lstDevices.ItemsSource` ve durum metni ayarlanır. Liste boşsa `"Eşleşen cihaz yok."`, hata varsa `"Cihazlar okunamadı: <mesaj>"`.
  - Yeni `UI/Handlers/Devices.ps1`: `Show-ComputerPicker` (`Show-OuPicker` deseni; `Find-DirectoryComputer` arka planda çalışır), `Start-DeviceLink`, `Start-DeviceUnlink`. Seçilen cihazın `ManagedBy` alanı başka birini gösteriyorsa `Show-ConfirmDialog` ile onay alınır. İşlem bitince `Start-UserLoad -ObjectGuid <current> -Force` çağrılır. `btnDeviceUnlink` yalnızca seçili cihazın `Source` değeri `Elle` veya `İkisi` olduğunda etkindir.
  - `UI/Shell.ps1`: düğme olayları ve `UI/Handlers/Devices.ps1` yüklemesi.
- Test: `Tests/Test-Devices.ps1` (bölüm `# ---- Profil verisi`), `Tests/Test-Build.ps1`

**Interfaces:**
- Consumes: `Get-UserDevice`, `Set-DeviceOwner`, `Find-DirectoryComputer`
- Produces: profil verisinde `Devices` ve `DevicesError`

- [ ] **Step 1: Başarısız testi yaz.** `Get-UserProfileData` testi çok bağımlılık gerektiriyor. Bu yüzden `Get-UserDevice` sahte fonksiyonu hata fırlatırken profilin yine döndüğünü doğrulayan küçük bir test yazılır; desen `Tests/Test-Phase3.ps1`'deki profil testinden alınır:

```powershell
Assert-True ($profile.DevicesError -match 'boom' -and $profile.Ad.SamAccountName) 'Cihaz hatası profili bozmaz'
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör.**
- [ ] **Step 3: Dosya değişikliklerini yap.**
- [ ] **Step 4: Tüm paketi çalıştır** (XAML ayrıştırma dahil). Expected: çıktı yok.
- [ ] **Step 5: Windows'ta elle doğrula:**
  - Profil açılınca Hesap sekmesinde `NB-<sam>` cihazları görünüyor.
  - "Cihaz Bağla…" ile bir bilgisayar bağlanınca listede "Elle" kaynağıyla çıkıyor.
  - "Bağı Kaldır" sonrası cihaz listeden düşüyor.
- [ ] **Step 6: Commit** — `git commit -m "Profilde Cihazlar bölümü, elle bağlama ve bağ kaldırma"`

---

### Task 8: Devre Dışı sayfası — onay penceresi, Silinmiş Cihazlar, sır penceresi

**Files:**
- Modify:
  - `UI/Handlers/Offboarding.ps1`:
    - `Remove-SelectedDisabledUser` önce `Get-RemovalDevicePreview` arka plan görevini çalıştırır, onay penceresi `OnSuccess` içinde açılır.
    - Satır biçimi ve not metni spec §Onay öncesi'ndeki gibidir; N = `Get-RecycleBinState` ile okunan değer (aynı görevde döndürülür).
    - `Complete-DisabledUserRemoval` özete `", <n> cihaz silindi"` ekler ve cihaz hatalarını yazar.
  - `UI/MainWindow.xaml`: Devre Dışı sayfasına iki grup düğmesi eklenir ("Kullanıcılar" / "Silinmiş Cihazlar"; mevcut `GroupTab` stili). Yeni görünüm:
    - `ListView x:Name="lstDd"` (sütunlar: Ad, Eski sahip, Eski OU, Silinme, Kalan gün, BitLocker, LAPS)
    - `TextBox x:Name="txtDdFilter"`, `TextBlock x:Name="txtDdSummary"`
    - `Button x:Name="btnDdShowSecrets"` ("Parolaları Göster"), `Button x:Name="btnDdRefresh"`
  - Yeni `UI/Dialogs/DeviceSecretDialog.xaml` ve `UI/Handlers/Devices.ps1` içinde `Show-DeviceSecretDialog -Secret [pscustomobject]`:
    - LAPS parolası, son geçerlilik tarihi, BitLocker kayıtları (Ad + kurtarma parolası). Her değerin yanında "Kopyala" düğmesi.
    - Değerler `TextBox IsReadOnly` içinde, `FontFamily` monospace.
    - Kapanışta `TextBox.Text = ''` yapılır ve `$Secret` referansı bırakılır.
  - `UI/Handlers/Devices.ps1`: `Start-DeletedDeviceLoad`, `Update-DeletedDeviceView` (filtre: ad veya eski sahip), `Show-SelectedDeletedDeviceSecret` (`Get-DeletedDeviceSecret` görevi; argümanlar `ObjectGuid` + `DeviceName`), `Copy-SecretToClipboard -Value [string]`.
  - `Copy-SecretToClipboard`: `[System.Windows.Clipboard]::SetText`, ardından 60 saniyelik `DispatcherTimer`. Süre dolunca panoda hâlâ aynı değer varsa `Clipboard.Clear()` çağrılır.
- Test: `Tests/Test-Devices.ps1` (bölüm `# ---- Onay metni`), `Tests/Test-Build.ps1`

**Interfaces:**
- Consumes: `Get-RemovalDevicePreview`, `Get-RecycleBinState`, `Get-DeletedDeviceList`, `Get-DeletedDeviceSecret`, `Remove-DisabledUser` sonucundaki `Devices`
- Produces: `Format-RemovalDeviceLine -Devices [pscustomobject[]] -> [string[]]` (`UI/Handlers/Offboarding.ps1`, test edilebilir saf fonksiyon)

- [ ] **Step 1: Başarısız testi yaz**

```powershell
$lines = Format-RemovalDeviceLine -Devices @(
  [pscustomobject]@{ Name='NB-ME9533'; BitLockerCount=2; LapsPresent=$true; Conflict=$null },
  [pscustomobject]@{ Name='NB-ME9533-2'; BitLockerCount=0; LapsPresent=$true; Conflict=$null },
  [pscustomobject]@{ Name='NB-XX0001'; BitLockerCount=0; LapsPresent=$false; Conflict='managedBy başka kullanıcıyı gösteriyor: Ali' })
Assert-True ($lines[0] -eq '|     Cihazlar: NB-ME9533 (BitLocker: 2 anahtar, LAPS: var), NB-ME9533-2 (BitLocker: yok, LAPS: var)') 'Cihaz satırı'
Assert-True ($lines[1] -eq '|     Atlanacak: NB-XX0001 (managedBy başka kullanıcıyı gösteriyor: Ali)') 'Atlanan satırı'
Assert-True (@(Format-RemovalDeviceLine -Devices @()).Count -eq 0) 'Cihazsız kullanıcıda satır yok'
```

- [ ] **Step 2: Çalıştır, başarısız olduğunu gör.**
- [ ] **Step 3: Dosya değişikliklerini yap.**
- [ ] **Step 4: Tüm paketi çalıştır.** Expected: çıktı yok.
- [ ] **Step 5: Windows'ta, WhatIf açıkken elle doğrula:**
  1. Cihazı olan bir test kullanıcısında onay penceresi cihazları ve saklama notunu gösteriyor.
  2. Simülasyon özeti cihaz sayısını içeriyor; AD'de hiçbir şey değişmiyor.
  3. "Silinmiş Cihazlar" listesinde `NB-GG0043` görünüyor; "Parolaları Göster" LAPS ve 2 BitLocker kaydını gösteriyor.
  4. Kopyalanan değer 60 saniye sonra panodan siliniyor.
  5. Denetim günlüğünde `device.deleted.secrets_view` kaydı var ve parola değerini içermiyor.
- [ ] **Step 6: Commit** — `git commit -m "Devre Dışı sayfasında cihazlı onay, Silinmiş Cihazlar ve sır penceresi"`
