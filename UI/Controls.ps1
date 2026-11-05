function Write-UiLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [Parameter()][ValidateSet('Info', 'Success', 'Warning', 'Error', 'Verbose')][string]$Level = 'Info',
        [Parameter()][datetime]$Timestamp = (Get-Date)
    )
    $tag = switch ($Level) { 'Success' { 'OK  ' } 'Warning' { 'UYARI' } 'Error' { 'HATA' } 'Verbose' { 'AYRNT' } default { 'BİLGİ' } }
    $line = '{0:HH:mm:ss}  [{1}]  {2}' -f $Timestamp, $tag, $Message
    if ($script:Ui.ContainsKey('lstLog') -and $script:Ui.lstLog) {
        $colorToken = switch ($Level) { 'Success' { 'SuccessBrush' } 'Warning' { 'WarningBrush' } 'Error' { 'DangerBrush' } 'Verbose' { 'TextMutedBrush' } default { 'TextBrush' } }
        $textBlock = New-Object -TypeName System.Windows.Controls.TextBlock
        $textBlock.Text = $line
        $textBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $textBlock.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $colorToken)
        [void]$script:Ui.lstLog.Items.Add($textBlock)
        while ($script:Ui.lstLog.Items.Count -gt 1000) { $script:Ui.lstLog.Items.RemoveAt(0) }
        $script:Ui.lstLog.ScrollIntoView($textBlock)
        if ($Level -ne 'Verbose') { $script:Ui.txtLogLast.Text = $line -replace '\s*\r?\n\s*', ' ' }
        if ($Level -eq 'Error') { Set-LogDrawer -Open $true }
    }
    Write-FileLog -Path $script:LogPath -Line ('{0:yyyy-MM-dd} {1}' -f $Timestamp, $line)
    switch ($Level) {
        'Warning' { Write-Warning $Message }
        default { Write-Verbose $line }
    }
}
function Show-MessageDialog {
    [CmdletBinding()]
    [OutputType([System.Windows.MessageBoxResult])]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter()][string]$Title = 'AD & Exchange Kullanıcı Yöneticisi',
        [Parameter()][System.Windows.MessageBoxButton]$Button = [System.Windows.MessageBoxButton]::OK,
        [Parameter()][System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Information
    )
    if ($script:Window -and $script:Window.IsLoaded) {
        return [System.Windows.MessageBox]::Show($script:Window, $Message, $Title, $Button, $Icon)
    }
    return [System.Windows.MessageBox]::Show($Message, $Title, $Button, $Icon)
}
function Invoke-UiAction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    try {
        & $Action
    }
    catch {
        Write-UiLog -Message "Beklenmeyen hata: $($_.Exception.Message)" -Level Error
        Write-UiLog -Message ($_.ScriptStackTrace) -Level Verbose
    }
}
function New-MainWindow {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][string]$Xaml)
    try {
        [xml]$xmlDocument = $Xaml
        $reader = New-Object -TypeName System.Xml.XmlNodeReader -ArgumentList $xmlDocument
        $thread = [System.Threading.Thread]::CurrentThread
        $previousCulture = $thread.CurrentCulture
        $previousUiCulture = $thread.CurrentUICulture
        try {
            $thread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
            $thread.CurrentUICulture = [System.Globalization.CultureInfo]::InvariantCulture
            $window = [System.Windows.Markup.XamlReader]::Load($reader)
        }
        finally {
            $thread.CurrentCulture = $previousCulture
            $thread.CurrentUICulture = $previousUiCulture
        }
        if ($script:ThemeDictionary -and -not $script:ThemeAppLevel) { $window.Resources.MergedDictionaries.Add($script:ThemeDictionary.PSObject.BaseObject) }
    }
    catch {
        $inner = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        throw "XAML yüklenemedi: $inner"
    }
    try {
        Set-WindowScale -Window $window
        if ($script:Window) { Initialize-DialogBound -Window $window }
        $window.Add_SourceInitialized({ param($sender, $e) Set-WindowChrome -Window $sender })
    }
    catch { Write-Verbose "Pencere ekran uyumu uygulanamadı: $($_.Exception.Message)" }
    $controls = @{}
    foreach ($match in [regex]::Matches($Xaml, 'x:Name="([A-Za-z0-9_]+)"')) {
        $name = $match.Groups[1].Value
        $control = $window.FindName($name)
        if ($control) { $controls[$name] = $control }
    }
    return @{ Window = $window; Controls = $controls }
}
function Format-DateText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][object]$Date)
    if ($null -eq $Date) { return '-' }
    return ([datetime]$Date).ToString('dd.MM.yyyy HH:mm')
}
function Format-RelativeTime {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][datetime]$Date)
    $span = (Get-Date) - $Date
    $future = $span.TotalSeconds -lt 0
    $abs = $span.Duration()
    if ($abs.TotalMinutes -lt 1) { return 'az önce' }
    $text = if ($abs.TotalDays -ge 1) { '{0} gün' -f [math]::Floor($abs.TotalDays) }
    elseif ($abs.TotalHours -ge 1) { '{0} saat' -f [math]::Floor($abs.TotalHours) }
    else { '{0} dakika' -f [math]::Floor($abs.TotalMinutes) }
    if ($future) { return "$text sonra" }
    return "$text önce"
}
function Get-BadgePrefix {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Kind)
    switch ($Kind) { 'Success' { return '✓ ' } 'Warning' { return '! ' } 'Error' { return '✕ ' } default { return '' } }
}
function Set-Badge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BorderName,
        [Parameter(Mandatory = $true)][string]$TextName,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter()][ValidateSet('Success', 'Error', 'Warning', 'Neutral', 'Accent')][string]$Kind = 'Neutral'
    )
    $tokens = @{
        Success = 'SuccessBgBrush', 'SuccessBrush'; Error = 'DangerBgBrush', 'DangerBrush'; Warning = 'WarningBgBrush', 'WarningBrush'
        Neutral = 'SurfaceHoverBrush', 'TextMutedBrush'; Accent = 'InfoBgBrush', 'AccentTextBrush'
    }
    $script:Ui[$BorderName].SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $tokens[$Kind][0])
    $script:Ui[$TextName].SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $tokens[$Kind][1])
    $script:Ui[$TextName].Text = (Get-BadgePrefix -Kind $Kind) + $Text
}
function Invoke-Deferred {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    $script:State.Deferred.Enqueue($Action)
    [void]$script:Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action] {
            if ($script:State.Deferred.Count -gt 0) { Invoke-UiAction $script:State.Deferred.Dequeue() }
        })
}
function Show-ConfirmDialog {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter()][string]$Title = 'İşlemi Onayla',
        [Parameter()][switch]$Warning,
        [Parameter()][System.Windows.Window]$Owner = $script:Window,
        [Parameter()][object[]]$Items,
        [Parameter()][string]$ApplyText = 'Uygula'
    )
    $dialog = New-MainWindow -Xaml $script:ConfirmXaml
    $script:State.ConfirmDialog = @{ Window = $dialog.Window; Controls = $dialog.Controls; Result = $false; ApplyText = $ApplyText }
    try {
        $c = $dialog.Controls
        $dialog.Window.Owner = $Owner
        $dialog.Window.Title = $Title
        $c.txtCfTitle.Text = $Title
        $c.txtCfMessage.Text = $Message
        if ($Items) {
            $c.icCfItems.ItemsSource = @($Items)
            $c.icCfItems.Visibility = 'Visible'
        }
        if ($Warning) { $c.bdCfHeader.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'DangerBgBrush') }
        $c.chkCfWhatIf.IsChecked = [bool]$script:State.Options.WhatIf
        $c.chkCfReplicate.IsChecked = [bool]$script:State.Options.Replicate
        $refreshOptions = {
            $cc = $script:State.ConfirmDialog.Controls
            $simulate = [bool]$cc.chkCfWhatIf.IsChecked
            $cc.chkCfReplicate.IsEnabled = -not $simulate
            $cc.btnCfYes.Content = if ($simulate) { 'Simüle Et' } else { $script:State.ConfirmDialog.ApplyText }
        }
        & $refreshOptions
        $c.chkCfWhatIf.Add_Click({ Invoke-UiAction $refreshOptions })
        $c.btnCfYes.Add_Click({
                Invoke-UiAction {
                    $state = $script:State.ConfirmDialog
                    $script:State.Options.WhatIf = [bool]$state.Controls.chkCfWhatIf.IsChecked
                    $script:State.Options.Replicate = [bool]$state.Controls.chkCfReplicate.IsChecked
                    $state.Result = $true
                    $state.Window.DialogResult = $true
                }
            })
        [void]$dialog.Window.ShowDialog()
        return [bool]$script:State.ConfirmDialog.Result
    }
    finally {
        $script:State.ConfirmDialog = $null
    }
}
function Save-LogToFile {
    [CmdletBinding()]
    param()
    $dialog = New-Object -TypeName Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'Metin dosyası (*.txt)|*.txt|Tüm dosyalar (*.*)|*.*'
    $dialog.FileName = 'ADExchangeUserManager_{0:yyyyMMdd_HHmmss}.txt' -f (Get-Date)
    if ($dialog.ShowDialog($script:Window)) {
        $lines = foreach ($entry in $script:Ui.lstLog.Items) { $entry.Text }
        Set-Content -Path $dialog.FileName -Value $lines -Encoding UTF8 -ErrorAction Stop
        Write-UiLog -Message "Günlük kaydedildi: $($dialog.FileName)" -Level Success
    }
}
function Register-ListSort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Windows.DependencyObject]$Root,
        [Parameter(Mandatory = $true)][System.Windows.Controls.ItemsControl]$List
    )
    $state = [pscustomobject]@{ List = $List; Active = -1; Descending = $false; Headers = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
    $queue = New-Object -TypeName 'System.Collections.Generic.Queue[object]'
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        if ($node -is [System.Windows.Controls.TextBlock] -and ([string]$node.Tag).StartsWith('sort:')) {
            $node.Resources['ListSortState'] = $state
            $node.Resources['ListSortIndex'] = $state.Headers.Count
            $state.Headers.Add([pscustomobject]@{ Control = $node; Property = ([string]$node.Tag).Substring(5); Text = [string]$node.Text })
            $node.Cursor = [System.Windows.Input.Cursors]::Hand
            $node.ToolTip = 'Sıralamak için tıklayın (tekrar tıklayınca ters sıralar)'
            $node.Add_MouseLeftButtonUp({
                    param($sender, $e)
                    $header = $sender
                    Invoke-UiAction { Set-ListSort -State $header.Resources['ListSortState'] -Index ([int]$header.Resources['ListSortIndex']) }
                })
        }
        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) { if ($child -is [System.Windows.DependencyObject]) { $queue.Enqueue($child) } }
    }
    $List.Resources['ListSortState'] = $state
    $descriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.Controls.ItemsControl]::ItemsSourceProperty, [System.Windows.Controls.ItemsControl])
    $descriptor.AddValueChanged($List, [System.EventHandler]{
            param($sender, $e)
            $target = $sender
            Invoke-UiAction { Update-ListSort -State $target.Resources['ListSortState'] }
        })
}
function Set-ListSort {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$State, [Parameter(Mandatory = $true)][int]$Index)
    if ($State.Active -eq $Index) { $State.Descending = -not $State.Descending }
    else { $State.Active = $Index; $State.Descending = $false }
    Update-ListSort -State $State
}
function Update-ListSort {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][psobject]$State)
    if (-not $State) { return }
    $items = $State.List.Items
    try {
        $items.Culture = [System.Globalization.CultureInfo]::CurrentCulture
        if ($items.SortDescriptions.Count -gt 0) { $items.SortDescriptions.Clear() }
        if ($State.Active -ge 0) {
            $direction = if ($State.Descending) { [System.ComponentModel.ListSortDirection]::Descending } else { [System.ComponentModel.ListSortDirection]::Ascending }
            $items.SortDescriptions.Add((New-Object -TypeName System.ComponentModel.SortDescription -ArgumentList $State.Headers[$State.Active].Property, $direction))
        }
    }
    catch { Write-UiLog -Message "Liste sıralanamadı: $($_.Exception.Message)" -Level Warning }
    for ($i = 0; $i -lt $State.Headers.Count; $i++) {
        $header = $State.Headers[$i]
        $header.Control.Text = if ($i -eq $State.Active) { '{0} {1}' -f $header.Text, [char]$(if ($State.Descending) { 0x25BC } else { 0x25B2 }) } else { $header.Text }
    }
}
