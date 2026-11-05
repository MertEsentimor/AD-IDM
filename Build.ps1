# Modüler projeyi tek dosyaya birleştirir: .\Build.ps1 [-OutputFolder .\dist]
# Çıktıda Configs şablonları da bulunur; Logs, Secrets ve gerçek ayarlar kopyalanmaz.
[CmdletBinding()]
param([Parameter()][string]$OutputFolder = (Join-Path -Path $PSScriptRoot -ChildPath 'dist'))

$ErrorActionPreference = 'Stop'
$utf8Bom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
$hereStringEndMarker = '<ADIDM-HERE-END>'
$sourceFiles = @(foreach ($folderName in 'Core', 'Modules', 'UI') {
        Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath $folderName) -Recurse -File -Include '*.ps1', '*.xaml'
    })
$embeddedEntries = foreach ($file in ($sourceFiles | Sort-Object -Property FullName)) {
    $relativePath = $file.FullName.Substring($PSScriptRoot.Length + 1) -replace '/', '\'
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) -replace "`r`n", "`n"
    if ($text.Contains($hereStringEndMarker)) { throw "Kaynakta ayrılmış işaret var: $relativePath" }
    # Satır başındaki here-string bitişi gömmeyi bozar; Read-AppFile okurken geri çevirir.
    $text = $text -replace "(?m)^'@", $hereStringEndMarker
    "    '$relativePath' = @'`n$text`n'@"
}
$entrySource = [System.IO.File]::ReadAllText((Join-Path -Path $PSScriptRoot -ChildPath 'Start-ADIDM.ps1'), [System.Text.Encoding]::UTF8) -replace "`r`n", "`n"
$marker = '$script:EmbeddedFiles = @{} # BUILD:EMBEDDED-FILES'
if (-not $entrySource.Contains($marker)) { throw "Start-ADIDM.ps1 içinde işaret bulunamadı: $marker" }
$output = $entrySource.Replace($marker, "`$script:EmbeddedFiles = @{`n$($embeddedEntries -join "`n")`n}")

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($output, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Çıktı ayrıştırılamadı: $($parseErrors[0].Message) (satır $($parseErrors[0].Extent.StartLineNumber))" }

$configFolder = Join-Path -Path $OutputFolder -ChildPath 'Configs'
[void](New-Item -Path $configFolder -ItemType Directory -Force)
Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Configs') -Filter '*.template.*' | Copy-Item -Destination $configFolder -Force
$assetFolder = Join-Path -Path $OutputFolder -ChildPath 'Assets'
[void](New-Item -Path $assetFolder -ItemType Directory -Force)
Copy-Item -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Assets/*') -Destination $assetFolder -Force
$outputPath = Join-Path -Path $OutputFolder -ChildPath 'AD-IDM.ps1'
[System.IO.File]::WriteAllText($outputPath, $output, $utf8Bom)
Write-Host "Oluşturuldu: $outputPath ($($sourceFiles.Count) dosya, $([math]::Round((Get-Item -LiteralPath $outputPath).Length / 1KB)) KB)"
