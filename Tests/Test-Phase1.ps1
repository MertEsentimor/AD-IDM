# Çalıştırma: pwsh -NoProfile -File Tests/Test-Phase1.ps1  (veya Windows'ta powershell.exe). WPF ve AD gerektirmez.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}

$sourceFiles = @(Get-ChildItem -Path $projectRoot -Recurse -File -Include '*.ps1', '*.xaml')
$scriptFiles = @($sourceFiles | Where-Object { $_.Extension -eq '.ps1' })

# ---- Kaynak dosya kontrolleri
foreach ($file in $sourceFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) "UTF-8 BOM: $($file.Name)"
}

$functionNames = @{}
$commandNames = @{}
foreach ($file in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Sözdizimi: $($file.Name)"
    foreach ($definition in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $functionNames[($definition.Name -replace '^global:', '')] = $true }
    foreach ($commandAst in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $commandName = $commandAst.GetCommandName()
        if ($commandName -match '^[A-Za-z]+-[A-Za-z]+$') { $commandNames[$commandName] = $file.Name }
    }
}
# Windows'a özel komutlar macOS'ta Get-Command ile bulunamaz.
$windowsOnlyCommands = 'Get-ItemPropertyValue', 'Add-Type', 'Get-Credential', 'Get-Secret', 'Set-Secret', 'Get-UserPhoto', 'Set-UserPhoto', 'Remove-UserPhoto', 'Get-Mailbox', 'Set-Mailbox', 'Disable-Mailbox', 'Enable-Mailbox', 'Get-MailboxDatabase', 'Set-CASMailbox', 'Get-CASMailbox', 'Set-RemoteMailbox', 'Get-RemoteMailbox', 'Get-Recipient', 'Get-MoveRequest', 'New-MoveRequest', 'Remove-MoveRequest', 'Get-MoveRequestStatistics', 'Get-MailboxStatistics'
# Taşınan akışlarda çağrılan ama sonraki fazlarda gelecek komutlar; o fazlara kadar arayüzden erişilemez.
$windowsOnlyCommands += 'New-MailboxExportRequest', 'Get-MailboxExportRequest', 'Get-MailboxExportRequestStatistics', 'Remove-MailboxExportRequest', 'Get-WinEvent'
$unresolved = @($commandNames.Keys | Where-Object { -not $functionNames[$_] -and $_ -notin $windowsOnlyCommands -and -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) -and $_ -notmatch '-AD[A-Z]|ScheduledTask' })
Assert-True ($unresolved.Count -eq 0) "Tanımsız komut yok: $($unresolved -join ', ')"

$windowXaml = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/MainWindow.xaml'))
$stylesXaml = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/Styles.xaml'))
[xml]$windowDocument = $windowXaml
[xml]$stylesDocument = $stylesXaml
Assert-True ($null -ne $windowDocument -and $null -ne $stylesDocument) 'XAML dosyaları geçerli XML'

