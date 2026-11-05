# Çalıştırma: pwsh -NoProfile -File Tests/Test-Build.ps1  (veya Windows'ta powershell.exe). Tek dosya çıktısını geçici klasöre üretip denetler.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}
$outputFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("adidm-build-" + [guid]::NewGuid().ToString('N'))
try {
    & (Join-Path -Path $projectRoot -ChildPath 'Build.ps1') -OutputFolder $outputFolder | Out-Null
    $outputPath = Join-Path -Path $outputFolder -ChildPath 'AD-IDM.ps1'
    Assert-True (Test-Path -LiteralPath $outputPath) 'Çıktı oluşur'
    $bytes = [System.IO.File]::ReadAllBytes($outputPath)
    Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'Çıktı UTF-8 BOM ile yazılır'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($outputPath, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Çıktı sözdizimi: $($parseErrors.Count) hata"
    $assignment = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:EmbeddedFiles' }, $true)
    $table = @{}
    foreach ($pair in $assignment.Right.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true).KeyValuePairs) { $table[[string]$pair.Item1.Value] = $pair.Item2.Extent.Text }
    $sources = @(foreach ($folderName in 'Core', 'Modules', 'UI') { Get-ChildItem -Path (Join-Path -Path $projectRoot -ChildPath $folderName) -Recurse -File -Include '*.ps1', '*.xaml' })
    Assert-True ($table.Count -eq $sources.Count) "Tüm kaynaklar gömülü ($($table.Count)/$($sources.Count))"
    $different = @(foreach ($file in $sources) {
            $key = $file.FullName.Substring($projectRoot.Length + 1) -replace '/', '\'
            $expected = [System.IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n"
            $embedded = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.StringConstantType -eq 'SingleQuotedHereString' -and $node.Value.Replace('<ADIDM-HERE-END>', "'@").TrimEnd("`n") -ceq $expected.TrimEnd("`n") }, $true)
            if (-not $table.ContainsKey($key) -or -not $embedded) { $key }
        })
    Assert-True ($different.Count -eq 0) "Gömülü içerik kaynakla aynı: $($different -join ', ')"
    $startText = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'Start-ADIDM.ps1'))
    $referenced = @([regex]::Matches($startText, "'((?:Core|Modules|UI)\\[^']+\.ps1)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $shellText = [System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/Shell.ps1'))
    $referenced += @([regex]::Matches($shellText, "'(UI\\[^']+\.xaml)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $missing = @($referenced | Where-Object { -not $table.ContainsKey($_) })
    Assert-True ($referenced.Count -ge 25 -and $missing.Count -eq 0) "Kodda istenen dosyalar gömülü ($($referenced.Count)): $($missing -join ', ')"
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path -Path $outputFolder -ChildPath 'Configs') -Filter '*.template.*').Count -eq 3) 'Şablonlar çıktıya kopyalanır'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path -Path $outputFolder -ChildPath 'Configs') -Filter '*.json' | Where-Object { $_.Name -notlike '*.template.json' }).Count -eq 0) 'Gerçek ayarlar çıktıya kopyalanmaz'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path -Path $outputFolder -ChildPath 'Secrets'))) 'Secrets çıktıya kopyalanmaz'
    Assert-True (Test-Path -LiteralPath (Join-Path -Path $outputFolder -ChildPath 'Assets/AD-IDM.ico')) 'Simge çıktıya kopyalanır'
    # Gömülü dosyalarla gerçek açılış: arayüze gelmeden, ayar yokken beklenen hatada durur.
    $previousOs = $env:OS
    $env:OS = 'Windows_NT'
    $shellPath = (Get-Process -Id $PID).Path
    $runOutput = & $shellPath -NoProfile -File $outputPath -TestMailTo 'a@test.local' 2>&1 | Out-String
    $env:OS = $previousOs
    Assert-True ($runOutput -match 'mail-config|E-posta ayar') "Gömülü çekirdek dosyalar yüklenir: $(($runOutput -replace '\s+', ' ').Substring(0, [math]::Min(120, ($runOutput -replace '\s+', ' ').Length)))"
}
finally { Remove-Item -LiteralPath $outputFolder -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($script:FailureCount -gt 0) {
    Write-Host "$script:FailureCount test başarısız."
    exit 1
}
Write-Host 'Tüm testler geçti.'
