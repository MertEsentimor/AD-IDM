# Çalıştırma: pwsh -NoProfile -File Tests/Test-GroupRestore.ps1  (veya Windows'ta powershell.exe). AD gerektirmez.
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Path $PSScriptRoot -Parent
$script:FailureCount = 0
function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Host "PASS  $Name" }
    else { Write-Host "FAIL  $Name"; $script:FailureCount++ }
}
function Write-UiLog { param([string]$Message, [string]$Level) }
. ([scriptblock]::Create([System.IO.File]::ReadAllText((Join-Path -Path $projectRoot -ChildPath 'UI/Handlers/Offboarding.ps1'), [System.Text.Encoding]::UTF8)))

$script:AppRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('adidm-grp-' + [guid]::NewGuid().ToString('N'))
$folder = Join-Path -Path $script:AppRoot -ChildPath 'Logs\RemovedGroups'
try {
    Assert-True ($null -eq (Get-RemovedGroupList -SamAccountName 'ali')) 'Klasör yoksa liste yok'
    $null = New-Item -Path $folder -ItemType Directory -Force
    Set-Content -LiteralPath (Join-Path $folder 'ali_20261101_090000.txt') -Value '# eski', 'CN=Eski,DC=x' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $folder 'ali_20261105_090000.txt') -Value '# yeni', 'CN=Muhasebe\, Ankara,OU=G,DC=x', '', 'CN=VPN,DC=x' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $folder 'ali_veli_20261106_090000.txt') -Value 'CN=Baska,DC=x' -Encoding UTF8
    $list = Get-RemovedGroupList -SamAccountName 'ALI'
    Assert-True ($list -and $list.Path -like '*ali_20261105_090000.txt') 'En yeni dosya seçilir, benzer adlı kullanıcı karışmaz, büyük/küçük harf fark etmez'
    Assert-True ($list.GroupDn.Count -eq 2 -and $list.GroupDn[1] -eq 'CN=VPN,DC=x') 'Yorum ve boş satırlar atlanır'
    $name = ($list.GroupDn[0] -replace '^CN=((?:\\,|[^,])+),.*$', '$1') -replace '\\,', ','
    Assert-True ($name -eq 'Muhasebe, Ankara') "Kaçışlı virgüllü CN adı çözülür: $name"
    Complete-RemovedGroupList -Path $list.Path
    Assert-True (Test-Path -LiteralPath (Join-Path $folder 'ali_20261105_090000.restored.txt')) 'Geri eklenen liste .restored.txt olur'
    Assert-True ($null -eq (Get-RemovedGroupList -SamAccountName 'ali')) 'Geri eklemeden sonra kullanıcının eski listeleri de önerilmez'
    Assert-True ($null -ne (Get-RemovedGroupList -SamAccountName 'ali_veli')) 'Benzer adlı kullanıcının listesine dokunulmaz'
}
finally { Remove-Item -LiteralPath $script:AppRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:FailureCount -gt 0) { Write-Host "$script:FailureCount test başarısız."; exit 1 }
Write-Host 'Tüm testler geçti.'
