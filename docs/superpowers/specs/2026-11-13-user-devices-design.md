# Kullanıcı–Cihaz Eşleştirme ve Silmede Cihaz Temizliği — Tasarım

Tarih: 2026-11-13 · Durum: Onay bekliyor

## Amaç ve gerekçe

Kullanıcılara ait bilgisayar nesneleri AD'de sahipsiz kalıyor. İstenen:

1. Her kullanıcının bilgisayarlarını profilde görmek.
2. Devre Dışı sayfasında kullanıcı silinirken bilgisayarlarını da silmek.
3. Silinen bilgisayarın son LAPS parolasına ve BitLocker kurtarma anahtarlarına, geri yükleme yapmadan uygulamadan ulaşmak.

Araç farklı adlandırma kuralları olan başka etki alanlarında da çalışabilir. Bu yüzden otomatik eşleştirme yalnızca bir kolaylıktır, ayarlanabilir olmalıdır ve elle eşleştirmeyle tamamlanır.

## Hedefler

- Ayarlanabilir ad kuralıyla otomatik eşleştirme (varsayılan `NB-{sam}`).
- AD `managedBy` alanıyla elle eşleştirme (bağla / bağı kaldır).
- Profilin "Hesap" sekmesinde salt okunur "Cihazlar" bölümü.
- Kullanıcı silinirken eşleşen cihazların da silinmesi. Onay, WhatIf ve PDC akışı mevcut `Remove-DisabledUser` ile aynı.
- Devre Dışı sayfasında "Silinmiş Cihazlar" listesi: Geri Dönüşüm Kutusu'ndan LAPS parolası ve BitLocker anahtarlarını isteğe bağlı gösterme ve kopyalama.

## Hedef dışı

- Canlı (silinmemiş) cihazların LAPS ve BitLocker parolalarını göstermek. Bu, sonraki ayrı bir iş.
- Silinmiş cihazı geri yükleme (`Restore-ADObject`) düğmesi. Denetim günlüğüne GUID yazılır, geri yükleme elle yapılır.
- Kullanıcı devre dışı bırakılırken cihazı devre dışı bırakma veya taşıma.
- Sahipsiz cihaz toplu raporu.
- Windows LAPS (`msLAPS-*`) desteği. Ortamda yalnızca eski Microsoft LAPS (`ms-Mcs-AdmPwd`) var.

## Anti-hedefler (çalışsa bile başarısızlık sayılır)

- Başka bir kullanıcının cihazını silmek. Gevşek eşleştirme ("içinde geçiyor") yasak.
- LAPS veya BitLocker sırlarını diske, uygulama günlüğüne ya da denetim günlüğüne yazmak.
- Sırları AD dışında bir kopyada toplamak. Kaynak her zaman AD ve Geri Dönüşüm Kutusu.
- Cihazlardan biri silinemediği hâlde kullanıcıyı silmek. Kullanıcı gittikten sonra o cihaz hiçbir ekranda görünmez kalır.

## Doğrulanan ortam bilgileri (2026-11-13)

- AD Geri Dönüşüm Kutusu açık.
- Eski Microsoft LAPS kullanılıyor. `ms-Mcs-AdmPwd` dolu, `msLAPS-*` boş.
- Silinmiş bilgisayar nesnelerinde `ms-Mcs-AdmPwd` okunabiliyor (örnek: `NB-GG0043`, `CT-WIN10`).
- Silinmiş bilgisayarın BitLocker alt nesneleri (`msFVE-RecoveryInformation`) Deleted Objects kabında duruyor. `lastKnownParent` = silinmiş bilgisayarın DN'i olacak şekilde bulunuyor, `msFVE-RecoveryPassword` okunabiliyor. Silinmiş bilgisayarın DN'ini `-SearchBase` olarak vermek **çalışmıyor**.
- Etki alanında 41 canlı BitLocker kaydı var.
- Bilgisayarların `managedBy` alanı başka bir amaçla kullanılmıyor.

## Eşleştirme kuralları

Bir kullanıcının cihaz listesi = **ad kuralı eşleşmeleri ∪ `managedBy` eşleşmeleri**.

### Ad kuralı

