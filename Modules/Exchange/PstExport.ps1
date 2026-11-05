function global:Test-PstExportAvailable {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($Sync.ExchangeMode -ne 'OnPremises') { return 'Exchange On-Premises bağlantısı yok.' }
    foreach ($name in 'New-MailboxExportRequest', 'Get-MailboxExportRequest', 'Get-MailboxExportRequestStatistics', 'Remove-MailboxExportRequest') {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) { return "Bağlanılan hesapta '$name' komutu yok. Exchange'de hesaba 'Mailbox Import Export' rolü atanmalı (ör. New-ManagementRoleAssignment -Role 'Mailbox Import Export' -User <hesap>), ardından Exchange'e yeniden bağlanın." }
    }
    return ''
}
function global:Start-MailboxPstExport {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter()][bool]$RemoveMailbox = $false
    )
    $problem = Test-PstExportAvailable
    if ($problem) { throw $problem }
    if ($FilePath -notmatch '^\\\\[^\\]+\\[^\\]+\\?.*\.pst$') { throw "PST yolu \\sunucu\paylaşım\dosya.pst biçiminde bir UNC yolu olmalıdır: $FilePath" }
    $mailbox = Get-Mailbox -Identity $Identity -ErrorAction Stop
    $alias = [string]$mailbox.Alias
    $existing = @(Get-MailboxExportRequest -Mailbox $alias -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -like 'ADEUM-PST*' })
    if ($existing.Count -gt 0) { throw "Bu posta kutusu için zaten bir PST dışa aktarma isteği var ($(($existing | ForEach-Object { "$($_.Name): $($_.Status)" }) -join ', ')). 'PST Dışa Aktarmaları' penceresinden kaldırıp tekrar deneyin." }
    $base = if ($RemoveMailbox) { 'ADEUM-PST-SIL' } else { 'ADEUM-PST' }
    $jobs = @(@{ Name = $base; FilePath = $FilePath; Archive = $false })
    $archive = [string]$mailbox.ArchiveGuid -and [string]$mailbox.ArchiveGuid -ne '00000000-0000-0000-0000-000000000000' -and [string]$mailbox.ArchiveStatus -ne 'None'
    if ($archive) { $jobs += @{ Name = "$base-ARSIV"; FilePath = ($FilePath -replace '(?i)\.pst$', '_Arsiv.pst'); Archive = $true } }
    foreach ($job in $jobs) {
        $text = "New-MailboxExportRequest -Mailbox $alias -FilePath '$($job.FilePath)' -Name $($job.Name)$(if ($job.Archive) { ' -IsArchive' })"
        if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] $text" -Level Warning; continue }
        if (-not $PSCmdlet.ShouldProcess($alias, $text)) { continue }
        $params = @{ Mailbox = $alias; FilePath = $job.FilePath; Name = $job.Name; ErrorAction = 'Stop' }
        if ($job.Archive) { $params.IsArchive = $true }
        New-MailboxExportRequest @params | Out-Null
        Write-WorkerLog -Message "PST dışa aktarma isteği oluşturuldu: $($job.FilePath)$(if ($job.Archive) { ' (arşiv)' })" -Level Success
    }
    if ($RemoveMailbox -and -not $WhatIfPreference) { Write-WorkerLog -Message 'Dışa aktarma tamamlanınca posta kutusu silinecek (Disable-Mailbox). Süreç durum çubuğundan ve PST Dışa Aktarmaları penceresinden izlenebilir.' -Level Info }
    return [pscustomobject]@{ Alias = $alias; FilePath = $FilePath; Archive = [bool]$archive; RemoveMailbox = $RemoveMailbox }
}
function global:Get-PstExportStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $problem = Test-PstExportAvailable
    if ($problem) { return }
    $requests = @(Get-MailboxExportRequest -ResultSize Unlimited -ErrorAction Stop | Where-Object { [string]$_.Name -like 'ADEUM-PST*' })
    foreach ($request in $requests) {
        $stats = $null
        try { $stats = $request | Get-MailboxExportRequestStatistics -ErrorAction Stop } catch { $stats = $null }
        $status = [string]$request.Status
        $name = [string]$request.Name
        $alias = if ($stats -and $stats.SourceAlias) { [string]$stats.SourceAlias } else { ([string]$request.Mailbox -split '/')[-1] }
        [pscustomobject]@{
            Key             = "$alias\$name"
            Alias           = $alias
            Mailbox         = [string]$request.Mailbox
            Name            = $name
            Archive         = $name -like '*-ARSIV'
            RemoveMailbox   = $name -like 'ADEUM-PST-SIL*'
            FilePath        = if ($stats -and $stats.FilePath) { [string]$stats.FilePath } else { [string]$request.FilePath }
            Status          = $status
            StatusDetail    = if ($stats) { [string]$stats.StatusDetail } else { '' }
            PercentComplete = if ($stats) { [int]$stats.PercentComplete } else { 0 }
            Transferred     = if ($stats) { Format-ByteSize -Bytes (ConvertTo-ByteCount -Value $stats.BytesTransferred) } else { '-' }
            Estimated       = if ($stats) { Format-ByteSize -Bytes (ConvertTo-ByteCount -Value $stats.EstimatedTransferSize) } else { '-' }
            Queued          = if ($stats) { $stats.QueuedTimestamp } else { $null }
            Completed       = if ($stats) { $stats.CompletionTimestamp } else { $null }
            FailureMessage  = if ($stats -and $status -like 'Failed*') { [string]$stats.Message } else { '' }
            IsFinal         = $status -in @('Completed', 'CompletedWithWarning', 'Failed')
            CheckedAt       = Get-Date
        }
    }
}
function global:Complete-MailboxPstExport {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Alias,
        [Parameter(Mandatory = $true)][ValidateSet('Remove', 'Clear')][string]$Action,
        [Parameter()][bool]$AllowWarning = $false
    )
    $problem = Test-PstExportAvailable
    if ($problem) { throw $problem }
    $requests = @(Get-MailboxExportRequest -Mailbox $Alias -ErrorAction Stop | Where-Object { [string]$_.Name -like 'ADEUM-PST*' })
    $mailboxRemoved = $false
    if ($Action -eq 'Remove') {
        if ($requests.Count -eq 0) { throw "$Alias için PST dışa aktarma isteği bulunamadı; posta kutusu silinmedi." }
        $allowed = if ($AllowWarning) { @('Completed', 'CompletedWithWarning') } else { @('Completed') }
        $notDone = @($requests | Where-Object { [string]$_.Status -notin $allowed })
        if ($notDone.Count -gt 0) { throw "Dışa aktarma tamamlanmadı ($(($notDone | ForEach-Object { "$($_.Name): $($_.Status)" }) -join ', ')); posta kutusu silinmedi." }
        foreach ($request in $requests) {
            $stats = $request | Get-MailboxExportRequestStatistics -ErrorAction Stop
            $path = [string]$stats.FilePath
            $file = $null
            try { $file = Get-Item -LiteralPath $path -ErrorAction Stop } catch { $file = $null }
            if (-not $file -or $file.Length -le 0) { throw "PST dosyası bu bilgisayardan doğrulanamadı ($path); posta kutusu silinmedi. Paylaşıma okuma izni verin veya dosyayı kontrol edip 'Posta Kutusunu Sil' ile elle tamamlayın." }
            Write-WorkerLog -Message "PST doğrulandı: $path ($(Format-ByteSize -Bytes $file.Length))" -Level Info
        }
        $mailbox = Get-Mailbox -Identity $Alias -ErrorAction Stop
        if ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] Disable-Mailbox -Identity $Alias" -Level Warning; return }
        if (-not $PSCmdlet.ShouldProcess($Alias, 'Disable-Mailbox (PST dışa aktarıldı)')) { return }
        Disable-Mailbox -Identity ([string]$mailbox.DistinguishedName) -Confirm:$false -ErrorAction Stop
        $mailboxRemoved = $true
        Write-WorkerLog -Message "Posta kutusu silindi (Disable-Mailbox): $Alias. Bağlantısı kesilen posta kutusu veritabanının saklama süresi boyunca geri bağlanabilir." -Level Success
    }
    elseif ($WhatIfPreference) { Write-WorkerLog -Message "[WhatIf] Remove-MailboxExportRequest ($Alias, $($requests.Count) istek)" -Level Warning; return }
    foreach ($request in $requests) {
        if (-not $PSCmdlet.ShouldProcess("$Alias\$($request.Name)", 'Remove-MailboxExportRequest')) { continue }
        try { $request | Remove-MailboxExportRequest -Confirm:$false -ErrorAction Stop }
        catch { Write-WorkerLog -Message "Dışa aktarma isteği kaldırılamadı ($($request.Name)): $($_.Exception.Message)" -Level Warning }
    }
    return [pscustomobject]@{ Alias = $Alias; Action = $Action; MailboxRemoved = $mailboxRemoved; Requests = $requests.Count }
}
