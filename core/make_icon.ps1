<#
  Generates assets\icon.ico -- the app icon, drawn in code so it is
  reproducible and license-free. Design: dark rounded tile, a cyan-to-green
  play triangle, and three shrinking bars suggesting compression.

  Output is a single 256x256 PNG-compressed ICO entry (valid since Vista;
  Explorer and shortcuts downscale it for small sizes).
#>

[CmdletBinding()]
param([string]$OutPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\icon.ico'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$size = 256
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)

# rounded dark tile
$r = 44
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc(4, 4, $r, $r, 180, 90)
$path.AddArc($size-4-$r, 4, $r, $r, 270, 90)
$path.AddArc($size-4-$r, $size-4-$r, $r, $r, 0, 90)
$path.AddArc(4, $size-4-$r, $r, $r, 90, 90)
$path.CloseFigure()
$tile = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
  (New-Object System.Drawing.Point(0,0)), (New-Object System.Drawing.Point(0,$size)),
  [System.Drawing.Color]::FromArgb(255, 34, 38, 54),
  [System.Drawing.Color]::FromArgb(255, 22, 24, 36))
$g.FillPath($tile, $path)

# play triangle, cyan -> green gradient
$tri = @(
  (New-Object System.Drawing.PointF(76, 62)),
  (New-Object System.Drawing.PointF(76, 194)),
  (New-Object System.Drawing.PointF(172, 128))
)
$triBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
  (New-Object System.Drawing.Point(76,62)), (New-Object System.Drawing.Point(172,194)),
  [System.Drawing.Color]::FromArgb(255, 80, 200, 255),
  [System.Drawing.Color]::FromArgb(255, 120, 230, 140))
$g.FillPolygon($triBrush, $tri)

# three shrinking bars = compression
$barBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 120, 230, 140))
$g.FillRectangle($barBrush, 190, 86, 42, 16)
$g.FillRectangle($barBrush, 190, 120, 28, 16)
$g.FillRectangle($barBrush, 190, 154, 16, 16)

$g.Dispose()

# PNG bytes -> single-entry ICO (width/height byte 0 == 256)
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$png = $ms.ToArray(); $ms.Dispose(); $bmp.Dispose()

$dir = Split-Path $OutPath -Parent
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$fs = [System.IO.File]::Create($OutPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)   # ICONDIR
$bw.Write([byte]0); $bw.Write([byte]0)                            # 256x256
$bw.Write([byte]0); $bw.Write([byte]0)                            # colors, reserved
$bw.Write([uint16]1); $bw.Write([uint16]32)                       # planes, bpp
$bw.Write([uint32]$png.Length); $bw.Write([uint32]22)             # size, offset
$bw.Write($png)
$bw.Dispose(); $fs.Dispose()

Write-Host "wrote $OutPath ($([math]::Round((Get-Item $OutPath).Length/1KB,1)) KB)"
