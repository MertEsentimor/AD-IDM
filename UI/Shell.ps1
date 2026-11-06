function Set-BusyState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$IsBusy,
        [Parameter()][string]$Message = 'Hazır'
    )
    $script:Ui.txtStatus.Text = $Message
    if ($IsBusy) {
        $script:Ui.prgStatus.Visibility = [System.Windows.Visibility]::Visible
        $script:Ui.prgStatus.IsIndeterminate = $true
        $script:Window.Cursor = [System.Windows.Input.Cursors]::AppStarting
    }
    else {
        $script:Ui.prgStatus.Visibility = [System.Windows.Visibility]::Hidden
        $script:Ui.prgStatus.IsIndeterminate = $false
        $script:Ui.prgStatus.Value = 0
        $script:Window.ClearValue([System.Windows.FrameworkElement]::CursorProperty)
    }
    Update-ActionState
}

function Show-WorkerMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Item)
    if ($Item.Kind -eq 'Progress') {
        $script:Ui.txtStatus.Text = $Item.Message
        if ($Item.Percent -ge 0) {
            $script:Ui.prgStatus.IsIndeterminate = $false
            $script:Ui.prgStatus.Value = [math]::Min(100, [double]$Item.Percent)
        }
        else { $script:Ui.prgStatus.IsIndeterminate = $true }
    }
    else { Write-UiLog -Message $Item.Message -Level $Item.Level -Timestamp $Item.Time }
}

$script:State = @{
    CurrentData = $null; Original = @{}; OriginalFlags = @{}; Environment = $null; IsPopulating = $false; PendingCount = 0
    PreviousSelection = $null; SuppressSelection = $false; LastUpdateSimulated = $false; ActionContext = @{}; PasswordDialog = $null
    Options = @{ WhatIf = $false; Replicate = $true }; ConfirmDialog = $null; OuList = @(); OuPicker = $null; OuSearch = @{ Dn = @(); Subtree = $true }; OuSearchView = $null
    Deferred = New-Object -TypeName 'System.Collections.Generic.Queue[scriptblock]'; ReplicationReload = $null; GroupList = New-Object -TypeName 'System.Collections.Generic.List[object]'
    SmtpList = New-Object -TypeName 'System.Collections.Generic.List[string]'; SelectTabAfterLoad = $null; EnableAfterLoad = $null; PendingOu = $null
    OriginalCas = $null; OriginalSmtp = @(); OriginalPolicy = $null; CurrentMove = $null; MonitoredMoves = @{}; MailboxDatabases = @(); DbPicker = $null; LastExchangeUser = $null; NewUserDialog = $null; NewUserDraft = $null; NewUserDatabases = @()
    PstExports = @{}; PstScanned = $false; PstAttempts = @{}; PstActionAlias = $null; DisabledList = @(); DisabledOu = ''; DisabledReplicate = $false
    LeaveEdit = New-Object -TypeName 'System.Collections.Generic.List[object]'; LeaveNowCandidate = ''; LeaveEditTarget = $null; LeaveList = @(); LeaveTask = $null; LeaveApplyExecute = $false; BulkLeave = $null; Report = $null; Settings = $null; ActiveNav = 'navUsers'; ReturningToSettings = $false
}
$script:FieldMap = [ordered]@{
    GivenName         = @{ Control = 'txtGivenName'; Ldap = 'givenName'; Label = 'Ad (First Name)'; Tab = 'tabGeneral' }
    Surname           = @{ Control = 'txtSurname'; Ldap = 'sn'; Label = 'Soyad (Last Name)'; Tab = 'tabGeneral' }
    DisplayName       = @{ Control = 'txtDisplayName'; Ldap = 'displayName'; Label = 'Display Name'; Tab = 'tabGeneral' }
    Description       = @{ Control = 'txtDescription'; Ldap = 'description'; Label = 'Description'; Tab = 'tabGeneral' }
    Office            = @{ Control = 'txtOffice'; Ldap = 'physicalDeliveryOfficeName'; Label = 'Office'; Tab = 'tabGeneral' }
    EmailAddress      = @{ Control = 'txtEmail'; Ldap = 'mail'; Label = 'E-Mail'; Tab = 'tabGeneral' }
    HomePhone         = @{ Control = 'txtHomePhone'; Ldap = 'homePhone'; Label = 'Home Phone'; Tab = 'tabGeneral' }
    MobilePhone       = @{ Control = 'txtMobilePhone'; Ldap = 'mobile'; Label = 'Mobile Phone'; Tab = 'tabGeneral' }
    SamAccountName    = @{ Control = 'txtSamAccountName'; Ldap = 'sAMAccountName'; Label = 'SamAccountName'; Tab = 'tabAccount' }
    UserPrincipalName = @{ Control = 'txtUpn'; Ldap = 'userPrincipalName'; Label = 'UserPrincipalName'; Tab = 'tabAccount' }
}
$script:AccountFlagMap = [ordered]@{
    Enabled              = @{ Check = 'chkAccountEnabled'; Label = 'lblAccountEnabled'; Text = 'Hesap etkin' }
    PasswordNeverExpires = @{ Check = 'chkPwdNeverExpires'; Label = 'lblPwdNeverExpires'; Text = 'Parola süresiz (Password never expires)' }
}
$script:CasMap = [ordered]@{
    OWAEnabled        = @{ Check = 'chkOWA'; Label = 'lblOWA'; Text = 'Outlook on the web (OWA)' }
    ActiveSyncEnabled = @{ Check = 'chkActiveSync'; Label = 'lblActiveSync'; Text = 'Exchange ActiveSync' }
    ImapEnabled       = @{ Check = 'chkImap'; Label = 'lblImap'; Text = 'IMAP4' }
    PopEnabled        = @{ Check = 'chkPop'; Label = 'lblPop'; Text = 'POP3' }
    MAPIEnabled       = @{ Check = 'chkMapi'; Label = 'lblMapi'; Text = 'MAPI (Outlook masaüstü)' }
}
$script:PolicyMap = [ordered]@{
    RetentionPolicy         = @{ Combo = 'cmbPolRetention'; Label = 'lblPolRetention'; Text = 'Bekletme politikası (Retention Policy)'; AllowNone = $true }
    AddressBookPolicy       = @{ Combo = 'cmbPolAddressBook'; Label = 'lblPolAddressBook'; Text = 'Adres defteri politikası (Address Book Policy)'; AllowNone = $true }
    SharingPolicy           = @{ Combo = 'cmbPolSharing'; Label = 'lblPolSharing'; Text = 'Paylaşım politikası (Sharing Policy)'; AllowNone = $true }
    RoleAssignmentPolicy    = @{ Combo = 'cmbPolRoleAssignment'; Label = 'lblPolRoleAssignment'; Text = 'Rol atama politikası (Role Assignment Policy)'; AllowNone = $false }
    OwaMailboxPolicy        = @{ Combo = 'cmbPolOwa'; Label = 'lblPolOwa'; Text = 'OWA posta kutusu politikası'; AllowNone = $true }
    ActiveSyncMailboxPolicy = @{ Combo = 'cmbPolActiveSync'; Label = 'lblPolActiveSync'; Text = 'Mobil cihaz politikası (ActiveSync)'; AllowNone = $false }
}
$script:NewUserFieldMap = [ordered]@{
    Name = 'txtNuName'
    DisplayName = 'txtNuDisplayName'
    GivenName = 'txtNuGivenName'
    Surname = 'txtNuSurname'
    SamAccountName = 'txtNuSam'
    UserPrincipalName = 'txtNuUpn'
    EmailAddress = 'txtNuEmail'
    Office = 'txtNuOffice'
    Company = 'txtNuCompany'
    Department = 'txtNuDepartment'
    Title = 'txtNuTitle'
    Description = 'txtNuDescription'
    MobilePhone = 'txtNuMobile'
    OfficePhone = 'txtNuOfficePhone'
}
$script:NoPolicyText = '(Yok)'
$script:AutoDatabaseText = '(Otomatik: Exchange uygun veritabanını seçsin)'
$script:CredDialog = $null
$script:Pages = @{ navUsers = 'pageUsers'; navLeave = 'pageLeave'; navPst = 'pagePst'; navDisabled = 'pageDisabled'; navReports = 'pageReports'; navSettings = 'pageSettings' }
$script:TabGroups = [ordered]@{
    grpIdentity = 'tabGeneral', 'tabAccount', 'tabGroups'
    grpLeave    = @('tabLeave')
    grpMail     = 'tabAddresses', 'tabFeatures', 'tabUsage', 'tabArchive', 'tabDatabase', 'tabPolicies'
}