- Ayar: `DeviceNamePattern`, `{sam}` yer tutucusu içeren bir şablon. Varsayılan `NB-{sam}`. Boş bırakılırsa otomatik eşleştirme kapanır.
- Eşleşen adlar, `{sam}` yerine kullanıcının `sAMAccountName` değeri konduktan sonra:
  - şablonun kendisi: `NB-ME9533`
  - şablon + `-` + herhangi bir ek: `NB-ME9533-2`
- Büyük/küçük harf fark etmez. Bunun dışındaki her şey eşleşmez: `FNB-ME9533`, `NB-ME95331`, `XNB-ME9533` gibi.
- LDAP sorgusu: `(&(objectClass=computer)(|(name=<şablon>)(name=<şablon>-*)))`. `sAMAccountName` LDAP filtresine yazılmadan önce kaçışlanmalı (`* ( ) \ NUL`).
- Şablonda `{sam}` yoksa veya LDAP joker karakteri `*` varsa ayar geçersiz sayılır ve kaydedilmez.

### Elle eşleştirme (`managedBy`)

- Profildeki "Cihaz Bağla" ile seçilen bilgisayarın `managedBy` alanı kullanıcının DN'i olur. "Bağı Kaldır" bu alanı temizler (`Set-ADComputer -Clear managedBy`).
- Sorgu: `(&(objectClass=computer)(managedBy=<kullanıcı DN>))`.
- Bağlanmak istenen cihazın `managedBy` alanı başka bir kullanıcıyı gösteriyorsa onay istenir, yazılırsa üzerine yazılır.

### Çakışma

Ad kuralıyla eşleşen bir cihazın `managedBy` alanı **başka** bir kullanıcıyı gösteriyorsa:

- Cihaz profilde uyarıyla listelenir: "managedBy başka kullanıcıyı gösteriyor: <ad>".
- Silmeye **dahil edilmez**. Onay penceresinde "atlanacak" olarak gösterilir.

## Profil: "Cihazlar" bölümü (Hesap sekmesi)

- Veri, `Get-UserProfileData` içinde ayrı bir adımda okunur. Hata olursa profil yine yüklenir, bölümde hata metni görünür (grup üyeliklerindeki desen).
- Sütunlar: Ad, Kaynak (Ad kuralı / Elle / İkisi), OU, Etkin, Son oturum (`lastLogonTimestamp`), BitLocker kaydı var mı, LAPS var mı, uyarı.
- "BitLocker var mı" için anahtarın kendisi değil yalnızca kaydın varlığı sorgulanır. "LAPS var mı" için `ms-Mcs-AdmPwdExpirationTime` kullanılır, parola okunmaz.
- Düğmeler: "Cihaz Bağla…" (bilgisayar arama/seçme penceresi), "Bağı Kaldır" (yalnızca kaynağı "Elle" veya "İkisi" olanlarda).
- Bağlama ve bağ kaldırma profil kaydetme akışına girmez, anında arka planda çalışır ve listeyi yeniler. Mevcut WhatIf seçeneğine uyar.

## Silme akışı (Devre Dışı sayfası)

### Onay öncesi

`Remove-SelectedDisabledUser`, onay penceresinden önce seçili kullanıcıların cihazlarını arka planda okur. Pencerede her kullanıcının altında şunlar listelenir:

```
| Ad Soyad (ME9533) - devre dışı: ...
|     Cihazlar: NB-ME9533 (BitLocker: 2 anahtar, LAPS: var), NB-ME9533-2 (BitLocker: yok, LAPS: var)
|     Atlanacak: NB-XX0001 (managedBy başka kullanıcıyı gösteriyor)
```

Pencereye şu not eklenir: "Cihazlar BitLocker ve LAPS bilgileriyle birlikte silinir. Geri Dönüşüm Kutusu'nda <N> gün saklanır; bu süre içinde Silinmiş Cihazlar listesinden görüntülenebilir." N değeri `msDS-deletedObjectLifetime`'tan okunur, boşsa `tombstoneLifetime`, o da boşsa 180.

### Sunucu tarafı (`Remove-DisabledUser` genişletilir)

Kullanıcı başına sıra:

