#Requires -Version 5.1

<#
.SYNOPSIS
    AD & Exchange Kullanıcı Yöneticisi (AD-IDM) V2.
.PARAMETER RunLeaveCheck
    Gece izin kontrolü; arayüz açılmaz, zamanlanmış görev bu modla çalışır.
.PARAMETER LeavePreview
    -RunLeaveCheck ile: hiçbir değişiklik yapmadan yapılacak işlemleri listeler.
.PARAMETER LeaveCheckDate
    -RunLeaveCheck ile: kontrolü beklemeden bu günün 00:00 durumuna göre çalıştırır.
.PARAMETER NoLeaveReplication
    -RunLeaveCheck ile: işlem sonrası repadmin /syncall komutunu atlar.
.PARAMETER InstallDesktopShortcut
    Masaüstüne yönetici olarak açılan AD-IDM kısayolunu oluşturur.
.PARAMETER InstallLeaveTask
    Gece izin görevini Görev Zamanlayıcısı'na kurar (yönetici olarak).
.PARAMETER LeaveTaskAccount
    Gece görevinin çalışacağı hesap; gMSA önerilir, ör. CONTOSO\gmsa-izin$.
.PARAMETER UninstallLeaveTask
    Gece izin görevini Görev Zamanlayıcısı'ndan kaldırır.
.PARAMETER TestLeaveMail
    Bu gece yapılacakları değişiklik yapmadan hesaplar ve önizleme e-postası gönderir.
.PARAMETER Theme
    Arayüz teması: Auto, Light veya Dark.
.PARAMETER LogPath
    İşlem günlüğü. Varsayılan: <betik klasörü>\Logs\AD-IDM_yyyyMMdd.log
.PARAMETER ExchangeMode
    Başlangıçta otomatik bağlanılacak Exchange ortamı: None veya OnPremises.
.PARAMETER ExchangeServer
    On-Premises bağlantı için varsayılan Exchange sunucusu FQDN.
.PARAMETER DomainController
    Tüm AD işlemlerinin yapılacağı tek DC. Verilmezse PDC Emulator kullanılır.
.PARAMETER DisabledUsersOu
    Devre dışı bırakılan kullanıcıların taşınacağı OU. Varsayılan: OU=DisabledUsers,<etki alanı DN>
.PARAMETER PreviousOuAttribute
    Önceki OU'nun saklandığı öznitelik. Varsayılan: adminDescription.
.PARAMETER LeaveAttribute
    Personel izin planının tutulduğu öznitelik. Varsayılan: extensionAttribute1.
.PARAMETER LegacyLeaveEndAttribute
    Eski izin sisteminin işe dönüş tarihi özniteliği; yok saymak için none. Varsayılan: extensionAttribute2.
.PARAMETER AuditLogPath
    SIEM değişiklik günlüğü. Parola ve gizli bilgiler yazılmaz.
.PARAMETER AuditLogFormat
    Değişiklik günlüğü biçimi: KeyValue veya Json.
.PARAMETER AuditMaxSizeMB
    Değişiklik günlüğü bu boyutu aşınca arşivlenir. Varsayılan: 50.
.PARAMETER SmsConfigPath
    SMS ayar dosyası. Varsayılan: <betik klasörü>\Configs\sms-config.json
.PARAMETER MailConfigPath
    E-posta ayar dosyası. Varsayılan: <betik klasörü>\Configs\mail-config.json
.PARAMETER SetSmsSecret
    sms-config.json 'Secrets' altındaki gizli bilgiyi DPAPI ile kaydeder.
.PARAMETER SetMailCredential
    SMTP kimliğini DPAPI ile kaydeder; dosyayı kullanacak hesapla çalıştırın.
.PARAMETER TestSmsTo
    Verilen numaraya parola içermeyen test SMS'i gönderir.
.PARAMETER TestMailTo
    Verilen adrese test e-postası gönderir.