$script:SettingsTabGroups = [ordered]@{
    grpSetMail     = 'tabSetServer', 'tabSetOutsource', 'tabSetLeaveReport'
    grpSetSms      = 'tabSetSmsService', 'tabSetSmsPhone', 'tabSetSmsMessages'
    grpSetPassword = @('tabSetPassword')
}

function Set-SettingsTabGroup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GroupName)
    foreach ($groupKey in $script:SettingsTabGroups.Keys) {
        $tabs = @($script:SettingsTabGroups[$groupKey])
        # Tek sayfalı grupta başlık grubun adını tekrar etmesin diye sekme şeridinde gösterilmez.
        foreach ($tabName in $tabs) { $script:Ui[$tabName].Visibility = if ($groupKey -eq $GroupName -and $tabs.Count -gt 1) { 'Visible' } else { 'Collapsed' } }
    }
    $script:Ui.tabSet.SelectedItem = $script:Ui[@($script:SettingsTabGroups[$GroupName])[0]]
}

function Set-ActivePage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$NavName)
    if ($script:State.ReturningToSettings) { return }
    if ($script:State.ActiveNav -eq 'navSettings' -and $NavName -ne 'navSettings' -and -not (Test-SettingsLeave)) {
        $script:State.ReturningToSettings = $true
        $script:Ui.navSettings.IsChecked = $true
        $script:State.ReturningToSettings = $false
        return
    }
    $script:State.ActiveNav = $NavName
    foreach ($navKey in $script:Pages.Keys) {
        $script:Ui[$script:Pages[$navKey]].Visibility = if ($navKey -eq $NavName) { 'Visible' } else { 'Collapsed' }
    }
    switch ($NavName) {
        'navPst' { Start-PstPoll -Force; Update-PstExportView }
        'navDisabled' { Start-DisabledUserLoad }
        'navLeave' { Start-LeaveScheduleLoad }
        'navReports' {
            if (-not $script:State.Report) { Initialize-ReportPage }
            Sync-ReportOu
        }
        'navSettings' { Initialize-SettingsPage }
    }
}

