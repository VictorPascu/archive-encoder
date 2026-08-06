<#
  End-to-end test of the image flow, in a disposable sandbox (same pattern as
  run_tests.ps1): synthetic images in, both tiers encoded, both confirms green,
  sources byte-identical afterward.
#>

[CmdletBinding()]
param([switch]$KeepSandbox)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\scripts_internal\_common.ps1"

$pass = 0; $fail = 0
function Check { param([string]$N, [bool]$Ok, [string]$D = '')
  if ($Ok) { $script:pass++; Write-Host ("  PASS  {0,-52} {1}" -f $N, $D) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ("  FAIL  {0,-52} {1}" -f $N, $D) -ForegroundColor Red } }

$sandbox = Join-Path $env:TEMP ("imgtest_" + [guid]::NewGuid().ToString('N').Substring(0,8))

try {
  foreach ($d in @('sources_images\important','sources_images\regular\sub')) {
    New-Item -ItemType Directory -Path (Join-Path $sandbox $d) -Force | Out-Null
  }

  # screenshot-like PNG: flat regions -> webp-lossless must win decisively
  $mkShot = {
    param($Path)
    $r = Invoke-FFmpegCapture -Arguments @(
      '-hide_banner','-nostdin','-v','error',
      '-f','lavfi','-i','color=c=0x2244AA:size=1280x800',
      '-vf','drawbox=x=40:y=40:w=400:h=200:color=white@1:t=fill,drawbox=x=40:y=300:w=900:h=60:color=0x66CC88@1:t=fill,drawbox=x=500:y=40:w=700:h=200:color=0x222222@1:t=fill',
      '-frames:v','1','-y',$Path)
    return ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $Path))
  }
  # photo-like JPEG (already lossy)
  $mkPhoto = {
    param($Path)
    $r = Invoke-FFmpegCapture -Arguments @(
      '-hide_banner','-nostdin','-v','error',
      '-f','lavfi','-i','gradients=size=1280x800:n=4',
      '-frames:v','1','-q:v','4','-y',$Path)
    return ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $Path))
  }

  Check 'important PNG created'        (& $mkShot  (Join-Path $sandbox 'sources_images\important\shot.png'))
  Check 'important JPEG created'       (& $mkPhoto (Join-Path $sandbox 'sources_images\important\photo.jpg'))
  Check 'regular nested PNG created'   (& $mkShot  (Join-Path $sandbox 'sources_images\regular\sub\shot2.png'))
  Check 'regular JPEG created'         (& $mkPhoto (Join-Path $sandbox 'sources_images\regular\photo2.jpg'))

  $srcHashes = @{}
  foreach ($f in (Get-ChildItem (Join-Path $sandbox 'sources_images') -Recurse -File)) {
    $srcHashes[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
  }

  Write-Host ""
  & "$repo\run_image_encode.ps1" -RepoRoot $sandbox | Out-Host
  Check 'image encode exited 0' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

  $man = Import-Csv (Join-Path $sandbox 'encoded_images\images_manifest.csv')

  # important PNG: converted, verified pixel-identical, meaningfully smaller
  $rShot = $man | Where-Object { $_.tier -eq 'important' -and $_.name -eq 'shot.png' }
  Check 'important PNG -> webp_lossless' ($rShot.action -eq 'webp_lossless') $rShot.action
  Check 'conversion self-verified pixel-identical' ($rShot.pixel_identical -eq 'True')
  Check 'lossless conversion is smaller' ([int64]$rShot.out_bytes -lt [int64]$rShot.src_bytes) `
    ("{0} -> {1}" -f $rShot.src_bytes, $rShot.out_bytes)
  Check 'important webp exists' (Test-Path (Join-Path $sandbox 'encoded_images\important\shot.png.webp'))

  # important JPEG: kept as-is, byte-identical
  $rPhoto = $man | Where-Object { $_.tier -eq 'important' -and $_.name -eq 'photo.jpg' }
  Check 'important JPEG kept as-is' ($rPhoto.action -eq 'copied') $rPhoto.action
  $srcJ = Join-Path $sandbox 'sources_images\important\photo.jpg'
  $cpJ  = Join-Path $sandbox 'encoded_images\important\photo.jpg'
  Check 'kept JPEG byte-identical' (
    (Get-FileHash $srcJ -Algorithm SHA256).Hash -eq (Get-FileHash $cpJ -Algorithm SHA256).Hash)

  # regular tier: nested mirroring + never-worse guarantee
  $rShot2 = $man | Where-Object { $_.tier -eq 'regular' -and $_.name -eq 'shot2.png' }
  Check 'regular nested PNG processed' ($null -ne $rShot2) $rShot2.action
  Check 'regular outputs never larger than source' (
    @($man | Where-Object { [int64]$_.out_bytes -gt [int64]$_.src_bytes }).Count -eq 0)

  Write-Host ""
  & "$repo\confirm_images_quick.ps1" -RepoRoot $sandbox | Out-Host
  Check 'images quick confirm PASS' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

  Write-Host ""
  & "$repo\confirm_images_deep.ps1" -RepoRoot $sandbox | Out-Host
  Check 'images deep confirm PASS' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

  $unchanged = $true
  foreach ($k in $srcHashes.Keys) {
    if ((Get-FileHash -LiteralPath $k -Algorithm SHA256).Hash -ne $srcHashes[$k]) { $unchanged = $false }
  }
  Check 'sandbox sources byte-identical after everything' $unchanged

} finally {
  if ($KeepSandbox) { Write-Host "`nsandbox kept: $sandbox" -ForegroundColor Yellow }
  elseif (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "==================== IMAGE E2E TEST ====================" -ForegroundColor Cyan
Write-Host ("Passed: {0}    Failed: {1}" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 } else { exit 0 }
