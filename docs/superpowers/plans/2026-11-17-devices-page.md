# Cihazlar Sayfası Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sol menüde OU bazlı bilgisayar listesi, toplu `managedBy` atama/bağ kaldırma, BitLocker/LAPS durum takibi ve canlı bilgisayar parolası görüntüleme sunan "Cihazlar" sayfası.

**Architecture:** Backend `Modules/AD/Devices.ps1` içinde üç yeni worker fonksiyonu (`Get-OuDeviceList`, `Get-DeviceSecret`, `Set-DeviceOwnerBulk`). Liste OU başına iki sorguyla yüklenir (bilgisayarlar + `msFVE-RecoveryInformation`), anahtar sayısı bellekte üst DN'e göre gruplanır. UI yeni `UI/Handlers/DevicesPage.ps1` + `MainWindow.xaml` içinde `pageDevices`; mevcut `Show-OuPicker`, `Show-ConfirmDialog`, `Show-DeviceSecretDialog`, `Copy-SecretToClipboard`, `Invoke-BackgroundTask`, `Get-ActionArgument` yeniden kullanılır.

**Tech Stack:** PowerShell 5.1, WPF/XAML, ActiveDirectory modülü. Testler: Pester'sız `Assert-True` scriptleri, `pwsh -NoProfile -File Tests/<ad>.ps1`.

**Spec:** `docs/superpowers/specs/2026-11-17-devices-page-design.md`

## Global Constraints

- Liste yüklenirken `ms-Mcs-AdmPwd` ve `msFVE-RecoveryPassword` **istenmez**; parolalar diske, `Write-WorkerLog`/`Write-UiLog`'a, denetime yazılmaz.
- Tüm AD çağrıları `Invoke-BackgroundTask` ile worker'da; sunucu `Get-PdcEmulator`.
- Liste üst sınırı 5000 bilgisayar; aşılırsa ilk 5000 + `Write-WorkerLog -Level Warning` "OU seçimini daraltın".
- `NeedsAttention = Enabled -and (OperatingSystem -notmatch 'Server') -and (BitLockerCount -eq 0 -or LapsState -ne 'Geçerli')`.
- `LapsState` değerleri tam olarak: `'Yok'`, `'Süresi geçmiş'`, `'Geçerli'`.
- XAML'de sabit renk yok; yalnızca tema fırçaları (`WarningBrush` vb.). Kontrol adları `Dv` önekli.
- Yeni bağımlılık yok. Kullanıcı arayüz metinleri Türkçe.
- Yetki kontrolü yok (yalnızca yetkili kullanıcılar); `Get-OuDeviceList` içinde `# shortcut: yetkisiz operatörde BitLocker sayısı 0 görünür, yetkisiz kullanım olursa yetki denetimi ekle` yorumu.

## Review Focus

