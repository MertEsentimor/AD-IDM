function global:Disconnect-ExchangeEnvironment {
    [CmdletBinding()]
    param()
    if ($Sync.ExchangeSession) {
        try { Remove-PSSession -Session $Sync.ExchangeSession -ErrorAction Stop } catch { Write-WorkerLog -Message "Exchange oturumu kapatılamadı: $($_.Exception.Message)" -Level Warning }
        if ($Sync.ExchangeModuleName) { Remove-Module -Name $Sync.ExchangeModuleName -Force -ErrorAction SilentlyContinue }
        if ($Sync.PstModuleName) { Remove-Module -Name $Sync.PstModuleName -Force -ErrorAction SilentlyContinue }
        Write-WorkerLog -Message 'Exchange On-Premises oturumu kapatıldı.' -Level Info
    }
    $Sync.ExchangeSession = $null
    $Sync.ExchangeModuleName = $null
    $Sync.PstModuleName = $null
    $Sync.PstExportReady = $false
    $Sync.Catalog = $null
    $Sync.ExchangeServer = $null
    $Sync.ExchangeMode = 'None'
}
function global:Connect-ExchangeEnvironment {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('OnPremises')][string]$Mode,
        [Parameter()][string]$Server,
        [Parameter()][System.Management.Automation.PSCredential]$Credential
    )
    Disconnect-ExchangeEnvironment
    $commands = @(
        'Get-Recipient', 'Get-Mailbox', 'Set-Mailbox', 'Get-CASMailbox', 'Set-CASMailbox', 'Get-MailboxStatistics',
        'Enable-Mailbox', 'Disable-Mailbox', 'Get-UserPhoto', 'Set-UserPhoto', 'Remove-UserPhoto',
        'Get-RetentionPolicy', 'Get-AddressBookPolicy', 'Get-SharingPolicy', 'Get-RoleAssignmentPolicy',
        'Get-OwaMailboxPolicy', 'Get-MobileDeviceMailboxPolicy'
    )
    if ([string]::IsNullOrWhiteSpace($Server)) { throw 'Exchange sunucusu (FQDN) belirtilmelidir.' }
    Set-WorkerProgress -Status "Exchange On-Premises ($Server) oturumu açılıyor..."
    $sessionParams = @{
        ConfigurationName = 'Microsoft.Exchange'
        ConnectionUri     = ('http://{0}/PowerShell/' -f $Server.Trim())
        Authentication    = 'Kerberos'
        ErrorAction       = 'Stop'
    }
    if ($Credential) { $sessionParams.Credential = $Credential }
    $session = New-PSSession @sessionParams
    try {
        Set-WorkerProgress -Status 'Exchange cmdlet''leri içe aktarılıyor...'
        $importCommands = $commands + @(
            'Get-RemoteMailbox', 'Set-RemoteMailbox', 'Get-MailboxDatabase',
            'New-MoveRequest', 'Get-MoveRequest', 'Get-MoveRequestStatistics', 'Remove-MoveRequest'
        )
        $module = Import-PSSession -Session $session -CommandName $importCommands -DisableNameChecking -AllowClobber -ErrorAction Stop
        Import-Module -ModuleInfo $module -Global -DisableNameChecking -ErrorAction Stop | Out-Null
    }
    catch {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        throw
    }
    $Sync.ExchangeSession = $session
    $Sync.ExchangeModuleName = $module.Name
    $Sync.ExchangeServer = $Server.Trim()
    $Sync.PstExportReady = $false
    try {
        $pstModule = Import-PSSession -Session $session -CommandName 'New-MailboxExportRequest', 'Get-MailboxExportRequest', 'Get-MailboxExportRequestStatistics', 'Remove-MailboxExportRequest' -DisableNameChecking -AllowClobber -ErrorAction Stop
        Import-Module -ModuleInfo $pstModule -Global -DisableNameChecking -ErrorAction Stop | Out-Null
        $Sync.PstModuleName = $pstModule.Name
        $Sync.PstExportReady = [bool](Get-Command -Name 'New-MailboxExportRequest' -ErrorAction SilentlyContinue)
    }
    catch { Write-WorkerLog -Message "PST dışa aktarma komutları alınamadı ('Mailbox Import Export' rolü atanmamış olabilir): $($_.Exception.Message)" -Level Verbose }
    if (-not $Sync.PstExportReady) { Write-WorkerLog -Message "Bu hesapta PST dışa aktarma yetkisi yok ('Mailbox Import Export' rolü); devre dışı bırakmadaki PST seçeneği kapalı." -Level Info }
    Write-WorkerLog -Message "Exchange On-Premises bağlantısı kuruldu: $Server" -Level Success
    $Sync.ExchangeMode = $Mode
    return [pscustomobject]@{ Mode = $Mode; Server = $Sync.ExchangeServer }
}
function global:Get-ExchangeCatalog {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($Sync.Catalog -and $Sync.Catalog.Mode -eq $Sync.ExchangeMode) { return $Sync.Catalog }
    Set-WorkerProgress -Status 'Exchange politika ve veritabanı listeleri okunuyor...'
    $catalog = @{ Mode = $Sync.ExchangeMode; Databases = @(); Policies = @{} }
    $sources = [ordered]@{
        RetentionPolicy         = 'Get-RetentionPolicy'
        AddressBookPolicy       = 'Get-AddressBookPolicy'
        SharingPolicy           = 'Get-SharingPolicy'
        RoleAssignmentPolicy    = 'Get-RoleAssignmentPolicy'
        OwaMailboxPolicy        = 'Get-OwaMailboxPolicy'
        ActiveSyncMailboxPolicy = 'Get-MobileDeviceMailboxPolicy'
    }
    foreach ($key in $sources.Keys) {
        try {
            if (-not (Get-Command -Name $sources[$key] -ErrorAction SilentlyContinue)) { throw "Komut bu oturumda yok (RBAC)." }
            $catalog.Policies[$key] = @(& $sources[$key] -ErrorAction Stop | ForEach-Object { [string]$_.Name } | Sort-Object)
        }
        catch {
            $catalog.Policies[$key] = @()
            Write-WorkerLog -Message "$($sources[$key]) okunamadı: $($_.Exception.Message)" -Level Verbose
        }
    }
    if ($Sync.ExchangeMode -eq 'OnPremises') {
        try {
            $catalog.Databases = @(Get-MailboxDatabase -ErrorAction Stop | Where-Object { [string]$_.Recovery -ne 'True' } |
                ForEach-Object { [string]$_.Name } | Sort-Object)
        }
        catch {
            Write-WorkerLog -Message "Posta kutusu veritabanı listesi okunamadı: $($_.Exception.Message)" -Level Warning
        }
    }
    $Sync.Catalog = $catalog
    return $catalog
}
