function global:Get-UserReport {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$SearchBase,
        [Parameter()][bool]$Subtree = $true,
        [Parameter()][ValidateSet('All', 'Enabled', 'Disabled')][string]$Status = 'All',
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$Fields,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter()][ValidateRange(1, 200000)][int]$MaxResults = 50000
    )
    $server = Get-PdcEmulator
    $leaveAttribute = [string]$Sync.LeaveAttribute
    $legacy = [string]$Sync.LegacyLeaveEndAttribute
    $propertyMap = @{
        DisplayName = 'DisplayName'; GivenName = 'GivenName'; Surname = 'Surname'; EmailAddress = 'mail'; ProxyAddresses = 'proxyAddresses'
        Department = 'Department'; Title = 'Title'; Company = 'Company'; Office = 'physicalDeliveryOfficeName'; Manager = 'manager'
        EmployeeID = 'employeeID'; MobilePhone = 'mobile'; OfficePhone = 'telephoneNumber'; City = 'l'; Description = 'Description'
        LockedOut = 'LockedOut'; PasswordNeverExpires = 'PasswordNeverExpires'; PasswordExpired = 'PasswordExpired'; PasswordLastSet = 'PasswordLastSet'
        LastLogonDate = 'LastLogonDate'; AccountExpirationDate = 'AccountExpirationDate'; WhenCreated = 'whenCreated'; WhenChanged = 'whenChanged'
        Ou = 'CanonicalName'; MemberOf = 'memberOf'
    }
    $properties = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Fields) { if ($propertyMap.ContainsKey($key)) { [void]$properties.Add($propertyMap[$key]) } }
    if ($Fields -contains 'Leave' -and $leaveAttribute) { [void]$properties.Add($leaveAttribute); if ($legacy) { [void]$properties.Add($legacy) } }
    $filter = switch ($Status) {
        'Enabled' { '(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))' }
        'Disabled' { '(&(objectCategory=person)(objectClass=user)(userAccountControl:1.2.840.113556.1.4.803:=2))' }
        default { '(&(objectCategory=person)(objectClass=user))' }
    }
    $parameters = @{ LDAPFilter = $filter; SearchScope = $(if ($Subtree) { 'Subtree' } else { 'OneLevel' }); ResultPageSize = 500; Server = $server; ErrorAction = 'Stop' }
    if ($properties.Count -gt 0) { $parameters.Properties = [string[]]@($properties) }
    $bases = @($SearchBase | Where-Object { $_ } | Select-Object -Unique)
    Write-WorkerLog -Message "Rapor: $($bases.Count) OU, durum: $Status, alanlar: $($Fields -join ', ')" -Level Verbose
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    $users = New-Object -TypeName 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $bases.Count; $i++) {
        Set-WorkerProgress -Percent ([int](70 * $i / [math]::Max(1, $bases.Count))) -Status ("Rapor için kullanıcılar okunuyor (OU {0}/{1})..." -f ($i + 1), $bases.Count)
        $remaining = $MaxResults - $users.Count
        if ($remaining -le 0) { break }
        $parameters.SearchBase = [string]$bases[$i]
        $parameters.ResultSetSize = $remaining
        try { foreach ($user in @(Get-ADUser @parameters)) { if ($seen.Add($user.ObjectGUID.ToString())) { $users.Add($user) } } }
        catch { Write-WorkerLog -Message "OU okunamadı ($($bases[$i])): $($_.Exception.Message)" -Level Warning }
    }
    if ($users.Count -ge $MaxResults) { Write-WorkerLog -Message "Rapor ilk $MaxResults kullanıcıyla sınırlandı." -Level Warning }
    $culture = [System.Globalization.CultureInfo]::GetCultureInfo('tr-TR')
    $formatDate = { param($Value) if ($null -eq $Value -or ($Value -is [datetime] -and $Value.Year -lt 1601)) { '' } else { ([datetime]$Value).ToString('dd.MM.yyyy HH:mm', $culture) } }
    $formatBool = { param($Value) if ($null -eq $Value) { '' } elseif ([bool]$Value) { 'Evet' } else { 'Hayır' } }
    $cnOf = { param($Dn) if (-not $Dn) { '' } else { ((([string]$Dn) -split '(?<!\\),', 2)[0] -replace '^CN=', '') -replace '\\(.)', '$1' } }
    $now = Get-Date
    $total = [math]::Max(1, $users.Count)
    $index = 0
    foreach ($user in ($users | Sort-Object -Property @{ Expression = { if ($_.DisplayName) { $_.DisplayName } else { $_.Name } } }, SamAccountName)) {
        $index++
        if ($index % 250 -eq 0) { Set-WorkerProgress -Percent (70 + [int](30 * $index / $total)) -Status "Rapor hazırlanıyor ($index/$($users.Count))..." }
        $row = [ordered]@{}
        foreach ($key in $Fields) {
            $value = switch ($key) {
                'SamAccountName' { [string]$user.SamAccountName }
                'UserPrincipalName' { [string]$user.UserPrincipalName }
                'DistinguishedName' { [string]$user.DistinguishedName }
                'Enabled' { & $formatBool $user.Enabled }
                'DisplayName' { if ($user.DisplayName) { [string]$user.DisplayName } else { [string]$user.Name } }
                'EmailAddress' { [string]$user.mail }
                'Office' { [string]$user.physicalDeliveryOfficeName }
                'EmployeeID' { [string]$user.employeeID }
                'MobilePhone' { [string]$user.mobile }
                'OfficePhone' { [string]$user.telephoneNumber }
                'City' { [string]$user.l }
                'Manager' { & $cnOf $user.manager }
                'ProxyAddresses' { (@($user.proxyAddresses | Where-Object { [string]$_ -like 'smtp:*' } | ForEach-Object { ([string]$_).Substring(5) }) | Sort-Object) -join ' | ' }
                'MemberOf' { (@($user.memberOf | ForEach-Object { & $cnOf $_ }) | Sort-Object) -join ' | ' }
                'Ou' { $cn = [string]$user.CanonicalName; if ($cn.LastIndexOf('/') -gt 0) { $cn.Substring(0, $cn.LastIndexOf('/')) } else { $cn } }
                { $_ -in @('LockedOut', 'PasswordNeverExpires', 'PasswordExpired') } { & $formatBool $user.$key }
                { $_ -in @('PasswordLastSet', 'LastLogonDate', 'AccountExpirationDate') } { & $formatDate $user.$key }
                'WhenCreated' { & $formatDate $user.whenCreated }
                'WhenChanged' { & $formatDate $user.whenChanged }
                'Leave' {
                    if (-not $leaveAttribute) { '' }
                    else {
                        $record = ConvertFrom-LeaveValue -Value ([string]$user.$leaveAttribute) -LegacyEnd $(if ($legacy) { [string]$user.$legacy } else { '' })
                        $text = (@($record.Periods | Where-Object { $_ -and $_.Until -gt $now } | ForEach-Object { '{0} - {1}' -f $_.Start.ToString('dd.MM.yyyy HH:mm', $culture), $_.Until.ToString('dd.MM.yyyy HH:mm', $culture) })) -join ' | '
                        if ($record.Problem) { $text = (@($text, "Hatalı kayıt: $($record.Problem)") | Where-Object { $_ }) -join ' | ' }
                        $text
                    }
                }
                default { [string]$user.$key }
            }
            $header = if ($Headers.ContainsKey($key)) { [string]$Headers[$key] } else { $key }
            $row[$header] = [string]$value
        }
        [pscustomobject]$row
    }
    Write-WorkerLog -Message "Rapor hazır: $($users.Count) kullanıcı, $($Fields.Count) alan" -Level Info
}
function global:Get-DashboardSummary {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][ValidateRange(1, 90)][int]$ExpiryDays = 7,
        [Parameter()][ValidateRange(1, 1000)][int]$MaxItems = 200
    )
    $server = Get-PdcEmulator
    $now = Get-Date
    $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $userFilter = '(objectCategory=person)(objectClass=user)'
    $disabledBit = '(userAccountControl:1.2.840.113556.1.4.803:=2)'
    $neverExpiresBit = '(userAccountControl:1.2.840.113556.1.4.803:=65536)'
    $nameOf = { param($User) if ($User.DisplayName) { [string]$User.DisplayName } else { [string]$User.Name } }

    Set-WorkerProgress -Percent 5 -Status 'Kilitli hesaplar okunuyor (PDC)...'
    $locked = @()
    try {
        # LockedOut, kilit süresi dolmuş hesapları ayıklar; lockoutTime tek başına yeterli değil.
        $locked = @(Get-ADUser -LDAPFilter "(&$userFilter(lockoutTime>=1))" -Properties DisplayName, LockedOut, lockoutTime -Server $server -ResultPageSize 500 -ErrorAction Stop |
                Where-Object { $_.LockedOut } | ForEach-Object {
                    $at = if ([long]$_.lockoutTime -gt 0) { [datetime]::FromFileTime([long]$_.lockoutTime) } else { $null }
                    [pscustomobject]@{ ObjectGuid = $_.ObjectGUID.ToString(); Name = & $nameOf $_; SamAccountName = [string]$_.SamAccountName; At = $at; DetailText = $(if ($at) { $at.ToString('dd.MM.yyyy HH:mm') } else { '' }) }
                } | Sort-Object -Property At -Descending)
    }
    catch { $errors.Add("Kilitli hesaplar okunamadı: $($_.Exception.Message)") }

    Set-WorkerProgress -Percent 35 -Status "Parolası $ExpiryDays gün içinde dolacaklar okunuyor..."
    $expiring = @()
    try {
        $limit = $now.AddDays($ExpiryDays)
        $expiring = @(Get-ADUser -LDAPFilter "(&$userFilter(!$disabledBit)(!$neverExpiresBit)(pwdLastSet>=1))" -Properties DisplayName, 'msDS-UserPasswordExpiryTimeComputed' -Server $server -ResultPageSize 500 -ErrorAction Stop | ForEach-Object {
                $computed = [long]$_.'msDS-UserPasswordExpiryTimeComputed'
                if ($computed -le 0 -or $computed -eq [long]::MaxValue) { return }
                $expiry = [datetime]::FromFileTime($computed)
                if ($expiry -lt $now -or $expiry -gt $limit) { return }
                $days = [int][math]::Floor(($expiry - $now).TotalDays)
                [pscustomobject]@{ ObjectGuid = $_.ObjectGUID.ToString(); Name = & $nameOf $_; SamAccountName = [string]$_.SamAccountName; At = $expiry; DetailText = $(if ($days -eq 0) { "Bugün $($expiry.ToString('HH:mm'))" } else { "$days gün ($($expiry.ToString('dd.MM.yyyy')))" }) }
            } | Sort-Object -Property At)
    }
    catch { $errors.Add("Parola bitişleri okunamadı: $($_.Exception.Message)") }

    Set-WorkerProgress -Percent 70 -Status 'Devre dışı kullanıcılar sayılıyor...'
    $disabled = $null
    try { $disabled = Get-DisabledUserList -SkipEventLog }
    catch { $errors.Add("Devre dışı kullanıcılar okunamadı: $($_.Exception.Message)") }
    $disabledUsers = if ($disabled) { @($disabled.Users) } else { @() }
    Set-WorkerProgress -Percent 100 -Status 'Ana sayfa özeti hazır.'
    return [pscustomobject]@{
        At              = $now
        ExpiryDays      = $ExpiryDays
        LockedCount     = $locked.Count
        Locked          = @($locked | Select-Object -First $MaxItems)
        ExpiringCount   = $expiring.Count
        Expiring        = @($expiring | Select-Object -First $MaxItems)
        DisabledCount   = $(if ($disabled) { $disabledUsers.Count } else { $null })
        DisabledOverdue = @($disabledUsers | Where-Object { $_.Overdue }).Count
        DisabledUnknown = @($disabledUsers | Where-Object { -not $_.DisabledAt }).Count
        Errors          = $errors.ToArray()
    }
}
function global:Get-InactiveUserList {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$SearchBase,
        [Parameter()][ValidateRange(1, 5000)][int]$MaxItems = 500
    )
    $server = Get-PdcEmulator
    $now = Get-Date
    $cutoff = $now.AddMonths(-1)
    # lastLogonTimestamp DC'ler arası çoğaltılır (~14 gün gecikme); 1 aylık eşik için yeterli, lastLogon gibi her DC'yi sorgulamaz.
    $cutoffFileTime = $cutoff.ToFileTimeUtc()
    $createdBefore = $cutoff.ToUniversalTime().ToString('yyyyMMddHHmmss.0Z')
    $filter = "(&(objectCategory=person)(objectClass=user)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(|(lastLogonTimestamp<=$cutoffFileTime)(&(!(lastLogonTimestamp=*))(whenCreated<=$createdBefore))))"
    $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    $rows = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $bases = @($SearchBase | Where-Object { $_ } | Select-Object -Unique)
    for ($i = 0; $i -lt $bases.Count; $i++) {
        Set-WorkerProgress -Percent ([int](100 * $i / $bases.Count)) -Status ("Uzun süredir oturum açmayanlar okunuyor (OU {0}/{1})..." -f ($i + 1), $bases.Count)
        try {
            foreach ($user in @(Get-ADUser -LDAPFilter $filter -SearchBase ([string]$bases[$i]) -SearchScope Subtree -Properties DisplayName, lastLogonTimestamp, whenCreated -Server $server -ResultPageSize 500 -ErrorAction Stop)) {
                if (-not $seen.Add($user.ObjectGUID.ToString())) { continue }
                $last = if ([long]$user.lastLogonTimestamp -gt 0) { [datetime]::FromFileTime([long]$user.lastLogonTimestamp) } else { $null }
                $name = if ($user.DisplayName) { [string]$user.DisplayName } else { [string]$user.Name }
                $detail = if ($last) { "$([int][math]::Floor(($now - $last).TotalDays)) gün ($($last.ToString('dd.MM.yyyy')))" } else { 'Hiç oturum açmadı' }
                $rows.Add([pscustomobject]@{ ObjectGuid = $user.ObjectGUID.ToString(); Name = $name; SamAccountName = [string]$user.SamAccountName; At = $last; DetailText = $detail })
            }
        }
        catch { $errors.Add("OU okunamadı ($($bases[$i])): $($_.Exception.Message)") }
    }
    # Hiç oturum açmayanlar (At = null) en üstte, ardından en eski oturum.
    $sorted = @($rows | Sort-Object -Property @{ Expression = { if ($_.At) { $_.At } else { [datetime]::MinValue } } }, Name)
    Set-WorkerProgress -Percent 100 -Status 'Uzun süredir oturum açmayanlar hazır.'
    return [pscustomobject]@{
        At     = $now
        Count  = $sorted.Count
        Users  = @($sorted | Select-Object -First $MaxItems)
        Errors = $errors.ToArray()
    }
}
