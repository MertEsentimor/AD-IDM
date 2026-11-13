function global:Test-DeviceNamePattern {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Pattern)
    if (-not $Pattern) { return $null }
    if ($Pattern -notmatch '\{sam\}') { return 'Cihaz ad kuralı {sam} yer tutucusunu içermeli (ör. NB-{sam}).' }
    if ($Pattern.Contains('*')) { return 'Cihaz ad kuralı * içeremez; ekler (-2 gibi) otomatik eşleşir.' }
    return $null
}
function global:Test-DeviceNameMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$SamAccountName,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not $Pattern -or (Test-DeviceNamePattern -Pattern $Pattern)) { return $false }
    $base = [regex]::Escape($Pattern).Replace('\{sam}', [regex]::Escape($SamAccountName))
    return [regex]::IsMatch($Name, "^$base(-.+)?$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
function global:ConvertTo-DeviceNameFilter {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$SamAccountName
    )
    if (-not $Pattern) { return $null }
    $problem = Test-DeviceNamePattern -Pattern $Pattern
    if ($problem) { throw $problem }
    $name = (ConvertTo-LdapFilterValue -Value $Pattern).Replace('{sam}', (ConvertTo-LdapFilterValue -Value $SamAccountName))
    return "(&(objectClass=computer)(|(name=$name)(name=$name-*)))"
}
function global:ConvertFrom-DeviceName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not $Pattern -or (Test-DeviceNamePattern -Pattern $Pattern)) { return $null }
    $expression = '^' + [regex]::Escape($Pattern).Replace('\{sam}', '(?<sam>[^-]+)') + '(-.+)?$'
    $match = [regex]::Match($Name, $expression, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) { return $match.Groups['sam'].Value }
    return $null
}
function global:Get-DnCommonName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$DistinguishedName)
    if ($DistinguishedName -match '^CN=((?:\\.|[^,])+)') { return ($Matches[1] -replace '\\(.)', '$1') }
    return [string]$DistinguishedName
}
function global:Get-UserDevice {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$SamAccountName,
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [Parameter()][string]$Server
    )
    if (-not $Server) { $Server = Get-PdcEmulator }
    $pattern = [string]$Sync.DeviceNamePattern
    $properties = @('managedBy', 'lastLogonTimestamp', 'Enabled', 'ms-Mcs-AdmPwdExpirationTime')
    $found = [ordered]@{}
    $nameFilter = ConvertTo-DeviceNameFilter -Pattern $pattern -SamAccountName $SamAccountName
    if ($nameFilter) {
        foreach ($computer in @(Get-ADComputer -LDAPFilter $nameFilter -Properties $properties -Server $Server -ErrorAction Stop)) {
            # Sunucu sorgusu ad-* ile geniş eşleşir; kural burada kesin olarak yeniden doğrulanır.
            if (-not $computer -or -not (Test-DeviceNameMatch -Pattern $pattern -SamAccountName $SamAccountName -Name ([string]$computer.Name))) { continue }
            $found[$computer.ObjectGUID.ToString()] = @{ Computer = $computer; ByName = $true; ByOwner = $false }
        }
    }
    $ownerFilter = '(&(objectClass=computer)(managedBy={0}))' -f (ConvertTo-LdapFilterValue -Value $DistinguishedName)
    foreach ($computer in @(Get-ADComputer -LDAPFilter $ownerFilter -Properties $properties -Server $Server -ErrorAction Stop)) {
        if (-not $computer) { continue }
        $key = $computer.ObjectGUID.ToString()
        if ($found.Contains($key)) { $found[$key].ByOwner = $true }
        else { $found[$key] = @{ Computer = $computer; ByName = $false; ByOwner = $true } }
    }
    $devices = foreach ($entry in $found.Values) {
        $computer = $entry.Computer
        $dn = [string]$computer.DistinguishedName
        $managedBy = [string]$computer.managedBy
        $bitLocker = @(Get-ADObject -SearchBase $dn -SearchScope OneLevel -LDAPFilter '(objectClass=msFVE-RecoveryInformation)' -Server $Server -ErrorAction Stop | Where-Object { $_ })
        [pscustomobject]@{
            Name              = [string]$computer.Name
            DistinguishedName = $dn
            ObjectGuid        = $computer.ObjectGUID.ToString()
            Enabled           = [bool]$computer.Enabled
            Ou                = Get-ParentDn -DistinguishedName $dn
            LastLogon         = if ([long]$computer.lastLogonTimestamp -gt 0) { [datetime]::FromFileTime([long]$computer.lastLogonTimestamp) } else { $null }
            Source            = if ($entry.ByName -and $entry.ByOwner) { 'İkisi' } elseif ($entry.ByName) { 'Ad kuralı' } else { 'Elle' }
            ManagedBy         = $managedBy
            Conflict          = if ($managedBy -and -not $managedBy.Equals($DistinguishedName, [System.StringComparison]::OrdinalIgnoreCase)) { "managedBy başka kullanıcıyı gösteriyor: $(Get-DnCommonName -DistinguishedName $managedBy)" } else { $null }
            BitLockerCount    = $bitLocker.Count
            LapsPresent       = [bool]$computer.'ms-Mcs-AdmPwdExpirationTime'
        }
    }
    return @($devices | Sort-Object -Property Name)
}
function global:Get-RecycleBinState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][string]$Server)
    if (-not $Server) { $Server = Get-PdcEmulator }
    $feature = Get-ADOptionalFeature -Identity 'Recycle Bin Feature' -Server $Server -ErrorAction Stop
    $configuration = [string](Get-ADRootDSE -Server $Server -ErrorAction Stop).configurationNamingContext
    $service = Get-ADObject -Identity "CN=Directory Service,CN=Windows NT,CN=Services,$configuration" -Properties 'msDS-deletedObjectLifetime', 'tombstoneLifetime' -Server $Server -ErrorAction Stop
    $days = 180
    if ([int]$service.'msDS-deletedObjectLifetime' -gt 0) { $days = [int]$service.'msDS-deletedObjectLifetime' }
    elseif ([int]$service.tombstoneLifetime -gt 0) { $days = [int]$service.tombstoneLifetime }
    return [pscustomobject]@{ Enabled = (@($feature.EnabledScopes | Where-Object { $_ }).Count -gt 0); LifetimeDays = $days }
}
function global:Get-RemovalDevicePreview {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][string[]]$ObjectGuid)
    $server = Get-PdcEmulator
    $preview = @{}
    foreach ($guid in $ObjectGuid) {
        try {
            $user = Get-ADUser -Identity $guid -Server $server -ErrorAction Stop
            $preview[$guid] = @(Get-UserDevice -SamAccountName ([string]$user.SamAccountName) -DistinguishedName ([string]$user.DistinguishedName) -Server $server)
        }
        catch {
            $preview[$guid] = @()
            Write-WorkerLog -Message "Cihazlar okunamadı ($guid): $($_.Exception.Message)" -Level Warning
        }
    }
    return $preview
}
