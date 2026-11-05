$script:Sync = [hashtable]::Synchronized(@{
        LogQueue     = New-Object -TypeName 'System.Collections.Concurrent.ConcurrentQueue[psobject]'
        ExchangeMode = 'None'
    })
$script:TaskEngine = @{
    Runspace      = $null
    CurrentJob    = $null
    Queue         = New-Object -TypeName 'System.Collections.Generic.Queue[hashtable]'
    OnMessage     = $null
    OnBusyChanged = $null
}

function Initialize-TaskEngine {
    [CmdletBinding()]
    param(
        [Parameter()][string[]]$WorkerScriptPaths = @(),
        [Parameter()][string[]]$WorkerScriptTexts = @(),
        [Parameter()][string[]]$RequiredModules = @(),
        [Parameter(Mandatory = $true)][scriptblock]$OnMessage,
        [Parameter(Mandatory = $true)][scriptblock]$OnBusyChanged
    )
    $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    if ($RequiredModules.Count -gt 0) { $initialState.ImportPSModule($RequiredModules) }
    $initialState.Variables.Add((New-Object -TypeName System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'Sync', $script:Sync, 'UI ile paylaşılan durum'))
    $runspace = [runspacefactory]::CreateRunspace($initialState)
    if ($env:OS -eq 'Windows_NT') { $runspace.ApartmentState = [System.Threading.ApartmentState]::STA }
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()
    $ps = [powershell]::Create()
    try {
        $ps.Runspace = $runspace
        $scriptTexts = @($WorkerScriptPaths | ForEach-Object { [System.IO.File]::ReadAllText($_, [System.Text.Encoding]::UTF8) }) + $WorkerScriptTexts
        foreach ($scriptText in $scriptTexts) {
            $ps.Commands.Clear()
            [void]$ps.AddScript($scriptText)
            [void]$ps.Invoke()
            if ($ps.HadErrors) { throw $ps.Streams.Error[0].Exception }
        }
        foreach ($module in $RequiredModules) {
            $ps.Commands.Clear()
            [void]$ps.AddCommand('Get-Module').AddParameter('Name', $module)
            if (-not $ps.Invoke()) { throw "$module modülü arka plan runspace'ine yüklenemedi." }
        }
    }
    catch {
        $runspace.Dispose()
        throw
    }
    finally {
        $ps.Dispose()
    }
    $script:TaskEngine.Runspace = $runspace
    $script:TaskEngine.OnMessage = $OnMessage
    $script:TaskEngine.OnBusyChanged = $OnBusyChanged
}

function Send-EngineLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter()][string]$Level = 'Info'
    )
    & $script:TaskEngine.OnMessage ([pscustomobject]@{ Kind = 'Log'; Level = $Level; Message = $Message; Percent = $null; Time = (Get-Date) })
}

function Invoke-BackgroundTask {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter()][hashtable]$Arguments = @{},
        [Parameter()][scriptblock]$OnSuccess,
        [Parameter()][scriptblock]$OnFailure,
        [Parameter()][switch]$Silent,
        [Parameter()][object[]]$AuditChanges = @()
    )
    if ($script:TaskEngine.CurrentJob) {
        if ($Silent) { return $false }
        $script:TaskEngine.Queue.Enqueue(@{ Name = $Name; Command = $Command; Arguments = $Arguments; OnSuccess = $OnSuccess; OnFailure = $OnFailure; AuditChanges = $AuditChanges })
        Send-EngineLog -Message "$Name sıraya alındı." -Level Verbose
        return $true
    }
    $ps = [powershell]::Create()
    try {
        $ps.Runspace = $script:TaskEngine.Runspace
        [void]$ps.AddCommand($Command)
        foreach ($key in $Arguments.Keys) { [void]$ps.AddParameter($key, $Arguments[$key]) }
        $handle = $ps.BeginInvoke()
    }
    catch {
        $ps.Dispose()
        throw
    }
    $script:TaskEngine.CurrentJob = @{
        Name       = $Name
        PowerShell = $ps
        Handle     = $handle
        OnSuccess  = $OnSuccess
        OnFailure  = $OnFailure
        Started    = Get-Date
        Silent     = [bool]$Silent
        Audit      = $(try { Get-AuditTaskContext -Command $Command -Arguments $Arguments -Changes $AuditChanges } catch { Write-Verbose $_.Exception.Message; $null })
    }
    if (-not $Silent) {
        & $script:TaskEngine.OnBusyChanged $true "$Name..."
        Send-EngineLog -Message "$Name başlatıldı." -Level Verbose
    }
    return $true
}

