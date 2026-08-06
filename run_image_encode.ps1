<#
  Image flow driver -- the picture-side sibling of run_encode.ps1.

  Tiers (mirroring the video flow):
    sources_images/important  ->  STRICTLY LOSSLESS.
        PNG/BMP/TIFF -> WebP lossless, and every conversion is verified
        pixel-identical (raw RGBA hash of both sides) BEFORE it is kept; any
        mismatch or non-benefit -> the original is copied unchanged. JPEG/HEIC
        are lossy formats already, so they are copied as-is (re-encoding them
        either loses quality or grows the file).
    sources_images/regular    ->  high-quality lossy allowed.
        Everything -> WebP quality 90, kept only if it is at least 20% smaller
        AND scores SSIM >= 0.97 against the source; otherwise falls back to
        the important-tier logic for that file.

  Outputs mirror the folder structure into encoded_images/. Converted files
  are named <original-name>.webp (suffix, not replacement -- collision-free
  and the source format stays visible); kept files keep their names.
  File mtimes are preserved. Sources are never written to. Re-runs skip
  finished files.

  Caveat (documented in README): WebP via ffmpeg does not carry EXIF/GPS
  metadata. Lossless-tier JPEGs are COPIED so their EXIF is intact; only
  converted files lose embedded metadata (file dates are preserved). Keep
  originals if EXIF matters to you -- which is the operating model anyway.
#>

[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [double]$LossyQuality = 90,
  [double]$LossyMinSaving = 0.20,
  [double]$LossyMinSsim = 0.97
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
. "$PSScriptRoot\scripts_internal\_common.ps1"

$LosslessExt = @('.png','.bmp','.tif','.tiff')
$LossyExt    = @('.jpg','.jpeg','.heic','.heif','.webp')
$AllExt      = $LosslessExt + $LossyExt

$outRoot  = Join-Path $RepoRoot 'encoded_images'
$manifest = Join-Path $outRoot 'images_manifest.csv'
if (-not (Test-Path -LiteralPath $outRoot)) { New-Item -ItemType Directory -Path $outRoot -Force | Out-Null }

function Get-PixelHash {
  <# Hash of the fully decoded RGBA pixels -- the ground truth two images are
     identical, independent of container/compression. $null on failure. #>
  param([Parameter(Mandatory)][string]$Path)
  $r = Invoke-FFmpegCapture -Arguments @(
        '-hide_banner','-nostdin','-v','error','-i',$Path,
        '-frames:v','1','-pix_fmt','rgba','-f','framemd5','-')
  $m = [regex]::Match($r.Text, '([0-9a-f]{32})')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Get-ImageSsim {
  <# -PreVfA applies a filter to the A (source) side first -- used to compare a
     gamut-mapped encode against the source mapped the same way, so SSIM
     measures ENCODING fidelity rather than the deliberate colorspace change. #>
  param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B, [string]$PreVfA = '')
  $graph = if ($PreVfA) { "[0:v]$PreVfA[a];[a][1:v]ssim" } else { '[0:v][1:v]ssim' }
  $r = Invoke-FFmpegCapture -Arguments @(
        '-hide_banner','-nostdin','-i',$A,'-i',$B,
        '-frames:v','1','-lavfi',$graph,'-f','null','-')
  $m = [regex]::Match($r.Text, 'All:\s*([0-9.]+)')
  if ($m.Success) { return [double]$m.Groups[1].Value }
  return $null
}

function Convert-ToWebp {
  param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Dst, [switch]$Lossless, [double]$Quality = 90, [string]$PreVf = '')
  $enc = if ($Lossless) { @('-c:v','libwebp','-lossless','1','-quality','100','-compression_level','6') }
         else           { @('-c:v','libwebp','-quality',"$Quality") }
  $vf = if ($PreVf) { @('-vf',$PreVf) } else { @() }
  $r = Invoke-FFmpegCapture -Arguments (@(
        '-hide_banner','-nostdin','-v','error','-i',$Src,'-frames:v','1') + $vf + $enc + @('-y',$Dst))
  return ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $Dst) -and (Get-Item -LiteralPath $Dst).Length -gt 0)
}

# (Get-ImageColorInfo / Get-P3MapFilter live in _common.ps1 -- shared with
#  confirm_images_deep.ps1, which must judge gamut-mapped files the same way.)

function Copy-Preserving {
  param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Dst)
  Copy-Item -LiteralPath $Src -Destination $Dst -Force
}

