$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationCore

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = 'C:\Users\ROG\.codex\pets\golden-shaded-cat\spritesheet.webp'
$outputPath = Join-Path $repoRoot 'src\Vibestick.Gui\Assets\PetSprites\golden-shaded-cat-spritesheet.cleaned.png'

$stream = [System.IO.File]::OpenRead($sourcePath)
try {
    $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
        $stream,
        [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
        [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $source = $decoder.Frames[0]
    $bitmap = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap(
        $source,
        [System.Windows.Media.PixelFormats]::Bgra32,
        $null,
        0)
} finally {
    $stream.Dispose()
}

$width = $bitmap.PixelWidth
$height = $bitmap.PixelHeight
$stride = $width * 4
$pixels = New-Object byte[] ($stride * $height)
$bitmap.CopyPixels($pixels, $stride, 0)

for ($index = 0; $index -lt $pixels.Length; $index += 4) {
    $blue = $pixels[$index]
    $green = $pixels[$index + 1]
    $red = $pixels[$index + 2]
    $alpha = $pixels[$index + 3]

    if ($alpha -lt 8 -or ($alpha -gt 0 -and $blue -gt 70 -and $red -lt 65 -and $green -lt 95)) {
        $pixels[$index] = 0
        $pixels[$index + 1] = 0
        $pixels[$index + 2] = 0
        $pixels[$index + 3] = 0
    }
}

$cleaned = [System.Windows.Media.Imaging.BitmapSource]::Create(
    $width,
    $height,
    96,
    96,
    [System.Windows.Media.PixelFormats]::Bgra32,
    $null,
    $pixels,
    $stride)

$encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($cleaned))
$output = [System.IO.File]::Create($outputPath)
try {
    $encoder.Save($output)
} finally {
    $output.Dispose()
}

Write-Host "Wrote $outputPath"