function Set-TabGroup {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GroupName)
    foreach ($groupKey in $script:TabGroups.Keys) {
        foreach ($tabName in $script:TabGroups[$groupKey]) {
            $script:Ui[$tabName].Visibility = if ($groupKey -eq $GroupName) { 'Visible' } else { 'Collapsed' }
        }
    }
    $script:Ui.tabMain.SelectedItem = $script:Ui[@($script:TabGroups[$GroupName])[0]]
}

function Select-MainTab {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$TabName)
    foreach ($groupKey in $script:TabGroups.Keys) {
        if (@($script:TabGroups[$groupKey]) -contains $TabName) { $script:Ui[$groupKey].IsChecked = $true; break }
    }
    $script:Ui.tabMain.SelectedItem = $script:Ui[$TabName]
}

function Set-LogDrawer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Open)
    $script:Ui.bdLogDrawer.Visibility = if ($Open) { 'Visible' } else { 'Collapsed' }
    if (-not $Open) { return }
    [void]$script:Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action] {
            $count = $script:Ui.lstLog.Items.Count
            if ($count -gt 0) { $script:Ui.lstLog.ScrollIntoView($script:Ui.lstLog.Items[$count - 1]) }
        })
}

function Register-ShellEvent {
    [CmdletBinding()]
    param()
    $ui = $script:Ui
    $ui.btnSearch.Add_Click({ Invoke-UiAction { Start-UserSearch } })
    $ui.btnOuSearch.Add_Click({ Invoke-UiAction { Start-OuUserSearch } })
    $ui.txtSearch.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Return) { $e.Handled = $true; Invoke-UiAction { Start-UserSearch } }
        })
    $ui.lstResults.Add_SelectionChanged({
            param($sender, $e)
            Invoke-UiAction {
                if ($script:State.SuppressSelection) { return }
                $selected = $script:Ui.lstResults.SelectedItem
                if (-not $selected) { return }
                if ($script:State.CurrentData -and $selected.ObjectGuid -eq $script:State.CurrentData.Ad.ObjectGuid) { return }
                if (-not (Confirm-DiscardChange)) {
                    $script:State.SuppressSelection = $true
                    $script:Ui.lstResults.SelectedItem = $script:State.PreviousSelection
                    $script:State.SuppressSelection = $false
                    return
                }
                $script:State.PreviousSelection = $selected
                Start-UserLoad -ObjectGuid $selected.ObjectGuid -Force
                if ($script:Layout.Mode -eq 'Compact') { Set-SidePane -Open $false }
            }
        })
    foreach ($key in $script:FieldMap.Keys) {
        $ui[$script:FieldMap[$key].Control].Add_TextChanged({ if (-not $script:State.IsPopulating) { Invoke-UiAction { Update-ChangeIndicator } } })
    }
    foreach ($key in $script:AccountFlagMap.Keys) {
        $ui[$script:AccountFlagMap[$key].Check].Add_Click({ if (-not $script:State.IsPopulating) { Invoke-UiAction { Update-ChangeIndicator } } })
    }
    $ui.btnGroupSearch.Add_Click({ Invoke-UiAction { Start-GroupSearch } })
    $ui.txtGroupSearch.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Return) { $e.Handled = $true; Invoke-UiAction { Start-GroupSearch } }
        })
    $ui.btnGroupAdd.Add_Click({ Invoke-UiAction { Add-SelectedGroup } })
    $ui.lstGroupResults.Add_MouseDoubleClick({ if ($script:Ui.btnGroupAdd.IsEnabled) { Invoke-UiAction { Add-SelectedGroup } } })
    $ui.btnGroupResultsClose.Add_Click({ Invoke-UiAction { $script:Ui.bdGroupResults.Visibility = 'Collapsed' } })
    $ui.btnGroupRemove.Add_Click({ Invoke-UiAction { Switch-SelectedGroupRemoval } })
    $ui.lstGroups.Add_MouseDoubleClick({ if ($script:Ui.btnGroupRemove.IsEnabled) { Invoke-UiAction { Switch-SelectedGroupRemoval } } })
    $ui.btnUnlock.Add_Click({ Invoke-UiAction { Start-UnlockAccount } })
    $ui.btnReplicate.Add_Click({ Invoke-UiAction { Start-AdReplication } })
    $ui.btnResetPassword.Add_Click({ Invoke-UiAction { Start-PasswordReset } })
    $ui.btnPhotoChange.Add_Click({ Invoke-UiAction { Start-PhotoChange } })
    $ui.btnPhotoRemove.Add_Click({ Invoke-UiAction { Start-PhotoRemove } })
    $ui.btnUpdate.Add_Click({ Invoke-UiAction { Start-UserUpdate } })
    $ui.btnSaveLog.Add_Click({ Invoke-UiAction { Save-LogToFile } })
    foreach ($key in $script:CasMap.Keys) {
        $ui[$script:CasMap[$key].Check].Add_Click({ if (-not $script:State.IsPopulating) { Invoke-UiAction { Update-ChangeIndicator } } })
    }
    foreach ($key in $script:PolicyMap.Keys) {
        $ui[$script:PolicyMap[$key].Combo].Add_SelectionChanged({ if (-not $script:State.IsPopulating) { Invoke-UiAction { Update-ChangeIndicator } } })
    }
    $ui.btnNewUser.Add_Click({ Invoke-UiAction { Start-NewUserCreation } })
    $ui.btnPstExport.Add_Click({ Invoke-UiAction { Start-ManualPstExport } })
    $ui.btnPstExportOpen.Add_Click({ $script:Ui.navPst.IsChecked = $true })
    $ui.txtPstMonitor.Add_MouseLeftButtonUp({ $script:Ui.navPst.IsChecked = $true })
    foreach ($name in 'chkDisableGroups', 'chkDisablePst', 'chkPstRemoveMailbox') {
        $ui[$name].Add_Click({ if (-not $script:State.IsPopulating) { Invoke-UiAction { Update-ChangeIndicator } } })
    }
    foreach ($name in 'txtPstFolder', 'txtPstFileName') {
        $ui[$name].Add_TextChanged({ if (-not $script:State.IsPopulating) { Invoke-UiAction { Update-ChangeIndicator } } })
    }
    Register-ListSort -Root $ui.pagePst -List $ui.lstPe
    $ui.btnPeRefresh.Add_Click({ Invoke-UiAction { Start-PstPoll -Force } })
    $ui.btnPeRemove.Add_Click({ Invoke-UiAction { Remove-SelectedPstMailbox } })
    $ui.btnPeClear.Add_Click({ Invoke-UiAction { Clear-SelectedPstRequest } })
    Register-ListSort -Root $ui.pageDisabled -List $ui.lstDu
    $ui.txtDuFilter.Add_TextChanged({ Invoke-UiAction { Update-DisabledUserView } })
    $ui.chkDuOverdue.Add_Click({ Invoke-UiAction { Update-DisabledUserView } })
    $ui.btnDuRefresh.Add_Click({ Invoke-UiAction { Start-DisabledUserLoad } })
    $ui.btnDuDelete.Add_Click({ Invoke-UiAction { Remove-SelectedDisabledUser } })
    $ui.btnDuOpen.Add_Click({ Invoke-UiAction { Open-SelectedDisabledUser } })
    $ui.btnDuEnable.Add_Click({ Invoke-UiAction { Enable-SelectedDisabledUser } })
    $ui.btnMoveOu.Add_Click({ Invoke-UiAction { Select-PendingOu } })
    $ui.lstDu.Add_MouseDoubleClick({ Invoke-UiAction { Open-SelectedDisabledUser } })
    $ui.dpLeaveStart.Add_SelectedDateChanged({
            Invoke-UiAction {
                $start = $script:Ui.dpLeaveStart.SelectedDate
                if ($start -and (-not $script:Ui.dpLeaveEnd.SelectedDate -or $script:Ui.dpLeaveEnd.SelectedDate -le $start)) { $script:Ui.dpLeaveEnd.SelectedDate = ([datetime]$start).Date.AddDays(1) }
                Update-LeaveView
            }
        })
    $ui.dpLeaveEnd.Add_SelectedDateChanged({ Invoke-UiAction { Update-LeaveView } })
    foreach ($name in 'cmbLeaveStartTime', 'cmbLeaveEndTime') {
        $ui[$name].AddHandler([System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [System.Windows.RoutedEventHandler]{ Invoke-UiAction { Update-LeaveView } })
    }
    $ui.btnLeaveAdd.Add_Click({ Invoke-UiAction { Add-LeavePeriod } })
    $ui.btnLeaveRemove.Add_Click({ Invoke-UiAction { Remove-LeavePeriod } })
    $ui.btnLeaveEdit.Add_Click({ Invoke-UiAction { Edit-LeavePeriod } })
    $ui.btnLeaveEditCancel.Add_Click({ Invoke-UiAction { Set-LeaveEditTarget -Period $null } })
    $ui.lstLeave.Add_MouseDoubleClick({ if ($script:Ui.btnLeaveEdit.IsEnabled -and $script:Ui.lstLeave.SelectedItem) { Invoke-UiAction { Edit-LeavePeriod } } })
    $ui.btnLeaveClear.Add_Click({ Invoke-UiAction { Clear-LeavePeriod } })
    $ui.lstLeave.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Delete) { Invoke-UiAction { Remove-LeavePeriod }; $e.Handled = $true }
        })
    $ui.chkLeaveNow.Add_Click({ Invoke-UiAction { Update-ChangeIndicator } })
    $ui.btnLeave1d.Add_Click({ Invoke-UiAction { Set-LeaveDuration -Days 1 } })
    $ui.btnLeave1w.Add_Click({ Invoke-UiAction { Set-LeaveDuration -Days 7 } })
    $ui.btnLeave2w.Add_Click({ Invoke-UiAction { Set-LeaveDuration -Days 14 } })
    $ui.btnLeaveScheduleTab.Add_Click({ $script:Ui.navLeave.IsChecked = $true })
    Register-ListSort -Root $ui.pageLeave -List $ui.lstLv
    $ui.txtLvFilter.Add_TextChanged({ Invoke-UiAction { Update-LeaveScheduleView } })
    foreach ($name in 'chkLvProblem', 'chkLvActive', 'chkLvTonight') { $ui[$name].Add_Click({ Invoke-UiAction { Update-LeaveScheduleView } }) }
    $ui.btnLvRefresh.Add_Click({ Invoke-UiAction { Start-LeaveScheduleLoad } })
    $ui.btnLvExport.Add_Click({ Invoke-UiAction { Export-LeaveSchedule } })
    $ui.btnLvBulk.Add_Click({ Invoke-UiAction { if (Show-BulkLeaveDialog -Owner $script:Window) { Start-LeaveScheduleLoad } } })
    $ui.btnLvRun.Add_Click({ Invoke-UiAction { Start-LeaveApply } })
    $ui.btnLvInstall.Add_Click({ Invoke-UiAction { Start-LeaveTaskInstall } })
    $ui.btnLvOpen.Add_Click({ Invoke-UiAction { Open-SelectedLeaveUser } })
    $ui.lstLv.Add_MouseDoubleClick({ Invoke-UiAction { Open-SelectedLeaveUser } })
    Register-SettingsPageEvent
    foreach ($groupName in $script:SettingsTabGroups.Keys) {
        $ui[$groupName].Add_Checked({ param($sender, $e) Invoke-UiAction { Set-SettingsTabGroup -GroupName $sender.Name } })
    }
    $ui.btnCreateMailbox.Add_Click({ Invoke-UiAction { Start-MailboxCreate } })
    $ui.btnAddAddress.Add_Click({ Invoke-UiAction { Add-SmtpAlias } })
    $ui.txtNewAddress.Add_KeyDown({
            param($sender, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Return) { $e.Handled = $true; Invoke-UiAction { Add-SmtpAlias } }
        })
    $ui.btnSetPrimary.Add_Click({ Invoke-UiAction { Set-SelectedPrimarySmtp } })
    $ui.lstAddresses.Add_MouseDoubleClick({ if ($script:Ui.btnSetPrimary.IsEnabled) { Invoke-UiAction { Set-SelectedPrimarySmtp } } })
    $ui.btnRemoveAddress.Add_Click({ Invoke-UiAction { Remove-SelectedSmtp } })
    $ui.btnArchiveEnable.Add_Click({ Invoke-UiAction { Start-ArchiveChange -Enable $true } })
    $ui.btnArchiveDisable.Add_Click({ Invoke-UiAction { Start-ArchiveChange -Enable $false } })
    $ui.btnStartMove.Add_Click({ Invoke-UiAction { Start-MailboxMoveAction } })
    $ui.btnMoveRefresh.Add_Click({ Invoke-UiAction { Start-MoveRefresh } })
    $ui.btnMoveClear.Add_Click({ Invoke-UiAction { Remove-MoveAction } })
    $ui.txtMonitor.Add_MouseLeftButtonUp({ Invoke-UiAction { if ($script:Ui.pnlTabs.Visibility -eq 'Visible') { $script:Ui.grpMail.IsChecked = $true; $script:Ui.tabMain.SelectedItem = $script:Ui.tabDatabase } } })
    $ui.cmbExMode.Add_SelectionChanged({
            Invoke-UiAction {
                $index = $script:Ui.cmbExMode.SelectedIndex
                $script:Ui.pnlOnPrem.Visibility = if ($index -eq 1) { 'Visible' } else { 'Collapsed' }
                Update-ActionState
            }
        })
    $ui.btnExConnect.Add_Click({ Invoke-UiAction { $script:Ui.popConnection.IsOpen = $false; Start-ExchangeConnection } })
    $ui.btnConnection.Add_Click({
            Invoke-UiAction {
                if ($script:Layout.ConnectionClosedAt -and ((Get-Date) - $script:Layout.ConnectionClosedAt).TotalMilliseconds -lt 300) { return }
                $script:Ui.popConnection.IsOpen = $true
            }
        })
    $ui.popConnection.Add_Closed({ $script:Layout.ConnectionClosedAt = Get-Date })
    $ui.btnReset.Add_Click({
            Invoke-UiAction {
                if ($script:State.CurrentData) {
                    Show-UserProfile -Data $script:State.CurrentData
                    Write-UiLog -Message 'Değişiklikler geri alındı.' -Level Info
                }
            }
        })
    $ui.btnReload.Add_Click({
            Invoke-UiAction { if ($script:State.CurrentData) { Start-UserLoad -ObjectGuid $script:State.CurrentData.Ad.ObjectGuid } }
        })
    $ui.btnTheme.Add_Click({ Invoke-UiAction { Set-AppTheme -Theme $(if ($script:Theme -eq 'Dark') { 'Light' } else { 'Dark' }) -Save } })
    $ui.btnClearLog.Add_Click({ $script:Ui.lstLog.Items.Clear(); $script:Ui.txtLogLast.Text = '' })
    $ui.btnLog.Add_Click({ Invoke-UiAction { Set-LogDrawer -Open ($script:Ui.bdLogDrawer.Visibility -ne 'Visible') } })
    foreach ($navName in $script:Pages.Keys) {
        $ui[$navName].Add_Checked({ param($sender, $e) Invoke-UiAction { Set-ActivePage -NavName $sender.Name } })
    }
    foreach ($groupName in $script:TabGroups.Keys) {
        $ui[$groupName].Add_Checked({ param($sender, $e) Invoke-UiAction { Set-TabGroup -GroupName $sender.Name } })
    }
    $script:Window.Add_KeyDown({
            param($sender, $e)
            Invoke-UiAction {
                if ($e.Key -eq [System.Windows.Input.Key]::F5 -and $script:Ui.navReports.IsChecked) {
                    if ($script:Ui.btnRpRun.IsEnabled) { $e.Handled = $true; Start-ReportRun }
                    return
                }
                if ($e.Key -eq [System.Windows.Input.Key]::S -and [System.Windows.Input.Keyboard]::Modifiers -eq [System.Windows.Input.ModifierKeys]::Control -and $script:Ui.navSettings.IsChecked) {
                    $e.Handled = $true
                    [void](Save-SettingsForm)
                    return
                }
                if ($e.Key -eq [System.Windows.Input.Key]::F5 -and $script:Ui.btnReload.IsEnabled) {
                    $e.Handled = $true
                    Start-UserLoad -ObjectGuid $script:State.CurrentData.Ad.ObjectGuid
                    return
                }
                if ([System.Windows.Input.Keyboard]::Modifiers -ne [System.Windows.Input.ModifierKeys]::Control) { return }
                $key = $e.Key
                if ($key -in @([System.Windows.Input.Key]::OemPlus, [System.Windows.Input.Key]::Add)) { $e.Handled = $true; Set-UiScale -Value 'Up' }
                elseif ($key -in @([System.Windows.Input.Key]::OemMinus, [System.Windows.Input.Key]::Subtract)) { $e.Handled = $true; Set-UiScale -Value 'Down' }
                elseif ($key -in @([System.Windows.Input.Key]::D0, [System.Windows.Input.Key]::NumPad0)) { $e.Handled = $true; Set-UiScale -Value 'Auto' }
                elseif ($key -eq [System.Windows.Input.Key]::B -and $script:Layout.Mode -eq 'Compact') { $e.Handled = $true; Set-SidePane -Open (-not $script:Layout.PaneOpen) }
                elseif ($key -eq [System.Windows.Input.Key]::L) { $e.Handled = $true; Set-LogDrawer -Open ($script:Ui.bdLogDrawer.Visibility -ne 'Visible') }
                elseif ($key -eq [System.Windows.Input.Key]::O -and $script:Ui.btnOuSearch.IsEnabled) { $e.Handled = $true; Start-OuUserSearch }
                elseif ($key -eq [System.Windows.Input.Key]::K) { $e.Handled = $true; [void]$script:Ui.txtSearch.Focus() }
            }
        })
    $script:Window.Add_ContentRendered({ Invoke-UiAction { Start-EnvironmentCheck } })
    $script:Window.Add_PreviewMouseWheel({
            param($sender, $e)
            if ([System.Windows.Input.Keyboard]::Modifiers -ne [System.Windows.Input.ModifierKeys]::Control) { return }
            $e.Handled = $true
            Invoke-UiAction { if ($e.Delta -gt 0) { Set-UiScale -Value 'Up' } else { Set-UiScale -Value 'Down' } }
        })
    $ui.btnView.Add_Click({
            Invoke-UiAction {
                if ($script:Layout.ViewClosedAt -and ((Get-Date) - $script:Layout.ViewClosedAt).TotalMilliseconds -lt 300) { return }
                Update-ScaleView
                $script:Ui.popView.IsOpen = $true
            }
        })
    $ui.popView.Add_Closed({ $script:Layout.ViewClosedAt = Get-Date })
    $ui.btnScaleUp.Add_Click({ Invoke-UiAction { Set-UiScale -Value 'Up' } })
    $ui.btnScaleDown.Add_Click({ Invoke-UiAction { Set-UiScale -Value 'Down' } })
    $ui.chkScaleAuto.Add_Click({
            Invoke-UiAction {
                if ($script:Layout.ScaleSync) { return }
                if ($script:Ui.chkScaleAuto.IsChecked) { Set-UiScale -Value 'Auto' }
                else { Set-UiScale -Value ($script:UiScale.ToString([System.Globalization.CultureInfo]::InvariantCulture)) }
            }
        })
    $ui.btnPane.Add_Click({ Invoke-UiAction { Set-SidePane -Open (-not $script:Layout.PaneOpen) } })
    $ui.svRoot.Add_SizeChanged({ Invoke-UiAction { Update-RootSize } })
    $ui.svRoot.Add_ScrollChanged({
            param($sender, $e)
            if ($e.OriginalSource -ne $script:Ui.svRoot) { return }
            if ($e.ViewportWidthChange -ne 0 -or $e.ViewportHeightChange -ne 0) { Invoke-UiAction { Update-RootSize } }
        })
    $script:Window.Add_Closing({
            param($sender, $e)
            $job = $script:TaskEngine.CurrentJob
            if ($job -and -not $job.Silent) {
                $answer = Show-MessageDialog -Message 'Bir işlem hâlâ sürüyor. Yine de çıkılsın mı?' -Button YesNo -Icon Warning
                if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true; return }
            }
            elseif (-not (Confirm-DiscardChange)) {
                $e.Cancel = $true
                return
            }
            if (-not (Test-SettingsLeave)) {
                $e.Cancel = $true
                return
            }
            if (@($script:State.PstExports.Values | Where-Object { $_.RemoveMailbox }).Count -gt 0) {
                Write-UiLog -Message 'PST dışa aktarmaları Exchange üzerinde sürer. Posta kutusu silme, uygulama bir sonraki açılıp Exchange''e bağlanınca yapılır.' -Level Info
            }
            if ($script:State.MonitoredMoves.Count -gt 0) {
                Write-UiLog -Message 'Süren taşıma istekleri Exchange üzerinde devam eder; uygulama kapansa da iptal edilmez.' -Level Info
            }
            Save-WindowPlacement
        })
}