function Invoke-ImageFile {
  <# Encodes/copies ONE image per tier policy. Returns a manifest row. #>
  param([Parameter(Mandatory)]$File, [Parameter(Mandatory)][string]$Tier, [Parameter(Mandatory)][string]$OutDir)

  $ext = $File.Extension.ToLower()
  $webpOut = Join-Path $OutDir ($File.Name + '.webp')
  $copyOut = Join-Path $OutDir $File.Name

  # resume: either form of output already present and non-empty
  foreach ($existing in @($webpOut, $copyOut)) {
    if ((Test-Path -LiteralPath $existing) -and (Get-Item -LiteralPath $existing).Length -gt 0) {
      return [pscustomobject]@{ name=$File.Name; action='SKIPPED_EXISTING'; reason='output already present'
        src_bytes=$File.Length; out_bytes=(Get-Item -LiteralPath $existing).Length
        pixel_identical=''; ssim=''; out_name=(Split-Path $existing -Leaf) }
    }
  }

  $tmp = "$webpOut.tmp.webp"
  $color = Get-ImageColorInfo -Path $File.FullName

  # ---- regular tier: try high-quality lossy first
  if ($Tier -eq 'regular') {
    $preVf = ''; $colorNote = ''
    $lossyAllowed = $true
    if ($color.HasIcc) {
      if ($color.Primaries -eq 'smpte432') {
        # Display-P3: WebP cannot carry the profile, so gamut-map the pixels to
        # sRGB -- correct rendering everywhere, small clip on extreme colors
        $preVf = Get-P3MapFilter -ColorInfo $color
        $colorNote = ', P3->sRGB gamut-mapped'
      } elseif ($color.Primaries -and $color.Primaries -notin @('bt709','unknown')) {
        # some other wide-gamut profile we don't have a mapping for: refuse
        $lossyAllowed = $false
      }
    }
    if ($lossyAllowed -and (Convert-ToWebp -Src $File.FullName -Dst $tmp -Quality $LossyQuality -PreVf $preVf)) {
      $newSize = (Get-Item -LiteralPath $tmp).Length
      if ($newSize -le $File.Length * (1 - $LossyMinSaving)) {
        $ssim = Get-ImageSsim -A $File.FullName -B $tmp -PreVfA $preVf
        if ($null -ne $ssim -and $ssim -ge $LossyMinSsim) {
          Move-Item -LiteralPath $tmp -Destination $webpOut -Force
          return [pscustomobject]@{ name=$File.Name; action='webp_lossy'; reason="q$LossyQuality, ssim $('{0:N4}' -f $ssim)$colorNote"
            src_bytes=$File.Length; out_bytes=$newSize; pixel_identical=''; ssim=('{0:N4}' -f $ssim)
            out_name=(Split-Path $webpOut -Leaf) }
        }
      }
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    # falls through to lossless logic below
  }

  # ---- sources with an embedded color profile must not be converted losslessly:
  # the pixels would survive but the PROFILE cannot ride in a WebP, and a
  # profile-stripped image renders wrong in managed viewers. Keep the original.
  if ($color.HasIcc -and $LosslessExt -contains $ext) {
    Copy-Preserving -Src $File.FullName -Dst $copyOut
    return [pscustomobject]@{ name=$File.Name; action='copied'; reason="embedded color profile ($($color.Primaries)) -- WebP cannot carry it; original kept"
      src_bytes=$File.Length; out_bytes=$File.Length; pixel_identical=''; ssim=''; out_name=$File.Name }
  }

  # ---- lossless-capable sources: WebP lossless, self-verified pixel-identical
  if ($LosslessExt -contains $ext) {
    if (Convert-ToWebp -Src $File.FullName -Dst $tmp -Lossless) {
      $newSize = (Get-Item -LiteralPath $tmp).Length
      if ($newSize -lt $File.Length * 0.95) {
        $hSrc = Get-PixelHash -Path $File.FullName
        $hOut = Get-PixelHash -Path $tmp
        if ($hSrc -and $hOut -and $hSrc -eq $hOut) {
          Move-Item -LiteralPath $tmp -Destination $webpOut -Force
          return [pscustomobject]@{ name=$File.Name; action='webp_lossless'; reason='pixel-identical, verified at encode time'
            src_bytes=$File.Length; out_bytes=$newSize; pixel_identical='True'; ssim=''
            out_name=(Split-Path $webpOut -Leaf) }
        }
        # pixels differ (ICC/colorspace edge) -> refuse the conversion
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Copy-Preserving -Src $File.FullName -Dst $copyOut
        return [pscustomobject]@{ name=$File.Name; action='copied'; reason='conversion NOT pixel-identical -- refused, original kept'
          src_bytes=$File.Length; out_bytes=$File.Length; pixel_identical='False'; ssim=''
          out_name=$File.Name }
      }
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      Copy-Preserving -Src $File.FullName -Dst $copyOut
      return [pscustomobject]@{ name=$File.Name; action='copied'; reason='webp-lossless not meaningfully smaller'
        src_bytes=$File.Length; out_bytes=$File.Length; pixel_identical=''; ssim=''; out_name=$File.Name }
    }
    Copy-Preserving -Src $File.FullName -Dst $copyOut
    return [pscustomobject]@{ name=$File.Name; action='copied'; reason='webp encode failed (odd format/size?) -- original kept'
      src_bytes=$File.Length; out_bytes=$File.Length; pixel_identical=''; ssim=''; out_name=$File.Name }
  }

  # ---- already-lossy sources in the lossless tier: keep as-is (EXIF intact)
  Copy-Preserving -Src $File.FullName -Dst $copyOut
  return [pscustomobject]@{ name=$File.Name; action='copied'; reason='lossy source format -- re-encoding would lose quality; kept as-is'
    src_bytes=$File.Length; out_bytes=$File.Length; pixel_identical=''; ssim=''; out_name=$File.Name }
}

# ================================================================= run
$allRows = New-Object System.Collections.Generic.List[object]
$sw = [Diagnostics.Stopwatch]::StartNew()

foreach ($tier in @('important','regular')) {
  $srcRoot = Join-Path $RepoRoot "sources_images\$tier"
  if (-not (Test-Path -LiteralPath $srcRoot)) { continue }
  $imgs = @(Get-ChildItem -LiteralPath $srcRoot -File -Recurse | Where-Object { $AllExt -contains $_.Extension.ToLower() })
  if (-not $imgs.Count) { Write-Host "tier '$tier': no images, skipping" -ForegroundColor DarkGray; continue }

  Write-Host ""
  Write-Host ("=== tier '{0}': {1} image(s), {2:N1} MB ===" -f $tier, $imgs.Count, (($imgs | Measure-Object Length -Sum).Sum/1MB)) -ForegroundColor Cyan

  $n = 0
  foreach ($f in $imgs) {
    $n++
    $rel = Split-Path ($f.FullName.Substring($srcRoot.Length).TrimStart('\')) -Parent
    $outDir = if ($rel) { Join-Path (Join-Path $outRoot $tier) $rel } else { Join-Path $outRoot $tier }
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

    $row = Invoke-ImageFile -File $f -Tier $tier -OutDir $outDir
    $row | Add-Member -NotePropertyName tier -NotePropertyValue $tier -Force
    $row | Add-Member -NotePropertyName relpath -NotePropertyValue $(if ($rel) { Join-Path $rel $f.Name } else { $f.Name }) -Force
    $allRows.Add($row)

    # keep chronology: output carries the source's file dates
    $outFile = Join-Path $outDir $row.out_name
    if (Test-Path -LiteralPath $outFile) {
      $oi = Get-Item -LiteralPath $outFile
      $oi.LastWriteTime = $f.LastWriteTime
      try { $oi.CreationTime = $f.CreationTime } catch { }
    }

    $col = switch ($row.action) { 'webp_lossless' {'Green'} 'webp_lossy' {'Green'} 'SKIPPED_EXISTING' {'DarkGray'} default {'Yellow'} }
    $ratio = if ($row.out_bytes -gt 0) { '{0:N2}x' -f ($row.src_bytes / $row.out_bytes) } else { '-' }
    Write-Host ("[{0,4}/{1}] {2,-40} {3,-16} {4,8} -> {5,8}  {6,6}  {7}" -f `
      $n, $imgs.Count, $row.relpath, $row.action, (Format-Bytes $row.src_bytes), (Format-Bytes $row.out_bytes), $ratio, $row.reason) -ForegroundColor $col

    if (($n % 25) -eq 0) { $allRows | Export-Csv -LiteralPath $manifest -NoTypeInformation -Encoding UTF8 }
  }
}

$sw.Stop()
if (-not $allRows.Count) { Write-Host "`nNothing found under sources_images\ -- put images in important\ or regular\ first." -ForegroundColor Yellow; exit 0 }
$allRows | Export-Csv -LiteralPath $manifest -NoTypeInformation -Encoding UTF8

$srcT = ($allRows | Measure-Object src_bytes -Sum).Sum
$outT = ($allRows | Measure-Object out_bytes -Sum).Sum
Write-Host ""
Write-Host "==================== IMAGE ENCODE RESULT ====================" -ForegroundColor Cyan
$allRows | Group-Object action | Sort-Object Count -Descending | ForEach-Object {
  Write-Host ("  {0,5} x {1,-18} {2,10} -> {3,10}" -f $_.Count, $_.Name,
    (Format-Bytes (($_.Group | Measure-Object src_bytes -Sum).Sum)),
    (Format-Bytes (($_.Group | Measure-Object out_bytes -Sum).Sum))) }
Write-Host ("  total: {0} -> {1}  ({2:N2}x, saved {3})  in {4:N1} min" -f `
  (Format-Bytes $srcT), (Format-Bytes $outT), $(if ($outT) { $srcT/$outT } else { 1 }), (Format-Bytes ($srcT-$outT)), $sw.Elapsed.TotalMinutes) -ForegroundColor Green
Write-Host ("  manifest: {0}" -f $manifest)
Write-Host ""
Write-Host "Next: .\confirm_images_quick.ps1, then .\confirm_images_deep.ps1 before trusting the set." -ForegroundColor DarkGray
exit 0
