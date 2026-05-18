param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $VibestickArgs
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$localDotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'

if (Test-Path $localDotnet) {
    $dotnet = $localDotnet
} else {
    $dotnet = 'dotnet'
}

& $dotnet run --project (Join-Path $repoRoot 'src\Vibestick.Cli') -- @VibestickArgs
exit $LASTEXITCODE

