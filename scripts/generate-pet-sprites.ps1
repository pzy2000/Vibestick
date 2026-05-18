$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$repoRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $repoRoot 'src\Vibestick.Gui\Assets\PetSprites'
$outputPath = Join-Path $outputDirectory 'vibestick-pet-spritesheet.png'
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$frameWidth = 128
$frameHeight = 128
$frames = 2
$moods = @(
    'idle',
    'running',
    'reasoning',
    'waiting',
    'error',
    'success',
    'offline',
    'power'
)

$bitmap = New-Object System.Drawing.Bitmap ($frameWidth * $frames), ($frameHeight * $moods.Count)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([System.Drawing.Color]::Transparent)

function New-Brush($hex) {
    return New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))
}

function New-Pen($hex, $width) {
    $pen = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml($hex), $width)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    return $pen
}

function New-RoundedRectPath($x, $y, $width, $height, $radius) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = $radius * 2
    $path.AddArc($x, $y, $diameter, $diameter, 180, 90)
    $path.AddArc($x + $width - $diameter, $y, $diameter, $diameter, 270, 90)
    $path.AddArc($x + $width - $diameter, $y + $height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($x, $y + $height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Draw-Frame($g, $originX, $originY, $mood, $frame) {
    $outline = New-Pen '#172033' 4
    $thin = New-Pen '#172033' 2
    $bodyBrush = New-Brush '#7c3aed'
    $bodyAccent = New-Brush '#38bdf8'
    $faceBrush = New-Brush '#f8fbff'
    $shadowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(34, 0, 0, 0))
    $white = New-Brush '#ffffff'
    $red = New-Brush '#ef4444'
    $green = New-Brush '#22c55e'
    $yellow = New-Brush '#facc15'
    $gray = New-Brush '#94a3b8'

    $bob = if ($frame -eq 0) { 0 } else { -3 }
    $cx = $originX + 64
    $cy = $originY + 68 + $bob

    if ($mood -eq 'offline') {
        $bodyBrush = New-Brush '#64748b'
        $bodyAccent = New-Brush '#cbd5e1'
    }
    if ($mood -eq 'power') {
        $bodyBrush = New-Brush '#f59e0b'
        $bodyAccent = New-Brush '#fef3c7'
    }

    $g.FillEllipse($shadowBrush, $originX + 31, $originY + 106, 66, 10)
    $bodyPath = New-RoundedRectPath ($cx - 30) ($cy - 42) 60 84 24
    $g.FillPath($bodyBrush, $bodyPath)
    $g.DrawPath($outline, $bodyPath)
    $bodyPath.Dispose()
    $g.FillEllipse($faceBrush, $cx - 24, $cy - 30, 48, 38)
    $g.DrawEllipse($thin, $cx - 24, $cy - 30, 48, 38)
    $g.FillRectangle($bodyAccent, $cx - 18, $cy + 24, 36, 9)
    $g.DrawRectangle($thin, $cx - 18, $cy + 24, 36, 9)

    $leftArmX = $cx - 30
    $rightArmX = $cx + 30
    $armY = $cy + 4
    $leftEnd = [System.Drawing.PointF]::new($leftArmX - 19, $armY + 11)
    $rightEnd = [System.Drawing.PointF]::new($rightArmX + 19, $armY + 11)

    switch ($mood) {
        'running' {
            $leftEnd = [System.Drawing.PointF]::new($leftArmX - 23, $armY + $(if ($frame -eq 0) { -10 } else { 13 }))
            $rightEnd = [System.Drawing.PointF]::new($rightArmX + 23, $armY + $(if ($frame -eq 0) { 13 } else { -10 }))
        }
        'reasoning' {
            $leftEnd = [System.Drawing.PointF]::new($leftArmX - 13, $armY - 2)
            $rightEnd = [System.Drawing.PointF]::new($rightArmX + 11, $armY - 22)
        }
        'waiting' {
            $leftEnd = [System.Drawing.PointF]::new($leftArmX - 20, $armY + 8)
            $rightEnd = [System.Drawing.PointF]::new($rightArmX + 14, $armY - 38)
        }
        'error' {
            $leftEnd = [System.Drawing.PointF]::new($cx + 12, $cy + 17)
            $rightEnd = [System.Drawing.PointF]::new($cx - 12, $cy + 17)
        }
        'success' {
            $leftEnd = [System.Drawing.PointF]::new($leftArmX - 18, $armY - 28)
            $rightEnd = [System.Drawing.PointF]::new($rightArmX + 18, $armY - 28)
        }
        'offline' {
            $leftEnd = [System.Drawing.PointF]::new($leftArmX - 15, $armY + 22)
            $rightEnd = [System.Drawing.PointF]::new($rightArmX + 15, $armY + 22)
        }
        'power' {
            $leftEnd = [System.Drawing.PointF]::new($leftArmX - 22, $armY - 4)
            $rightEnd = [System.Drawing.PointF]::new($rightArmX + 22, $armY - 4)
        }
    }

    $g.DrawLine($outline, $leftArmX, $armY, $leftEnd.X, $leftEnd.Y)
    $g.DrawLine($outline, $rightArmX, $armY, $rightEnd.X, $rightEnd.Y)

    $eyeY = $cy - 15
    if ($mood -eq 'offline') {
        $g.DrawLine($thin, $cx - 14, $eyeY, $cx - 6, $eyeY)
        $g.DrawLine($thin, $cx + 6, $eyeY, $cx + 14, $eyeY)
        $g.DrawArc($thin, $cx - 8, $eyeY + 11, 16, 8, 0, 180)
    } elseif ($mood -eq 'error') {
        $g.DrawLine($thin, $cx - 15, $eyeY - 3, $cx - 5, $eyeY + 4)
        $g.DrawLine($thin, $cx - 5, $eyeY - 3, $cx - 15, $eyeY + 4)
        $g.DrawLine($thin, $cx + 5, $eyeY - 3, $cx + 15, $eyeY + 4)
        $g.DrawLine($thin, $cx + 15, $eyeY - 3, $cx + 5, $eyeY + 4)
        $g.DrawArc($thin, $cx - 8, $eyeY + 14, 16, 8, 180, 180)
    } else {
        $g.FillEllipse($outline.Brush, $cx - 15, $eyeY - 4, 9, 12)
        $g.FillEllipse($outline.Brush, $cx + 6, $eyeY - 4, 9, 12)
        $g.FillEllipse($white, $cx - 12, $eyeY - 1, 3, 4)
        $g.FillEllipse($white, $cx + 9, $eyeY - 1, 3, 4)
        if ($mood -eq 'success') {
            $g.DrawArc($thin, $cx - 10, $eyeY + 10, 20, 12, 0, 180)
        } else {
            $g.DrawArc($thin, $cx - 7, $eyeY + 13, 14, 7, 0, 180)
        }
    }

    switch ($mood) {
        'reasoning' {
            $g.FillEllipse($white, $originX + 89, $originY + 20 + $bob, 8, 8)
            $g.FillEllipse($white, $originX + 100, $originY + 11 + $bob, 13, 13)
            $g.DrawString('?', (New-Object System.Drawing.Font 'Segoe UI', 13, ([System.Drawing.FontStyle]::Bold)), $outline.Brush, $originX + 102, $originY + 9 + $bob)
        }
        'waiting' {
            $g.FillEllipse($red, $originX + 94, $originY + 14 + $bob, 22, 22)
            $g.DrawString('!', (New-Object System.Drawing.Font 'Segoe UI', 18, ([System.Drawing.FontStyle]::Bold)), $white, $originX + 100, $originY + 9 + $bob)
        }
        'success' {
            $g.FillEllipse($green, $originX + 94, $originY + 16 + $bob, 22, 22)
            $g.DrawString('V', (New-Object System.Drawing.Font 'Segoe UI', 16, ([System.Drawing.FontStyle]::Bold)), $white, $originX + 98, $originY + 12 + $bob)
        }
        'power' {
            $points = @(
                [System.Drawing.PointF]::new($originX + 98, $originY + 13 + $bob),
                [System.Drawing.PointF]::new($originX + 84, $originY + 47 + $bob),
                [System.Drawing.PointF]::new($originX + 101, $originY + 42 + $bob),
                [System.Drawing.PointF]::new($originX + 91, $originY + 72 + $bob),
                [System.Drawing.PointF]::new($originX + 116, $originY + 34 + $bob),
                [System.Drawing.PointF]::new($originX + 99, $originY + 39 + $bob)
            )
            $g.FillPolygon($yellow, $points)
            $g.DrawPolygon($thin, $points)
        }
        'offline' {
            $g.DrawString('Z', (New-Object System.Drawing.Font 'Segoe UI', 16, ([System.Drawing.FontStyle]::Bold)), $gray, $originX + 95, $originY + 11 + $bob)
        }
    }

    $outline.Dispose()
    $thin.Dispose()
    $bodyBrush.Dispose()
    $bodyAccent.Dispose()
    $faceBrush.Dispose()
    $shadowBrush.Dispose()
    $white.Dispose()
    $red.Dispose()
    $green.Dispose()
    $yellow.Dispose()
    $gray.Dispose()
}

for ($row = 0; $row -lt $moods.Count; $row++) {
    for ($frame = 0; $frame -lt $frames; $frame++) {
        Draw-Frame $graphics ($frame * $frameWidth) ($row * $frameHeight) ($moods[$row]) $frame
    }
}

$bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
Write-Host "Wrote $outputPath"