.PARAMETER TestNewUser
    Kullanıcı ekleme akışını test eder. -TestOu verilmezse yalnız ön kontrol yapar (AD'ye yazmaz, SMS göndermez).
.PARAMETER TestOu
    -TestNewUser ile: test kullanıcısının oluşturulacağı OU'nun DN'i. Test sonunda kullanıcı silinir.
.PARAMETER TestMobile
    -TestNewUser -TestOu ile: hoş geldiniz SMS'inin gideceği (sizin) cep telefonunuz.
.PARAMETER TestIncludeCc
    -TestNewUser ile: test e-postasını mail-config.json'daki CC adreslerine de gönderir.
.PARAMETER KeepTestUser
    -TestNewUser -TestOu ile: test kullanıcısını silmez.
#>
[CmdletBinding()]
param(
    [Parameter()][switch]$RunLeaveCheck,
    [Parameter()][switch]$LeavePreview,
    [Parameter()][datetime]$LeaveCheckDate,
    [Parameter()][switch]$NoLeaveReplication,
    [Parameter()][switch]$InstallDesktopShortcut,
    [Parameter()][switch]$InstallLeaveTask,
    [Parameter()][string]$LeaveTaskAccount,
    [Parameter()][switch]$UninstallLeaveTask,
    [Parameter()][switch]$TestLeaveMail,
    [Parameter()][ValidateSet('Auto', 'Light', 'Dark')][string]$Theme = 'Auto',
    [Parameter()][string]$LogPath,
    [Parameter()][ValidateSet('None', 'OnPremises')][string]$ExchangeMode = 'None',
    [Parameter()][string]$ExchangeServer,
    [Parameter()][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')][string]$DomainController,
    [Parameter()][string]$DisabledUsersOu,
    [Parameter()][ValidatePattern('^[A-Za-z][A-Za-z0-9-]*$')][string]$PreviousOuAttribute = 'adminDescription',
    [Parameter()][ValidatePattern('^[A-Za-z][A-Za-z0-9-]*$')][string]$LeaveAttribute = 'extensionAttribute1',
    [Parameter()][ValidatePattern('^[A-Za-z][A-Za-z0-9-]*$')][string]$LegacyLeaveEndAttribute = 'extensionAttribute2',
    [Parameter()][string]$AuditLogPath,
    [Parameter()][ValidateSet('KeyValue', 'Json')][string]$AuditLogFormat = 'KeyValue',
    [Parameter()][ValidateRange(1, 2048)][int]$AuditMaxSizeMB = 50,
    [Parameter()][string]$SmsConfigPath,
    [Parameter()][string]$MailConfigPath,
    [Parameter()][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$SetSmsSecret,
    [Parameter()][switch]$SetMailCredential,
    [Parameter()][string]$TestSmsTo,
    [Parameter()][string]$TestMailTo,
    [Parameter()][switch]$TestNewUser,
    [Parameter()][string]$TestOu,
    [Parameter()][string]$TestMobile,
    [Parameter()][switch]$TestIncludeCc,
    [Parameter()][switch]$KeepTestUser
)

if ('ğ'.Length -ne 1) { throw 'Betik ANSI olarak okundu. Dosyaları UTF-8 BOM ile kaydedin.' }

if ($env:OS -ne 'Windows_NT') { throw 'Bu araç yalnızca Windows üzerinde çalışır (WPF, DPAPI).' }

$script:AppRoot = $PSScriptRoot
$script:EmbeddedFiles = @{} # BUILD:EMBEDDED-FILES
function Read-AppFile {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    if ($script:EmbeddedFiles.ContainsKey($RelativePath)) { return $script:EmbeddedFiles[$RelativePath].Replace('<ADIDM-HERE-END>', "'@") }
    return [System.IO.File]::ReadAllText((Join-Path -Path $script:AppRoot -ChildPath $RelativePath), [System.Text.Encoding]::UTF8)
}
$script:ThemePreference = $Theme
$script:LogPath = if ($LogPath) { $LogPath } else { Join-Path -Path $script:AppRoot -ChildPath ('Logs\AD-IDM_{0:yyyyMMdd}.log' -f (Get-Date)) }
$script:SmsConfigPath = if ($SmsConfigPath) { $SmsConfigPath } else { Join-Path -Path $script:AppRoot -ChildPath 'Configs\sms-config.json' }
$script:AppConfigPath = Join-Path -Path $script:AppRoot -ChildPath 'Configs\app-config.json'
$script:MailConfigPath = if ($MailConfigPath) { $MailConfigPath } else { Join-Path -Path $script:AppRoot -ChildPath 'Configs\mail-config.json' }
$script:ScriptFullPath = $PSCommandPath
$script:ScriptFileName = Split-Path -Path $PSCommandPath -Leaf
$script:LeaveTaskArgs = @(foreach ($name in 'DomainController', 'LeaveAttribute', 'LegacyLeaveEndAttribute', 'PreviousOuAttribute', 'DisabledUsersOu', 'AuditLogPath', 'AuditLogFormat', 'AuditMaxSizeMB', 'MailConfigPath') {
        if ($PSBoundParameters.ContainsKey($name)) { '-{0} "{1}"' -f $name, $PSBoundParameters[$name] }
    })
$script:StartupExchangeMode = $ExchangeMode
$script:StartupExchangeServer = $ExchangeServer
$script:WorkerScripts = 'Core\WorkerBootstrap.ps1', 'Core\Notify.ps1', 'Modules\AD\Search.ps1', 'Modules\AD\Users.ps1', 'Modules\AD\Groups.ps1', 'Modules\Leave\LeaveParser.ps1', 'Modules\Exchange\Session.ps1', 'Modules\Exchange\Mailbox.ps1', 'Modules\Exchange\PstExport.ps1', 'Modules\AD\Devices.ps1', 'Modules\AD\DisabledUsers.ps1', 'Modules\AD\Reports.ps1', 'Modules\Leave\LeaveEngine.ps1', 'Modules\Workflows\Provision.ps1'
$script:Ui = @{}
$script:Window = $null

foreach ($relativePath in 'Core\Elevation.ps1', 'Core\Logging.ps1', 'Core\Audit.ps1', 'Core\Config.ps1', 'Core\Secrets.ps1', 'Core\Notify.ps1', 'Core\Runspace.ps1', 'Modules\Leave\LeaveTask.ps1', 'Modules\AD\Devices.ps1') {
    . ([scriptblock]::Create((Read-AppFile -RelativePath $relativePath)))
}
$script:Sync.Pdc = if ($DomainController) { $DomainController } else { $null }
$script:Sync.DefaultDc = $null
$script:Sync.LeaveTaskPath = '\ADEUM\'
$script:Sync.LeaveTaskName = 'Izin Kontrolu'
$script:Sync.ExchangeServer = $null
$script:Sync.ExchangeSession = $null
$script:Sync.ExchangeModuleName = $null
$script:Sync.Catalog = $null
$script:Sync.PstExportReady = $false
$script:Sync.PstModuleName = $null
$script:Sync.DisabledUsersOu = $DisabledUsersOu
$script:Sync.PreviousOuAttribute = $PreviousOuAttribute
try {
    $deviceSetting = Get-DeviceNamePatternSetting -Path $script:AppConfigPath
    $script:Sync.DeviceNamePattern = $deviceSetting.Pattern
    if ($deviceSetting.Warning) { Write-Warning $deviceSetting.Warning }
}
catch {
    $script:Sync.DeviceNamePattern = ''
    Write-Warning "app-config.json okunamadı, otomatik cihaz eşleştirme kapalı: $($_.Exception.Message)"
}
$script:Sync.LeaveAttribute = $LeaveAttribute
$script:Sync.LegacyLeaveEndAttribute = if ($LegacyLeaveEndAttribute -eq 'none') { '' } else { $LegacyLeaveEndAttribute }
Initialize-Audit -Path $(if ($AuditLogPath) { $AuditLogPath } else { Join-Path -Path $script:AppRoot -ChildPath 'Logs\ADExchangeUserManager-audit.log' }) -Format $AuditLogFormat -MaxSizeMB $AuditMaxSizeMB

if ($SetSmsSecret) { Invoke-SmsSecretSetup -Name $SetSmsSecret; return }
if ($SetMailCredential) { Invoke-MailCredentialSetup; return }
if ($InstallDesktopShortcut) { Write-Host "Kısayol oluşturuldu: $(Install-DesktopShortcut)" -ForegroundColor Green; return }
if ($InstallLeaveTask) { Install-LeaveTask -Account $LeaveTaskAccount; return }
if ($UninstallLeaveTask) { Uninstall-LeaveTask; return }
if ($TestLeaveMail) { exit (Invoke-LeaveMailTest) }
if ($RunLeaveCheck) {
    $checkParameters = @{ Preview = [bool]$LeavePreview; NoReplicate = [bool]$NoLeaveReplication }
    if ($PSBoundParameters.ContainsKey('LeaveCheckDate')) { $checkParameters.Date = $LeaveCheckDate }
    exit (Invoke-LeaveCheck @checkParameters)
}
if ($TestSmsTo) { exit (Invoke-SmsTest -PhoneNumber $TestSmsTo) }
if ($TestNewUser) {
    . ([scriptblock]::Create((Read-AppFile -RelativePath 'Modules\Workflows\ProvisionTest.ps1')))
    exit (Invoke-NewUserTest -OuPath $TestOu -Mobile $TestMobile -MailTo $TestMailTo -IncludeCc:$TestIncludeCc -KeepUser:$KeepTestUser)
}
if ($TestMailTo) { exit (Invoke-MailTest -To $TestMailTo) }

$isAdministrator = Test-IsAdministrator
if (-not $isAdministrator -or [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $relaunch = @{ FilePath = (Get-Process -Id $PID).Path; ArgumentList = (Get-RelaunchArgument -ScriptPath $PSCommandPath -ExecutionPolicy ([string](Get-ExecutionPolicy)) -Parameters $PSBoundParameters) }
    if (-not $isAdministrator) { $relaunch.Verb = 'RunAs' }
    try { Start-Process @relaunch -ErrorAction Stop }
    catch {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("AD-IDM yönetici olarak açılamadı.`n`n$($_.Exception.Message)", 'AD-IDM', 'OK', 'Warning')
    }
    return
}

foreach ($relativePath in 'UI\Theme.ps1', 'UI\Layout.ps1', 'UI\Controls.ps1', 'UI\Handlers\Search.ps1', 'UI\Handlers\UserProfile.ps1', 'UI\Handlers\Exchange.ps1', 'UI\Handlers\Groups.ps1', 'UI\Handlers\Actions.ps1', 'UI\Handlers\NewUser.ps1', 'UI\Handlers\Offboarding.ps1', 'UI\Handlers\Leave.ps1', 'UI\Handlers\Reports.ps1', 'UI\Handlers\Settings.ps1', 'UI\Handlers\Dashboard.ps1', 'UI\Handlers\Devices.ps1', 'UI\Handlers\DevicesPage.ps1', 'UI\Shell.ps1') {
    . ([scriptblock]::Create((Read-AppFile -RelativePath $relativePath)))
}

Start-MainWindow