1. Bir bilgisayar hem seçili üst OU'da hem alt OU'da (Subtree + iç içe seçim) → listede bir kez görünür. *(Task 1 testi)*
2. Atamada bir bilgisayar hata verir (ör. yetki) → diğerleri yine atanır, hatalı olan adıyla raporlanır. *(Task 2 testi)*
3. Cihazlar sayfasından parola görüntülenirken profilde başka kullanıcı açık → denetim kaydı o kullanıcıyı hedef yazmaz. *(Task 3 testi)*
4. Bilgisayar adı veya OU adında LDAP özel karakteri (`(`, `*`, `\`) → BitLocker gruplama `Get-ParentDn` ile DN üzerinden yapıldığı için doğru sayılır. *(Task 1 testi: `CN=PC\, (A)` içeren DN)*
5. LAPS `ms-Mcs-AdmPwdExpirationTime` = 0 veya 1 (bazı ortamlarda "hemen yenile" değeri) → `'Yok'` sayılır, tarih hesaplanmaz. *(Task 1 testi)*

---

### Task 1: `Get-OuDeviceList` (liste + durum)

**Files:**
- Modify: `Modules/AD/Devices.ps1` (dosya sonuna)
- Test: `Tests/Test-Devices.ps1` (sona yeni bölüm `# ---- OU cihaz listesi`)

**Interfaces:**
- Consumes: `Get-PdcEmulator`, `Get-ParentDn`, `Get-DnCommonName`, `Set-WorkerProgress`, `Write-WorkerLog` (mevcut).
- Produces: `Get-OuDeviceList -OuDn <string[]> [-Subtree <bool>]` → `pscustomobject[]`, alanlar: `Name, DistinguishedName, ObjectGuid, Enabled, StatusText, Ou, OperatingSystem, LastLogon, LastLogonText, ManagedBy, OwnerName, BitLockerCount, BitLockerText, LapsExpiresAt, LapsText, LapsState, NeedsAttention`.

- [ ] **Step 1: Failing testleri yaz.** `Get-ADComputer` ve `Get-ADObject`'i `function global:` sahteleriyle değiştir (dosyadaki mevcut sahte deseni izle; çağrı parametrelerini `$script:Calls`'a kaydet). Fikstür: OU-A (`OU=A,DC=test,DC=local`) altında `PC1` (etkin, Windows 11, 2 anahtar, LAPS gelecek tarih), `PC2` (etkin, Windows 10, 0 anahtar, LAPS yok), `SRV1` (etkin, "Windows Server 2022", 0 anahtar), `PC3` (devre dışı, 0 anahtar), `PC\, (X)` (etkin, 1 anahtar, LAPS geçmiş tarih), `PC4` (etkin, LAPS değeri `1`); OU-A/Sub altında `PC5`; anahtar sahtesi ayrıca listede olmayan `CN=OTHER,OU=B,...` altında 1 anahtar döner.

```powershell
$list = @(Get-OuDeviceList -OuDn 'OU=A,DC=test,DC=local', 'OU=Sub,OU=A,DC=test,DC=local' -Subtree $true)
$byName = @{}; foreach ($d in $list) { $byName[$d.Name] = $d }
Assert-True ($list.Count -eq @($list.ObjectGuid | Select-Object -Unique).Count) 'İç içe OU seçiminde bilgisayar tekil'
Assert-True ($byName['PC1'].BitLockerCount -eq 2 -and $byName['PC1'].LapsState -eq 'Geçerli' -and -not $byName['PC1'].NeedsAttention) 'PC1 sorunsuz'
Assert-True ($byName['PC2'].BitLockerCount -eq 0 -and $byName['PC2'].LapsState -eq 'Yok' -and $byName['PC2'].NeedsAttention) 'PC2 uyarı'
Assert-True (-not $byName['SRV1'].NeedsAttention) 'Sunucu uyarı sayılmaz'
Assert-True (-not $byName['PC3'].NeedsAttention) 'Devre dışı uyarı sayılmaz'
Assert-True ($byName['PC, (X)'].BitLockerCount -eq 1 -and $byName['PC, (X)'].LapsState -eq 'Süresi geçmiş') 'Özel karakterli DN doğru gruplanır'
Assert-True ($byName['PC4'].LapsState -eq 'Yok' -and $null -eq $byName['PC4'].LapsExpiresAt) 'LAPS değeri 1 = Yok'
Assert-True (-not ($list | Get-Member -Name '*Pwd*', '*Password*')) 'Liste nesnesinde parola alanı yok'
Assert-True (-not (@($script:Calls | Where-Object { $_.Command -eq 'Get-ADComputer' }).Properties -match 'AdmPwd$|RecoveryPassword')) 'Parola özelliği istenmez'
```

Ayrıca: 5001 bilgisayar dönen sahteyle `$list.Count -eq 5000` ve `Write-WorkerLog` sahtesine Warning düştüğünü doğrulayan `'5000 üst sınırı'` testi.

- [ ] **Step 2: Çalıştır, FAIL gör.** `pwsh -NoProfile -File Tests/Test-Devices.ps1` → yeni satırlar `FAIL` veya "Get-OuDeviceList is not recognized".

