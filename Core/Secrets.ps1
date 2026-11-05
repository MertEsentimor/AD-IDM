function Get-SmsSecretPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter()][hashtable]$Definition = @{})
    $path = if ($Definition.Path) { [string]$Definition.Path } else { "Secrets\$Name.xml" }
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path -Path $script:AppRoot -ChildPath $path }
    return $path
}
function Resolve-SmsSecret {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $result = @{}
    if (-not $Config.Secrets) { return $result }
    foreach ($name in $Config.Secrets.Keys) {
        $definition = $Config.Secrets[$name]
        if ($definition -isnot [hashtable]) { throw "Secrets.$name bir nesne olmalıdır (Source: SecretManagement, CliXml veya Prompt)." }
        $source = if ($definition.Source) { [string]$definition.Source } else { 'CliXml' }
        switch ($source) {
            'SecretManagement' {
                if (-not (Get-Command -Name Get-Secret -ErrorAction SilentlyContinue)) { throw 'Microsoft.PowerShell.SecretManagement modülü yüklü değil (Install-Module Microsoft.PowerShell.SecretManagement).' }
                $parameters = @{ Name = $(if ($definition.Name) { [string]$definition.Name } else { $name }); ErrorAction = 'Stop' }
                if ($definition.Vault) { $parameters.Vault = [string]$definition.Vault }
                $value = Get-Secret @parameters
                if ($value -is [string]) { $value = ConvertTo-SecureString -String $value -AsPlainText -Force }
                $result[$name] = $value
            }
            'CliXml' {
                $path = Get-SmsSecretPath -Name $name -Definition $definition
                if (-not (Test-Path -LiteralPath $path)) { throw "Gizli bilgi dosyası yok: $path. Oluşturmak için: .\Start-ADIDM.ps1 -SetSmsSecret $name" }
                try { $result[$name] = Import-Clixml -LiteralPath $path -ErrorAction Stop }
                catch { throw "Gizli bilgi dosyası çözülemedi: $path. DPAPI dosyası yalnızca onu oluşturan Windows hesabı ve bilgisayarda açılır. ($($_.Exception.Message))" }
            }
            'Prompt' {
                if (-not $script:SmsCache.Secrets.ContainsKey($name)) {
                    $label = if ($definition.Label) { [string]$definition.Label } else { $name }
                    $credential = Get-Credential -Message "SMS servisi: $label (bu oturum boyunca hatırlanır, diske yazılmaz)" -UserName $(if ($definition.UserName) { [string]$definition.UserName } else { $name })
                    if (-not $credential) { throw "SMS servisi gizli bilgisi girilmedi: $name" }
                    $script:SmsCache.Secrets[$name] = $credential
                }
                $result[$name] = $script:SmsCache.Secrets[$name]
            }
            default { throw "Secrets.$name için bilinmeyen Source: $source" }
        }
    }
    return $result
}
function Invoke-SmsSecretSetup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Name)
    $sms = Get-SmsConfiguration
    if (-not $sms.Config) { throw "SMS ayar dosyası okunamadı: $($sms.Reason)" }
    $definition = if ($sms.Config.Secrets -and $sms.Config.Secrets.ContainsKey($Name)) { $sms.Config.Secrets[$Name] } else { throw "sms-config.json içinde Secrets.$Name tanımlı değil." }
    $source = if ($definition.Source) { [string]$definition.Source } else { 'CliXml' }
    if ($source -eq 'Prompt') { Write-Host "Secrets.$Name 'Prompt' kaynağını kullanıyor: değer her oturumda sorulur, kaydedilmez." -ForegroundColor Yellow; return }
    $value = if ($definition.Type -eq 'Credential') { Get-Credential -Message "SMS servisi: $Name" -UserName ([string]$definition.UserName) }
    else { Read-Host -Prompt "SMS servisi '$Name' değeri" -AsSecureString }
    if (-not $value) { throw 'Değer girilmedi.' }
    if ($source -eq 'SecretManagement') {
        if (-not (Get-Command -Name Set-Secret -ErrorAction SilentlyContinue)) { throw 'Microsoft.PowerShell.SecretManagement modülü yüklü değil.' }
        $parameters = @{ Name = $(if ($definition.Name) { [string]$definition.Name } else { $Name }); Secret = $value; ErrorAction = 'Stop' }
        if ($definition.Vault) { $parameters.Vault = [string]$definition.Vault }
        if ($PSCmdlet.ShouldProcess($parameters.Name, 'Set-Secret')) { Set-Secret @parameters; Write-Host "Kasaya kaydedildi: $($parameters.Name)" -ForegroundColor Green }
        return
    }
    $path = Get-SmsSecretPath -Name $Name -Definition $definition
    if ($PSCmdlet.ShouldProcess($path, 'Export-Clixml (DPAPI)')) {
        $folder = Split-Path -Path $path -Parent
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force) }
        $value | Export-Clixml -LiteralPath $path -Force
        Write-Host "Kaydedildi: $path" -ForegroundColor Green
        Write-Host "Dosya DPAPI ile şifrelidir: yalnızca $env:USERDOMAIN\$env:USERNAME hesabı bu bilgisayarda ($env:COMPUTERNAME) açabilir. Manager'ı başka hesap kullanacaksa o hesapla tekrar çalıştırın." -ForegroundColor Yellow
    }
}
function Invoke-MailCredentialSetup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $mail = Get-MailConfiguration
    $file = if ($mail.Config -and $mail.Config.CredentialFile) { [string]$mail.Config.CredentialFile } else { 'Secrets\smtp-credential.xml' }
    if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path -Path $script:AppRoot -ChildPath $file }
    $credential = Get-Credential -Message 'İzin raporunu gönderecek SMTP hesabı'
    if (-not $credential) { throw 'Kimlik bilgisi girilmedi.' }
    if ($PSCmdlet.ShouldProcess($file, 'Export-Clixml (DPAPI)')) {
        $folder = Split-Path -Path $file -Parent
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force) }
        $credential | Export-Clixml -LiteralPath $file -Force
        Write-Host "Kaydedildi: $file" -ForegroundColor Green
        Write-Host "Dosyayı yalnızca $env:USERDOMAIN\$env:USERNAME bu bilgisayarda ($env:COMPUTERNAME) açabilir: bu komutu gece görevinin hesabıyla çalıştırın. gMSA için 'Authentication': 'Windows' kullanın." -ForegroundColor Yellow
    }
}
