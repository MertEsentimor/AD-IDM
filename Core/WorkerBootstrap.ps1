$global:ErrorActionPreference = 'Stop'
$global:ProgressPreference = 'SilentlyContinue'

function global:Write-WorkerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [Parameter()][ValidateSet('Info', 'Success', 'Warning', 'Error', 'Verbose')][string]$Level = 'Info'
    )
    $Sync.LogQueue.Enqueue([pscustomobject]@{ Kind = 'Log'; Level = $Level; Message = $Message; Percent = $null; Time = (Get-Date) })
}

function global:Set-WorkerProgress {
    [CmdletBinding()]
    param(
        [Parameter()][int]$Percent = -1,
        [Parameter(Mandatory = $true)][string]$Status
    )
    $Sync.LogQueue.Enqueue([pscustomobject]@{ Kind = 'Progress'; Level = 'Info'; Message = $Status; Percent = $Percent; Time = (Get-Date) })
}
