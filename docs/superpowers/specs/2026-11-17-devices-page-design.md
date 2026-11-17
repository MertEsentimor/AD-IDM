# Cihazlar Sayfası — Tasarım

Tarih: 2026-11-17 · Durum: Onay bekliyor · Önceki iş: `2026-11-13-user-devices-design.md`

## Amaç ve gerekçe

Bugün bilgisayar–kullanıcı bağı yalnızca kullanıcı profilinden, tek tek kurulabiliyor. Canlı bilgisayarların LAPS ve BitLocker parolaları uygulamada hiç görünmüyor (önceki tasarımda "sonraki ayrı iş" olarak bırakılmıştı). İstenen:

1. OU seçerek bilgisayarları listelemek.
2. Seçilen bilgisayarları bir kullanıcıya toplu atamak. Bir kullanıcının birden çok bilgisayarı olabilir.
3. Bilgisayarların BitLocker ve LAPS durumunu takip etmek: hangisinde eksik veya süresi geçmiş.
4. Gerektiğinde bir bilgisayarın LAPS parolasına ve BitLocker kurtarma anahtarlarına bakıp kopyalamak.

## Hedefler

- Sol menüde yeni "Cihazlar" sayfası (`navDevices`).
- `Show-OuPicker` ile çoklu OU seçimi (alt OU seçeneğiyle), seçilen OU'lardaki bilgisayarların listesi.
- Liste sütunları: Ad, Sahip, Durum (Etkin/Devre dışı), Son oturum, BitLocker (anahtar sayısı), LAPS (bitiş tarihi), OU.
- BitLocker anahtarı olmayan ya da LAPS parolası olmayan/süresi geçmiş satırlar uyarı rengiyle gösterilir.
- "Yalnızca eksik/süresi geçmiş" filtresi (istemci tarafı, yeniden sorgu yok).
- Çoklu seçim + kullanıcı arama kutusu + "Ata": seçilen tüm bilgisayarların `managedBy` alanı o kullanıcıya yazılır.
- Çoklu seçim + "Bağı Kaldır": seçilen bilgisayarların `managedBy` alanı temizlenir.
- Tek seçim + "Parolaları Göster": mevcut `DeviceSecret.xaml` penceresi canlı bilgisayar için açılır.
- Her parola görüntüleme denetim kaydına yazılır (kim, hangi bilgisayar, ne zaman — parola değil).

## Hedef dışı

- Bilgisayar silme, taşıma, devre dışı bırakma, yeniden adlandırma.
- LAPS parolasını sıfırlama/süresini ileri çekme (`ms-Mcs-AdmPwdExpirationTime` yazma).
- Windows LAPS (`msLAPS-*`). Ortamda yalnızca eski Microsoft LAPS var (önceki tasarımda doğrulandı).
- Ad kuralıyla (`NB-{sam}`) otomatik toplu atama. Atama yalnızca elle, `managedBy` ile.
- Listeyi CSV/Excel'e aktarma.
- Bir bilgisayara birden çok sahip. `managedBy` tek değerlidir.

## Anti-hedefler

- LAPS parolası veya BitLocker anahtarını diske, uygulama günlüğüne, denetim günlüğüne ya da liste verisine yazmak. Liste yüklenirken parola özellikleri (`ms-Mcs-AdmPwd`, `msFVE-RecoveryPassword`) **istenmez**.
- Başka bir kullanıcıya bağlı bilgisayarı sormadan başkasına atamak.
- Büyük OU'larda (yüzlerce bilgisayar) bilgisayar başına LDAP sorgusu atıp listeyi dakikalarca bekletmek.
- Kısmi başarısızlıkta "tamamlandı" demek. Atanamayan her bilgisayar sonuçta adıyla görünür.

## Yaklaşımlar

BitLocker anahtarları her bilgisayarın altında ayrı `msFVE-RecoveryInformation` nesneleri. Sayılarını almanın yolu yükleme hızını belirliyor.

