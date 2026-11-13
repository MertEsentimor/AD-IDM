$script:SmsCache = @{ Stamp = $null; Config = $null; Secrets = @{} }
function ConvertTo-PlainHashtable {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) { $table[$property.Name] = ConvertTo-PlainHashtable -InputObject $property.Value }
        return $table
    }
    if ($InputObject -is [System.Collections.IList] -and $InputObject -isnot [string]) { return , @($InputObject | ForEach-Object { ConvertTo-PlainHashtable -InputObject $_ }) }
    return $InputObject
}
function Get-DeviceNamePatternSetting {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $pattern = 'NB-{sam}'
    if (Test-Path -LiteralPath $Path) {
        $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($document.PSObject.Properties['DeviceNamePattern']) { $pattern = [string]$document.DeviceNamePattern }
    }
    $problem = Test-DeviceNamePattern -Pattern $pattern
    if ($problem) { return [pscustomobject]@{ Pattern = ''; Warning = "$problem Otomatik cihaz eşleştirme kapatıldı ($Path)." } }
    return [pscustomobject]@{ Pattern = $pattern.Trim(); Warning = $null }
}
function Resolve-AppPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$Path)
    if (-not $Path) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path -Path $script:AppRoot -ChildPath $Path)
}
function Get-SmsConfiguration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $path = $script:SmsConfigPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Available = $false; Reason = "ayar dosyası yok ($path)"; Config = $null }
    }
    try {
        $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc
        if ($script:SmsCache.Stamp -ne $stamp) {
            $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
            $script:SmsCache.Config = ConvertTo-PlainHashtable -InputObject ($json | ConvertFrom-Json -ErrorAction Stop)
            $script:SmsCache.Stamp = $stamp
        }
        $config = $script:SmsCache.Config
        if ($config.Enabled -ne $true) { return [pscustomobject]@{ Available = $false; Reason = 'sms-config.json içinde Enabled = false'; Config = $config } }
        if (-not $config.Url) { return [pscustomobject]@{ Available = $false; Reason = 'sms-config.json içinde Url boş'; Config = $config } }
        if (-not $config.Provider) { $config.Provider = 'SMS servisi' }
        return [pscustomobject]@{ Available = $true; Reason = $null; Config = $config }
    }
    catch {
        return [pscustomobject]@{ Available = $false; Reason = "ayar dosyası okunamadı: $($_.Exception.Message)"; Config = $null }
    }
}
function Get-MailConfiguration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $path = $script:MailConfigPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ Available = $false; Reason = "ayar dosyası yok ($path)"; Config = $null } }
    try {
        $config = ConvertTo-PlainHashtable -InputObject ((Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop)
    }
    catch { return [pscustomobject]@{ Available = $false; Reason = "ayar dosyası okunamadı: $($_.Exception.Message)"; Config = $null } }
    $to = @($config.To | Where-Object { $_ })
    $reason = if ($config.Enabled -ne $true) { 'mail-config.json içinde Enabled = false' }
    elseif (-not $config.SmtpServer -or [string]$config.SmtpServer -match 'BURAYA') { 'mail-config.json içinde SmtpServer doldurulmamış' }
    elseif (-not $config.From -or [string]$config.From -match 'BURAYA') { 'mail-config.json içinde From doldurulmamış' }
    elseif ($to.Count -eq 0 -or ($to -join ' ') -match 'BURAYA') { 'mail-config.json içinde To (alıcılar) doldurulmamış' }
    else { $null }
    return [pscustomobject]@{ Available = -not $reason; Reason = $reason; Config = $config }
}
function Get-OutsourceMailConfiguration {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $mail = Get-MailConfiguration
    $config = $mail.Config
    $section = if ($config -and $config.OutsourceMail) { $config.OutsourceMail } else { $null }
    $resolve = { param([string]$Path) if (-not $Path) { '' } elseif ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path -Path $script:AppRoot -ChildPath $Path } }
    $bodyFile = if ($section -and $section.BodyFile) { & $resolve ([string]$section.BodyFile) } else { '' }
    $attachments = @(if ($section) { @($section.Attachments | Where-Object { $_ } | ForEach-Object { & $resolve ([string]$_) }) })
    $reason = if (-not $config) { $mail.Reason }
    elseif (-not $section) { 'mail-config.json içinde OutsourceMail bölümü yok' }
    elseif ($section.Enabled -ne $true) { 'mail-config.json: OutsourceMail.Enabled = false' }
    elseif (-not $config.SmtpServer -or -not $config.From) { 'mail-config.json içinde SmtpServer / From doldurulmamış' }
    elseif (-not $bodyFile -or -not (Test-Path -LiteralPath $bodyFile)) { "e-posta metin dosyası bulunamadı: $bodyFile" }
    elseif (@($attachments | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -gt 0) { "ek dosyası bulunamadı: $(@($attachments | Where-Object { -not (Test-Path -LiteralPath $_) }) -join ', ')" }
    else { $null }
    return [pscustomobject]@{ Available = -not $reason; Reason = $reason; Config = $config; Section = $section; BodyFile = $bodyFile; Attachments = $attachments }
}
