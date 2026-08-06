<#
.SYNOPSIS
    Regenerates every icon asset the app ships from a single vector definition.

.DESCRIPTION
    Produces two sets of artwork from the same drawing code:

      1. src/AccessibilityMapper.App/Assets/Icons/app.ico
         The Win32 icon embedded in the executable (Explorer, taskbar, Alt-Tab,
         window chrome). Frames are PNG-compressed, which every Windows release in
         our supported range (10.0.17763+) reads natively.

      2. build/Package/Images/*.png
         The Microsoft Store / MSIX logo set, including the scale- and targetsize-
         qualified variants that makepri.exe indexes into resources.pri.

    Re-run this after changing the artwork below; the outputs are committed so a
    normal build never depends on this script.

.EXAMPLE
    pwsh -File build/New-AppIcons.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

$repoRoot  = Split-Path -Parent $PSScriptRoot
$icoPath   = Join-Path $repoRoot 'src\AccessibilityMapper.App\Assets\Icons\app.ico'
$imagesDir = Join-Path $PSScriptRoot 'Package\Images'

# ---------------------------------------------------------------------------
# Artwork. Drawn in a 256x256 design space and scaled to each output size, so
# every asset is redrawn at its native resolution rather than resampled.
#
# Mirrors the macOS app icon (issues.md #1): a light blue rounded frame around a
# cyan-to-green map, faint contour lines across it, and a centred orange map pin
# carrying the International Symbol of Access. Corners are transparent, so the
# icon looks correct on any background.
#
# Below 32 px the frame, map and contours turn to mush, so Get-IconBitmap asks
# for -Simplified and gets an enlarged pin and glyph on transparency instead.
# ---------------------------------------------------------------------------
$DESIGN = 256.0

function New-Color([string]$hex) {
    return [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($hex)
}

function New-Brush([string]$hex) {
    return New-Object System.Windows.Media.SolidColorBrush((New-Color $hex))
}

function New-Pt([double]$x, [double]$y) {
    return New-Object System.Windows.Point($x, $y)
}

<# The map pin silhouette: a circular head unioned with a triangle whose sides
   are tangent to that circle, which is what gives the teardrop its straight
   flanks meeting at the tip without hand-fitting Bezier control points. #>
function New-PinGeometry {
    # Proportions measured off the macOS icon: the pin is ~42% of the frame width
    # and centred, with the head a touch above centre.
    $cx = 128.0; $cy = 100.0; $r = 46.0; $tipY = 188.0

    $head = New-Object System.Windows.Media.EllipseGeometry((New-Pt $cx $cy), $r, $r)

    # Tangent points sit at +/-acos(r/d) either side of straight-down.
    $d = $tipY - $cy
    $a = [Math]::Acos($r / $d)
    $dx = $r * [Math]::Sin($a)
    $dy = $r * [Math]::Cos($a)

    $figure = New-Object System.Windows.Media.PathFigure
    $figure.StartPoint = New-Pt ($cx - $dx) ($cy + $dy)
    $figure.Segments.Add((New-Object System.Windows.Media.LineSegment((New-Pt ($cx + $dx) ($cy + $dy)), $false)))
    $figure.Segments.Add((New-Object System.Windows.Media.LineSegment((New-Pt $cx $tipY), $false)))
    $figure.IsClosed = $true

    $triangle = New-Object System.Windows.Media.PathGeometry
    $triangle.Figures.Add($figure)

    return New-Object System.Windows.Media.CombinedGeometry(
        [System.Windows.Media.GeometryCombineMode]::Union, $head, $triangle)
}

<# International Symbol of Access as the macOS icon draws it: a seated figure
   facing right, with the wheel an arc left OPEN at the upper right so the thigh
   exits cleanly. Drawing the wheel as a closed ring instead puts a stroke
   straight across it and the whole thing reads as a prohibition sign.
   Sized for a radius-50 pin head centred on (128, 100). #>
function Draw-AccessGlyph {
    param([Parameter(Mandatory)]$Dc)

    $glyph = New-Brush '#FFFBFAEF'

    # Laid out at full head size, then eased in so it keeps the margin the macOS
    # icon leaves between the figure and the edge of the pin head.
    $Dc.PushTransform((New-Object System.Windows.Media.ScaleTransform(0.84, 0.84, 128, 100)))

    function New-LimbPen([double]$thickness) {
        $pen = New-Object System.Windows.Media.Pen($glyph, $thickness)
        $pen.StartLineCap = [System.Windows.Media.PenLineCap]::Round
        $pen.EndLineCap   = [System.Windows.Media.PenLineCap]::Round
        $pen.LineJoin     = [System.Windows.Media.PenLineJoin]::Round
        return $pen
    }

    # Head.
    $Dc.DrawEllipse($glyph, $null, (New-Pt 117.0 74.0), 9.5, 9.5)

    # Wheel: an arc from about 1 o'clock, the long way round, to about 5 o'clock.
    $wheelCentre = New-Pt 122.0 112.0
    $wheelR = 24.0
    $startAngle = -55.0 * [Math]::PI / 180.0
    $endAngle   =  60.0 * [Math]::PI / 180.0
    $wheelFigure = New-Object System.Windows.Media.PathFigure
    $wheelFigure.StartPoint = New-Pt ($wheelCentre.X + $wheelR * [Math]::Cos($startAngle)) `
                                     ($wheelCentre.Y + $wheelR * [Math]::Sin($startAngle))
    $wheelFigure.Segments.Add((New-Object System.Windows.Media.ArcSegment(
        (New-Pt ($wheelCentre.X + $wheelR * [Math]::Cos($endAngle)) `
                ($wheelCentre.Y + $wheelR * [Math]::Sin($endAngle))),
        (New-Object System.Windows.Size($wheelR, $wheelR)),
        0.0, $true, [System.Windows.Media.SweepDirection]::Counterclockwise, $true)))
    $wheel = New-Object System.Windows.Media.PathGeometry
    $wheel.Figures.Add($wheelFigure)
    $Dc.DrawGeometry($null, (New-LimbPen 8.0), $wheel)

    # Torso, then thigh out to the shin and foot.
    $body = New-Object System.Windows.Media.PathGeometry
    $bodyFigure = New-Object System.Windows.Media.PathFigure
    $bodyFigure.StartPoint = New-Pt 116.0 87.0
    $bodyFigure.Segments.Add((New-Object System.Windows.Media.LineSegment((New-Pt 118.0 108.0), $true)))
    $bodyFigure.Segments.Add((New-Object System.Windows.Media.LineSegment((New-Pt 145.0 111.0), $true)))
    $bodyFigure.Segments.Add((New-Object System.Windows.Media.LineSegment((New-Pt 151.0 129.0), $true)))
    $body.Figures.Add($bodyFigure)
    $Dc.DrawGeometry($null, (New-LimbPen 11.0), $body)

    # Arm reaching forward, and the foot.
    $Dc.DrawLine((New-LimbPen 10.0), (New-Pt 118.0 95.0), (New-Pt 141.0 95.0))
    $Dc.DrawLine((New-LimbPen 9.0),  (New-Pt 149.0 132.0), (New-Pt 159.0 130.0))

    $Dc.Pop()
}

function New-IconDrawing {
    param([switch]$Simplified)

    $visual = New-Object System.Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()

    if (-not $Simplified) {
        # Frame, ~5% of the icon width thick.
        $frame = New-Object System.Windows.Rect(8, 8, 240, 240)
        $dc.DrawRoundedRectangle((New-Brush '#FF48B5EF'), $null, $frame, 54, 54)

        # Map interior. The macOS art is a four-corner blend; a diagonal ramp
        # through the average of the two off-diagonal corners reproduces it
        # closely enough, and LinearGradientBrush can express it directly.
        $map = New-Object System.Windows.Rect(21, 21, 214, 214)
        $mapBrush = New-Object System.Windows.Media.LinearGradientBrush
        $mapBrush.StartPoint = New-Pt 0 0
        $mapBrush.EndPoint   = New-Pt 1 1
        $mapBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-Color '#FF89E4FA'), 0.0)))
        $mapBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-Color '#FF8DE0BC'), 0.5)))
        $mapBrush.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-Color '#FF9EDC7B'), 1.0)))

        $mapGeometry = New-Object System.Windows.Media.RectangleGeometry($map, 42, 42)
        $dc.DrawGeometry($mapBrush, $null, $mapGeometry)

        # Contour and road hints, clipped to the map so they never touch the frame.
        $dc.PushClip($mapGeometry)

        $contour = New-Object System.Windows.Media.Pen((New-Brush '#2E0B6B5A'), 4.0)
        $contour.StartLineCap = [System.Windows.Media.PenLineCap]::Round
        $contour.EndLineCap   = [System.Windows.Media.PenLineCap]::Round

        $curves = @(
            @((New-Pt 21 62),  (New-Pt 68 46),   (New-Pt 116 80),  (New-Pt 172 54)),
            @((New-Pt 21 96),  (New-Pt 74 82),   (New-Pt 120 112), (New-Pt 190 88)),
            @((New-Pt 21 196), (New-Pt 78 176),  (New-Pt 132 206), (New-Pt 196 178)),
            @((New-Pt 21 222), (New-Pt 84 210),  (New-Pt 140 232), (New-Pt 214 208)),
            @((New-Pt 150 21), (New-Pt 172 62),  (New-Pt 150 104), (New-Pt 176 150)),
            @((New-Pt 196 46), (New-Pt 216 92),  (New-Pt 198 132), (New-Pt 222 176)),
            @((New-Pt 52 21),  (New-Pt 38 66),   (New-Pt 62 108),  (New-Pt 44 156))
        )
        foreach ($c in $curves) {
            $figure = New-Object System.Windows.Media.PathFigure
            $figure.StartPoint = $c[0]
            $figure.Segments.Add((New-Object System.Windows.Media.BezierSegment($c[1], $c[2], $c[3], $true)))
            $path = New-Object System.Windows.Media.PathGeometry
            $path.Figures.Add($figure)
            $dc.DrawGeometry($null, $contour, $path)
        }

        # A road easing across the lower map. Kept faint: at 48 px anything
        # stronger reads as a crack across the icon rather than a map feature.
        $road = New-Object System.Windows.Media.Pen((New-Brush '#22FFFFFF'), 7.0)
        $dc.DrawLine($road, (New-Pt 21 162), (New-Pt 235 142))

        $dc.Pop()
    }

    $pin = New-PinGeometry

    # Without the frame the pin has the whole canvas, so it grows to use it.
    if ($Simplified) {
        $dc.PushTransform((New-Object System.Windows.Media.ScaleTransform(1.7, 1.7, 128, 132)))
    }

    # Offset silhouettes stand in for a blur: RenderTargetBitmap does not apply
    # Effects reliably, and at icon sizes the difference is invisible.
    $dc.PushTransform((New-Object System.Windows.Media.TranslateTransform(0, 5)))
    $dc.DrawGeometry((New-Brush '#1A000000'), $null, $pin)
    $dc.Pop()
    $dc.PushTransform((New-Object System.Windows.Media.TranslateTransform(0, 2)))
    $dc.DrawGeometry((New-Brush '#14000000'), $null, $pin)
    $dc.Pop()

    $pinBrush = New-Object System.Windows.Media.LinearGradientBrush(
        (New-Color '#FFF1562B'), (New-Color '#FFE94B25'), 90.0)
    $dc.DrawGeometry($pinBrush, $null, $pin)

    Draw-AccessGlyph -Dc $dc

    if ($Simplified) { $dc.Pop() }

    $dc.Close()
    return $visual
}

<# Renders the icon centred on a transparent canvas of the requested pixel size.
   Non-square canvases (wide tiles, splash screen) letterbox the square artwork
   rather than distorting it. #>
function Get-IconBitmap {
    param(
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [double]$Coverage = 1.0
    )

    # Below 32 rendered pixels the frame and contour lines stop resolving, so the
    # artwork falls back to pin + glyph alone (issues.md #1).
    # 32 px included: with the frame in play the wheelchair is about six pixels
    # across there, and the acceptance criterion is that it stays readable.
    $rendered = [Math]::Min($Width, $Height) * $Coverage
    $art = New-IconDrawing -Simplified:($rendered -le 32)
    $scale = $rendered / $DESIGN

    $host_ = New-Object System.Windows.Media.DrawingVisual
    $dc = $host_.RenderOpen()
    $offsetX = ($Width  - ($DESIGN * $scale)) / 2.0
    $offsetY = ($Height - ($DESIGN * $scale)) / 2.0
    $dc.PushTransform((New-Object System.Windows.Media.TranslateTransform($offsetX, $offsetY)))
    $dc.PushTransform((New-Object System.Windows.Media.ScaleTransform($scale, $scale)))
    $dc.DrawDrawing($art.Drawing)
    $dc.Pop()
    $dc.Pop()
    $dc.Close()

    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
        $Width, $Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($host_)
    return $rtb
}

function Get-PngBytes {
    param([Parameter(Mandatory)]$Bitmap)

    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $stream = New-Object System.IO.MemoryStream
    $encoder.Save($stream)

    # Unary comma: without it PowerShell unrolls the byte[] into the pipeline and the
    # caller gets a loosely typed object[], which binds BinaryWriter.Write to the
    # wrong overload.
    return , $stream.ToArray()
}

function Save-Png {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [double]$Coverage = 1.0
    )

    $bytes = Get-PngBytes (Get-IconBitmap -Width $Width -Height $Height -Coverage $Coverage)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

<# Writes a multi-frame .ico. Each frame is a complete PNG file; the ICONDIRENTRY
   records its length and offset. Width/height bytes are 0 for 256 px by spec. #>
function Save-Ico {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int[]]$Sizes
    )

    $frames = New-Object System.Collections.Generic.List[byte[]]
    foreach ($size in $Sizes) {
        [byte[]]$frame = Get-PngBytes (Get-IconBitmap -Width $size -Height $size)
        $frames.Add($frame)
    }

    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)

    $writer.Write([uint16]0)              # reserved
    $writer.Write([uint16]1)              # type: icon
    $writer.Write([uint16]$Sizes.Count)

    $offset = 6 + (16 * $Sizes.Count)
    for ($i = 0; $i -lt $Sizes.Count; $i++) {
        $size = $Sizes[$i]
        $dimension = 0
        if ($size -lt 256) { $dimension = $size }

        $writer.Write([byte]$dimension)   # width  (0 => 256)
        $writer.Write([byte]$dimension)   # height (0 => 256)
        $writer.Write([byte]0)            # palette entries
        $writer.Write([byte]0)            # reserved
        $writer.Write([uint16]1)          # colour planes
        $writer.Write([uint16]32)         # bits per pixel
        $writer.Write([uint32]$frames[$i].Length)
        $writer.Write([uint32]$offset)
        $offset += $frames[$i].Length
    }

    foreach ($frame in $frames) { $writer.Write($frame, 0, $frame.Length) }

    $writer.Flush()
    [System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
    $writer.Dispose()
}

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $icoPath) | Out-Null
New-Item -ItemType Directory -Force -Path $imagesDir | Out-Null

Save-Ico -Path $icoPath -Sizes @(16, 20, 24, 32, 40, 48, 64, 128, 256)
Write-Host "app.ico          -> $icoPath"

# Base tile sizes at 100% scale. Coverage < 1 leaves the padding Windows expects
# around tile artwork so the icon is not flush to the tile edge.
$tiles = @(
    @{ Name = 'Square44x44Logo';   W = 44;  H = 44;  Coverage = 1.00 },
    @{ Name = 'Square71x71Logo';   W = 71;  H = 71;  Coverage = 0.72 },
    @{ Name = 'Square150x150Logo'; W = 150; H = 150; Coverage = 0.66 },
    @{ Name = 'Square310x310Logo'; W = 310; H = 310; Coverage = 0.60 },
    @{ Name = 'Wide310x150Logo';   W = 310; H = 150; Coverage = 0.66 },
    @{ Name = 'StoreLogo';         W = 50;  H = 50;  Coverage = 1.00 },
    @{ Name = 'SplashScreen';      W = 620; H = 300; Coverage = 0.55 }
)

$scales = @(100, 125, 150, 200, 400)
$emitted = 0

foreach ($tile in $tiles) {
    foreach ($scale in $scales) {
        $w = [int][Math]::Round($tile.W * $scale / 100.0)
        $h = [int][Math]::Round($tile.H * $scale / 100.0)
        $path = Join-Path $imagesDir ("{0}.scale-{1}.png" -f $tile.Name, $scale)
        Save-Png -Path $path -Width $w -Height $h -Coverage $tile.Coverage
        $emitted++
    }
}

# Target-size variants drive the taskbar, Alt-Tab and the Start "all apps" list.
# The unplated form is what Windows shows without a coloured backplate.
foreach ($size in @(16, 24, 32, 48, 256)) {
    foreach ($suffix in @('', '_altform-unplated')) {
        $path = Join-Path $imagesDir ("Square44x44Logo.targetsize-{0}{1}.png" -f $size, $suffix)
        Save-Png -Path $path -Width $size -Height $size
        $emitted++
    }
}

Write-Host "MSIX logo assets -> $imagesDir ($emitted files)"