1. Mevcut kontroller: hesap devre dışı mı, Devre Dışı OU'sunda mı.
2. Geri Dönüşüm Kutusu açık mı? (`Get-ADOptionalFeature 'Recycle Bin Feature'`, `EnabledScopes` boş değil.) Oturum başına bir kez okunup önbelleğe alınabilir. Kapalıysa **bu kullanıcı için hiçbir şey silinmez**, sonuç "Geri Dönüşüm Kutusu kapalı" olur.
3. Cihazlar sunucu tarafında **yeniden** çözülür. Onay penceresindeki listeye güvenilmez, aradaki değişiklikler yakalanır. Çakışmalı cihazlar atlanır.
4. Her cihaz için `Remove-ADObject -Identity <DN> -Recursive -Server <PDC>`. `-Recursive` BitLocker alt nesneleri için gerekli.
5. Herhangi bir cihaz silinemezse kullanıcı **silinmez**. Sonuç mesajında silinen ve silinemeyen cihazlar ayrı ayrı yazılır.
6. Tüm cihazlar silindiyse kullanıcı mevcut şekilde silinir.

Sonuç nesnesine `Devices` alanı eklenir (cihaz başına Name, DN, ObjectGuid, Success, Message). `Complete-DisabledUserRemoval` özet metne cihaz sayısını ekler.

WhatIf açıkken her `Remove-ADObject` için mevcut `[WhatIf]` günlük satırı yazılır, hiçbir şey silinmez.

### Denetim günlüğü

Silinen her cihaz için `Write-AuditEvent -Action 'DeviceDeleted'` yazılır: `device_name`, `device_dn`, `device_guid`, `owner_sam`, `match_source`, `bitlocker_count`, `laps_present`. Geri yükleme komutu bu kayıttan kurulabilir: `Restore-ADObject -Identity <device_guid>`, ardından BitLocker alt nesneleri.

## "Silinmiş Cihazlar" listesi (Devre Dışı sayfası)

- Kaynak: `Get-ADObject -IncludeDeletedObjects -LDAPFilter '(&(objectClass=computer)(isDeleted=TRUE))'`, PDC üzerinde çalışır.
- Varsayılan filtre yalnızca bu araçla silinen cihazlar değil, tüm silinmiş bilgisayarlar. Ad ve eski sahip filtresi olur.
- Sütunlar: Ad (`msDS-LastKnownRDN`), Eski OU (`lastKnownParent`), Silinme zamanı (`whenChanged`), Kalan gün, Eski sahip.
  - Eski sahip `managedBy`'dan alınır. Silinmiş kullanıcıda bu bağ kalkmış olabilir; o zaman ad kuralı ters çevrilerek `sam` gösterilir, o da yoksa `-`.
- Liste yüklenirken parola okunmaz, yalnızca var olup olmadıkları gösterilir.
- "Parolaları Göster" (seçili tek cihaz):
  - LAPS: silinmiş nesnenin `ms-Mcs-AdmPwd` ve `ms-Mcs-AdmPwdExpirationTime` alanları.
  - BitLocker: `(objectClass=msFVE-RecoveryInformation)` + `-IncludeDeletedObjects`, `lastKnownParent -eq <silinmiş bilgisayar DN>` ile süzülür. Kayıt başına Ad (tarih + kurtarma kimliği) ve `msFVE-RecoveryPassword`.
  - Sonuç, kendi hâlinde kapanan bir pencerede gösterilir, her değerin yanında "Kopyala" düğmesi olur. Pencere kapanınca değerler bellekten bırakılır.
  - Panoya kopyalanan değer 60 saniye sonra, panoda hâlâ aynı değer duruyorsa temizlenir.
  - Her görüntüleme `Write-AuditEvent -Action 'DeletedDeviceSecretsViewed'` ile yazılır (cihaz adı, GUID; **değerler değil**).
- Yetki: Deleted Objects kabını okuma yetkisi olmayan hesapta hata mesajı gösterilir: "Silinmiş nesneleri okuma yetkiniz yok (Domain Admins veya Deleted Objects kabında okuma izni gerekir)."

## Kısıtlar

