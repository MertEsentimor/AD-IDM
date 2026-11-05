function Write-FileLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line
    )
    try {
        $folder = Split-Path -Path $Path -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder)) { [void](New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop) }
        Add-Content -LiteralPath $Path -Value $Line -Encoding UTF8 -ErrorAction Stop
    }
    catch { Write-Verbose "Günlük dosyasına yazılamadı: $($_.Exception.Message)" }
}
