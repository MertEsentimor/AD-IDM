function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList ([System.Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RelaunchArgument {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$ExecutionPolicy,
        [Parameter()][System.Collections.IDictionary]$Parameters = @{}
    )
    $arguments = New-Object -TypeName 'System.Collections.Generic.List[string]'
    # Yükseltilen süreç ortam değişkenlerini almaz; geçerli yürütme ilkesi açıkça taşınır.
    $arguments.AddRange([string[]]@('-NoProfile', '-ExecutionPolicy', $ExecutionPolicy, '-STA', '-File', ('"{0}"' -f $ScriptPath)))
    foreach ($entry in $Parameters.GetEnumerator()) {
        if ($entry.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($entry.Value.IsPresent) { $arguments.Add("-$($entry.Key)") }
            continue
        }
        $arguments.Add("-$($entry.Key)")
        $arguments.Add(('"{0}"' -f ([string]$entry.Value -replace '"', '\"')))
    }
    return $arguments.ToArray()
}

function Set-ShortcutRunAsAdministrator {
    # .lnk LinkFlags alanındaki RunAsUser biti (0x2000): "Yönetici olarak çalıştır" ile aynıdır.
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    if ($Bytes.Length -lt 76 -or $Bytes[0] -ne 0x4C) { throw 'Geçerli bir kısayol dosyası değil.' }
    $Bytes[0x15] = $Bytes[0x15] -bor 0x20
    return , $Bytes
}

function Install-DesktopShortcut {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param()
    $shortcutPath = Join-Path -Path ([System.Environment]::GetFolderPath('Desktop')) -ChildPath 'AD-IDM.lnk'
    $iconPath = Join-Path -Path $script:AppRoot -ChildPath 'Assets\AD-IDM.ico'
    $powerShellPath = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not $PSCmdlet.ShouldProcess($shortcutPath, 'Masaüstü kısayolu oluştur')) { return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powerShellPath
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}"' -f $script:ScriptFullPath
    $shortcut.WorkingDirectory = $script:AppRoot
    $shortcut.Description = 'AD & Exchange Kullanıcı Yöneticisi'
    if (Test-Path -LiteralPath $iconPath) { $shortcut.IconLocation = "$iconPath,0" }
    else { Write-Warning "Simge bulunamadı, varsayılan simge kullanılacak: $iconPath" }
    $shortcut.Save()
    [System.IO.File]::WriteAllBytes($shortcutPath, (Set-ShortcutRunAsAdministrator -Bytes ([System.IO.File]::ReadAllBytes($shortcutPath))))
    return $shortcutPath
}
