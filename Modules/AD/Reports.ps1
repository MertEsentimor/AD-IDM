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