- **A) Bilgisayar başına sorgu** (`Get-UserDevice` deseni). Mevcut kod; ama 300 bilgisayar = 300+ sorgu, büyük OU'da dakikalar.
- **B) OU başına toplu sorgu — SEÇİLDİ.** Her seçilen OU için bir `Get-ADComputer` ve bir `Get-ADObject -LDAPFilter '(objectClass=msFVE-RecoveryInformation)'` (aynı SearchScope). Anahtar sayısı, anahtarın üst DN'ine (`Get-ParentDn`) göre bellekte gruplanır. Bilgisayar sayısından bağımsız olarak OU başına 2 sorgu; durum sütunları ve filtre ilk yüklemede hazır.
- **C) Anahtar sayısını seçince okumak.** En hızlı açılış ama "eksik BitLocker" filtresi çalışmaz; durum takibi isteğini karşılamadığı için elendi.

Kullanıcı B'yi seçti.

## Tasarım

### Backend (`Modules/AD/Devices.ps1`)

**`Get-OuDeviceList -OuDn <string[]> -Subtree <bool>`** (yeni)
- Her OU için:
  - `Get-ADComputer -Filter * -SearchBase $ou -SearchScope (Subtree|OneLevel) -Properties managedBy, lastLogonTimestamp, Enabled, 'ms-Mcs-AdmPwdExpirationTime', OperatingSystem`
  - `Get-ADObject -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -SearchBase $ou -SearchScope Subtree -Properties whenCreated` (BitLocker nesneleri bilgisayarın altında olduğundan, OneLevel bilgisayar araması için bile anahtar araması Subtree olmalı; yalnızca listede olan bilgisayarlar sayılır.)
- İç içe OU seçilirse aynı bilgisayar iki kez gelebilir: `ObjectGUID` ile tekilleştir.
- Üst sınır: toplam 5000 bilgisayar (`Get-OuUser` deseni). Sınır aşılırsa ilk 5000 gösterilir ve `Write-WorkerLog -Level Warning` ile "OU seçimini daraltın" uyarısı verilir. *(Builder kontrolü sonrası verilen karar.)*
- Sunucu: `Get-PdcEmulator` (mevcut desen).
- `Set-WorkerProgress` ile OU başına ilerleme.
- Satır nesnesi: `Name, DistinguishedName, ObjectGuid, Enabled, StatusText, Ou, LastLogon, LastLogonText, ManagedBy, OwnerName, BitLockerCount, BitLockerText, LapsExpiresAt, LapsText, LapsState ('Yok'|'Süresi geçmiş'|'Geçerli'), NeedsAttention (bool)`.
- `NeedsAttention = Enabled -and (OperatingSystem -notmatch 'Server') -and (BitLockerCount -eq 0 -or LapsState -ne 'Geçerli')`. Devre dışı bilgisayarlar ve sunucular uyarı sayılmaz, filtrede çıkmaz (kullanıcı kararı). Sütunlarında değerleri yine görünür.
- `LapsExpiresAt`: `ms-Mcs-AdmPwdExpirationTime > 1` ise `FromFileTime`, değilse `$null`. `LapsState`: `$null` → 'Yok', `< Now` → 'Süresi geçmiş', diğer → 'Geçerli'.
- `OwnerName`: `Get-DnCommonName -DistinguishedName $managedBy`, boşsa `'-'`.
- Sıralama: Ad.

**`Get-DeviceSecret -ComputerDn <string> -DeviceName <string>`** (yeni, canlı bilgisayar)
- `Get-ADComputer -Identity $ComputerDn -Properties 'ms-Mcs-AdmPwd', 'ms-Mcs-AdmPwdExpirationTime'`
- `Get-ADObject -SearchBase $ComputerDn -SearchScope OneLevel -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -Properties 'msFVE-RecoveryPassword'`
- Dönüş nesnesi `Get-DeletedDeviceSecret` ile aynı biçimde (`DeviceName, LapsPassword, LapsExpiresAt, BitLocker[Name, RecoveryPassword]`), böylece `Show-DeviceSecretDialog` değişmeden kullanılır.
- Yetki hatası (`Access is denied|Erişim engellendi|insufficient access`) Türkçe ve anlaşılır mesaja çevrilir. Okuma yetkisi yoksa AD özelliği boş döner (hata değil). `Show-DeviceSecretDialog` isteğe bağlı bir `-EmptyHint` parametresi alır; canlı bilgisayar için "kayıtlı değil veya okuma yetkiniz yok" metni geçilir, silinmiş cihaz penceresinin metni değişmez. *(Builder kontrolü sonrası verilen karar.)*

**`Find-DirectoryUser`** — dönüş nesnesine `DistinguishedName` eklenir (atama için gerekli; mevcut çağıranları etkilemez).