- [ ] **Step 3: `function global:Get-OuDeviceList` yaz.** Parametreler: `[Parameter(Mandatory)][string[]]$OuDn`, `[bool]$Subtree = $true`. Her OU için `Get-ADComputer -Filter * -SearchBase $ou -SearchScope ($Subtree ? Subtree : OneLevel) -Properties managedBy, lastLogonTimestamp, Enabled, 'ms-Mcs-AdmPwdExpirationTime', OperatingSystem -ResultSetSize 5001` ve `Get-ADObject -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -SearchBase $ou -SearchScope Subtree`; anahtarları `Get-ParentDn` ile hashtable'da say (aynı anahtarı iki OU'dan iki kez saymamak için anahtar DN'ini de tekilleştir). Bilgisayarları `ObjectGUID` ile tekilleştir. `LapsExpiresAt`: değer `> 1` ise `FromFileTime`. Metinler: `StatusText` 'Etkin'/'Devre dışı'; `LastLogonText` `dd.MM.yyyy` veya '-'; `BitLockerText` "N anahtar"/'Yok'; `LapsText` = `'Yok'` | `"Süresi geçmiş (dd.MM.yyyy)"` | `"dd.MM.yyyy HH:mm"`; `OwnerName` `Get-DnCommonName` veya '-'. `Set-WorkerProgress` OU başına. Shortcut yorumunu ekle. Sonuç `Sort-Object Name`.

- [ ] **Step 4: Çalıştır, PASS gör.** Aynı komut; tüm satırlar `PASS`, son satırda hata sayısı 0.

- [ ] **Step 5: Commit.** `git add Modules/AD/Devices.ps1 Tests/Test-Devices.ps1 && git commit -m "Cihazlar: OU bazlı bilgisayar listesi ve BitLocker/LAPS durumu"`

### Task 2: `Get-DeviceSecret`, `Set-DeviceOwnerBulk`, `Find-DirectoryUser` DN

**Files:**
- Modify: `Modules/AD/Devices.ps1`, `Modules/AD/Search.ps1:61-86` (`Find-DirectoryUser`)
- Test: `Tests/Test-Devices.ps1`

**Interfaces:**
- Consumes: `Set-DeviceOwner -ComputerDn -OwnerDn` (mevcut, `[pscustomobject]@{Step;Success;Message}` döner).
- Produces:
  - `Get-DeviceSecret -ComputerDn <string> -DeviceName <string>` → `[pscustomobject]@{ DeviceName; LapsPassword; LapsExpiresAt; BitLocker = @([pscustomobject]@{Name; RecoveryPassword}) }` (`Get-DeletedDeviceSecret` ile aynı biçim).
  - `Set-DeviceOwnerBulk -ComputerDn <string[]> [-OwnerDn <string>]` (`SupportsShouldProcess`) → `pscustomobject[]` (`Set-DeviceOwner` sonuçları).
  - `Find-DirectoryUser` sonuç nesnesine `DistinguishedName` alanı.

- [ ] **Step 1: Failing testler.**

```powershell
# Get-DeviceSecret: sahte Get-ADComputer 'ms-Mcs-AdmPwd'='P@ss', bitiş gelecek; sahte Get-ADObject OneLevel altında 2 anahtar
$secret = Get-DeviceSecret -ComputerDn 'CN=PC1,OU=A,DC=test,DC=local' -DeviceName 'PC1'
Assert-True ($secret.LapsPassword -eq 'P@ss' -and @($secret.BitLocker).Count -eq 2 -and $secret.DeviceName -eq 'PC1') 'Canlı parola okunur'
# Yetki hatası
$msg = Get-ThrownMessage { <sahte Get-ADComputer 'Access is denied' atar>; Get-DeviceSecret -ComputerDn 'CN=PC1,...' -DeviceName 'PC1' }
Assert-True ($msg -match 'yetkiniz yok') 'Yetki hatası Türkçe'
# Bulk: sahte Set-ADComputer CN=BAD için atar
$results = @(Set-DeviceOwnerBulk -ComputerDn 'CN=OK1,OU=A,DC=test,DC=local', 'CN=BAD,OU=A,DC=test,DC=local', 'CN=OK2,OU=A,DC=test,DC=local' -OwnerDn 'CN=Ali,OU=U,DC=test,DC=local' -Confirm:$false)
Assert-True ($results.Count -eq 3 -and @($results | Where-Object Success).Count -eq 2 -and ($results | Where-Object { -not $_.Success }).Step -eq 'BAD') 'Kısmi hata diğerlerini durdurmaz'
$results = @(Set-DeviceOwnerBulk -ComputerDn 'CN=OK1,OU=A,DC=test,DC=local' -OwnerDn 'CN=Ali,OU=U,DC=test,DC=local' -WhatIf)
Assert-True ($results[0].Message -eq 'simüle edildi') 'WhatIf iletilir'
Assert-True ((Find-DirectoryUser -Query 'ali')[0].DistinguishedName -eq '<sahte kullanıcı DN>') 'Kullanıcı aramasında DN var'
```

