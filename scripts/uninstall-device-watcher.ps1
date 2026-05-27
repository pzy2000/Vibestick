[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'Vibestick\app\current'),
    [switch] $KeepFiles
)

$ErrorActionPreference = 'Stop'

$installPath = [System.IO.Path]::GetFullPath($InstallRoot)
$safeBase = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Vibestick\app'))
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'VibestickDeviceWatcher'

if ($PSCmdlet.ShouldProcess($runKey, "Remove $runName")) {
    Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue
}

$watcherProcesses = Get-Process -Name 'vibestick-device-watcher' -ErrorAction SilentlyContinue
foreach ($process in $watcherProcesses) {
    if ($PSCmdlet.ShouldProcess("PID $($process.Id)", 'Stop Vibestick device watcher')) {
        Stop-Process -Id $process.Id -Force
    }
}

if (-not $KeepFiles) {
    if (-not $installPath.StartsWith($safeBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove install root outside $safeBase`: $installPath"
    }

    if ((Test-Path -LiteralPath $installPath -PathType Container) -and
        $PSCmdlet.ShouldProcess($installPath, 'Remove installed files')) {
        Remove-Item -LiteralPath $installPath -Recurse -Force
    }
}

if ($WhatIfPreference) {
    Write-Host "Vibestick device watcher uninstall dry run completed."
} else {
    Write-Host "Vibestick device watcher uninstalled."
}