function Show-SplashStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][ValidateRange(0, 100)][int]$Percent
    )
    if (-not $script:Splash) { return }
    try {
        $script:Splash.Controls.txtSplashStep.Text = $Message
        $script:Splash.Controls.prgSplash.Value = $Percent
        # Açılış UI iş parçacığını bloklar; çizimin işlenmesi için kuyruk boşaltılır.
        $script:Splash.Window.Dispatcher.Invoke([action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
    }
    catch { Write-Verbose "Açılış ekranı güncellenemedi: $($_.Exception.Message)" }
}
function Close-Splash {
    [CmdletBinding()]
    param()
    if (-not $script:Splash) { return }
    try { $script:Splash.Window.Close() } catch { Write-Verbose "Açılış ekranı kapatılamadı: $($_.Exception.Message)" }
    $script:Splash = $null
}
function Start-MainWindow {
    [CmdletBinding()]
    param()
    Initialize-DpiAwareness
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    [void](Initialize-NativeMethod)
    $script:DesignXaml = Read-AppFile -RelativePath 'UI\Styles.xaml'
    $script:Xaml = Read-AppFile -RelativePath 'UI\MainWindow.xaml'
    $script:ConfirmXaml = Read-AppFile -RelativePath 'UI\Dialogs\Confirm.xaml'
    $script:OuPickerXaml = Read-AppFile -RelativePath 'UI\Dialogs\OuPicker.xaml'
    $script:PasswordXaml = Read-AppFile -RelativePath 'UI\Dialogs\PasswordReset.xaml'
    $script:CredentialXaml = Read-AppFile -RelativePath 'UI\Dialogs\Credential.xaml'
    $script:NewUserXaml = Read-AppFile -RelativePath 'UI\Dialogs\NewUser.xaml'
    $script:BulkLeaveXaml = Read-AppFile -RelativePath 'UI\Dialogs\BulkLeave.xaml'
    $script:DbPickerXaml = Read-AppFile -RelativePath 'UI\Dialogs\DatabasePicker.xaml'
    try { Initialize-UiScale }
    catch { Write-Verbose "Arayüz ölçeği okunamadı: $($_.Exception.Message)"; $script:UiScaleSetting = 'Auto'; $script:UiScale = 1.0 }
    try { Initialize-Theme }
    catch {
        # Tema adları çözülmezse pencere siyah ve okunamaz açılır; devam edilmez.
        $text = "Tema yüklenemedi: $($_.Exception.Message)"
        Write-Error -Message $text
        [void][System.Windows.MessageBox]::Show($text, 'AD-IDM', 'OK', 'Error')
        return
    }
    try {
        $script:Splash = New-MainWindow -Xaml (Read-AppFile -RelativePath 'UI\Splash.xaml')
        $script:Splash.Window.Show()
    }
    catch { Write-Verbose "Açılış ekranı gösterilemedi: $($_.Exception.Message)"; $script:Splash = $null }
    Show-SplashStep -Message 'ActiveDirectory modülü denetleniyor…' -Percent 10
    $adModule = Get-Module -ListAvailable -Name ActiveDirectory | Sort-Object -Property Version -Descending | Select-Object -First 1
    if (-not $adModule) {
        Close-Splash
        $text = "ActiveDirectory modülü (RSAT) bulunamadı.`n`nWindows 10/11: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`nWindows Server: Install-WindowsFeature RSAT-AD-PowerShell"
        Write-Error -Message $text -Category NotInstalled
        [void][System.Windows.MessageBox]::Show($text, 'AD-IDM', 'OK', 'Error')
        return
    }
    $timer = $null
    $moveTimer = $null
    $pstTimer = $null
    try {
        Show-SplashStep -Message 'Arka plan iş motoru başlatılıyor (ActiveDirectory yükleniyor)…' -Percent 25
        Initialize-TaskEngine -WorkerScriptTexts @($script:WorkerScripts | ForEach-Object { Read-AppFile -RelativePath $_ }) -RequiredModules @('ActiveDirectory') `
            -OnMessage { param($Item) Show-WorkerMessage -Item $Item } `
            -OnBusyChanged { param($IsBusy, $Message) Set-BusyState -IsBusy $IsBusy -Message $Message }
        Show-SplashStep -Message 'Ana pencere oluşturuluyor…' -Percent 60
        $main = New-MainWindow -Xaml $script:Xaml
        $script:Window = $main.Window
        $script:Ui = $main.Controls
        Set-ThemeButton
        $iconPath = Join-Path -Path $script:AppRoot -ChildPath 'Assets\AD-IDM.ico'
        if (Test-Path -LiteralPath $iconPath) {
            try { $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object -TypeName System.Uri -ArgumentList $iconPath)) }
            catch { Write-Verbose "Pencere simgesi yüklenemedi: $($_.Exception.Message)" }
        }
        $script:Ui.txtLogPath.Text = "Günlük dosyası: $script:LogPath"
        Show-SplashStep -Message 'Arayüz hazırlanıyor…' -Percent 75
        Set-TabGroup -GroupName 'grpIdentity'
        Set-SettingsTabGroup -GroupName 'grpSetMail'
        foreach ($name in 'txtCanonicalName', 'txtDn') { $script:Ui[$name].IsReadOnly = $true }
        Update-ActionState
        Register-ShellEvent
        Initialize-WindowSize
        Update-ScaleView
        Write-UiLog -Message "Uygulama başlatıldı. PowerShell $($PSVersionTable.PSVersion) | ActiveDirectory v$($adModule.Version) | Kullanıcı: $env:USERDOMAIN\$env:USERNAME" -Level Info
        Show-SplashStep -Message 'Değişiklik günlüğü ve SMS servisi denetleniyor…' -Percent 85
        if (Write-AuditEvent -Action 'session.start' -Result 'info' -Fields ([ordered]@{ message = "PowerShell $($PSVersionTable.PSVersion)" })) {
            Write-UiLog -Message "Değişiklik günlüğü (SIEM, $($script:Audit.Format)): $($script:Audit.Path)" -Level Info
        }
        else {
            Close-Splash
            [void](Show-MessageDialog -Message "Değişiklik günlüğü yazılamıyor:`n$($script:Audit.Path)`n`nYapılan değişiklikler SIEM'e aktarılamaz. Klasöre yazma izni verin veya -AuditLogPath ile başka yol seçin." -Icon Warning)
        }
        $sms = Get-SmsConfiguration
        if ($sms.Available) { Write-UiLog -Message "Parola SMS servisi hazır: $($sms.Config.Provider) ($script:SmsConfigPath)" -Level Info }
        else { Write-UiLog -Message "Parola SMS servisi kapalı: $($sms.Reason)" -Level Verbose }
        $timer = New-Object -TypeName System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $timer.Add_Tick({ try { Invoke-TaskPump } catch { Write-UiLog -Message "Zamanlayıcı hatası: $($_.Exception.Message)" -Level Error } })
        $timer.Start()
        $moveTimer = New-Object -TypeName System.Windows.Threading.DispatcherTimer
        $moveTimer.Interval = [TimeSpan]::FromSeconds(15)
        $moveTimer.Add_Tick({ try { Start-MovePoll } catch { Write-UiLog -Message "Taşıma izleme hatası: $($_.Exception.Message)" -Level Warning } })
        $moveTimer.Start()
        $pstTimer = New-Object -TypeName System.Windows.Threading.DispatcherTimer
        $pstTimer.Interval = [TimeSpan]::FromSeconds(30)
        $pstTimer.Add_Tick({ try { Start-PstPoll } catch { Write-UiLog -Message "PST izleme hatası: $($_.Exception.Message)" -Level Warning } })
        $pstTimer.Start()
        $script:Window.Dispatcher.Add_UnhandledException({
                param($sender, $e)
                $e.Handled = $true
                $exception = $e.Exception
                while ($exception.InnerException) { $exception = $exception.InnerException }
                try { Write-UiLog -Message "Beklenmeyen arayüz hatası: $($exception.Message)" -Level Error } catch { Write-Warning $exception.Message }
            })
        Show-SplashStep -Message 'Hazır' -Percent 100
        $script:Window.Add_ContentRendered({ Close-Splash })
        [void]$script:Window.ShowDialog()
    }
    catch {
        Close-Splash
        $message = "Uygulama başlatılamadı: $($_.Exception.Message)"
        Write-Error -Message $message
        [void][System.Windows.MessageBox]::Show($message, 'AD-IDM', 'OK', 'Error')
    }
    finally {
        Close-Splash
        if ($timer) { $timer.Stop() }
        if ($moveTimer) { $moveTimer.Stop() }
        if ($pstTimer) { $pstTimer.Stop() }
        # İş sürerken Exchange oturumu aynı runspace'ten kapatılamaz; süreç kapanınca sunucu tarafında zaman aşımına düşer.
        if ($script:TaskEngine.Runspace -and $script:Sync.ExchangeMode -ne 'None' -and -not $script:TaskEngine.CurrentJob) {
            $disconnect = [powershell]::Create()
            try {
                $disconnect.Runspace = $script:TaskEngine.Runspace
                [void]$disconnect.AddCommand('Disconnect-ExchangeEnvironment').Invoke()
            }
            catch { Write-Verbose "Exchange bağlantısı kapatılamadı: $($_.Exception.Message)" }
            finally { $disconnect.Dispose() }
        }
        try { [void](Write-AuditEvent -Action 'session.end' -Result 'info') } catch { Write-Verbose $_.Exception.Message }
        if (-not (Stop-TaskEngine)) { Write-FileLog -Path $script:LogPath -Line ('{0:yyyy-MM-dd HH:mm:ss}  [UYARI]  Süren iş durdurulamadı; runspace kapatılmadan çıkılıyor.' -f (Get-Date)) }
    }
}