- [ ] **Step 2: Çalıştır, FAIL gör.** `pwsh -NoProfile -File Tests/Test-Devices.ps1`

- [ ] **Step 3: Uygula.**
  - `Get-DeviceSecret`: spec'teki iki sorgu, sunucu `Get-PdcEmulator`. Hata mesajı `Access is denied|Erişim engellendi|insufficient access` ise `throw 'Parolaları okuma yetkiniz yok (LAPS ve BitLocker okuma izni gerekir).'`. Hiçbir log satırına değer yazma.
  - `Set-DeviceOwnerBulk`: her DN için `Set-DeviceOwner -ComputerDn $dn -OwnerDn $OwnerDn -WhatIf:$WhatIfPreference -Confirm:$false`; sonuçları topla. (`Set-DeviceOwner` hatayı kendisi yakalayıp `Success=$false` döndürüyor.)
  - `Find-DirectoryUser`: nesneye `DistinguishedName = [string]$user.DistinguishedName`.

- [ ] **Step 4: Çalıştır, PASS gör.** Ayrıca `pwsh -NoProfile -File Tests/Test-Phase1.ps1` (Find-DirectoryUser'ı kullanan testler kırılmamalı) → hata sayısı 0.

- [ ] **Step 5: Commit.** `git commit -m "Cihazlar: canlı parola okuma, toplu sahip atama, kullanıcı aramasında DN"` (yalnızca bu task'ın dosyaları).

### Task 3: Denetim bağlamı

**Files:**
- Modify: `Core/Audit.ps1:117-158` (`Get-AuditTaskContext`)
- Test: `Tests/Test-Devices.ps1`

**Interfaces:**
- Consumes: Task 2 komut adları ve argümanları (`ComputerDn`, `DeviceName`, `OwnerDn`).
- Produces: action'lar `device.secrets_view`, `device.link`, `device.unlink`.

- [ ] **Step 1: Failing testler.** `$script:State = @{ CurrentData = @{ Ad = @{ SamAccountName = 'profiluser'; DistinguishedName = 'CN=Profil,...'; ObjectGuid = 'g'; UserPrincipalName = 'p@test' } } }` ile:

```powershell
$ctx = Get-AuditTaskContext -Command 'Get-DeviceSecret' -Arguments @{ ComputerDn = 'CN=PC1,OU=A,DC=test,DC=local'; DeviceName = 'PC1' }
Assert-True ($ctx.Action -eq 'device.secrets_view' -and $ctx.Target.target_device -eq 'PC1' -and $ctx.Target.target_dn -eq 'CN=PC1,OU=A,DC=test,DC=local' -and -not $ctx.Target.Contains('target_user')) 'Parola görüntüleme denetimi, profil kullanıcısı hedef değil'
$ctx = Get-AuditTaskContext -Command 'Set-DeviceOwnerBulk' -Arguments @{ ComputerDn = @('CN=PC1,OU=A,DC=test,DC=local'); OwnerDn = 'CN=Ali,OU=U,DC=test,DC=local' }
Assert-True ($ctx.Action -eq 'device.link' -and $ctx.Target.target_owner -eq 'CN=Ali,OU=U,DC=test,DC=local' -and -not $ctx.Target.Contains('target_user')) 'Toplu atama denetimi'
$ctx = Get-AuditTaskContext -Command 'Set-DeviceOwnerBulk' -Arguments @{ ComputerDn = @('CN=PC1,OU=A,DC=test,DC=local'); OwnerDn = '' }
Assert-True ($ctx.Action -eq 'device.unlink') 'Toplu bağ kaldırma denetimi'
```

- [ ] **Step 2: Çalıştır, FAIL gör.**
- [ ] **Step 3: Uygula.** `switch`'e iki komut; hedef ataması `elseif ($Command -eq 'Get-DeletedDeviceSecret')` satırının yanına iki yeni `elseif` (genel `else` dalından **önce**). `Set-DeviceOwnerBulk` için `target_owner = OwnerDn`, `target_device = (ComputerDn | Get-DnCommonName) -join ', '`.
- [ ] **Step 4: Çalıştır, PASS gör.** `Tests/Test-Devices.ps1` ve `Tests/Test-Phase*.ps1` hata sayısı 0.
- [ ] **Step 5: Commit.** `git commit -m "Cihazlar: parola görüntüleme ve toplu atama denetim kaydı"`

### Task 4: Cihazlar sayfası (XAML + handler + kayıt)

**Files:**
- Modify: `UI/MainWindow.xaml` (nav: `navDisabled` satırından önce; sayfa: `pageDisabled` deseninde yeni `pageDevices`)
- Create: `UI/Handlers/DevicesPage.ps1`
- Modify: `UI/Handlers/Devices.ps1:164` (`Show-DeviceSecretDialog` → `-EmptyHint` parametresi)
- Modify: `UI/Shell.ps1:98` (`$script:Pages` + `navDevices = 'pageDevices'`), `UI/Shell.ps1:140` civarı (`'navDevices' { Initialize-DevicesPage }`), `UI/Shell.ps1:303` (`Register-DevicesPageEvent`)
- Modify: `Start-ADIDM.ps1:194` (`'UI\Handlers\DevicesPage.ps1'`, `Devices.ps1`'den sonra, `Shell.ps1`'den önce)
- Test: `Tests/Test-Theme.ps1`, `Tests/Test-Build.ps1` (mevcut; geçmeli), `Tests/Test-Devices.ps1` (filtre fonksiyonu)

**Interfaces:**
- Consumes: Task 1–2 fonksiyonları; `Show-OuPicker`, `Show-ConfirmDialog -Message -Items -Warning -ApplyText`, `Get-ActionArgument`, `Invoke-BackgroundTask`, `Start-UserLoad -ObjectGuid -Force`, `Write-UiLog`, `Copy-SecretToClipboard`.
- Produces: `Register-DevicesPageEvent`, `Initialize-DevicesPage` (ilk açılışta OU seçili değilse yalnızca boş durum metni), `Start-DevicesPageLoad`, `Test-DeviceAttentionFilter -Item <psobject> -OnlyAttention <bool>` → `[bool]` (saf fonksiyon, test edilebilir), `Start-DevicesPageAssign`, `Start-DevicesPageUnlink`, `Show-DevicesPageSecret`, `Start-DevicesPageUserSearch`.

**XAML kararları:** Liste `pnlDdDevices` deseninde (Card içinde başlık Grid + `ListBox` öğe şablonu Grid), `lstDv` `SelectionMode="Extended"`. Sütunlar: Ad, Sahip (`OwnerName`), Durum, Son oturum, BitLocker (`BitLockerText`), LAPS (`LapsText`), OU. `NeedsAttention=True` için `DataTrigger` ile BitLocker/LAPS metni `{DynamicResource WarningBrush}`. Üst çubuk: `btnDvPickOu` ("OU Seç"), `txtDvOu`, `chkDvAttention` ("Yalnızca eksik/süresi geçmiş"), `btnDvRefresh`. Alt çubuk: `txtDvUser` (Tag="Atanacak kullanıcıyı ara"), `btnDvUserSearch`, `lstDvUserResults` (profildeki `lstDeviceSearch` deseni; `DisplayName — SamAccountName`), `btnDvAssign` ("Ata"), `btnDvUnlink` ("Bağı Kaldır"), `btnDvSecret` ("Parolaları Göster"), `txtDvSummary`. Nav: `navDevices`, `Tag="&#xE7F8;"`, `Content="Cihazlar"`.

- [ ] **Step 1: Failing filtre testi** (`Tests/Test-Devices.ps1` dot-source listesine `UI/Handlers/DevicesPage.ps1` ekle):

```powershell
Assert-True (Test-DeviceAttentionFilter -Item ([pscustomobject]@{ NeedsAttention = $false }) -OnlyAttention $false) 'Filtre kapalı: hepsi görünür'
Assert-True (-not (Test-DeviceAttentionFilter -Item ([pscustomobject]@{ NeedsAttention = $false }) -OnlyAttention $true)) 'Filtre açık: sorunsuz gizlenir'
Assert-True (Test-DeviceAttentionFilter -Item ([pscustomobject]@{ NeedsAttention = $true }) -OnlyAttention $true) 'Filtre açık: uyarılı görünür'
```

- [ ] **Step 2: Çalıştır, FAIL gör.**
- [ ] **Step 3: XAML ekle** (nav + `pageDevices`), yukarıdaki kontrol adlarıyla. Yeni stil yalnızca gerekiyorsa `Styles.xaml`'a.
- [ ] **Step 4: `UI/Handlers/DevicesPage.ps1` yaz.** Davranış (spec "UI" bölümü):
  - OU: `Show-OuPicker -Owner $script:Window -Selected $script:State.DevicesPage.Ou -Multiple -Title 'Hangi OU''lardaki bilgisayarlar listelensin?' -AcceptText 'Bilgisayarları Listele' -Subtree ([ref]$subtree)`; seçim `$script:State.DevicesPage = @{ Ou; Subtree; Items; OwnerDn }` içinde tutulur.
  - Yükleme: `Get-OuDeviceList`; sonuç `ObservableCollection`'a, `CollectionViewSource.GetDefaultView(...).Filter` = `Test-DeviceAttentionFilter` + `chkDvAttention.IsChecked`. Özet: "N bilgisayar, M uyarı".
  - Düğme durumu: Ata = seçim ≥1 ve kullanıcı seçili; Bağı Kaldır = seçim ≥1; Parolaları Göster = seçim tam 1.
  - Ata: farklı sahipli seçilenler varsa `Show-ConfirmDialog -Warning -Items ("NB-X (Eski → Yeni)" satırları) -ApplyText 'Ata'`; `Invoke-BackgroundTask -Command 'Set-DeviceOwnerBulk' -Arguments (Get-ActionArgument @{ ComputerDn = [string[]]...; OwnerDn = ... })`. Sonuç: başarısızlar `txtDvSummary` + `Write-UiLog -Level Error`; WhatIf'te "Simülasyon" metni; ardından `Start-DevicesPageLoad`; açık profilin DN'i eski/yeni sahiplerden biriyse `Start-UserLoad -ObjectGuid $script:State.CurrentData.Ad.ObjectGuid -Force`.
  - Bağı Kaldır: `Show-ConfirmDialog -Message "N bilgisayarın sahibi kaldırılacak."` → aynı akış, `OwnerDn = ''`.
  - Parolaları Göster: `Invoke-BackgroundTask -Command 'Get-DeviceSecret' -Arguments @{ ComputerDn; DeviceName }` → `Show-DeviceSecretDialog -Secret $secret -EmptyHint 'kayıtlı değil veya okuma yetkiniz yok'`.
  - `Show-DeviceSecretDialog`'a `[string]$EmptyHint` ekle; boşsa mevcut metinler aynen kalır (silinmiş cihaz penceresi değişmez), doluysa "Bu cihazda LAPS parolası $EmptyHint." / "Bu cihaz için BitLocker kaydı $EmptyHint.".
- [ ] **Step 5: `Shell.ps1` ve `Start-ADIDM.ps1` kaydı** (Files bölümündeki satırlar).
- [ ] **Step 6: Testleri çalıştır.** `for f in Tests/Test-*.ps1; do pwsh -NoProfile -File "$f" >/dev/null 2>&1 && echo "OK $f" || echo "FAIL $f"; done` → hepsi `OK`. (`Test-Theme` sabit renk ve fırça varlığını, `Test-Build` Start-ADIDM referanslarını denetler.)
- [ ] **Step 7: Manuel kontrol (Windows, AD erişimli makine — kullanıcı yapar).** OU seç → liste; filtre; 2 bilgisayar seç → kullanıcıya ata (WhatIf açık ve kapalı); bağ kaldır; parola göster → kopyala → 60 sn sonra pano boş; denetim dosyasında `device.secrets_view` satırı var, parola yok.
- [ ] **Step 8: Commit.** `git commit -m "Cihazlar sayfası: OU listesi, toplu atama, parola görüntüleme"`
