[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'Vibestick\app\current'),
    [switch] $NoStart
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$localDotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'
$dotnet = if (Test-Path $localDotnet) { $localDotnet } else { 'dotnet' }

$guiProject = Join-Path $repoRoot 'src\Vibestick.Gui\Vibestick.Gui.csproj'
$watcherProject = Join-Path $repoRoot 'src\Vibestick.DeviceWatcher\Vibestick.DeviceWatcher.csproj'
$installPath = [System.IO.Path]::GetFullPath($InstallRoot)
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'VibestickDeviceWatcher'

if ($PSCmdlet.ShouldProcess($installPath, 'Publish Vibestick GUI and device watcher')) {
    New-Item -ItemType Directory -Force -Path $installPath | Out-Null

    & $dotnet publish $guiProject --configuration Release --no-self-contained --output $installPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    & $dotnet publish $watcherProject --configuration Release --no-self-contained --output $installPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$watcherExe = Join-Path $installPath 'vibestick-device-watcher.exe'
$guiExe = Join-Path $installPath 'vibestick-gui.exe'
$runValue = "`"$watcherExe`" --gui-path `"$guiExe`""

if ($PSCmdlet.ShouldProcess($runKey, "Register $runName")) {
    New-Item -Path $runKey -Force | Out-Null
    New-ItemProperty -Path $runKey -Name $runName -Value $runValue -PropertyType String -Force | Out-Null
}

if (-not $NoStart -and $PSCmdlet.ShouldProcess($watcherExe, 'Start device watcher')) {
    Start-Process -FilePath $watcherExe -ArgumentList @('--gui-path', $guiExe) -WindowStyle Hidden
}

if ($WhatIfPreference) {
    Write-Host "Vibestick device watcher install dry run completed."
} else {
    Write-Host "Vibestick device watcher installed."
}
Write-Host "Install root: $installPath"
Write-Host "Run key: $runName = $runValue"
