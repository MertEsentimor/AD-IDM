function global:ConvertTo-LdapFilterValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return ($Value -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00')
}
function global:Get-EnvironmentStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $status = [ordered]@{
        AdAvailable      = $false
        DomainName       = $null
        NetBiosName      = $null
        DomainController = $null
        UpnSuffixes      = @()
        ExchangeServers  = @()
    }
    Set-WorkerProgress -Percent 10 -Status 'Active Directory bağlantısı kontrol ediliyor...'
    $dc = Get-PdcEmulator
    $domain = Get-ADDomain -ErrorAction Stop
    $status.AdAvailable = $true
    $status.DomainName = [string]$domain.DNSRoot
    $status.NetBiosName = [string]$domain.NetBIOSName
    $status.DomainController = $dc
    $Sync.DefaultDc = $status.DomainController
    Write-WorkerLog -Message ("Active Directory bağlantısı hazır: {0} (DC: {1})" -f $status.DomainName, $status.DomainController) -Level Success
    try {
        $forest = Get-ADForest -ErrorAction Stop
        $suffixes = @($forest.Domains) + @($forest.UPNSuffixes) | Where-Object { $_ } | Sort-Object -Unique
        $status.UpnSuffixes = @($suffixes)
    }
    catch {
        Write-WorkerLog -Message "UPN son ekleri okunamadı: $($_.Exception.Message)" -Level Warning
        $status.UpnSuffixes = @($status.DomainName)
    }
    Set-WorkerProgress -Percent 50 -Status 'Exchange sunucuları aranıyor...'
    try {
        $configNc = (Get-ADRootDSE -ErrorAction Stop).configurationNamingContext
        $servers = Get-ADObject -SearchBase ("CN=Microsoft Exchange,CN=Services,{0}" -f $configNc) `
            -LDAPFilter '(objectClass=msExchExchangeServer)' -Properties networkAddress, serialNumber -ErrorAction Stop
        $list = foreach ($server in $servers) {
            $fqdn = @($server.networkAddress) | Where-Object { $_ -like 'ncacn_ip_tcp:*' } | Select-Object -First 1
            [pscustomobject]@{
                Name    = [string]$server.Name
                Fqdn    = if ($fqdn) { ($fqdn -replace '^ncacn_ip_tcp:', '') } else { [string]$server.Name }
                Version = [string]($server.serialNumber | Select-Object -First 1)
            }
        }
        $status.ExchangeServers = @($list | Sort-Object -Property Fqdn)
        if ($status.ExchangeServers.Count -gt 0) {
            Write-WorkerLog -Message ("Exchange On-Premises sunucuları bulundu: {0}" -f (($status.ExchangeServers | ForEach-Object { "$($_.Fqdn) [$($_.Version)]" }) -join ', ')) -Level Info
        }
    }
    catch {
        Write-WorkerLog -Message 'AD yapılandırmasında Exchange On-Premises organizasyonu bulunamadı.' -Level Verbose
    }
    Set-WorkerProgress -Percent 100 -Status 'Başlangıç kontrolleri tamamlandı.'
    return [pscustomobject]$status
}
function global:Find-DirectoryUser {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Query,
        [Parameter()][ValidateRange(1, 1000)][int]$MaxResults = 100
    )
    $escaped = ConvertTo-LdapFilterValue -Value $Query.Trim()
    $filter = '(&(objectCategory=person)(objectClass=user)(|(sAMAccountName={0}*)(displayName=*{0}*)(userPrincipalName={0}*)(mail={0}*)))' -f $escaped
    Write-WorkerLog -Message "LDAP araması: $filter" -Level Verbose
    Set-WorkerProgress -Status "'$Query' aranıyor..."
    $users = @(Get-ADUser -LDAPFilter $filter -Properties DisplayName, UserPrincipalName -ResultSetSize $MaxResults -ErrorAction Stop)
    if ($users.Count -ge $MaxResults) {
        Write-WorkerLog -Message "İlk $MaxResults sonuç gösteriliyor; aramayı daraltın." -Level Warning
    }
    foreach ($user in ($users | Sort-Object -Property DisplayName, SamAccountName)) {
        [pscustomobject]@{
            DisplayName       = if ($user.DisplayName) { [string]$user.DisplayName } else { [string]$user.Name }
            SamAccountName    = [string]$user.SamAccountName
            UserPrincipalName = [string]$user.UserPrincipalName
            Enabled           = [bool]$user.Enabled
            StatusText        = if ($user.Enabled) { [string]$user.UserPrincipalName } else { "Devre dışı | $($user.UserPrincipalName)" }
            ObjectGuid        = $user.ObjectGUID.ToString()
        }
    }
}
function global:Get-OuUser {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$SearchBase,
        [Parameter()][bool]$Subtree = $true,
        [Parameter()][ValidateRange(1, 50000)][int]$MaxResults = 5000
    )
    $server = Get-PdcEmulator
    $scope = if ($Subtree) { 'Subtree' } else { 'OneLevel' }
    $bases = @($SearchBase | Where-Object { $_ } | Select-Object -Unique)
    Write-WorkerLog -Message "OU araması: $($bases -join ' | ') (kapsam: $scope)" -Level Verbose
    $parameters = @{
        SearchScope    = $scope
        LDAPFilter     = '(&(objectCategory=person)(objectClass=user))'
        Properties     = @('DisplayName', 'UserPrincipalName', 'CanonicalName')
        ResultPageSize = 500
        ResultSetSize  = $MaxResults
        Server         = $server
        ErrorAction    = 'Stop'
    }
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    $users = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $baseNames = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $limitHit = $false
    for ($i = 0; $i -lt $bases.Count; $i++) {
        $base = [string]$bases[$i]
        Set-WorkerProgress -Percent ([int](100 * $i / [math]::Max(1, $bases.Count))) -Status ("OU'daki kullanıcılar okunuyor ({0}/{1}, {2})..." -f ($i + 1), $bases.Count, $(if ($Subtree) { 'alt OU''lar dahil' } else { 'yalnız seçilen OU' }))
        try { $baseNames.Add([string](Get-ADObject -Identity $base -Properties CanonicalName -Server $server -ErrorAction Stop).CanonicalName) }
        catch { Write-WorkerLog -Message "OU yolu okunamadı ($base): $($_.Exception.Message)" -Level Verbose }
        $remaining = $MaxResults - $users.Count
        if ($remaining -le 0) { $limitHit = $true; break }
        $parameters.SearchBase = $base
        $parameters.ResultSetSize = $remaining
        try {
            foreach ($user in @(Get-ADUser @parameters)) { if ($seen.Add($user.ObjectGUID.ToString())) { $users.Add($user) } }
        }
        catch { Write-WorkerLog -Message "OU okunamadı ($base): $($_.Exception.Message)" -Level Warning }
        if ($users.Count -ge $MaxResults) { $limitHit = $true }
    }
    if ($limitHit) {
        Write-WorkerLog -Message "İlk $MaxResults kullanıcı gösteriliyor; daha az veya daha alt OU seçin." -Level Warning
    }
    $baseList = @($baseNames | Sort-Object -Property Length -Descending)
    foreach ($user in ($users | Sort-Object -Property DisplayName, SamAccountName)) {
        $upn = [string]$user.UserPrincipalName
        $location = ''
        $canonical = [string]$user.CanonicalName
        $parent = if ($canonical.LastIndexOf('/') -gt 0) { $canonical.Substring(0, $canonical.LastIndexOf('/')) } else { '' }
        $owner = $baseList | Where-Object { $parent -eq $_ -or $parent.StartsWith("$_/", [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($bases.Count -gt 1 -and $owner) { $location = $owner.Split('/')[-1] + $parent.Substring($owner.Length) }
        elseif ($owner -and $parent.Length -gt $owner.Length) { $location = $parent.Substring($owner.Length + 1) }
        $parts = @()
        if (-not $user.Enabled) { $parts += 'Devre dışı' }
        if ($location) { $parts += $location }
        $parts += $upn
        [pscustomobject]@{
            DisplayName       = if ($user.DisplayName) { [string]$user.DisplayName } else { [string]$user.Name }
            SamAccountName    = [string]$user.SamAccountName
            UserPrincipalName = $upn
            Enabled           = [bool]$user.Enabled
            StatusText        = ($parts | Where-Object { $_ }) -join ' | '
            ObjectGuid        = $user.ObjectGUID.ToString()
        }
    }
}
function global:Get-OrganizationalUnitList {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    Set-WorkerProgress -Status 'Organizational Unit listesi okunuyor...'
    $list = @(Get-ADOrganizationalUnit -Filter * -Properties CanonicalName -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ DistinguishedName = [string]$_.DistinguishedName; CanonicalName = [string]$_.CanonicalName }
        })
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        $users = Get-ADObject -Identity $domain.UsersContainer -Properties CanonicalName -ErrorAction Stop
        $list += [pscustomobject]@{ DistinguishedName = [string]$users.DistinguishedName; CanonicalName = [string]$users.CanonicalName }
    }
    catch { Write-WorkerLog -Message "Users kapsayıcısı okunamadı: $($_.Exception.Message)" -Level Verbose }
    return ($list | Sort-Object -Property CanonicalName)
}
function global:Get-PdcEmulator {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $Sync.Pdc) { $Sync.Pdc = [string](Get-ADDomain -ErrorAction Stop).PDCEmulator }
    if ($global:PSDefaultParameterValues['*-AD*:Server'] -ne $Sync.Pdc) { $global:PSDefaultParameterValues['*-AD*:Server'] = $Sync.Pdc }
    $Sync.DefaultDc = $Sync.Pdc
    return $Sync.Pdc
}
function global:Get-ParentDn {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$DistinguishedName)
    if ($DistinguishedName -match '^(?:\\.|[^,])+,(.+)$') { return $Matches[1] }
    return ''
}
function global:Get-DisabledUsersOu {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $Sync.DisabledUsersOu) { $Sync.DisabledUsersOu = 'OU=DisabledUsers,' + [string](Get-ADDomain -ErrorAction Stop).DistinguishedName }
    return $Sync.DisabledUsersOu
}
function global:Get-StoredDisableInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowEmptyString()][string]$Value)
    $info = @{ PreviousOu = ''; By = ''; At = $null }
    $prefix = 'ADEUM-PreviousOU='
    if (-not $Value -or -not $Value.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $info }
    $parts = $Value.Substring($prefix.Length).Split('|')
    $info.PreviousOu = $parts[0]
    foreach ($part in @($parts | Select-Object -Skip 1)) {
        if ($part -match '^By=(.*)$') { $info.By = $Matches[1] }
        elseif ($part -match '^At=(.*)$') {
            $parsed = [datetime]::MinValue
            $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
            if ([datetime]::TryParse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { $info.At = $parsed.ToLocalTime() }
        }
    }
    return $info
}
function global:Get-StoredPreviousOu {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$Value)
    return [string](Get-StoredDisableInfo -Value $Value).PreviousOu
}