$namespace = New-Object -TypeName System.Xml.XmlNamespaceManager -ArgumentList $windowDocument.NameTable
$namespace.AddNamespace('w', 'http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$tabHeaders = @($windowDocument.SelectNodes('//w:TabControl[@*[local-name()="Name"]="tabMain"]/w:TabItem', $namespace) | ForEach-Object { $_.GetAttribute('Header') })
$expectedHeaders = 'Genel', 'Hesap', 'Grup Üyelikleri', 'İzin', 'E-posta Adresleri', 'Posta Kutusu Özellikleri', 'Kullanım', 'Arşiv', 'Veritabanı ve Taşıma', 'Politikalar'
Assert-True (($tabHeaders -join '|') -ceq ($expectedHeaders -join '|')) "10 sekme sırasıyla var ($($tabHeaders.Count))"

$xamlNames = @([regex]::Matches($windowXaml, 'x:Name="([A-Za-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
Assert-True ($xamlNames.Count -eq @($xamlNames | Select-Object -Unique).Count) 'x:Name değerleri benzersiz'
$elementReferences = @([regex]::Matches($windowXaml, 'ElementName=([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$missingElements = @($elementReferences | Where-Object { $_ -notin $xamlNames })
Assert-True ($missingElements.Count -eq 0) "ElementName hedefleri var: $($missingElements -join ', ')"

$paletteXaml = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/Themes/Light.xaml'))
$styleKeys = @([regex]::Matches($stylesXaml + $paletteXaml, 'x:Key="([A-Za-z0-9_.]+)"') | ForEach-Object { $_.Groups[1].Value })
$resourceReferences = @([regex]::Matches($windowXaml + $stylesXaml, '\{(?:Dynamic|Static)Resource ([A-Za-z0-9_.]+)\}') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$missingResources = @($resourceReferences | Where-Object { $_ -notin $styleKeys })
Assert-True ($missingResources.Count -eq 0) "Kaynak anahtarları var: $($missingResources -join ', ')"

$uiScriptText = (@($scriptFiles | Where-Object { $_.DirectoryName -match '[\\/]UI([\\/]|$)' }) | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
$hashtableMembers = 'ContainsKey', 'Keys', 'Clone'
$uiReferences = @([regex]::Matches($uiScriptText, '\$(?:script:)?[Uu]i\.([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$missingControls = @($uiReferences | Where-Object { $_ -notin $xamlNames -and $_ -notin $hashtableMembers })
Assert-True ($missingControls.Count -eq 0) "Koddaki denetimler XAML'de var: $($missingControls -join ', ')"

$allScriptText = ($scriptFiles | Where-Object { $_.DirectoryName -notmatch 'Tests$' } | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
$usedVariables = @([regex]::Matches($allScriptText, '\$script:([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$assignedVariables = @([regex]::Matches($allScriptText, '\$script:([A-Za-z0-9_]+)\s*=[^=]') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
$unassigned = @($usedVariables | Where-Object { $_ -notin $assignedVariables })
Assert-True ($unassigned.Count -eq 0) "`$script: değişkenleri atanıyor: $($unassigned -join ', ')"

# ---- Arka plan motoru (gerçek runspace)
. (Join-Path -Path $projectRoot -ChildPath 'Core/Runspace.ps1')
$observed = @{ Messages = New-Object -TypeName System.Collections.ArrayList; Busy = New-Object -TypeName System.Collections.ArrayList; Order = New-Object -TypeName System.Collections.ArrayList; Failure = $null; Result = $null }
Initialize-TaskEngine -WorkerScriptPaths @((Join-Path -Path $projectRoot -ChildPath 'Core/WorkerBootstrap.ps1'), (Join-Path -Path $PSScriptRoot -ChildPath 'DemoWorker.ps1')) `
    -OnMessage { param($Item) [void]$observed.Messages.Add($Item) } `
    -OnBusyChanged { param($IsBusy, $Message) [void]$observed.Busy.Add($IsBusy) }

function Wait-TaskEngine {
    param([int]$TimeoutSeconds = 20)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($script:TaskEngine.CurrentJob -and (Get-Date) -lt $deadline) {
        Invoke-TaskPump
        Start-Sleep -Milliseconds 10
    }
    Invoke-TaskPump
    return -not $script:TaskEngine.CurrentJob
}

$callerThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
$startedAt = Get-Date
[void](Invoke-BackgroundTask -Name 'A' -Command 'Invoke-DemoTask' -Arguments @{ Seconds = 5; StepMilliseconds = 100 } -OnSuccess {
        param($Result)
        $observed.Result = $Result
        [void]$observed.Order.Add('A')
    })
Assert-True (((Get-Date) - $startedAt).TotalMilliseconds -lt 250) 'İş başlatma çağıranı bekletmez (0,5 sn işte < 250 ms)'
[void](Invoke-BackgroundTask -Name 'B' -Command 'Invoke-DemoTask' -Arguments @{ Seconds = 1; StepMilliseconds = 10 } -OnSuccess { param($Result) [void]$observed.Order.Add('B') })
$silentAccepted = Invoke-BackgroundTask -Name 'Sessiz' -Command 'Invoke-DemoTask' -Silent
Assert-True (-not $silentAccepted) 'Meşgulken sessiz iş reddedilir'
Assert-True (Wait-TaskEngine) 'Kuyruktaki işler biter'
Assert-True (($observed.Order -join ',') -eq 'A,B') "FIFO sırası: $($observed.Order -join ',')"
Assert-True ($null -ne $observed.Result -and $observed.Result.Seconds -eq 5) 'İş sonucu UI tarafına döner'
Assert-True ($observed.Result.ThreadId -ne $callerThreadId) 'İş ayrı iş parçacığında çalışır'
Assert-True (@($observed.Messages | Where-Object { $_.Kind -eq 'Progress' }).Count -ge 6) 'İlerleme iletileri akar'
Assert-True (@($observed.Messages | Where-Object { $_.Kind -eq 'Log' -and $_.Message -like 'Test işi sürüyor*' }).Count -ge 1) 'Worker günlüğü akar'
Assert-True ($observed.Busy[-1] -eq $false) 'Son durum: meşgul değil'

[void](Invoke-BackgroundTask -Name 'Hata' -Command 'Invoke-DemoTask' -Arguments @{ Seconds = 1; StepMilliseconds = 10; ThrowAtEnd = $true } -OnFailure { param($Failure) $observed.Failure = $Failure })
[void](Invoke-BackgroundTask -Name 'Sonraki' -Command 'Invoke-DemoTask' -Arguments @{ Seconds = 1; StepMilliseconds = 10 } -OnSuccess { param($Result) [void]$observed.Order.Add('Sonraki') })
Assert-True (Wait-TaskEngine) 'Hatalı iş sonrası motor durmaz'
Assert-True ($observed.Failure -like 'Test hatası*') "Hata iletisi çağırana ulaşır: $($observed.Failure)"
Assert-True ($observed.Order -contains 'Sonraki') 'Hatadan sonra kuyruk sürer'
Assert-True (@($observed.Messages | Where-Object { $_.Level -eq 'Error' -and $_.Message -like 'Hata başarısız*' }).Count -eq 1) 'Hata günlüğe yazılır'

[void](Invoke-BackgroundTask -Name 'Geri çağırım' -Command 'Invoke-DemoTask' -Arguments @{ Seconds = 1; StepMilliseconds = 10 } -OnSuccess { throw 'geri çağırım patladı' })
Assert-True (Wait-TaskEngine) 'Geri çağırım hatası pompayı durdurmaz'
Assert-True (@($observed.Messages | Where-Object { $_.Message -like '*geri çağırım patladı*' }).Count -eq 1) 'Geri çağırım hatası günlüğe yazılır'

$runspaceUnderTest = $script:TaskEngine.Runspace
[void](Invoke-BackgroundTask -Name 'Uzun' -Command 'Invoke-DemoTask' -Arguments @{ Seconds = 600 })
[void](Invoke-BackgroundTask -Name 'Kuyrukta' -Command 'Invoke-DemoTask')
Start-Sleep -Milliseconds 200
$stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
$stopResult = Stop-TaskEngine
Assert-True ($stopResult -and $stopWatch.Elapsed.TotalSeconds -lt 5) "Süren iş kapanışta durur ($([int]$stopWatch.Elapsed.TotalMilliseconds) ms)"
Assert-True ($runspaceUnderTest.RunspaceStateInfo.State -in 'Closed', 'Closing' -and $null -eq $script:TaskEngine.Runspace) "Runspace kapatılır ($($runspaceUnderTest.RunspaceStateInfo.State))"
Assert-True ($script:TaskEngine.Queue.Count -eq 0) 'Kapanışta kuyruk boşalır'

Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
