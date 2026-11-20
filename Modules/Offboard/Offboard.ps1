function global:ConvertFrom-OffboardValue {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Value)
    $record = [pscustomobject]@{ Raw = ([string]$Value).Trim(); Owned = $false; Date = $null; PstFolder = ''; By = ''; PstRetry = $false; Problem = '' }
    if (-not $record.Raw.StartsWith('ADEUM-OFFBOARD', [System.StringComparison]::OrdinalIgnoreCase)) { return $record }
    $record.Owned = $true
    $parts = @($record.Raw.Split(';') | Select-Object -Skip 1 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $date = [datetime]::MinValue
    if ($parts.Count -eq 0 -or -not [datetime]::TryParseExact($parts[0], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$date)) {
        $record.Problem = "hatalı offboarding kaydı '$($record.Raw)' (beklenen ADEUM-OFFBOARD;yyyy-MM-dd;...)"
        return $record
    }
    $record.Date = $date
    foreach ($part in @($parts | Select-Object -Skip 1)) {
        if ($part -match '^(?i)PST=(.*)$') { $record.PstFolder = $Matches[1].Trim() }
        elseif ($part -match '^(?i)BY=(.*)$') { $record.By = $Matches[1].Trim() }
        elseif ($part -match '^(?i)STATE=PSTRETRY$') { $record.PstRetry = $true }
    }
    return $record
}
function global:ConvertTo-OffboardValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][datetime]$Date,
        [Parameter()][AllowEmptyString()][string]$PstFolder = '',
        [Parameter()][AllowEmptyString()][string]$By = '',
        [Parameter()][bool]$PstRetry = $false
    )
    $parts = @('ADEUM-OFFBOARD', $Date.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))
    # ';' ayraç olduğu için değerlerden çıkarılır.
    if ($PstFolder) { $parts += 'PST=' + $PstFolder.Replace(';', '').Trim().TrimEnd('\') }
    if ($By) { $parts += 'BY=' + $By.Replace(';', '').Trim() }
    if ($PstRetry) { $parts += 'STATE=PSTRETRY' }
    return $parts -join ';'
}
function global:Get-OffboardState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][psobject]$Record,
        [Parameter()][bool]$Enabled = $true,
        [Parameter()][datetime]$Date = (Get-Date)
    )
    $kind = if (-not $Record.Owned) { 'None' }
    elseif ($Record.Problem) { 'Invalid' }
    elseif ($Record.PstRetry) { if ($Enabled) { 'Invalid' } else { 'PstRetry' } }
    elseif ($Record.Date -gt $Date.Date) { 'Planned' }
    elseif ($Enabled) { 'Due' }
    else { 'AlreadyDisabled' }
    $text = switch ($kind) {
        'Invalid' { if ($Record.Problem) { "Hatalı offboarding kaydı: $($Record.Problem)" } else { 'PST yeniden deneme kaydı var ama hesap etkin; kayıt elle kontrol edilmeli' } }
        'PstRetry' { 'Hesap kapatıldı; PST dışa aktarma gece görevinde yeniden denenecek' }
        'Planned' { "Planlı offboarding: $($Record.Date.ToString('dd.MM.yyyy')) 00:00'da hesap kapatılır, gruplardan çıkarılır, PST alınır ve posta kutusu silinir" }
        'Due' { "Offboarding tarihi geldi ($($Record.Date.ToString('dd.MM.yyyy'))); gece görevi işleyecek" }
        'AlreadyDisabled' { 'Offboarding tarihi geldi ama hesap zaten kapalı; kayıt temizlenecek' }
        default { '' }
    }
    return [pscustomobject]@{ Kind = $kind; Text = $text }
}
function global:Get-OffboardCandidate {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][string]$Server)
    $attribute = $Sync.OffboardAttribute
    $parameters = @{
        LDAPFilter     = "(&(objectCategory=person)(objectClass=user)($attribute=ADEUM-OFFBOARD*))"
        Properties     = @($attribute, 'DisplayName')
        ResultPageSize = 500
        ErrorAction    = 'Stop'
    }
    if ($Server) { $parameters.Server = $Server }
    foreach ($user in @(Get-ADUser @parameters)) {
        [pscustomobject]@{
            ObjectGuid        = $user.ObjectGUID.ToString()
            Name              = if ($user.DisplayName) { [string]$user.DisplayName } else { [string]$user.Name }
            SamAccountName    = [string]$user.SamAccountName
            DistinguishedName = [string]$user.DistinguishedName
            Enabled           = [bool]$user.Enabled
            Record            = ConvertFrom-OffboardValue -Value ([string]$user.$attribute)
        }
    }
}
function global:Write-RemovedGroupFile {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [Parameter(Mandatory = $true)][string]$SamAccountName,
        [Parameter(Mandatory = $true)][string[]]$GroupDn,
        [Parameter()][string]$Operator = ''
    )
    if (-not (Test-Path -LiteralPath $Folder)) { $null = New-Item -Path $Folder -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false }
    $path = Join-Path -Path $Folder -ChildPath ('{0}_{1}.txt' -f $SamAccountName, (Get-Date).ToString('yyyyMMdd_HHmmss'))
    $lines = @("# $SamAccountName - devre dışı bırakılırken çıkarılan gruplar ($((Get-Date).ToString('dd.MM.yyyy HH:mm')), $Operator)",
        "# Geri eklemek için: Get-Content '<bu dosya>' | Where-Object { `$_ -notlike '#*' } | ForEach-Object { Add-ADGroupMember -Identity `$_ -Members $SamAccountName }") + $GroupDn
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
    return $path
}
function global:Invoke-OffboardEnforcement {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][datetime]$Date = (Get-Date),
        [Parameter(Mandatory = $true)][string]$RemovedGroupFolder,
        [Parameter()][string]$Operator = '',
        # Exchange bağlantısı yalnız işlenecek hesap varsa kurulur; bağlanamazsa $false döner.
        [Parameter()][scriptblock]$ConnectExchange = { $false }
    )
    $pdc = Get-PdcEmulator
    $attribute = $Sync.OffboardAttribute
    $users = @(Get-OffboardCandidate -Server $pdc)
    $results = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $problems = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $work = @(foreach ($user in $users) {
            $state = Get-OffboardState -Record $user.Record -Enabled $user.Enabled -Date $Date
            if ($state.Kind -eq 'Invalid') { $problems.Add("$($user.SamAccountName): $($state.Text)"); continue }
            if (@('Due', 'PstRetry', 'AlreadyDisabled') -contains $state.Kind) { [pscustomobject]@{ User = $user; Kind = $state.Kind } }
        })
    Write-WorkerLog -Message ("Offboarding kontrolü - {0} kayıt, işlenecek: {1}, hatalı: {2}." -f $users.Count, $work.Count, $problems.Count) -Level Info
    foreach ($problem in $problems) { Write-WorkerLog -Message "Hatalı offboarding kaydı atlandı: $problem" -Level Warning }
    $exchangeReady = $null
    foreach ($item in $work) {
        $user = $item.User
        $record = $user.Record
        $result = [pscustomobject]@{
            ObjectGuid = $user.ObjectGuid; Name = $user.Name; SamAccountName = $user.SamAccountName; DistinguishedName = $user.DistinguishedName
            Kind = $item.Kind; Period = $record.Date.ToString('dd.MM.yyyy'); ReturnDate = ''; OldValue = $record.Raw; NewValue = ''
            Success = $false; Message = ''; Steps = @(); AppliedAt = $null; Replicated = 0; ReplicationErrors = ''
        }
        try {
            if ($item.Kind -eq 'AlreadyDisabled') {
                if ($PSCmdlet.ShouldProcess($user.SamAccountName, "$attribute temizle (hesap zaten kapalı)")) { Set-ADUser -Identity $user.ObjectGuid -Server $pdc -Clear $attribute -ErrorAction Stop -Confirm:$false }
                $result.Success = $true
                $result.Message = 'Hesap zaten kapalıydı; offboarding planı temizlendi.'
                continue
            }
            if ($null -eq $exchangeReady) { $exchangeReady = [bool](& $ConnectExchange) }
            $pst = $null
            $pstSkip = ''
            if (-not $record.PstFolder) { $pstSkip = 'Planda PST klasörü yok' }
            elseif (-not $exchangeReady -or (Test-PstExportAvailable)) { $pstSkip = 'Exchange bağlantısı veya PST yetkisi yok' }
            else {
                $mailbox = $null
                try { $mailbox = Get-Mailbox -Identity $user.ObjectGuid -ErrorAction Stop } catch { $mailbox = $null }
                if ($mailbox) { $pst = @{ FilePath = '{0}\{1}_{2}.pst' -f $record.PstFolder.TrimEnd('\'), $user.SamAccountName, $Date.ToString('yyyyMMdd'); RemoveMailbox = $true } }
                else { $pstSkip = 'posta kutusu yok' }
            }
            if ($item.Kind -eq 'PstRetry') {
                if (-not $pst) {
                    $result.NewValue = $record.Raw
                    $result.Message = "PST yeniden denenemedi: $pstSkip."
                    if ($pstSkip -eq 'posta kutusu yok' -and $PSCmdlet.ShouldProcess($user.SamAccountName, "$attribute temizle (posta kutusu yok)")) {
                        Set-ADUser -Identity $user.ObjectGuid -Server $pdc -Clear $attribute -ErrorAction Stop -Confirm:$false
                        $result.NewValue = ''
                        $result.Success = $true
                        $result.Message = 'Posta kutusu yok; PST gerekmiyor, offboarding planı temizlendi.'
                    }
                    continue
                }
                $export = Start-MailboxPstExport -Identity $user.ObjectGuid -FilePath $pst.FilePath -RemoveMailbox $true -Confirm:$false
                if ($PSCmdlet.ShouldProcess($user.SamAccountName, "$attribute temizle")) { Set-ADUser -Identity $user.ObjectGuid -Server $pdc -Clear $attribute -ErrorAction Stop -Confirm:$false }
                $result.Success = $true
                $result.Message = "PST isteği oluşturuldu: $(if ($export) { $export.FilePath } else { $pst.FilePath }); tamamlanınca posta kutusu silinecek."
                continue
            }
            $cleanup = @{ RemoveGroups = $true }
            if ($pst) { $cleanup.Pst = $pst }
            $steps = @(Invoke-UserUpdate -ObjectGuid $user.ObjectGuid -AccountFlags @{ Enabled = $false } -DisableCleanup $cleanup -ExchangeIdentity $user.ObjectGuid -Confirm:$false)
            $result.Steps = $steps
            $disabled = @($steps | Where-Object { $_.Step -eq 'Hesap seçenekleri' -and $_.Success }).Count -gt 0
            $groupStep = @($steps | Where-Object { $_.Step -eq 'Grup temizliği' -and $_.Success -and $_.Data -and @($_.Data.RemovedDn).Count -gt 0 }) | Select-Object -First 1
            if ($groupStep -and -not $WhatIfPreference) {
                try { $null = Write-RemovedGroupFile -Folder $RemovedGroupFolder -SamAccountName $user.SamAccountName -GroupDn ([string[]]$groupStep.Data.RemovedDn) -Operator $Operator }
                catch { Write-WorkerLog -Message "$($user.SamAccountName): çıkarılan grup listesi kaydedilemedi: $($_.Exception.Message)" -Level Warning }
            }
            $failedSteps = @($steps | Where-Object { -not $_.Success })
            if (-not $disabled) {
                # Hesap kapanmadıysa plan korunur; sonraki çalışmada baştan denenir.
                $result.NewValue = $record.Raw
                $result.Message = 'Hesap devre dışı bırakılamadı: ' + (($failedSteps | ForEach-Object { "$($_.Step): $($_.Message)" }) -join '; ')
                continue
            }
            $pstFailed = $pst -and @($steps | Where-Object { $_.Step -eq 'PST dışa aktarma' -and $_.Success }).Count -eq 0
            $needsRetry = $pstFailed -or ($pstSkip -and $pstSkip -ne 'posta kutusu yok')
            $result.NewValue = if ($needsRetry) { ConvertTo-OffboardValue -Date $record.Date -PstFolder $record.PstFolder -By $record.By -PstRetry $true } else { '' }
            if ($PSCmdlet.ShouldProcess($user.SamAccountName, "$attribute güncelle")) {
                if ($result.NewValue) { Set-ADUser -Identity $user.ObjectGuid -Server $pdc -Replace @{ $attribute = $result.NewValue } -ErrorAction Stop -Confirm:$false }
                else { Set-ADUser -Identity $user.ObjectGuid -Server $pdc -Clear $attribute -ErrorAction Stop -Confirm:$false }
            }
            $result.Success = $failedSteps.Count -eq 0 -and -not $needsRetry
            $notes = @($failedSteps | ForEach-Object { "$($_.Step): $($_.Message)" })
            if ($pstSkip -and $pstSkip -ne 'posta kutusu yok') { $notes += "PST başlatılmadı ($pstSkip); sonraki çalışmada yeniden denenecek" }
            elseif ($pstFailed) { $notes += 'PST sonraki çalışmada yeniden denenecek' }
            $result.Message = if ($notes.Count -gt 0) { 'Hesap kapatıldı. ' + ($notes -join '; ') } elseif ($pst) { 'Hesap kapatıldı, gruplardan çıkarıldı, PST başlatıldı, DisabledUsers OU''suna taşındı.' } else { 'Hesap kapatıldı, gruplardan çıkarıldı, DisabledUsers OU''suna taşındı (posta kutusu yok).' }
        }
        catch {
            if (-not $result.NewValue) { $result.NewValue = $record.Raw }
            $result.Message = $_.Exception.Message
        }
        finally {
            $result.AppliedAt = [datetime]::Now
            Write-WorkerLog -Message "$($user.SamAccountName): offboarding $(if ($result.Success) { 'tamam' } else { 'SORUNLU' }) - $($result.Message)" -Level $(if ($result.Success) { 'Success' } else { 'Error' })
            $results.Add($result)
        }
    }
    return [pscustomobject]@{ Date = $Date; Server = $pdc; Users = $users.Count; Simulated = [bool]$WhatIfPreference; Problems = $problems.ToArray(); Results = $results.ToArray() }
}
function global:Complete-OffboardMailboxRemoval {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter()][System.Collections.Generic.HashSet[string]]$Reported)
    # Yalnız 'Completed': uyarılı veya başarısız dışa aktarmada posta kutusu silinmez, raporlanır.
    $jobs = @(Get-PstExportStatus | Where-Object { $_.Owned -and $_.RemoveMailbox })
    foreach ($alias in @($jobs | Select-Object -ExpandProperty Alias -Unique)) {
        $mine = @($jobs | Where-Object { $_.Alias -eq $alias })
        $statuses = @($mine | ForEach-Object { [string]$_.Status })
        if (@($statuses | Where-Object { $_ -ne 'Completed' }).Count -eq 0) {
            $outcome = [pscustomobject]@{ Alias = $alias; Removed = $false; Message = '' }
            try {
                $done = Complete-MailboxPstExport -Alias $alias -Action Remove -Confirm:$false
                $outcome.Removed = [bool]($done -and $done.MailboxRemoved)
                $outcome.Message = if ($outcome.Removed) { 'PST doğrulandı, posta kutusu silindi.' } else { 'Simülasyon' }
            }
            catch { $outcome.Message = $_.Exception.Message }
            $outcome
        }
        elseif (@($statuses | Where-Object { $_ -like 'Failed*' -or $_ -eq 'CompletedWithWarning' }).Count -gt 0 -and (-not $Reported -or $Reported.Add($alias))) {
            Write-WorkerLog -Message "$alias PST dışa aktarma sorunlu ($($statuses -join ', ')); posta kutusu silinmedi, İşler sayfasından elle kontrol edin." -Level Warning
            [pscustomobject]@{ Alias = $alias; Removed = $false; Message = "PST sorunlu ($($statuses -join ', ')); posta kutusu silinmedi." }
        }
    }
}
