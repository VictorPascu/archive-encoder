<#
  Builds a synthetic mini-corpus that mimics the real footage's awkward
  characteristics, so the calibration pipeline can be integration-tested
  without reading a single byte of the concert files.

  Three 4K clips:
    000001 - realised 40 fps but tagged as a 60 fps capture  -> the "dark VFR" case
    000002 - realised 60 of 60                               -> the "bright fast" case
    000003 - same, then stamped with a -90 display matrix    -> the rotation case
#>

[CmdletBinding()]
param([string]$Corpus = "$PSScriptRoot\corpus")

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\..\core\_common.ps1"

if (-not (Test-Path -LiteralPath $Corpus)) { New-Item -ItemType Directory -Path $Corpus -Force | Out-Null }

function New-SynthClip {
  param([string]$Name, [int]$Rate, [int]$Duration, [string]$CaptureFps)
  $p = Join-Path $Corpus $Name
  if (Test-Path -LiteralPath $p) { Write-Host "  exists: $Name"; return $p }
  $null = Invoke-FFmpegCapture -Arguments @(
    '-hide_banner','-nostdin','-v','error',
    '-f','lavfi','-i',"testsrc2=size=3840x2160:rate=$Rate`:duration=$Duration",
    '-f','lavfi','-i',"sine=frequency=440:sample_rate=48000:duration=$Duration",
    '-c:v','libx265','-preset','ultrafast','-crf','20','-pix_fmt','yuv420p','-tag:v','hvc1',
    '-c:a','aac','-b:a','256k','-ac','2',
    '-metadata',"com.android.capture.fps=$CaptureFps",
    '-metadata','location=+48.1750+011.5499/',
    '-video_track_timescale','90000','-movflags','+use_metadata_tags',
    $p)
  Write-Host "  built : $Name"
  return $p
}

Write-Host ""
Write-Host "Building synthetic corpus in $Corpus" -ForegroundColor Cyan
$null = New-SynthClip -Name '20991112_000001.mp4' -Rate 40 -Duration 8 -CaptureFps '60.000000'
$null = New-SynthClip -Name '20991112_000002.mp4' -Rate 60 -Duration 8 -CaptureFps '60.000000'
$flat = New-SynthClip -Name 'flat_for_rotation.mp4' -Rate 60 -Duration 8 -CaptureFps '60.000000'

$rotDst = Join-Path $Corpus '20991112_000003.mp4'
if (-not (Test-Path -LiteralPath $rotDst)) {
  $null = Invoke-FFmpegCapture -Arguments @(
    '-hide_banner','-nostdin','-v','error',
    '-display_rotation','-90','-i',$flat,
    '-map','0:v:0','-map','0:a:0','-c','copy',
    '-map_metadata','0','-movflags','+use_metadata_tags',
    $rotDst)
  Write-Host "  built : 20991112_000003.mp4 (rotated -90)"
}

Write-Host ""
Write-Host "Corpus contents as Get-VideoInfo sees them:" -ForegroundColor Cyan
foreach ($f in (Get-ChildItem -LiteralPath $Corpus -File -Filter '20991112_*.mp4' | Sort-Object Name)) {
  $i = Get-VideoInfo -Path $f.FullName
  Write-Host ("  {0}  {1}x{2}  disp {3}x{4}  rot {5,4}  {6} fr  avg {7} fps  claimed {8}  ratio {9}  loc '{10}'" -f `
    $i.Name, $i.Width, $i.Height, $i.DisplayW, $i.DisplayH, $i.Rotation,
    $i.Frames, $i.AvgFps, $i.CaptureFps, $i.VfrRatio, $i.Location)
}