function Invoke-TaskCallback {
    [CmdletBinding()]
    param(
        [Parameter()][scriptblock]$Callback,
        [Parameter()][AllowNull()][object]$Argument
    )
    if (-not $Callback) { return }
    try { & $Callback $Argument }
    catch { Send-EngineLog -Message "İş sonrası işlem hatası: $($_.Exception.Message)" -Level Error }
}

function Complete-BackgroundTask {
    [CmdletBinding()]
    param()
    $job = $script:TaskEngine.CurrentJob
    $script:TaskEngine.CurrentJob = $null
    $result = $null
    $failure = $null
    try {
        $output = $job.PowerShell.EndInvoke($job.Handle)
        $result = if ($output.Count -eq 1) { $output[0] } else { @($output) }
        foreach ($record in $job.PowerShell.Streams.Error) { Send-EngineLog -Message "$($job.Name): $($record.Exception.Message)" -Level Warning }
    }
    catch {
        $exception = $_.Exception
        while ($exception.InnerException -and ($exception -is [System.Management.Automation.MethodInvocationException])) { $exception = $exception.InnerException }
        $failure = $exception.Message
    }
    finally {
        $job.PowerShell.Dispose()
    }
    if ($job.Audit) {
        try { Write-AuditTaskResult -Context $job.Audit -Result $result -Failure $failure }
        catch { Send-EngineLog -Message "Değişiklik günlüğü kaydı oluşturulamadı: $($_.Exception.Message)" -Level Error }
    }
    if (-not $job.Silent) { & $script:TaskEngine.OnBusyChanged $false $(if ($failure) { "$($job.Name) başarısız." } else { 'Hazır' }) }
    if ($failure) {
        Send-EngineLog -Message "$($job.Name) başarısız: $failure" -Level $(if ($job.Silent) { 'Warning' } else { 'Error' })
        Invoke-TaskCallback -Callback $job.OnFailure -Argument $failure
    }
    else {
        if (-not $job.Silent) { Send-EngineLog -Message ('{0} tamamlandı ({1:N1} sn).' -f $job.Name, ((Get-Date) - $job.Started).TotalSeconds) -Level Verbose }
        Invoke-TaskCallback -Callback $job.OnSuccess -Argument $result
    }
    if (-not $script:TaskEngine.CurrentJob -and $script:TaskEngine.Queue.Count -gt 0) {
        $next = $script:TaskEngine.Queue.Dequeue()
        [void](Invoke-BackgroundTask @next)
    }
}

function Invoke-TaskPump {
    [CmdletBinding()]
    param()
    $job = $script:TaskEngine.CurrentJob
    # Son iletiler sonuçtan önce gösterilsin diye bitiş, kuyruk boşaltılmadan önce okunur.
    $finished = $job -and $job.Handle.IsCompleted
    $item = $null
    $processed = 0
    while ($processed -lt 200 -and $script:Sync.LogQueue.TryDequeue([ref]$item)) {
        $processed++
        & $script:TaskEngine.OnMessage $item
    }
    if ($finished -and $script:Sync.LogQueue.IsEmpty) { Complete-BackgroundTask }
}

function Stop-TaskEngine {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][int]$TimeoutMilliseconds = 5000)
    $script:TaskEngine.Queue.Clear()
    $job = $script:TaskEngine.CurrentJob
    $script:TaskEngine.CurrentJob = $null
    $stopped = $true
    if ($job) {
        $stopped = $job.PowerShell.BeginStop($null, $null).AsyncWaitHandle.WaitOne($TimeoutMilliseconds)
        if ($stopped) { $job.PowerShell.Dispose() }
    }
    $runspace = $script:TaskEngine.Runspace
    # Durmayan iş varken Close süresiz bekleyebilir; arka plan iş parçacığı süreçle birlikte biter.
    if ($stopped -and $runspace) {
        $runspace.Close()
        $runspace.Dispose()
        $script:TaskEngine.Runspace = $null
    }
    return $stopped
}
