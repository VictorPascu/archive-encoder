<#
  Negative control for verify_encoded.ps1.

  A verification pass that has only ever returned PASS proves nothing. This
  builds four deliberately-defective outputs -- one per failure mode the real
  job could plausibly hit -- and confirms the checker catches each by name.

    000001 -> crushed quality        must fail  vmaf
    000002 -> re-encoded audio       must fail  audio_not_identical
    000003 -> rotation not applied   must fail  orientation
    000004 -> truncated             must fail  frames
#>

[CmdletBinding()]
param(
  [string]$Corpus = "$PSScriptRoot\corpus",
  [string]$BadDir = "$PSScriptRoot\enc_bad"
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_common.ps1"

if (-not (Test-Path -LiteralPath $BadDir)) { New-Item -ItemType Directory -Path $BadDir -Force | Out-Null }

$c1 = Join-Path $Corpus '20991112_000001.mp4'
$c2 = Join-Path $Corpus '20991112_000002.mp4'
$c3 = Join-Path $Corpus '20991112_000003.mp4'   # the rotated one

Write-Host ""
Write-Host "Building defective outputs in $BadDir" -ForegroundColor Cyan

# --- 1. crushed quality: should trip the VMAF threshold
$o1 = Join-Path $BadDir '20991112_000001.mp4'
if (-not (Test-Path -LiteralPath $o1)) {
  $null = Invoke-FFmpegCapture -Arguments @(
    '-hide_banner','-nostdin','-v','error','-i',$c1,'-map','0:v:0','-map','0:a:0',
    '-c:v','hevc_nvenc','-preset','p1','-rc','vbr','-cq','51','-b:v','0','-maxrate','1M','-bufsize','2M',
    '-pix_fmt','yuv420p','-tag:v','hvc1',
    '-c:a','copy','-fps_mode','passthrough','-video_track_timescale','90000',
    '-map_metadata','0','-movflags','+use_metadata_tags+faststart', $o1)
  Write-Host "  built 000001 (crushed quality)"
}

# --- 2. re-encoded audio: should trip the audio hash
$o2 = Join-Path $BadDir '20991112_000002.mp4'
if (-not (Test-Path -LiteralPath $o2)) {
  $null = Invoke-FFmpegCapture -Arguments @(
    '-hide_banner','-nostdin','-v','error','-i',$c2,'-map','0:v:0','-map','0:a:0',
    '-c:v','hevc_nvenc','-preset','p7','-rc','vbr','-cq','26','-b:v','0',
    '-pix_fmt','yuv420p','-tag:v','hvc1',
    '-c:a','aac','-b:a','128k',
    '-fps_mode','passthrough','-video_track_timescale','90000',
    '-map_metadata','0','-movflags','+use_metadata_tags+faststart', $o2)
  Write-Host "  built 000002 (audio re-encoded to 128k)"
}

# --- 3. genuinely sideways.
#   NOTE: -noautorotate is NOT a defect -- it leaves the pixels untransposed but
#   carries the -90 matrix through, so the file still DISPLAYS 2160x3840 and
#   plays correctly. (An earlier version of this control used it and the checker
#   rightly passed the file.) -display_rotation 0 is the real defect: it drops
#   the matrix without transposing, so the video plays on its side.
$o3 = Join-Path $BadDir '20991112_000003.mp4'
if (-not (Test-Path -LiteralPath $o3)) {
  $null = Invoke-FFmpegCapture -Arguments @(
    '-hide_banner','-nostdin','-v','error','-display_rotation','0','-i',$c3,'-map','0:v:0','-map','0:a:0',
    '-c:v','hevc_nvenc','-preset','p7','-rc','vbr','-cq','26','-b:v','0',
    '-pix_fmt','yuv420p','-tag:v','hvc1',
    '-c:a','copy','-fps_mode','passthrough','-video_track_timescale','90000',
    '-map_metadata','0','-movflags','+use_metadata_tags+faststart', $o3)
  Write-Host "  built 000003 (rotation dropped -- would play sideways)"
}

# --- 4. truncated: a source copy named 000004 plus a short encode of it
$src4 = Join-Path $Corpus '20991112_000004.mp4'
if (-not (Test-Path -LiteralPath $src4)) { Copy-Item -LiteralPath $c2 -Destination $src4 }
$o4 = Join-Path $BadDir '20991112_000004.mp4'
if (-not (Test-Path -LiteralPath $o4)) {
  $null = Invoke-FFmpegCapture -Arguments @(
    '-hide_banner','-nostdin','-v','error','-i',$src4,'-t','2','-map','0:v:0','-map','0:a:0',
    '-c:v','hevc_nvenc','-preset','p7','-rc','vbr','-cq','26','-b:v','0',
    '-pix_fmt','yuv420p','-tag:v','hvc1',
    '-c:a','copy','-fps_mode','passthrough','-video_track_timescale','90000',
    '-map_metadata','0','-movflags','+use_metadata_tags+faststart', $o4)
  Write-Host "  built 000004 (truncated to 2s)"
}

Write-Host ""
Write-Host "Expected: ALL FOUR must FAIL, each for its own stated reason." -ForegroundColor Yellow
Write-Host ""
& "$PSScriptRoot\verify_encoded.ps1" -SourceDir $Corpus -EncDir $BadDir -Filter '20991112_*.mp4' `
    -ManifestOut (Join-Path $BadDir 'manifest-bad.csv')

Write-Host ""
Write-Host "=============== NEGATIVE CONTROL SCORECARD ===============" -ForegroundColor Cyan
$m = Import-Csv -LiteralPath (Join-Path $BadDir 'manifest-bad.csv')
$expect = @{
  '20991112_000001.mp4' = 'vmaf'
  '20991112_000002.mp4' = 'audio_not_identical'
  '20991112_000003.mp4' = 'orientation'
  '20991112_000004.mp4' = 'frames'
}
$good = 0
foreach ($k in ($expect.Keys | Sort-Object)) {
  $row = $m | Where-Object name -eq $k
  if (-not $row) { Write-Host ("  MISS  {0}  no row" -f $k) -ForegroundColor Red; continue }
  $hit = ($row.verdict -eq 'FAIL' -and $row.reasons -like "*$($expect[$k])*")
  if ($hit) { $good++ }
  Write-Host ("  {0}  {1,-24} verdict={2,-4} reasons='{3}'  (wanted '{4}')" -f `
    $(if ($hit) { 'CAUGHT' } else { 'MISS  ' }), $k, $row.verdict, $row.reasons, $expect[$k]) `
    -ForegroundColor $(if ($hit) { 'Green' } else { 'Red' })
}
Write-Host ""
if ($good -eq $expect.Count) {
  Write-Host "All $good failure modes detected. The checker is proven to actually fail things." -ForegroundColor Green
  exit 0
} else {
  Write-Host "Only $good/$($expect.Count) detected -- the checker has blind spots. Fix before trusting it." -ForegroundColor Red
  exit 1
}
