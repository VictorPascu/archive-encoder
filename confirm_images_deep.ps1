<#
  Deep confirmation for the image flow -- the pre-delete check.

  Per file, by what the output claims to be:
    converted lossless (.png/.bmp/.tiff -> .webp)  ->  PIXEL-HASH IDENTITY:
        both sides decoded to raw RGBA and hashed; equal = mathematically zero
        image difference. Stronger than anything the video flow can promise.
    converted lossy (regular tier .webp)           ->  SSIM against the source
        (>= threshold), plus a review pair saved for eyeballing.
    kept copies                                    ->  SHA-256 file identity.

  Writes encoded_images/confirm-images-deep.csv and review pairs into
  encoded_images/_review (viewable with the UI's review window convention:
  <label>_src.jpg / <label>_enc.jpg).
#>

[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [double]$LossyMinSsim = 0.97,
  [int]$ReviewPairs = 10
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
. "$PSScriptRoot\scripts_internal\_common.ps1"

$LosslessExt = @('.png','.bmp','.tif','.tiff')
$AllExt      = $LosslessExt + @('.jpg','.jpeg','.heic','.heif','.webp')
$outRoot   = Join-Path $RepoRoot 'encoded_images'
$reviewDir = Join-Path $outRoot '_review'

function Get-PixelHash {
  param([Parameter(Mandatory)][string]$Path)
  $r = Invoke-FFmpegCapture -Arguments @(
        '-hide_banner','-nostdin','-v','error','-i',$Path,
        '-frames:v','1','-pix_fmt','rgba','-f','framemd5','-')
  $m = [regex]::Match($r.Text, '([0-9a-f]{32})')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Get-ImageSsim {
  param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B, [string]$PreVfA = '')
  $graph = if ($PreVfA) { "[0:v]$PreVfA[a];[a][1:v]ssim" } else { '[0:v][1:v]ssim' }
  $r = Invoke-FFmpegCapture -Arguments @(
        '-hide_banner','-nostdin','-i',$A,'-i',$B,
        '-frames:v','1','-lavfi',$graph,'-f','null','-')
  $m = [regex]::Match($r.Text, 'All:\s*([0-9.]+)')
  if ($m.Success) { return [double]$m.Groups[1].Value }
  return $null
}

function Get-SourcePreVf {
  <# For a Display-P3 source whose encode was gamut-mapped to sRGB, the source
     must be mapped the same way before comparison -- otherwise SSIM punishes
     the DELIBERATE colorspace change instead of measuring encoding fidelity.
     Probe-based (self-contained), matching run_image_encode's logic. #>
  param([Parameter(Mandatory)][string]$SrcPath)
  $c = Get-ImageColorInfo -Path $SrcPath
  if ($c.HasIcc -and $c.Primaries -eq 'smpte432') { return (Get-P3MapFilter -ColorInfo $c) }
  return ''
}

function Write-ReviewPair {
  <# -SrcPreVf: when the encode was gamut-mapped, the source side of the pair
     gets the same map, so the pair compares ENCODING difference -- not the
     deliberate P3->sRGB change, which would otherwise dominate the eyeball. #>
  param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Enc, [Parameter(Mandatory)][string]$Label, [string]$SrcPreVf = '')
  if (-not (Test-Path -LiteralPath $reviewDir)) { New-Item -ItemType Directory -Path $reviewDir -Force | Out-Null }
  $base = Join-Path $reviewDir ($Label -replace '[^\w\-\.]','_')
  $scale = 'scale=min(1600\,iw):-1'
  $srcVf = if ($SrcPreVf) { "$SrcPreVf,$scale" } else { $scale }
  foreach ($side in @(@{P=$Src;S='src';VF=$srcVf}, @{P=$Enc;S='enc';VF=$scale})) {
    $null = Invoke-FFmpegCapture -Arguments @(
      '-hide_banner','-nostdin','-v','error','-i',$side.P,
      '-frames:v','1','-vf',$side.VF,'-q:v','3','-y',("{0}_{1}.jpg" -f $base, $side.S))
  }
}

$rows = New-Object System.Collections.Generic.List[object]
$lossyReviewed = 0
$sw = [Diagnostics.Stopwatch]::StartNew()

