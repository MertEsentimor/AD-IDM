function global:ConvertTo-GroupItem {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][object]$Group,
        [Parameter()][bool]$IsPrimary = $false
    )
    $scope = switch ([string]$Group.GroupScope) { 'DomainLocal' { 'Etki alanı yerel' } 'Global' { 'Global' } 'Universal' { 'Evrensel' } default { [string]$Group.GroupScope } }
    $category = switch ([string]$Group.GroupCategory) { 'Security' { 'Güvenlik' } 'Distribution' { 'Dağıtım' } default { [string]$Group.GroupCategory } }
    [pscustomobject]@{
        DistinguishedName = [string]$Group.DistinguishedName
        Name              = [string]$Group.Name
        SamAccountName    = [string]$Group.SamAccountName
        Description       = [string]$Group.Description
        ScopeText         = (@($scope, $category) | Where-Object { $_ }) -join ' / '
        IsPrimary         = $IsPrimary
        CanEdit           = -not $IsPrimary
    }
}
function global:Get-UserGroupMembership {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][object]$AdUser)
    $dns = @($AdUser.memberOf | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $found = @{}
    for ($i = 0; $i -lt $dns.Count; $i += 50) {
        $chunk = $dns[$i..([math]::Min($i + 49, $dns.Count - 1))]
        $filter = '(|' + (($chunk | ForEach-Object { '(distinguishedName={0})' -f (ConvertTo-LdapFilterValue -Value $_) }) -join '') + ')'
        foreach ($group in @(Get-ADGroup -LDAPFilter $filter -Properties Description -ErrorAction Stop)) {
            $found[([string]$group.DistinguishedName).ToUpperInvariant()] = $group
        }
    }
    foreach ($dn in $dns) {
        $group = $found[$dn.ToUpperInvariant()]
        if ($group) { ConvertTo-GroupItem -Group $group }
        else {
            $rdn = ($dn -split '(?<!\\),', 2)[0] -replace '^CN=', '' -replace '\\(.)', '$1'
            [pscustomobject]@{
                DistinguishedName = $dn; Name = $rdn; SamAccountName = $null; Description = $null
                ScopeText = 'Başka etki alanı (bu araçtan değiştirilemez)'; IsPrimary = $false; CanEdit = $false
            }
        }
    }
    if ($AdUser.primaryGroupID -and $AdUser.SID) {
        try {
            $sid = '{0}-{1}' -f $AdUser.SID.AccountDomainSid.Value, [int]$AdUser.primaryGroupID
            $primary = Get-ADGroup -Identity $sid -Properties Description -ErrorAction Stop
            ConvertTo-GroupItem -Group $primary -IsPrimary $true
        }
        catch { Write-WorkerLog -Message "Birincil grup okunamadı: $($_.Exception.Message)" -Level Verbose }
    }
}
function global:Find-DirectoryGroup {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Query,
        [Parameter()][ValidateRange(1, 1000)][int]$MaxResults = 100
    )
    $escaped = ConvertTo-LdapFilterValue -Value $Query.Trim()
    $filter = '(&(objectCategory=group)(|(name=*{0}*)(sAMAccountName={0}*)(displayName=*{0}*)(mail={0}*)))' -f $escaped
    Write-WorkerLog -Message "Grup araması: $filter" -Level Verbose
    Set-WorkerProgress -Status "'$Query' grubu aranıyor..."
    $groups = @(Get-ADGroup -LDAPFilter $filter -Properties Description -ResultSetSize $MaxResults -ErrorAction Stop)
    if ($groups.Count -ge $MaxResults) { Write-WorkerLog -Message "İlk $MaxResults grup gösteriliyor; aramayı daraltın." -Level Warning }
    foreach ($group in ($groups | Sort-Object -Property Name)) { ConvertTo-GroupItem -Group $group }
}
function global:Set-UserGroupMembership {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter()][AllowEmptyCollection()][string[]]$Add = @(),
        [Parameter()][AllowEmptyCollection()][string[]]$Remove = @()
    )
    if ($WhatIfPreference) {
        foreach ($group in $Add) { Write-WorkerLog -Message "[WhatIf] Add-ADGroupMember -Identity '$group' -Members $Identity" -Level Warning }
        foreach ($group in $Remove) { Write-WorkerLog -Message "[WhatIf] Remove-ADGroupMember -Identity '$group' -Members $Identity" -Level Warning }
        return
    }
    $server = Get-PdcEmulator
    $failures = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($group in $Add) {
        if (-not $PSCmdlet.ShouldProcess($group, 'Add-ADGroupMember')) { continue }
        try {
            Add-ADGroupMember -Identity $group -Members $Identity -Server $server -Confirm:$false -ErrorAction Stop
            Write-WorkerLog -Message "Gruba eklendi: $group" -Level Success
        }
        catch { $failures.Add("Eklenemedi ($group): $($_.Exception.Message)") }
    }
    foreach ($group in $Remove) {
        if (-not $PSCmdlet.ShouldProcess($group, 'Remove-ADGroupMember')) { continue }
        try {
            Remove-ADGroupMember -Identity $group -Members $Identity -Server $server -Confirm:$false -ErrorAction Stop
            Write-WorkerLog -Message "Gruptan çıkarıldı: $group" -Level Success
        }
        catch { $failures.Add("Çıkarılamadı ($group): $($_.Exception.Message)") }
    }
    if ($failures.Count -gt 0) { throw ($failures -join ' | ') }
}
function global:Clear-UserGroupMembership {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Identity)
    $server = Get-PdcEmulator
    $user = Get-ADUser -Identity $Identity -Server $server -Properties memberOf, primaryGroupID, SID -ErrorAction Stop
    $domainSid = $user.SID.AccountDomainSid.Value
    $domainUsers = Get-ADGroup -Identity "$domainSid-513" -Server $server -ErrorAction Stop
    $targets = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($dn in @($user.memberOf | Where-Object { $_ })) {
        if (-not [string]::Equals([string]$dn, [string]$domainUsers.DistinguishedName, [System.StringComparison]::OrdinalIgnoreCase)) { $targets.Add([string]$dn) }
    }
    $primaryId = [int]$user.primaryGroupID
    $oldPrimary = $null
    if ($primaryId -and $primaryId -ne 513) {
        try { $oldPrimary = Get-ADGroup -Identity "$domainSid-$primaryId" -Server $server -ErrorAction Stop } catch { $oldPrimary = $null }
    }
    $label = { param($Dn) if ([string]$Dn -match '^CN=((?:[^,\\]|\\.)+),') { $Matches[1] -replace '\\(.)', '$1' } else { [string]$Dn } }
    $removed = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $failures = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($WhatIfPreference) {
        if ($oldPrimary) { Write-WorkerLog -Message "[WhatIf] Birincil grup '$($oldPrimary.Name)' -> 'Domain Users' yapılacak ve '$($oldPrimary.Name)' grubundan çıkarılacaktı." -Level Warning }
        foreach ($dn in $targets) { Write-WorkerLog -Message "[WhatIf] Remove-ADGroupMember -Identity '$dn' -Members $Identity" -Level Warning }
        return [pscustomobject]@{ Removed = [string[]]@($targets | ForEach-Object { & $label $_ }); Failed = [string[]]@(); RemovedDn = [string[]]$targets.ToArray() }
    }
    if (-not $PSCmdlet.ShouldProcess($Identity, "Domain Users dışındaki $($targets.Count) gruptan çıkar")) { return }
    if ($oldPrimary) {
        try {
            if (@($user.memberOf) -notcontains [string]$domainUsers.DistinguishedName) {
                Add-ADGroupMember -Identity $domainUsers -Members $user.ObjectGUID -Server $server -Confirm:$false -ErrorAction Stop
            }
            Set-ADUser -Identity $user.ObjectGUID -Server $server -Replace @{ primaryGroupID = 513 } -ErrorAction Stop
            Write-WorkerLog -Message "Birincil grup 'Domain Users' yapıldı (önceki: $($oldPrimary.Name))." -Level Success
            $targets.Add([string]$oldPrimary.DistinguishedName)
        }
        catch { $failures.Add("Birincil grup değiştirilemedi ($($oldPrimary.Name)): $($_.Exception.Message)") }
    }
    foreach ($dn in $targets) {
        try {
            Remove-ADGroupMember -Identity $dn -Members $user.ObjectGUID -Server $server -Confirm:$false -ErrorAction Stop
            $removed.Add($dn)
            Write-WorkerLog -Message "Gruptan çıkarıldı: $(& $label $dn)" -Level Success
        }
        catch { $failures.Add("Çıkarılamadı ($(& $label $dn)): $($_.Exception.Message)") }
    }
    $result = [pscustomobject]@{ Removed = [string[]]@($removed | ForEach-Object { & $label $_ }); Failed = [string[]]$failures.ToArray(); RemovedDn = [string[]]$removed.ToArray() }
    if ($failures.Count -gt 0) {
        $exception = New-Object -TypeName System.InvalidOperationException -ArgumentList ("$($removed.Count) gruptan çıkarıldı, $($failures.Count) hata: " + ($failures -join ' | '))
        $exception.Data['Result'] = $result
        throw $exception
    }
    return $result
}
