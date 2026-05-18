param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $GuiArgs
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$localDotnet = Join-Path $env:USERPROFILE '.dotnet\dotnet.exe'

if (Test-Path $localDotnet) {
    $dotnet = $localDotnet
} else {
    $dotnet = 'dotnet'
}

& $dotnet run --project (Join-Path $repoRoot 'src\Vibestick.Gui') --configuration Release -- @GuiArgs
exit $LASTEXITCODE