foreach ($tier in @('important','regular')) {
  $srcRoot = Join-Path $RepoRoot "sources_images\$tier"
  if (-not (Test-Path -LiteralPath $srcRoot)) { continue }
  $imgs = @(Get-ChildItem -LiteralPath $srcRoot -File -Recurse | Where-Object { $AllExt -contains $_.Extension.ToLower() })
  if (-not $imgs.Count) { continue }
  Write-Host ""
  Write-Host "=== tier '$tier': deep-verifying $($imgs.Count) image(s) ===" -ForegroundColor Cyan

  $n = 0
  foreach ($f in $imgs) {
    $n++
    $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\')
    $relDir = Split-Path $rel -Parent
    $outDir = if ($relDir) { Join-Path (Join-Path $outRoot $tier) $relDir } else { Join-Path $outRoot $tier }
    $webp = Join-Path $outDir ($f.Name + '.webp')
    $copy = Join-Path $outDir $f.Name

    $fails = New-Object System.Collections.Generic.List[string]
    $mode = ''; $detail = ''

    if (Test-Path -LiteralPath $webp) {
      if ($LosslessExt -contains $f.Extension.ToLower() -and $tier -eq 'important') {
        $mode = 'pixel_identity'
        $h1 = Get-PixelHash -Path $f.FullName
        $h2 = Get-PixelHash -Path $webp
        if (-not ($h1 -and $h2 -and $h1 -eq $h2)) { $fails.Add('pixels_differ') }
        $detail = 'raw RGBA hash equal'
      } else {
        $mode = 'ssim'
        $preVf = Get-SourcePreVf -SrcPath $f.FullName
        $ssim = Get-ImageSsim -A $f.FullName -B $webp -PreVfA $preVf
        if ($null -eq $ssim -or $ssim -lt $LossyMinSsim) { $fails.Add("ssim($ssim)") }
        $detail = 'ssim ' + $(if ($null -ne $ssim) { '{0:N4}' -f $ssim } else { 'n/a' }) + $(if ($preVf) { ' (P3-mapped)' } else { '' })
        if (-not $fails.Count -and $lossyReviewed -lt $ReviewPairs) {
          Write-ReviewPair -Src $f.FullName -Enc $webp -Label "img_${tier}_$($f.BaseName)" -SrcPreVf $preVf
          $lossyReviewed++
        }
      }
    }
    elseif (Test-Path -LiteralPath $copy) {
      $mode = 'file_identity'
      $hs = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
      $hc = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
      if ($hs -ne $hc) { $fails.Add('copy_hash_differs') }
      $detail = 'sha256 equal'
    }
    else { $mode = 'missing'; $fails.Add('missing_output') }

    $verdict = if ($fails.Count) { 'FAIL' } else { 'PASS' }
    if ($fails.Count -or ($n % 50 -eq 0)) {
      $col = if ($fails.Count) { 'Red' } else { 'DarkGray' }
      Write-Host ("  [{0,4}/{1}] {2,-42} {3,-14} {4}" -f $n, $imgs.Count, $rel, $mode, $(if ($fails.Count) { $fails -join ', ' } else { $detail })) -ForegroundColor $col
    }
    $rows.Add([pscustomobject]@{ tier=$tier; relpath=$rel; check=$mode; verdict=$verdict; detail=$detail; reasons=($fails -join '; ') })
  }
}

$sw.Stop()
if (-not $rows.Count) { Write-Host "`nNo images found under sources_images\." -ForegroundColor Yellow; exit 0 }
$csv = Join-Path $outRoot 'confirm-images-deep.csv'
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

$bad = @($rows | Where-Object verdict -ne 'PASS')
Write-Host ""
Write-Host "================ IMAGES DEEP CONFIRM ================" -ForegroundColor Cyan
$rows | Group-Object check | ForEach-Object {
  $f2 = @($_.Group | Where-Object verdict -ne 'PASS').Count
  Write-Host ("  {0,5} x {1,-15} failures: {2}" -f $_.Count, $_.Name, $f2) -ForegroundColor $(if ($f2) { 'Red' } else { 'Green' }) }
Write-Host ("  elapsed {0:N1} min   review pairs: {1} in {2}   csv: {3}" -f $sw.Elapsed.TotalMinutes, $lossyReviewed, $reviewDir, $csv)
if ($bad.Count) {
  Write-Host ""
  $bad | Select-Object -First 20 | ForEach-Object { Write-Host ("  FAIL {0}\{1}: {2}" -f $_.tier, $_.relpath, $_.reasons) -ForegroundColor Red }
  Write-Host "GATE: FAIL -- do NOT delete any originals." -ForegroundColor Red
  exit 1
}
Write-Host ""
Write-Host "GATE: PASS -- lossless conversions are PIXEL-IDENTICAL, copies are byte-identical," -ForegroundColor Green
Write-Host "lossy conversions cleared the SSIM gate (review pairs saved for your eyes)." -ForegroundColor Green
Write-Host "Deleting originals is YOUR action -- nothing here will ever do it." -ForegroundColor Green
exit 0