**Atama:** yeni backend yok. Mevcut `Set-DeviceOwner -ComputerDn -OwnerDn` bilgisayar başına çağrılır. Çoklu seçim için ince bir sarmalayıcı: **`Set-DeviceOwnerBulk -ComputerDn <string[]> -OwnerDn <string>`** her bilgisayar için `Set-DeviceOwner` çağırır, sonuç dizisini döner (WhatIf mevcut fonksiyonun içinde zaten işleniyor). Biri başarısız olursa diğerleri devam eder; sonuç her bilgisayarı başarı/hata ile listeler.

### Denetim (`Core/Audit.ps1` — `Get-AuditTaskContext`)

- `'Get-DeviceSecret'` → `device.secrets_view`, `target_device = DeviceName`, `target_dn = ComputerDn`.
- `'Set-DeviceOwnerBulk'` → `device.link` / `device.unlink` (OwnerDn'e göre), `target_owner = OwnerDn`, değişikliklerde her bilgisayar adı ve sonucu.
- **Dikkat:** mevcut `else` dalı, komutta "Exchange|Replication|Remove-DisabledUser" yoksa hedefi `$script:State.CurrentData` (açık profil) olarak yazıyor. Cihazlar sayfasından gelen çağrılarda bu yanlış kullanıcıyı hedef yazar. Yeni komutlar bu dala düşmeden kendi dallarında ele alınmalı.
- Parola alanları zaten `Write-AuditEvent` içinde (`password|secret`) süzülüyor; dönüş değeri denetime hiç verilmez.

### UI

**`UI/MainWindow.xaml`**
- `navDevices` (`Tag="&#xE7F8;"`, "Cihazlar"), "Devre Dışı"dan önce.
- Sayfa düzeni (Devre Dışı sayfasının deseni):
  - Üst çubuk: "OU Seç" düğmesi, seçili OU özeti, "Yenile", "Yalnızca eksik/süresi geçmiş" CheckBox.
  - Orta: `ListView` (`SelectionMode="Extended"`) + `GridView` sütunları. `NeedsAttention` satırlar `DataTrigger` ile tema uyarı fırçası (`WarningBrush` vb. — Light/Dark paletinde var olanı kullan, sabit renk yasak; Theme testi bunu denetliyor).
  - Alt çubuk: kullanıcı arama kutusu + sonuç açılır listesi, "Ata", "Bağı Kaldır", "Parolaları Göster", durum metni (`txtDvSummary`).
- Stiller `Window.Resources`/`Styles.xaml` içinde; yeni stil gerekmiyorsa ekleme.
- Kontrol adları `Dv` önekiyle (`lstDv`, `btnDvPickOu`, `btnDvAssign`, `btnDvUnlink`, `btnDvSecret`, `chkDvAttention`, `txtDvUser`, `lstDvUserResults`, `txtDvSummary`, `txtDvOu`).

**`UI/Handlers/DevicesPage.ps1`** (yeni) veya mevcut `UI/Handlers/Devices.ps1` içine eklenir (builder seçimi; mevcut dosya 200+ satır, ayrı dosya tercih edilir). Yeni dosyaysa `Start-ADIDM.ps1` yükleme sırasına ve `Test-Build.ps1` beklentilerine eklenmeli.
- OU seçimi: `Show-OuPicker -Multiple -Subtree ([ref]$subtree) -Title 'Hangi OU''lardaki bilgisayarlar listelensin?' -AcceptText 'Bilgisayarları Listele'`. Son seçim oturum boyunca `$script:State` içinde tutulur ("Yenile" bunu kullanır).
- Yükleme: `Invoke-BackgroundTask -Command 'Get-OuDeviceList'`. Sonuç bir `ObservableCollection`'a; filtre `CollectionViewSource.GetDefaultView(...).Filter` ile.
- Kullanıcı arama: `Find-DirectoryUser` arka planda, profildeki satır içi bilgisayar aramasının (`Start-DeviceSearch`) kullanıcı versiyonu. Seçilen kullanıcının DN'i saklanır.
- **Ata:**
  1. Seçili bilgisayar ve seçili kullanıcı yoksa durum metniyle uyar.
  2. Seçilenler arasında `ManagedBy` dolu ve hedef kullanıcıdan farklı olanlar varsa, mevcut `Confirm.xaml` ile onay: "Şu bilgisayarların sahibi değişecek: NB-X (Ali Veli → Ayşe Kaya), ...".
  3. `Invoke-BackgroundTask -Command 'Set-DeviceOwnerBulk'`. WhatIf seçeneği `$script:State.Options.WhatIf` ile aynı şekilde iletilir.
  4. Sonuç: başarısızlar adıyla durum metninde; ardından liste yenilenir.
- **Bağı Kaldır:** onay ("N bilgisayarın sahibi kaldırılacak") → `Set-DeviceOwnerBulk -OwnerDn ''` → yenile.
- **Parolaları Göster:** tek seçim zorunlu (çoklu seçimde düğme pasif). `Invoke-BackgroundTask -Command 'Get-DeviceSecret'` → `Show-DeviceSecretDialog`. Pano davranışı (`Copy-SecretToClipboard`, 60 sn temizleme, Win+V hariç) aynen.
- Düğme durumları seçim değiştikçe güncellenir (`Update-DeviceButtonState` deseni).
- Atama/bağ kaldırma sonrası, açık profilin kullanıcısı (`$script:State.CurrentData.Ad.DistinguishedName`) eski veya yeni sahiplerden biriyse profil yeniden yüklenir; değilse bir şey yapılmaz. *(Builder kontrolü sonrası verilen karar: ayrı bir cihaz önbelleği yok, profil cihazları `CurrentData` içinden geliyor.)*

### Testler (`Tests/Test-Devices.ps1`)

AD'siz, Pester'sız mevcut assert stiliyle:
- `Get-OuDeviceList` mantığı için AD cmdlet'leri sahte fonksiyonlarla değiştirilir:
  - BitLocker sayısı üst DN'e göre doğru gruplanıyor; başka OU'daki/listede olmayan bilgisayarın anahtarı sayılmıyor.
  - İç içe OU seçiminde bilgisayar bir kez geliyor.
  - LAPS: özellik yok → 'Yok', geçmiş tarih → 'Süresi geçmiş', gelecek → 'Geçerli'; `NeedsAttention` doğru.
  - Devre dışı bilgisayar ve `OperatingSystem` içinde "Server" geçen bilgisayar, anahtarı yoksa bile `NeedsAttention = $false`.
  - Liste nesnesinde `ms-Mcs-AdmPwd` veya parola alanı yok; `Get-ADComputer` çağrısında `-Properties` parola özelliği içermiyor.
- `Get-AuditTaskContext`: `Get-DeviceSecret` → `device.secrets_view`, `target_device` dolu, açık profil kullanıcısı hedefe yazılmıyor.
- `Set-DeviceOwnerBulk`: bir bilgisayar hata verince diğerleri yine işleniyor, sonuçta hata görünüyor.
- `Test-Theme.ps1` yeni XAML'de sabit renk olmadığını zaten denetliyor; geçmeli.
- `Test-Build.ps1` yeni handler dosyası eklendiyse güncellenmeli.

## Kısıtlar

- Aracı yalnızca BitLocker ve LAPS okuma yetkisi olan yöneticiler kullanır (kullanıcı kararı). Bu yüzden listede yetki kontrolü veya "Bilinmiyor" durumu yok. Yetkisiz biri açarsa BitLocker sayısı 0 görünür. Bu bilinen bir sınırdır ve koda `shortcut:` yorumu olarak yazılır.
- PowerShell 5.1, WPF, `ActiveDirectory` modülü; yeni bağımlılık yok.
- Tüm AD çağrıları arka plan runspace'inde (`Invoke-BackgroundTask`), UI iş parçacığı bloklanmaz.
- Yazma ve parola okuma PDC emülatöründen (`Get-PdcEmulator`).
- LAPS parolası okumak AD'de "All Extended Rights"/LAPS okuma izni, BitLocker anahtarı okumak `msFVE-RecoveryInformation` okuma izni ister. Uygulama izin vermez, yalnızca var olanı kullanır.

## Builder'a bırakılanlar

- Yeni handler dosyası mı, mevcut `Devices.ps1`'e ekleme mi (ayrı dosya önerilir).
- Kullanıcı arama sonucunun açılır liste mi, küçük ListBox mı olacağı (profildeki bilgisayar aramasıyla tutarlı olan).
- Uyarı rengi için hangi mevcut tema fırçasının kullanılacağı.
- Sütun genişlikleri ve sayfadaki boşluklar (Devre Dışı sayfasıyla tutarlı).
