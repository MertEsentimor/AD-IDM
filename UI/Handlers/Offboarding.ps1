function Reset-DisableOption {
    [CmdletBinding()]
    param()
    $ui = $script:Ui
    $ui.chkDisableGroups.IsChecked = $false
    $ui.chkDisablePst.IsChecked = $false
    $ui.chkPstRemoveMailbox.IsChecked = $true
    $ui.chkPstExportRemoveMailbox.IsChecked = $false
    $sam = if ($script:State.CurrentData) { [string]$script:State.CurrentData.Ad.SamAccountName } else { '' }
    $ui.txtPstFileName.Text = if ($sam) { '{0}_{1}.pst' -f $sam, (Get-Date).ToString('yyyyMMdd') } else { '' }
    $ui.txtPstExportName.Text = $ui.txtPstFileName.Text
    if (-not ([string]$ui.txtPstFolder.Text).Trim() -or -not ([string]$ui.txtPstExportFolder.Text).Trim()) {
        $setting = Read-AppSetting
        if ($setting -and $setting.PSObject.Properties['PstFolder']) {
            if (-not ([string]$ui.txtPstFolder.Text).Trim()) { $ui.txtPstFolder.Text = [string]$setting.PstFolder }
            if (-not ([string]$ui.txtPstExportFolder.Text).Trim()) { $ui.txtPstExportFolder.Text = [string]$setting.PstFolder }
        }
    }
}
function Get-DisableCleanup {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $ui = $script:Ui
    $result = @{}
    if ([bool]$ui.chkDisableGroups.IsChecked) { $result.RemoveGroups = $true }
    if ([bool]$ui.chkDisablePst.IsChecked -and $ui.chkDisablePst.IsEnabled) {
        $folder = ([string]$ui.txtPstFolder.Text).Trim().TrimEnd('\')
        $name = ([string]$ui.txtPstFileName.Text).Trim()
        if ($name -and $name -notmatch '(?i)\.pst$') { $name += '.pst' }
        $result.Pst = @{ Folder = $folder; FileName = $name; FilePath = $(if ($folder -and $name) { "$folder\$name" } else { '' }); RemoveMailbox = [bool]$ui.chkPstRemoveMailbox.IsChecked }
    }
    return $result
}
function Get-DisableGroupPreview {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@($script:State.GroupList | Where-Object { $_.State -ne 'Added' -and -not $_.Group.IsPrimary } | ForEach-Object { [string]$_.Group.Name } | Sort-Object)
}
function Update-DisableOptionView {
    [CmdletBinding()]
    param()
    $ui = $script:Ui
    $data = $script:State.CurrentData
    $show = $data -and $script:State.OriginalFlags -and [bool]$script:State.OriginalFlags.Enabled -and -not [bool]$ui.chkAccountEnabled.IsChecked
    $ui.bdDisableOptions.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
    if (-not $show) { return }
    $groups = Get-DisableGroupPreview
    $primary = @($script:State.GroupList | Where-Object { $_.Group.IsPrimary } | ForEach-Object { [string]$_.Group.Name }) | Select-Object -First 1
    $ui.txtDisableGroupsInfo.Text = if ($groups.Count -eq 0) { "Domain Users dışında grup üyeliği yok$(if ($primary) { " (birincil grup: $primary)" })." }
    else {
        $list = if ($groups.Count -gt 8) { (($groups | Select-Object -First 8) -join ', ') + " ve $($groups.Count - 8) grup daha" } else { $groups -join ', ' }
        "$($groups.Count) grup: $list. Çıkarılan grupların listesi Logs\RemovedGroups klasörüne kaydedilir."
    }
    $exchange = $data.Exchange
    $reason = if (-not $exchange -or -not $exchange.HasMailbox) { 'Kullanıcının posta kutusu yok.' }
    elseif ($exchange.AddressSource -ne 'Mailbox') { 'Posta kutusu şirket içi Exchange''te değil; PST dışa aktarma yalnızca şirket içi posta kutularında yapılabilir.' }
    elseif ($script:Sync.ExchangeMode -ne 'OnPremises') { 'Exchange On-Premises bağlantısı yok.' }
    elseif (-not $script:Sync.PstExportReady) { "Bağlanılan hesabın PST dışa aktarma yetkisi yok: Exchange'de 'Mailbox Import Export' rolü atanmalı, ardından yeniden bağlanın." }
    else { $null }
    $ui.chkDisablePst.IsEnabled = -not $reason
    if ($reason) { $ui.chkDisablePst.IsChecked = $false }
    $pst = [bool]$ui.chkDisablePst.IsChecked
    $ui.pnlDisablePst.Visibility = if ($pst) { 'Visible' } else { 'Collapsed' }
    $archive = $exchange -and $exchange.Archive -and $exchange.Archive.Enabled
    $ui.txtDisablePstInfo.Text = if ($reason) { $reason }
    else { "Posta kutusu$(if ($archive) { ' ve arşivi' }) Exchange tarafından belirttiğiniz paylaşıma PST olarak yazılır. İlerleme durum çubuğunda ve 'PST Dışa Aktarmaları' penceresinde izlenir." }
    if ($pst) {
        $cleanup = Get-DisableCleanup
        $path = $cleanup.Pst.FilePath
        $ui.txtPstPreview.Text = if (-not $path) { 'Klasör ve dosya adını girin.' }
        else {
            "Dosya: $path$(if ($archive) { "  +  arşiv: $($path -replace '(?i)\.pst$', '_Arsiv.pst')" })`n" +
            $(if ($cleanup.Pst.RemoveMailbox) { "Dışa aktarma tamamlanıp dosya doğrulanınca posta kutusu$(if ($archive) { ' ve arşivi' }) silinir (Disable-Mailbox; AD hesabı kalır, posta kutusu veritabanının saklama süresi boyunca geri bağlanabilir)." }
            else { 'Posta kutusu silinmez.' })
        }
    }
}
function Add-DisableCleanupChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cleanup,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Summary,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Audit
    )
    if ($Cleanup.RemoveGroups) {
        $groups = Get-DisableGroupPreview
        $Summary.Add("Grup  |  Domain Users dışındaki tüm gruplardan çıkarılacak ($($groups.Count) grup)")
        $Audit.Add(@{ Step = 'GroupCleanup'; Action = 'user.group.clear'; Category = 'group'; Field = 'memberOf'; Label = 'Domain Users dışındaki gruplar'; Operation = 'remove'; Old = ($groups -join '; '); New = 'Domain Users' })
    }
    if ($Cleanup.Pst) {
        $Summary.Add("Exchange  |  Posta kutusu PST'ye aktarılacak: $($Cleanup.Pst.FilePath)$(if ($Cleanup.Pst.RemoveMailbox) { '; tamamlanınca posta kutusu silinecek' })")
        $Audit.Add(@{ Step = 'PstExport'; Action = 'mailbox.pst.export'; Category = 'mailbox'; Field = 'PST'; Label = $(if ($Cleanup.Pst.RemoveMailbox) { 'PST + posta kutusunu sil' } else { 'PST' }); Operation = 'export'; Old = ''; New = $Cleanup.Pst.FilePath })
    }
}
function Test-DisableCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cleanup,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Warnings
    )
    if (-not $Cleanup.Pst) { return }
    $pst = $Cleanup.Pst
    if ($script:Sync.ExchangeMode -ne 'OnPremises' -or -not $script:Sync.PstExportReady) { $Errors.Add('PST dışa aktarma için Exchange On-Premises bağlantısı ve Mailbox Import Export rolü gerekiyor.') }
    if ($pst.Folder -notmatch '^\\\\[^\\/:*?"<>|]+\\[^\\/:*?"<>|]+') { $Errors.Add("PST klasörü bir UNC paylaşımı olmalı (ör. \\dosyasunucu\PST$). Exchange dosyayı kendi sunucusundan yazar; yerel yol (C:\...) kullanılamaz.") }
    if (-not $pst.FileName -or $pst.FileName -match '[\\/:*?"<>|]') { $Errors.Add('PST dosya adı boş veya geçersiz karakter içeriyor.') }
    if ($pst.FilePath -and (Test-Path -LiteralPath $pst.FilePath -ErrorAction SilentlyContinue)) { $Errors.Add("Bu adla bir dosya zaten var: $($pst.FilePath)") }
    if ($Errors.Count -eq 0) { $Warnings.Add("PST'yi Exchange sunucusu yazar: paylaşımda 'Exchange Trusted Subsystem' grubunun okuma/yazma izni olmalı.") }
}
function Save-RemovedGroupList {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SamAccountName, [Parameter(Mandatory = $true)][string[]]$GroupDn)
    try {
        $folder = Join-Path -Path $script:AppRoot -ChildPath 'Logs\RemovedGroups'
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop }
        $path = Join-Path -Path $folder -ChildPath ('{0}_{1}.txt' -f $SamAccountName, (Get-Date).ToString('yyyyMMdd_HHmmss'))
        $lines = @("# $SamAccountName - devre dışı bırakılırken çıkarılan gruplar ($((Get-Date).ToString('dd.MM.yyyy HH:mm')), $($script:Audit.Operator))",
            "# Geri eklemek için: Get-Content '<bu dosya>' | Where-Object { `$_ -notlike '#*' } | ForEach-Object { Add-ADGroupMember -Identity `$_ -Members $SamAccountName }") + $GroupDn
        Set-Content -LiteralPath $path -Value $lines -Encoding UTF8 -ErrorAction Stop
        Write-UiLog -Message "Çıkarılan grupların listesi kaydedildi: $path" -Level Info
    }
    catch { Write-UiLog -Message "Çıkarılan grup listesi kaydedilemedi: $($_.Exception.Message)" -Level Warning }
}
function Get-RemovedGroupList {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$SamAccountName)
    $folder = Join-Path -Path $script:AppRoot -ChildPath 'Logs\RemovedGroups'
    if (-not (Test-Path -LiteralPath $folder)) { return $null }
    # Geri eklenmiş listeler .restored.txt adını alır ve bu kalıba uymaz.
    $pattern = '^{0}_\d{{8}}_\d{{6}}\.txt$' -f [regex]::Escape($SamAccountName)
    $file = Get-ChildItem -LiteralPath $folder -Filter "$($SamAccountName)_*.txt" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern } | Sort-Object -Property Name -Descending | Select-Object -First 1
    if (-not $file) { return $null }
    try { $groupDn = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction Stop | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notlike '#*' }) }
    catch { Write-UiLog -Message "Çıkarılan grup listesi okunamadı ($($file.FullName)): $($_.Exception.Message)" -Level Warning; return $null }
    if ($groupDn.Count -eq 0) { return $null }
    return [pscustomobject]@{ Path = $file.FullName; SavedAt = $file.LastWriteTime; GroupDn = $groupDn }
}
function Complete-RemovedGroupList {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    # Eski devre dışı bırakmalardan kalan listeler de kapanır; yoksa sonraki etkinleştirmede bayat gruplar önerilir.
    $samPrefix = [System.IO.Path]::GetFileName($Path) -replace '_\d{8}_\d{6}\.txt$', ''
    $pattern = '^{0}_\d{{8}}_\d{{6}}\.txt$' -f [regex]::Escape($samPrefix)
    foreach ($file in @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($Path)) -Filter "$($samPrefix)_*.txt" -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern })) {
        try {
            Rename-Item -LiteralPath $file.FullName -NewName ($file.BaseName + '.restored.txt') -ErrorAction Stop
            Write-UiLog -Message "Grup listesi geri eklendi olarak işaretlendi: $($file.FullName)" -Level Info
        }
        catch { Write-UiLog -Message "Grup listesi işaretlenemedi; sonraki etkinleştirmede yeniden önerilir: $($_.Exception.Message)" -Level Warning }
    }
}
function Start-ManualPstExport {
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data -or -not (Test-ExchangeReady)) { return }
    $exchange = $data.Exchange
    if (-not $exchange.HasMailbox -or $exchange.AddressSource -ne 'Mailbox') { [void](Show-MessageDialog -Message 'PST dışa aktarma yalnızca şirket içi Exchange posta kutularında yapılabilir.' -Icon Warning); return }
    if (-not $script:Sync.PstExportReady) { [void](Show-MessageDialog -Message "Bağlanılan hesabın PST dışa aktarma yetkisi yok. Exchange'de hesaba 'Mailbox Import Export' rolü atayın, ardından Exchange'e yeniden bağlanın:`n`nNew-ManagementRoleAssignment -Role 'Mailbox Import Export' -User '$($script:Audit.Operator)'" -Icon Warning); return }
    $folder = ([string]$script:Ui.txtPstExportFolder.Text).Trim().TrimEnd('\')
    $name = ([string]$script:Ui.txtPstExportName.Text).Trim()
    if ($name -and $name -notmatch '(?i)\.pst$') { $name += '.pst' }
    $removeMailbox = [bool]$script:Ui.chkPstExportRemoveMailbox.IsChecked
    if ($removeMailbox -and $data.Ad.Enabled) { [void](Show-MessageDialog -Message 'Hesap etkin: posta kutusu yalnızca devre dışı hesaplarda otomatik silinebilir. Seçeneği kaldırın veya hesabı önce devre dışı bırakın.' -Icon Warning); return }
    $cleanup = @{ Pst = @{ Folder = $folder; FileName = $name; FilePath = $(if ($folder -and $name) { "$folder\$name" } else { '' }); RemoveMailbox = $removeMailbox } }
    $errors = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $warnings = New-Object -TypeName 'System.Collections.Generic.List[string]'
    Test-DisableCleanup -Cleanup $cleanup -Errors $errors -Warnings $warnings
    if ($errors.Count -gt 0) { [void](Show-MessageDialog -Message ("PST dışa aktarma başlatılamadı:`n`n| " + ($errors -join "`n| ")) -Icon Warning); return }
    $path = $cleanup.Pst.FilePath
    $archive = $exchange.Archive -and $exchange.Archive.Enabled
    $message = "'$($data.Ad.SamAccountName)' posta kutusu PST'ye aktarılacak (New-MailboxExportRequest).`n`n| Dosya: $path$(if ($archive) { "`n| Arşiv: $($path -replace '(?i)\.pst$', '_Arsiv.pst')" })`n| $(if ($removeMailbox) { 'Dışa aktarma tamamlanıp PST doğrulanınca posta kutusu silinir (Disable-Mailbox; AD hesabı kalır).' } else { 'Hesap ve posta kutusu değişmez.' })`n`n$($warnings -join "`n")"
    if (-not (Show-ConfirmDialog -Message $message -Title 'PST Dışa Aktar' -Warning:$removeMailbox)) { return }
    if (-not $script:State.Options.WhatIf) { Save-AppSetting -Values @{ PstFolder = $folder } }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf; Sam = $data.Ad.SamAccountName }
    [void](Invoke-BackgroundTask -Name 'PST dışa aktarma isteği oluşturuluyor' -Command 'Start-MailboxPstExport' -Arguments (Get-ActionArgument @{ Identity = [string]$exchange.Identity; FilePath = $path; RemoveMailbox = $removeMailbox }) -OnSuccess {
            param($Result)
            if ($script:State.ActionContext.Simulate) { [void](Show-MessageDialog -Message 'PST dışa aktarma simüle edildi. Hiçbir istek oluşturulmadı.' -Icon Information); return }
            $script:State.PstScanned = $false
            $script:Ui.txtPstMonitor.Text = 'PST dışa aktarma kuyruğa alındı...'
            $script:Ui.txtPstMonitor.Visibility = 'Visible'
            $script:Ui.txtPstExportInfo.Text = "Dışa aktarma isteği oluşturuldu. İlerleme durum çubuğunda ve 'İlerlemeyi Göster' penceresinde izlenir (30 sn'de bir)."
        })
}
function Get-PstStatusText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string]$Status)
    switch ($Status) {
        'Queued' { 'Sırada' }
        'InProgress' { 'Aktarılıyor' }
        'Completed' { 'Tamamlandı' }
        'CompletedWithWarning' { 'Uyarıyla tamamlandı' }
        'Failed' { 'Başarısız' }
        'Suspended' { 'Askıya alındı' }
        'AutoSuspended' { 'Askıya alındı' }
        default { $Status }
    }
}
function Start-PstPoll {
    [CmdletBinding()]
    param([Parameter()][switch]$Force)
    $onPage = [bool]$script:Ui.navPst.IsChecked
    if ($script:Sync.ExchangeMode -ne 'OnPremises' -or (-not $script:Sync.PstExportReady -and -not $onPage)) {
        $script:State.PstScanned = $false
        $script:State.ExchangeJobs = @()
        if ($script:State.PstExports.Count -gt 0) { $script:State.PstExports = @{}; Update-PstMonitor }
        return
    }
    if ($script:TaskEngine.CurrentJob) { return }
    if (-not $Force -and $script:State.PstScanned -and $script:State.PstExports.Count -eq 0 -and -not $onPage) { return }
    # Tüm Exchange işleri yalnızca sayfa açıkken sorgulanır; arka planda sadece bu aracın PST istekleri izlenir.
    $arguments = @{ AllJobs = $onPage; IncludeFinished = [bool]$script:Ui.chkPeFinished.IsChecked }
    [void](Invoke-BackgroundTask -Name 'Exchange işleri izleme' -Command 'Get-PstExportStatus' -Arguments $arguments -Silent -OnSuccess {
            param($Result)
            Receive-PstStatus -Results $Result
        })
}
function Receive-PstStatus {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Results)
    $script:State.PstScanned = $true
    $previous = $script:State.PstExports
    $current = @{}
    $script:State.ExchangeJobs = @($Results | Where-Object { $_ -and $_.Key })
    foreach ($item in @($script:State.ExchangeJobs | Where-Object { $_.Owned })) {
        $current[[string]$item.Key] = $item
        $old = $previous[[string]$item.Key]
        $label = "$($item.Alias)$(if ($item.Archive) { ' (arşiv)' })"
        if (-not $old) {
            if (-not $item.IsFinal) { Write-UiLog -Message "PST dışa aktarma izleniyor: $label -> $($item.FilePath)" -Level Info }
        }
        elseif ($old.Status -ne $item.Status) {
            if ($item.Status -eq 'Failed') { Write-UiLog -Message "PST dışa aktarma BAŞARISIZ: $label  -  $($item.FailureMessage)" -Level Error }
            elseif ($item.IsFinal) { Write-UiLog -Message "PST dışa aktarma bitti: $label ($(Get-PstStatusText -Status $item.Status), $($item.Transferred))" -Level Success }
            else { Write-UiLog -Message "PST dışa aktarma: $label $(Get-PstStatusText -Status $item.Status) (%$($item.PercentComplete))" -Level Info }
        }
    }
    $script:State.PstExports = $current
    foreach ($group in @($current.Values | Group-Object -Property Alias)) {
        $items = @($group.Group)
        if (-not ($items | Where-Object { $_.RemoveMailbox })) { continue }
        if (@($items | Where-Object { $_.Status -ne 'Completed' }).Count -gt 0) { continue }
        $last = $script:State.PstAttempts[$group.Name]
        if ($last -and ((Get-Date) - $last.At).TotalMinutes -lt 10) { continue }
        Start-PstCompletion -Alias $group.Name -Action Remove -Automatic
        break
    }
    Update-PstMonitor
}
function Update-PstMonitor {
    [CmdletBinding()]
    param()
    $items = @($script:State.PstExports.Values)
    $active = @($items | Where-Object { -not $_.IsFinal })
    $failed = @($items | Where-Object { $_.Status -eq 'Failed' })
    $waiting = @($items | Where-Object { $_.RemoveMailbox -and $_.IsFinal -and $_.Status -ne 'Failed' })
    $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($item in ($active | Select-Object -First 3)) { $parts.Add("$($item.Alias)$(if ($item.Archive) { ' (arşiv)' }) %$($item.PercentComplete)") }
    $text = if ($active.Count -gt 0) { "PST dışa aktarılıyor ($($active.Count))  |  " + ($parts -join '  |  ') }
    elseif ($failed.Count -gt 0) { "PST dışa aktarma başarısız ($($failed.Count))" }
    elseif ($waiting.Count -gt 0) { "PST tamamlandı, posta kutusu silme bekliyor ($(@($waiting | Group-Object -Property Alias).Count))" }
    else { '' }
    $script:Ui.txtPstMonitor.Text = $text
    $script:Ui.txtPstMonitor.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
    $script:Ui.txtPstMonitor.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(if ($failed.Count -gt 0) { 'DangerBrush' } else { 'AccentTextBrush' }))
    Update-PstExportView
}
function Start-PstCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Alias,
        [Parameter(Mandatory = $true)][ValidateSet('Remove', 'Clear')][string]$Action,
        [Parameter()][switch]$AllowWarning,
        [Parameter()][switch]$Automatic
    )
    if ($script:TaskEngine.CurrentJob) {
        if (-not $Automatic) { [void](Show-MessageDialog -Message 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' -Icon Information) }
        return
    }
    $script:State.PstAttempts[$Alias] = @{ At = Get-Date; Error = $null }
    $script:State.PstActionAlias = $Alias
    $name = if ($Action -eq 'Remove') { "PST alındı, posta kutusu siliniyor: $Alias" } else { "PST isteği kaldırılıyor: $Alias" }
    [void](Invoke-BackgroundTask -Name $name -Command 'Complete-MailboxPstExport' -Arguments (Get-ActionArgument @{ Alias = $Alias; Action = $Action; AllowWarning = [bool]$AllowWarning }) -OnSuccess {
            param($Result)
            $done = @($Result | Where-Object { $_ -and $_.PSObject.Properties['MailboxRemoved'] }) | Select-Object -First 1
            if ($done -and $done.MailboxRemoved) { Write-UiLog -Message "PST dışa aktarma tamamlandı ve '$($done.Alias)' posta kutusu silindi." -Level Success }
            elseif ($done) { Write-UiLog -Message "PST isteği listeden kaldırıldı: $($done.Alias)" -Level Info }
            [void]$script:State.PstAttempts.Remove([string]$script:State.PstActionAlias)
            $script:State.PstScanned = $false
            Start-PstPoll -Force
        } -OnFailure {
            param($Message)
            $alias = [string]$script:State.PstActionAlias
            if ($script:State.PstAttempts[$alias]) { $script:State.PstAttempts[$alias].Error = $Message }
            Write-UiLog -Message "PST tamamlama yapılamadı ($alias): $Message  (10 dakika sonra tekrar denenecek)" -Level Error
            Update-PstExportView
        })
}
function Update-PstExportView {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $selectedKey = if ($c.lstPe.SelectedItem) { [string]$c.lstPe.SelectedItem.Key } else { $null }
    $showFinished = [bool]$c.chkPeFinished.IsChecked
    $rows = foreach ($item in ($script:State.ExchangeJobs | Sort-Object -Property IsFinal, JobType, Alias, Archive)) {
        if ($item.IsFinal -and -not $item.Owned -and -not $showFinished) { continue }
        $attempt = $script:State.PstAttempts[[string]$item.Alias]
        $kind = if ($item.Status -eq 'Failed') { 'Failed' } elseif ($item.IsFinal) { 'Done' } else { 'Running' }
        $isMove = $item.JobType -eq 'Move'
        $after = if ($isMove) { 'Veritabanı taşıma (Veritabanı ve Taşıma sekmesinden yönetilir)' }
        elseif (-not $item.Owned) { 'Bu araç dışında başlatıldı' }
        elseif (-not $item.RemoveMailbox) { 'Posta kutusu kalır' }
        elseif ($attempt -and $attempt.Error) { 'Silinemedi: ' + $attempt.Error }
        elseif ($item.IsFinal -and $item.Status -eq 'Completed') { 'Siliniyor...' }
        elseif ($item.Status -eq 'CompletedWithWarning') { 'Uyarı nedeniyle beklemede: kontrol edip elle silin' }
        else { 'Tamamlanınca silinecek' }
        [pscustomobject]@{
            Key          = [string]$item.Key
            Alias        = [string]$item.Alias
            TypeText     = if ($isMove) { 'Taşıma' } elseif ($item.Archive) { 'PST (arşiv)' } else { 'PST' }
            FilePath     = [string]$item.FilePath
            StatusText   = $(if ($isMove) { Get-MoveStatusText -Status $item.Status } else { Get-PstStatusText -Status $item.Status }) + $(if ($item.StatusDetail -and -not $item.IsFinal) { " ($($item.StatusDetail))" } else { '' }) + $(if ($item.FailureMessage) { ": $($item.FailureMessage)" } else { '' })
            Percent      = [double]$item.PercentComplete
            SizeText     = "$($item.Transferred) / $($item.Estimated)"
            AfterText    = $after
            Kind         = $kind
            Status       = [string]$item.Status
            RemoveMailbox = [bool]$item.RemoveMailbox
            Owned        = [bool]$item.Owned
            JobSpec      = '{0}|{1}|{2}|{3}' -f $item.JobType, $item.RequestId, $item.RequestGuid, $item.RequestQueue
        }
    }
    $rows = @($rows)
    $c.lstPe.ItemsSource = $rows
    if ($selectedKey) { $c.lstPe.SelectedItem = $rows | Where-Object { $_.Key -eq $selectedKey } | Select-Object -First 1 }
    $c.txtPeEmpty.Visibility = if ($rows.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $c.txtPeSummary.Text = if ($script:Sync.ExchangeMode -ne 'OnPremises') { 'Exchange On-Premises bağlantısı gerekiyor.' }
    else { "$(if (-not $script:Sync.PstExportReady) { 'PST istekleri görünmüyor (Mailbox Import Export rolü yok)  |  ' })$($rows.Count) iş  |  $(@($rows | Where-Object { $_.Kind -eq 'Running' }).Count) sürüyor  |  30 saniyede bir yenilenir  |  son kontrol $((Get-Date).ToString('HH:mm:ss'))" }
}
function Start-DisabledUserLoad {
    [CmdletBinding()]
    param()
    $script:Ui.txtDuSummary.Text = 'Liste okunuyor (DC güvenlik günlükleri taranıyor olabilir)...'
    $started = Invoke-BackgroundTask -Name 'Devre dışı kullanıcılar okunuyor' -Command 'Get-DisabledUserList' -OnSuccess {
        param($Result)
        $script:State.DisabledOu = [string]$Result.Ou
        $script:State.DisabledList = @($Result.Users | Where-Object { $_ })
        Update-DisabledUserView
        if ($script:State.DisabledReplicate) {
            $script:State.DisabledReplicate = $false
            Start-AdReplication
        }
    } -OnFailure {
        param($Message)
        $script:Ui.txtDuSummary.Text = "Liste okunamadı: $Message"
    }
    if (-not $started) { $script:Ui.txtDuSummary.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' }
}
function Update-DisabledUserView {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $filter = ([string]$c.txtDuFilter.Text).Trim()
    $overdueOnly = [bool]$c.chkDuOverdue.IsChecked
    $all = @($script:State.DisabledList)
    $comparison = [System.StringComparison]::CurrentCultureIgnoreCase
    $items = @($all | Where-Object {
            (-not $overdueOnly -or $_.Overdue) -and (-not $filter -or ("$($_.Name) $($_.SamAccountName) $($_.ByText)").IndexOf($filter, $comparison) -ge 0)
        })
    $c.lstDu.ItemsSource = $items
    $c.txtDuOu.Text = $script:State.DisabledOu
    $overdue = @($all | Where-Object { $_.Overdue }).Count
    $c.txtDuSummary.Text = "$($all.Count) devre dışı kullanıcı; $overdue tanesi 1 ayı doldurdu (sarı satırlar). Gösterilen: $($items.Count)."
}
function Remove-SelectedDisabledUser {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $selected = @($c.lstDu.SelectedItems)
    if ($selected.Count -eq 0) { $c.txtDuSummary.Text = 'Silmek için listeden bir veya daha fazla kullanıcı seçin (Ctrl / Shift ile çoklu seçim).'; return }
    if ($script:TaskEngine.CurrentJob -and -not $script:TaskEngine.CurrentJob.Silent) { $c.txtDuSummary.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.'; return }
    $script:State.PendingRemoval = $selected
    $c.txtDuSummary.Text = 'Kullanıcıların cihazları okunuyor...'
    [void](Invoke-BackgroundTask -Name 'Silinecek cihazlar okunuyor' -Command 'Get-RemovalDevicePreview' -Arguments @{ ObjectGuid = [string[]]@($selected | ForEach-Object { $_.ObjectGuid }) } -OnSuccess {
            param($Result)
            Confirm-DisabledUserRemoval -Preview (@($Result | Where-Object { $_ }) | Select-Object -First 1)
        } -OnFailure {
            param($Message)
            $script:Ui.txtDuSummary.Text = "Cihazlar okunamadı, silme başlatılmadı: $Message"
        })
}
function Format-RemovalDeviceLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowEmptyCollection()][object[]]$Devices = @())
    $devices = @($Devices | Where-Object { $_ })
    $deleted = @($devices | Where-Object { -not $_.Conflict } | ForEach-Object {
            "$($_.Name) (BitLocker: $(if ($_.BitLockerCount) { "$($_.BitLockerCount) anahtar" } else { 'yok' }), LAPS: $(if ($_.LapsPresent) { 'var' } else { 'yok' }))"
        })
    $skipped = @($devices | Where-Object { $_.Conflict } | ForEach-Object { "$($_.Name) ($($_.Conflict))" })
    $lines = @()
    if ($deleted.Count) { $lines += '|     Cihazlar: ' + ($deleted -join ', ') }
    if ($skipped.Count) { $lines += '|     Atlanacak: ' + ($skipped -join ', ') }
    return $lines
}
function Format-RemovalSummary {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyCollection()][object[]]$Results = @())
    $count = @($Results | Where-Object { $_ -and $_.Success } | ForEach-Object { @($_.Devices) } | Where-Object { $_ -and $_.Success -and -not $_.Skipped }).Count
    if ($count -eq 0) { return '' }
    return ", $count cihaz silindi"
}
function Confirm-DisabledUserRemoval {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Preview)
    $c = $script:Ui
    $selected = @($script:State.PendingRemoval)
    $script:State.PendingRemoval = $null
    if ($selected.Count -eq 0) { return }
    $deviceMap = if ($Preview -and $Preview.Devices) { $Preview.Devices } else { @{} }
    $lifetime = if ($Preview -and $Preview.RecycleBin) { [int]$Preview.RecycleBin.LifetimeDays } else { 180 }
    $lines = foreach ($user in $selected) {
        "| $($user.Name) ($($user.SamAccountName))  -  devre dışı: $($user.DisabledText), $($user.DaysText)"
        Format-RemovalDeviceLine -Devices @($deviceMap[[string]$user.ObjectGuid])
    }
    $c.txtDuSummary.Text = ''
    $recent = @($selected | Where-Object { -not $_.Overdue }).Count
    $message = "$($selected.Count) kullanıcı Active Directory'den KALICI olarak silinecek (PDC üzerinde Remove-ADObject -Recursive):`n`n" + ($lines -join "`n") +
    "`n`nExchange On-Premises posta kutuları bağlantısız duruma geçer ve veritabanının silinmiş posta kutusu saklama süresi (varsayılan 30 gün) sonunda temizlenir. AD Geri Dönüşüm Kutusu etkin değilse bu işlem geri alınamaz."
    if (@($deviceMap.Values | ForEach-Object { @($_) } | Where-Object { $_ }).Count -gt 0) {
        $message += "`n`nCihazlar BitLocker ve LAPS bilgileriyle birlikte silinir. Geri Dönüşüm Kutusu'nda $lifetime gün saklanır; bu süre içinde Silinmiş Cihazlar listesinden görüntülenebilir. Bir cihaz silinemezse sahibi olan kullanıcı da silinmez."
    }
    if ($Preview -and $Preview.RecycleBin -and -not $Preview.RecycleBin.Enabled) { $message += "`n`nDİKKAT: AD Geri Dönüşüm Kutusu kapalı; hiçbir kullanıcı ve cihaz silinmeyecek." }
    if ($recent -gt 0) { $message += "`n`nDİKKAT: Seçilenlerden $recent tanesi henüz 1 ayı doldurmadı veya devre dışı bırakılma tarihi bilinmiyor." }
    if (-not (Show-ConfirmDialog -Message $message -Title "Kullanıcı Sil ($($selected.Count))" -Warning)) { return }
    $script:State.ActionContext = @{ Simulate = [bool]$script:State.Options.WhatIf }
    $arguments = Get-ActionArgument @{ ObjectGuid = [string[]]@($selected | ForEach-Object { $_.ObjectGuid }) }
    $c.txtDuSummary.Text = 'Kullanıcılar siliniyor...'
    [void](Invoke-BackgroundTask -Name "Kullanıcılar siliniyor ($($selected.Count))" -Command 'Remove-DisabledUser' -Arguments $arguments -OnSuccess {
            param($Result)
            Complete-DisabledUserRemoval -Results $Result
        } -OnFailure {
            param($Message)
            $script:Ui.txtDuSummary.Text = "Silme başarısız: $Message"
        })
}
function Complete-DisabledUserRemoval {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Results)
    $items = @($Results | Where-Object { $_ -and $_.PSObject.Properties['Success'] })
    $failed = @($items | Where-Object { -not $_.Success })
    $succeeded = @($items | Where-Object { $_.Success })
    $simulated = [bool]$script:State.ActionContext.Simulate
    $text = if ($simulated) { "Simülasyon: $($succeeded.Count) kullanıcı silinecekti; değişiklik yapılmadı." } else { "$($succeeded.Count) kullanıcı silindi$(Format-RemovalSummary -Results $succeeded)" + $(if ($failed.Count -gt 0) { ", $($failed.Count) kullanıcı silinemedi: " + (($failed | ForEach-Object { "$($_.Step) ($($_.Message))" }) -join '; ') } else { '.' }) }
    Write-UiLog -Message $text -Level $(if ($failed.Count -gt 0) { 'Warning' } elseif ($simulated) { 'Info' } else { 'Success' })
    $script:Ui.txtDuSummary.Text = $text
    if ($simulated -or $succeeded.Count -eq 0) { return }
    $script:State.DeletedDevices = $null
    $current = $script:State.CurrentData
    if ($current -and @($succeeded | ForEach-Object { $_.ObjectGuid }) -contains $current.Ad.ObjectGuid) {
        Write-UiLog -Message 'Ekranda açık olan kullanıcı silindi; gösterilen bilgiler artık geçerli değil.' -Level Warning
    }
    $script:State.DisabledReplicate = [bool]$script:State.Options.Replicate
    Start-DisabledUserLoad
}
function Open-SelectedDisabledUser {
    [CmdletBinding()]
    param()
    $item = $script:Ui.lstDu.SelectedItem
    if (-not $item) { $script:Ui.txtDuSummary.Text = 'Açmak için listeden bir kullanıcı seçin.'; return }
    if (-not (Confirm-DiscardChange)) { return }
    $script:Ui.navUsers.IsChecked = $true
    $script:Ui.txtSearch.Text = [string]$item.SamAccountName
    Start-UserLoad -ObjectGuid ([string]$item.ObjectGuid) -Force
}
function Enable-SelectedDisabledUser {
    [CmdletBinding()]
    param()
    $c = $script:Ui
    $selected = @($c.lstDu.SelectedItems)
    if ($selected.Count -ne 1) { $c.txtDuSummary.Text = 'Etkinleştirmek için listeden tek bir kullanıcı seçin.'; return }
    if ($script:TaskEngine.CurrentJob -and -not $script:TaskEngine.CurrentJob.Silent) { $c.txtDuSummary.Text = 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.'; return }
    if (-not (Confirm-DiscardChange)) { return }
    $item = $selected[0]
    $script:State.EnableAfterLoad = [string]$item.ObjectGuid
    $c.navUsers.IsChecked = $true
    $c.txtSearch.Text = [string]$item.SamAccountName
    Start-UserLoad -ObjectGuid ([string]$item.ObjectGuid) -Force
}
function Start-PendingEnable {
    # Profildeki "Etkin" değişikliğiyle aynı onay akışı: eski OU, grup geri ekleme ve uyarılar dahil.
    [CmdletBinding()]
    param()
    $data = $script:State.CurrentData
    if (-not $data) { return }
    if ($data.Ad.Enabled) { Write-UiLog -Message "'$($data.Ad.SamAccountName)' hesabı zaten etkin." -Level Info; return }
    $script:Ui.chkAccountEnabled.IsChecked = $true
    Select-MainTab -TabName 'tabAccount'
    Update-ChangeIndicator
    Start-UserUpdate
}
function Remove-SelectedExchangeJob {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Items)
    if ($script:TaskEngine.CurrentJob) { [void](Show-MessageDialog -Message 'Başka bir işlem sürüyor; biraz sonra tekrar deneyin.' -Icon Information); return }
    $lines = @($Items | Select-Object -First 15 | ForEach-Object { "| $($_.Alias)  -  $($_.TypeText)  -  $($_.StatusText)" })
    if ($Items.Count -gt 15) { $lines += "| ... ve $($Items.Count - 15) iş daha" }
    $running = @($Items | Where-Object { $_.Kind -eq 'Running' }).Count
    $message = "$($Items.Count) Exchange işi kaldırılacak (Remove-MailboxExportRequest / Remove-MoveRequest).`n`n$($lines -join "`n")`n`n$(if ($running) { "Süren $running iş iptal edilir. " })Posta kutularına ve oluşmuş PST dosyalarına dokunulmaz. Posta kutusu silinmiş işler istek GUID'i ile kaldırılır."
    if (-not (Show-ConfirmDialog -Message $message -Title 'İşleri Kaldır' -Warning)) { return }
    [void](Invoke-BackgroundTask -Name "Exchange işleri kaldırılıyor ($($Items.Count))" -Command 'Remove-ExchangeJob' -Arguments (Get-ActionArgument @{ Job = [string[]]@($Items | ForEach-Object { $_.JobSpec }) }) -OnSuccess {
            param($Result)
            $failed = @($Result | Where-Object { $_ -and $_.PSObject.Properties['Removed'] -and -not $_.Removed })
            if ($failed.Count -gt 0) { [void](Show-MessageDialog -Message ("Kaldırılamayan işler:`n`n" + (($failed | ForEach-Object { "| $($_.RequestId): $($_.Error)" }) -join "`n")) -Icon Warning) }
            $script:State.PstScanned = $false
            Start-PstPoll -Force
        })
}
function Remove-SelectedPstMailbox {
    [CmdletBinding()]
    param()
    $item = $script:Ui.lstPe.SelectedItem
    if (-not $item) { $script:Ui.txtPeSummary.Text = 'Listeden bir istek seçin.'; return }
    if (-not $item.Owned) { [void](Show-MessageDialog -Message 'Bu işlem yalnızca bu araçla başlatılan PST dışa aktarmalarında yapılabilir. Taşıma isteklerini Veritabanı ve Taşıma sekmesinden yönetin.' -Icon Information); return }
    $all = @($script:State.PstExports.Values | Where-Object { $_.Alias -eq $item.Alias })
    $notDone = @($all | Where-Object { $_.Status -notin 'Completed', 'CompletedWithWarning' })
    if ($notDone.Count -gt 0) { [void](Show-MessageDialog -Message "'$($item.Alias)' için dışa aktarma henüz tamamlanmadı; posta kutusu silinemez." -Icon Warning); return }
    $warning = @($all | Where-Object { $_.Status -eq 'CompletedWithWarning' }).Count -gt 0
    $message = "'$($item.Alias)' posta kutusu silinecek (Disable-Mailbox).`n`n| PST: $(($all | ForEach-Object { $_.FilePath }) -join ', ')`n| AD hesabı silinmez; posta kutusu veritabanının saklama süresi boyunca geri bağlanabilir.$(if ($warning) { "`n`nDışa aktarma uyarıyla tamamlandı: PST'yi açıp içeriği kontrol ettiğinizden emin olun." })"
    if (-not (Show-ConfirmDialog -Message $message -Title 'Posta Kutusunu Sil' -Warning)) { return }
    Start-PstCompletion -Alias $item.Alias -Action Remove -AllowWarning:$warning
}
function Clear-SelectedPstRequest {
    [CmdletBinding()]
    param()
    $items = @($script:Ui.lstPe.SelectedItems)
    if ($items.Count -eq 0) { $script:Ui.txtPeSummary.Text = 'Listeden bir veya daha fazla iş seçin.'; return }
    $item = $items[0]
    if (@($items | Where-Object { -not $_.Owned }).Count -gt 0) {
        if (@($items | Where-Object { $_.Owned }).Count -gt 0) { [void](Show-MessageDialog -Message 'Bu araçla başlatılan PST istekleri diğer işlerle birlikte kaldırılamaz; onları ayrı seçin.' -Icon Information); return }
        Remove-SelectedExchangeJob -Items $items
        return
    }
    if ($items.Count -gt 1) { [void](Show-MessageDialog -Message 'Bu araçla başlatılan PST isteklerini tek tek kaldırın.' -Icon Information); return }
    $message = "'$($item.Alias)' için PST dışa aktarma isteği kaldırılacak (Remove-MailboxExportRequest).`n`n| Durum: $($item.StatusText)`n| PST dosyası ve posta kutusu olduğu gibi kalır$(if ($item.Kind -eq 'Running') { '; süren aktarım iptal edilir' }).`n| Posta kutusu artık otomatik silinmez."
    if (-not (Show-ConfirmDialog -Message $message -Title 'İsteği Kaldır')) { return }
    Start-PstCompletion -Alias $item.Alias -Action Clear
}
