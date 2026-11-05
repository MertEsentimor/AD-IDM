function global:Invoke-DemoTask {
    [CmdletBinding()]
    param(
        [Parameter()][int]$Seconds = 30,
        [Parameter()][int]$StepMilliseconds = 1000,
        [Parameter()][switch]$ThrowAtEnd
    )
    for ($step = 1; $step -le $Seconds; $step++) {
        Start-Sleep -Milliseconds $StepMilliseconds
        Set-WorkerProgress -Percent ([int]($step * 100 / $Seconds)) -Status "Test işi: $step / $Seconds sn"
        if ($step % 5 -eq 0) { Write-WorkerLog -Message "Test işi sürüyor: $step sn" }
    }
    if ($ThrowAtEnd) { throw 'Test hatası: arka plan işi bilerek başarısız oldu.' }
    return [pscustomobject]@{ Seconds = $Seconds; ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId }
}
