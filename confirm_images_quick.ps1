<#
  Rapid check of the image flow: does EVERY image under sources_images/ have an
  output (converted .webp or kept copy), with matching dimensions and sane size?
  Seconds per hundred files. Pixel-level proof is confirm_images_deep.ps1's job.
#>

[CmdletBinding()]
param([string]$RepoRoot = '')

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
. "$PSScriptRoot\scripts_internal\_common.ps1"

$AllExt = @('.png','.bmp','.tif','.tiff','.jpg','.jpeg','.heic','.heif','.webp')
$outRoot = Join-Path $RepoRoot 'encoded_images'

function Get-ImageDims {
  param([Parameter(Mandatory)][string]$Path)
  $raw = Invoke-FFprobeJson -Arguments @('-v','error','-select_streams','v:0',
           '-show_entries','stream=width,height','-of','csv=p=0','--',$Path)
  $m = [regex]::Match($raw, '(\d+),(\d+)')
  if ($m.Success) { return @([int]$m.Groups[1].Value, [int]$m.Groups[2].Value) }
  return $null
}

$rows = New-Object System.Collections.Generic.List[object]
$sw = [Diagnostics.Stopwatch]::StartNew()

foreach ($tier in @('important','regular')) {
  $srcRoot = Join-Path $RepoRoot "sources_images\$tier"
  if (-not (Test-Path -LiteralPath $srcRoot)) { continue }
  $imgs = @(Get-ChildItem -LiteralPath $srcRoot -File -Recurse | Where-Object { $AllExt -contains $_.Extension.ToLower() })
  if (-not $imgs.Count) { continue }
  Write-Host ""
  Write-Host "=== tier '$tier': $($imgs.Count) image(s) ===" -ForegroundColor Cyan

  foreach ($f in $imgs) {
    $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\')
    $relDir = Split-Path $rel -Parent
    $outDir = if ($relDir) { Join-Path (Join-Path $outRoot $tier) $relDir } else { Join-Path $outRoot $tier }
    $webp = Join-Path $outDir ($f.Name + '.webp')
    $copy = Join-Path $outDir $f.Name
    $out = if (Test-Path -LiteralPath $webp) { $webp } elseif (Test-Path -LiteralPath $copy) { $copy } else { $null }

    $fails = New-Object System.Collections.Generic.List[string]
    if (-not $out) { $fails.Add('missing_output') }
    else {
      if ((Get-Item -LiteralPath $out).Length -le 0) { $fails.Add('empty_output') }
      $ds = Get-ImageDims -Path $f.FullName
      $do = Get-ImageDims -Path $out
      if ($ds -and $do -and (($ds[0] -ne $do[0]) -or ($ds[1] -ne $do[1]))) {
        $fails.Add("dims($($do[0])x$($do[1])vs$($ds[0])x$($ds[1]))")
      }
      if ((Split-Path $out -Leaf) -eq $f.Name) {
        if ((Get-Item -LiteralPath $out).Length -ne $f.Length) { $fails.Add('copy_size_differs') }
      }
    }
    $verdict = if ($fails.Count) { 'FAIL' } else { 'OK' }
    if ($fails.Count) {
      Write-Host ("  {0,-44} {1}: {2}" -f $rel, $verdict, ($fails -join ', ')) -ForegroundColor Red
    }
    $rows.Add([pscustomobject]@{ tier=$tier; relpath=$rel; verdict=$verdict; reasons=($fails -join '; ') })
  }
}

$sw.Stop()
if (-not $rows.Count) { Write-Host "`nNo images found under sources_images\." -ForegroundColor Yellow; exit 0 }
$csv = Join-Path $outRoot 'confirm-images-quick.csv'
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

$bad = @($rows | Where-Object verdict -ne 'OK')
Write-Host ""
Write-Host "================ IMAGES QUICK CONFIRM ================" -ForegroundColor Cyan
Write-Host ("checked: {0} in {1:N1} min   ok: {2}   problems: {3}   csv: {4}" -f `
  $rows.Count, $sw.Elapsed.TotalMinutes, ($rows.Count - $bad.Count), $bad.Count, $csv)
if ($bad.Count) {
  Write-Host "GATE: FAIL -- re-run .\run_image_encode.ps1 (it resumes), then re-check." -ForegroundColor Red
  exit 1
}
Write-Host "GATE: PASS -- coverage complete. Run .\confirm_images_deep.ps1 for pixel-level proof." -ForegroundColor Green
exit 0
