# AD-IDM

Active Directory ve Exchange On-Premises kullanıcılarını tek ekrandan yöneten Windows masaüstü aracı. PowerShell 5.1 ve WPF ile yazılmıştır.

Kullanıcı arama ve düzenleme, işe giriş (provisioning), işten çıkış (offboarding), PST dışa aktarma ve personel izinlerine göre hesap kapatıp açma işlemlerini kapsar. Değişiklikler önce bir listede toplanır, onaydan sonra sırayla uygulanır ve her adım ayrı raporlanır.

## İçindekiler

- [Özellikler](#özellikler)
- [Gereksinimler](#gereksinimler)
- [Hızlı başlangıç](#hızlı-başlangıç)
- [Yapılandırma](#yapılandırma)
- [Gece izin görevi](#gece-izin-görevi)
- [Komut satırı parametreleri](#komut-satırı-parametreleri)
- [İş akışları](#iş-akışları)
- [Veri biçimleri](#veri-biçimleri)
- [Günlükler](#günlükler)
- [Mimari](#mimari)
- [Geliştirme](#geliştirme)
- [Güvenlik notları](#güvenlik-notları)
- [Bilinen sınırlar](#bilinen-sınırlar)

## Özellikler

| Alan | Yetenekler |
|---|---|
| **Kullanıcılar** | Ad, UPN veya e-posta ile arama, OU'ya göre listeleme, kimlik ve iletişim bilgileri, hesap seçenekleri, fotoğraf, kilit açma, parola sıfırlama |
| **Gruplar** | Arama, ekleme ve çıkarma; değişiklikler kaydedilene kadar uygulanmaz |
| **Exchange** | Kerberos ile Remote PowerShell, posta kutusu oluşturma, e-posta adresleri, CAS özellikleri, kullanım, arşiv, veritabanı taşıma, politikalar |
| **İşe giriş** | Çakışma denetimi, kullanıcı ve posta kutusu oluşturma, parola üretimi, hoş geldin SMS'i, outsource bilgilendirme e-postası |
| **İşten çıkış** | Önceki OU kaydı, `DisabledUsers` OU'suna taşıma, grup temizliği, PST alma, PST sonrası posta kutusu silme, kalıcı silme |
| **İzin motoru** | Tam gün ve saatli izin, toplu izin, izin planı, başsız gece görevi, e-posta raporu |
| **Raporlar** | OU ve alan seçimi, önizleme, CSV dışa aktarma |
| **Ayarlar** | Mail, SMS ve şifre ayarları, test gönderimi, `.bak` yedeği, masaüstü kısayolu oluşturma |
| **Güvenlik** | DPAPI ile şifreli sırlar, WhatIf simülasyonu, SIEM uyumlu değişiklik günlüğü |
| **Arayüz** | Açık ve koyu tema, ölçekleme, klavye kısayolları, donmayan arka plan işleri |

## Gereksinimler

**Zorunlu**

- Windows 10/11 veya Windows Server (etki alanına bağlı)
- Windows PowerShell 5.1 (PowerShell 7 desteklenmez)
- ActiveDirectory modülü (RSAT)
- Arayüz için yerel yönetici hakkı: uygulama yönetici değilse UAC ile kendini yeniden başlatır

RSAT kurulumu:

```powershell
# Windows 10/11
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

# Windows Server
Install-WindowsFeature RSAT-AD-PowerShell
```

**İsteğe bağlı**

| Özellik | Gereken |
|---|---|
| Exchange işlemleri | Exchange On-Premises ve `Recipient Management` veya `Organization Management` rolü |
| PST dışa aktarma | `Mailbox Import Export` rolü ve UNC paylaşımında `Exchange Trusted Subsystem` için okuma/yazma izni |
| Parola SMS'i | HTTP(S) tabanlı bir SMS servisi |
| E-posta | SMTP sunucusu veya relay |
| Gece görevi | Yönetici oturumu ve hizmet hesabı (gMSA önerilir) |

## Hızlı başlangıç

1. Depoyu yerel bir klasöre alın. Kod yönetici yetkisiyle çalıştığı için yazma iznini yalnızca yöneticilere verin:

   ```powershell
   git clone https://github.com/MertEsentimor/AD-IDM.git C:\Scripts\AD-IDM
   cd C:\Scripts\AD-IDM
   icacls .
   ```

2. Ayar dosyalarını şablondan oluşturun:

   ```powershell
   Copy-Item Configs\sms-config.template.json Configs\sms-config.json
   Copy-Item Configs\mail-config.template.json Configs\mail-config.json
   Copy-Item Configs\outsource-mail.template.txt Configs\outsource-mail.txt
   ```

3. Uygulamayı açın:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-ADIDM.ps1
   ```

4. **Ayarlar** sayfasından SMTP ve SMS bilgilerini girin, ardından **Masaüstü Kısayolu Oluştur** düğmesine basın.

İlk değişikliklerinizi test kullanıcısıyla ve onay penceresindeki **WhatIf** kutusu işaretliyken deneyin.

## Yapılandırma

Ayarlar **Ayarlar** sayfasından veya doğrudan JSON dosyalarından yönetilir. Sayfadan kaydetmek önceki dosyayı `.bak` olarak saklar. Dosyayı elle düzenlerken JSON içindeki ters eğik çizgileri çift yazın (`Configs\\outsource-mail.txt`).

| Dosya | Açıklama | Depoda |
|---|---|---|
| `Configs/mail-config.json` | SMTP, outsource e-postası, izin raporu | Hayır |
| `Configs/sms-config.json` | SMS servisi, telefon biçimi, mesajlar, parola kuralları | Hayır |
| `Configs/outsource-mail.txt` | Outsource e-posta metni (`.txt` veya `.html`) | Hayır |
| `Configs/*.template.*` | Başlangıç şablonları | Evet |
| `Secrets/` | DPAPI ile şifreli sırlar | Hayır |

### Ayarlar menüsü

```text
Mail
├─ Sunucu
├─ Outsource Bilgilendirme
└─ İzin Raporu
SMS
├─ Servis
├─ Telefon
└─ Mesajlar
Şifre
```

### E-posta kimlik doğrulaması

`Authentication` alanı şu değerleri alır:

| Değer | Kullanım |
|---|---|
| `Anonymous` | Kimliksiz relay |
| `Windows` | Oturum açan veya görevin hesabı; gMSA için bunu seçin |
| `Credential` | `CredentialFile` içindeki şifreli kimlik |

```powershell
.\Start-ADIDM.ps1 -SetMailCredential
.\Start-ADIDM.ps1 -TestMailTo ben@contoso.com
```

### SMS servisi

`Url` veya `Body` içinde `{{PhoneNumber}}` ve `{{Message}}` yer tutucuları zorunludur. ADSelfService Plus biçimindeki `%mobNo%` ve `%message%` de kabul edilir.

API anahtarını ayar dosyasına açık yazmayın. `{{Secret:ApiKey}}` kullanın ve anahtarı şifreli kaydedin:

```json
{
  "Url": "https://sms.contoso.com/send?key={{Secret:ApiKey}}",
  "Secrets": { "ApiKey": { "Source": "CliXml" } }
}
```

```powershell
.\Start-ADIDM.ps1 -SetSmsSecret ApiKey
.\Start-ADIDM.ps1 -TestSmsTo 05xxxxxxxxx
```

Şifreli dosyaları yalnızca kaydeden hesap, kaydedildiği bilgisayarda açabilir. Uygulamayı başka hesap kullanacaksa sırları o hesapla yeniden kaydedin.

## Gece izin görevi

Görev her gün 23:58'de başlar, işlemleri 00:00:00'da uygular ve saatli izinleri 23:30'a kadar izler. Grup üyeliklerine dokunmaz. Açılışta da 5 dakika sonra çalışarak kaçırılan işlemleri telafi eder.

Kurulum için **yönetici** PowerShell'de:

```powershell
# Önce değişiklik yapmadan yapılacakları görün
.\Start-ADIDM.ps1 -RunLeaveCheck -LeavePreview -LeaveCheckDate (Get-Date).Date

# Görevi kurun (kendi hesabınız kabul edilmez)
.\Start-ADIDM.ps1 -InstallLeaveTask -LeaveTaskAccount 'CONTOSO\gmsa-izin$'

# Kaldırmak için
.\Start-ADIDM.ps1 -UninstallLeaveTask
```

Görev `\ADEUM\Izin Kontrolu` adıyla kurulur. Hizmet hesabının izin özniteliğini yazma ve hesap açıp kapatma yetkisi olmalıdır. Aynı veriyi işleyen başka bir görev aynı anda çalışmamalıdır.

Rapor e-postası `SendWhen` ayarına göre gönderilir:

| Değer | Davranış |
|---|---|
| `Always` | Her gece |
| `Changes` | Yalnızca hesap kapanan veya açılan gecelerde |
| `Failures` | Yalnızca hata veya sorunlu kayıt varsa |

Motor yalnızca kendi kapattığı hesapları açar. `DisabledUsers` altındaki, işten çıkış işareti taşıyan veya başka nedenle kapalı olan hesapları açmaz.

## Komut satırı parametreleri

Parametresiz çalıştırma arayüzü açar. Test ve görev komutları yükseltme istemez.

**Genel**

| Parametre | Açıklama |
|---|---|
| `-Theme` | `Auto`, `Light` veya `Dark` |
| `-LogPath` | İşlem günlüğü yolu |
| `-ExchangeMode`, `-ExchangeServer` | Açılışta Exchange'e otomatik bağlanma |
| `-DomainController` | Tüm AD işlemleri için tek DC; verilmezse PDC Emulator |
| `-DisabledUsersOu` | Kapatılan hesapların OU'su; varsayılan `OU=DisabledUsers,<etki alanı DN>` |
| `-PreviousOuAttribute` | Önceki OU özniteliği; varsayılan `adminDescription` |
| `-LeaveAttribute` | İzin özniteliği; varsayılan `extensionAttribute1` |
| `-LegacyLeaveEndAttribute` | Eski dönüş tarihi özniteliği; varsayılan `extensionAttribute2`, kapatmak için `none` |
| `-AuditLogPath`, `-AuditLogFormat`, `-AuditMaxSizeMB` | Değişiklik günlüğü yolu, biçimi (`KeyValue`, `Json`) ve arşiv boyutu |
| `-SmsConfigPath`, `-MailConfigPath` | Ayar dosyası yolları |

**Kurulum ve sırlar**

| Parametre | Açıklama |
|---|---|
| `-InstallDesktopShortcut` | Yönetici olarak açılan masaüstü kısayolu oluşturur |
| `-InstallLeaveTask`, `-LeaveTaskAccount` | Gece görevini kurar |
| `-UninstallLeaveTask` | Gece görevini kaldırır |
| `-SetSmsSecret <ad>` | SMS gizli bilgisini DPAPI ile kaydeder |
| `-SetMailCredential` | SMTP kimliğini DPAPI ile kaydeder |

**Gece kontrolü**

| Parametre | Açıklama |
|---|---|
| `-RunLeaveCheck` | Arayüzsüz izin kontrolü |
| `-LeavePreview` | Değişiklik yapmadan listeler |
| `-LeaveCheckDate <tarih>` | Beklemeden o günün 00:00 durumuna göre çalışır |
| `-NoLeaveReplication` | İşlem sonrası `repadmin /syncall` komutunu atlar |

**Test**

| Parametre | Açıklama |
|---|---|
| `-TestSmsTo <numara>` | Parola içermeyen test SMS'i gönderir |
| `-TestMailTo <adres>` | Test e-postası gönderir |
| `-TestLeaveMail` | Değişiklik yapmadan rapor önizlemesi gönderir |
| `-TestNewUser` | Kullanıcı akışı ön kontrolü; AD'ye yazmaz, SMS göndermez |
| `-TestNewUser -TestOu <DN> -TestMobile <numara> -TestMailTo <adres>` | Uçtan uca test; kullanıcıyı oluşturur, gerçek SMS ve e-posta gönderir, sonra siler |
| `-TestIncludeCc`, `-KeepTestUser` | Test e-postasına CC ekler, test kullanıcısını silmez |

## İş akışları

### Bekleyen değişiklikler

Sekmelerdeki değişiklikler hemen uygulanmaz. Alttaki bantta toplanır, onaydan sonra worker tarafından sırayla işlenir. Bir adım başarısız olursa diğerleri çalışmaya devam eder ve her biri ayrı raporlanır. **WhatIf** işaretliyse hiçbir şey yazılmaz, komutlar günlüğe düşer.

### İşe giriş

1. Ön kontroller: SMS ayarı, telefon, e-posta alıcısı, `SamAccountName` ve UPN çakışması
2. AD kullanıcısı oluşturma (ilk oturumda parola değişimi zorunlu)
3. İstenirse posta kutusu
4. Parola üretimi ve hoş geldin SMS'i
5. Outsource ise bilgilendirme e-postası

Ön kontrol başarısızsa hiçbir şey yazılmaz. Hesap oluştuktan sonra başarısız olan adımlarda kullanıcı **silinmez**, işlem uyarıyla tamamlanır.

### İşten çıkış

1. Önceki OU, kapatan kişi ve zaman önceki OU özniteliğine yazılır
2. Hesap kapatılır ve `DisabledUsers` OU'suna taşınır
3. İstenirse Domain Users dışındaki gruplardan çıkarılır
4. İstenirse PST isteği oluşturulur
5. "PST sonrası sil" seçiliyse dışa aktarma bitince posta kutusu silinir

Hesap kapatılamazsa sonraki adımlar çalışmaz. Çıkarılan gruplar ve geri alma komutu `Logs\RemovedGroups\` altına yazılır.

Posta kutusu yalnızca şu koşullarda silinir: dışa aktarma `Completed` olmuş, PST dosyası bu makineden okunabilmiş ve boş değilse. `CompletedWithWarning` durumunda otomatik silme yapılmaz. Silme işlemi uygulama açık ve Exchange bağlıyken gerçekleşir; uygulama kapalıysa sonraki bağlantıda yapılır.

Kalıcı silme yalnızca kapalı ve `DisabledUsers` altındaki hesaplarda çalışır.

## Veri biçimleri

Aşağıdaki biçimler AD üzerinde saklanır. Önceki sürümle uyumludur, değiştirilmemelidir.

**İzin kaydı** (`extensionAttribute1`):

```text
ADEUM-LEAVE;2026-12-01..2026-12-05;2026-12-10@13:00..2026-12-10@18:00;OFF=2026-12-01
```

`OFF=`, hesabı motorun hangi tarihte kapattığını gösterir. Motor yalnızca bu işareti taşıyan hesapları izin bitince açar.

**Önceki OU kaydı** (`adminDescription`):

```text
ADEUM-PreviousOU=OU=IT,DC=contoso,DC=local|By=CONTOSO\admin|At=2026-11-05T10:00:00Z
```

**PST istekleri:** `ADEUM-PST*` izlenir, `ADEUM-PST-SIL*` tamamlanınca posta kutusunun silineceğini belirtir.

## Günlükler

| Dosya | İçerik |
|---|---|
| `Logs\AD-IDM_yyyyMMdd.log` | Günlük işlem kaydı |
| `Logs\ADExchangeUserManager-audit.log` | SIEM değişiklik günlüğü (`KeyValue` veya `Json`); boyut aşılınca arşivlenir |
| `Logs\LeaveCheck_yyyyMM.log` | Gece görevi |
| `Logs\RemovedGroups\` | Grup geri alma dosyaları; rotasyona girmez |
| `Logs\NewUserTest_*.log` | Kullanıcı akışı testleri |

Değişiklik günlüğünde parola ve gizli alanlar yer almaz. İşlem günlükleri otomatik silinmez; saklama süresini kendi politikanıza göre yönetin.

## Mimari

```text
UI iş parçacığı (STA)                 Worker runspace
┌───────────────────────┐             ┌───────────────────────────┐
│ WPF ve olay işleyiciler│── iş ─────▶│ FIFO kuyruktan tek iş      │
│ DispatcherTimer (100ms)│◀─ ileti ───│ AD / Exchange / SMS / Mail │
└───────────────────────┘  Sync        └───────────────────────────┘
                           hashtable
```

- Arayüz donmaz: tüm ağ işlemleri tek bir arka plan runspace'inde sırayla çalışır.
- İletişim `Synchronized Hashtable` ve `ConcurrentQueue` ile yapılır; UI bunları zamanlayıcıyla okur.
- Başsız komutlar WPF yüklemeden, aynı modülleri kullanarak çalışır.

### Klasör yapısı

```text
Start-ADIDM.ps1          Giriş noktası: parametreler, yükseltme, yönlendirme
Build.ps1                Tek dosya derlemesi
Assets/                  Uygulama simgesi
Configs/                 Ayar şablonları
Core/                    Runspace, günlük, audit, config, DPAPI, SMS/mail, yükseltme
Modules/
├─ AD/                   Arama, kullanıcı, grup, devre dışı kullanıcılar, rapor
├─ Exchange/             Oturum, posta kutusu, PST
├─ Leave/                İzin biçimi, motor, gece görevi
└─ Workflows/            Kullanıcı oluşturma ve testi
UI/
├─ MainWindow.xaml       Ana pencere ve sayfalar
├─ Styles.xaml           Stiller
├─ Themes/               Light.xaml, Dark.xaml (renklerin tek kaynağı)
├─ Dialogs/              Onay, OU seçici, parola, yeni kullanıcı vb.
├─ Handlers/             Sayfa ve sekme mantığı
└─ Shell.ps1             Olay bağlama ve açılış
Tests/                   Otomatik testler
Tools/                   Geliştirme araçları
```

## Geliştirme

### Kurallar

- Tüm `.ps1` ve `.xaml` dosyaları **UTF-8 BOM** ile kaydedilmelidir; yoksa PowerShell 5.1 Türkçe karakterleri bozuk okur.
- Kod Windows PowerShell 5.1 ile uyumlu kalmalıdır (ör. `??` ve üçlü operatör kullanılmaz).
- Renkler yalnızca `UI/Themes/` içinde tanımlanır. XAML'de `{DynamicResource}`, kodda `SetResourceReference` kullanılır.
- UI iş parçacığından AD veya Exchange çağrılmaz; işler `Invoke-BackgroundTask` ile worker'a verilir.

### Testler

Testler Pester gerektirmez. AD, Exchange, SMS ve SMTP komutları sahtedir; dizine ve dış servislere yazmaz.

```powershell
Get-ChildItem .\Tests\Test-*.ps1 | ForEach-Object {
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $_.FullName
    if ($LASTEXITCODE -ne 0) { Write-Warning "Başarısız: $($_.Name)" }
}
```

| Test | Kapsam |
|---|---|
| `Test-Phase1` | Kaynak denetimleri, tanımsız komut ve denetim kontrolü, arka plan motoru |
| `Test-Phase2` | Audit, sırlar, SMS ve e-posta (yerel sahte sunucularla) |
| `Test-Phase3` | Bekleyen değişiklikler, simülasyon, kısmi hata |
| `Test-Phase4` | Exchange adresleri ve doğrulamaları |
| `Test-Phase5` | İşe giriş akışı |
| `Test-Phase6` | İşten çıkış, PST ve silme güvenliği |
| `Test-Phase7` | İzin motoru ve rapor kuralları |
| `Test-Theme` | Kontrast, tema, yerleşim; Windows'ta gerçek WPF yüklemesi |
| `Test-Build` | Tek dosya çıktısı |
| `Test-Shortcut` | Yükseltme argümanları, kısayol, simge |

macOS veya Linux'ta `pwsh` ile çalışan testler mantığı doğrular, ama WPF ve DPAPI adımlarını atlar. Tam doğrulama Windows PowerShell 5.1 gerektirir.

### Tek dosya derlemesi

```powershell
.\Build.ps1                 # dist\AD-IDM.ps1, dist\Configs\, dist\Assets\
.\Build.ps1 -OutputFolder C:\Yayin
```

Çıktı, tüm kaynakları düz metin olarak içerir. Gerçek ayarlar ve sırlar kopyalanmaz; `Configs` ve `Secrets` dosyalarını çıktının yanına siz yerleştirirsiniz. `dist` elle düzenlenmez, kaynak değişince yeniden derlenir. Kısayol ve gece görevi kuruldukları dosyanın yolunu sakladığı için sürüm değiştirince yeniden kurulmalıdır.

### V1 XAML dönüştürme

`Tools/Convert-V1XamlColor.ps1`, sabit renkli XAML'i tema adlarına çevirir ve tanımadığı renkte hata verir.

## Güvenlik notları

- **Klasör yetkisi:** Uygulama yönetici olarak çalışır ve kısayol `ExecutionPolicy Bypass` kullanır. Klasöre yazabilen biri yönetici oturumunda kod çalıştırabilir. Yazma iznini yalnızca yöneticilere verin.
- **Depoya alınmayanlar:** `.gitignore`, `Secrets`, `Logs`, `dist`, `Ekler` ve gerçek ayarları dışarıda tutar. Gerçek adres, parola veya kurum bilgisi commit etmeyin.
- **SMS parolası:** Parola SMS içinde açık metin taşınır. Bu yüzden geçicidir ve ilk oturumda değiştirilmesi zorunludur; günlüklere yazılmaz.
- **SMTP:** `Credential` kullanırken `UseSsl` değerini `true` yapın.
- **CSV raporları:** Kişisel veri içerir; erişimi kısıtlı bir yerde saklayın.
- **Riskli işlemler:** Gece görevi, "Şimdi Uygula", hesap kapatma, posta kutusu silme ve kalıcı silme gerçek hesapları etkiler. Önce `-LeavePreview`, WhatIf ve test hesapları kullanın.
- **Geri alınamayan silme:** AD Geri Dönüşüm Kutusu kapalıysa kalıcı silme geri alınamaz.

## Bilinen sınırlar

- Yalnızca Windows ve Exchange On-Premises desteklenir.
- PST izleme ve PST sonrası silme, uygulama açık ve Exchange bağlıyken çalışır.
- İş sürerken uygulama kapatılırsa Exchange oturumu kapatılamaz; sunucu tarafında zaman aşımına düşer.
- `Get-LeaveTaskInfo`, görev okunurken oluşan her hatayı "kurulu değil" olarak gösterir. Uygulama yönetici olarak çalıştığı için bu normalde görülmez; görülürse görev gerçekten kurulu olmayabilir veya başka bir okuma hatası olabilir.
- Arayüz ve iletiler yalnızca Türkçedir.