- PowerShell 5.1, ActiveDirectory modülü, mevcut runspace / `Invoke-BackgroundTask` / `Set-WorkerProgress` desenleri.
- UI iş parçacığı bloklanmaz, tüm AD çağrıları arka planda çalışır.
- Silme ve silinmiş nesne okuma PDC (`Get-PdcEmulator`) üzerinde yapılır.
- Sırlar `Write-WorkerLog`, `Write-UiLog` ve denetim günlüğüne hiçbir koşulda girmez. Arka plan görevinin sonuç nesnesi sırrı UI'ya taşıyabilir ama görev argümanları ve hata metinleri taşıyamaz.

## Yaklaşımlar

| | Yaklaşım | Artı | Eksi |
|---|---|---|---|
| A | Eşleşmeyi her seferinde AD'den sorgula, ad kuralı + `managedBy` | Kayıt tutulmaz, hep güncel; elle eşleştirme AD'de, tüm yöneticiler görür | Elle bağlama için bilgisayarlara yazma yetkisi gerekir |
| B | Eşitleme işiyle tüm eşleşmeleri `managedBy`'a yaz | Ad değişse de eşleşme kalır | Sürekli çalışan iş, kural zaten kesin; gereksiz yük |
| C | A + sahipsiz cihaz toplu raporu | Eski artıkları temizler | Kapsam büyür; sonraya bırakıldı |

**Seçilen: A.** Elle eşleştirme `managedBy` ile yapılır.

Sırların saklanması için de iki yol değerlendirildi:
- (1) Geri Dönüşüm Kutusu'ndan okumak
- (2) Silinen cihazlar için DPAPI ile şifrelenmiş yerel kopya

**Seçilen: (1).** Ortamda doğrulandı. AD dışında sır kopyası oluşmaz, AD yetkileri ve denetimi geçerli kalır.

## Kullanıcının verdiği kararlar

- Eşleştirme profilde görünür, kullanıcı silinince cihazlar da silinir.
- Varsayılan kural yalnızca `NB-` öneki. `FNB-`, `TNB-` eşleşmez. `-2` gibi ekler aynı kullanıcıya aittir.
- Kural her etki alanı için ayarlanabilir olmalı. Elle eşleştirme `managedBy` ile yapılır.
- Yerel sır kopyası tutulmaz. Silinmiş cihazın son parolaları Geri Dönüşüm Kutusu'ndan uygulama içinde okunur.

## Tasarımcının kararları (onayınızı bekleyen öneriler)

- Cihaz silinemezse kullanıcı da silinmez.
- Geri Dönüşüm Kutusu kapalıysa o kullanıcı için hiçbir şey silinmez.
- `managedBy` çakışmasında cihaz silinmez, uyarıyla gösterilir.
- Cihazlar sunucu tarafında silmeden hemen önce yeniden çözülür.
- Pano 60 saniye sonra temizlenir.
- "Silinmiş Cihazlar" tüm silinmiş bilgisayarları listeler, yalnızca bu araçla silinenleri değil.

## Uygulayıcıya bırakılanlar

- `DeviceNamePattern` ayarının nerede tutulacağı. Mevcut ayar dosyaları yalnızca Mail ve Sms. Seçenekler: yeni bir `Configs/app-config.template.json` ve Ayarlar'da yeni bir sekme, veya `Start-ADIDM.ps1` parametresi (`DisabledUsersOu` deseni). Ayarlar ekranı tercih edilir; kural önizlemesi oraya konur.
- Bilgisayar seçme penceresi. `Show-OuPicker` deseni örnek alınabilir.
- XAML yerleşimi: Hesap sekmesinde yeni bir `Section`, Devre Dışı sayfasında ikinci liste (sekme veya bölünmüş görünüm). Stiller `Styles.xaml`'den.
- Test: mevcut `Tests/Test-Phase6.ps1` sahte cmdlet deseniyle yeni bir `Tests/Test-Devices.ps1`. En az şu durumlar:
  - ad kuralı eşleşir / eşleşmez (`NB-ME9533`, `NB-ME9533-2` evet; `FNB-ME9533`, `NB-ME95331` hayır)
  - LDAP kaçışlama
  - çakışmalı cihaz atlanır
  - cihaz silme hatasında kullanıcı silinmez
  - Geri Dönüşüm Kutusu kapalıyken hiçbir şey silinmez
  - WhatIf'te `Remove-ADObject` çağrılmaz
  - denetim kaydında sır alanı yok
