<#
  End-to-end test of the drop-folder flow, in a disposable sandbox.

  What it does:
    1. Builds a temp repo-root under %TEMP% (never touches the real sources/)
    2. Generates one tiny S24U-format clip per tier -- 4K HEVC 8-bit BT.709,
       AAC stereo, com.android.capture.fps tag, GPS tag, mp4
    3. Runs run_encode.ps1 against the sandbox
    4. Asserts: exit 0, outputs exist at mirrored paths, and each tier used the
       right engine (x265 for important, NVENC for regular -- or the documented
       CPU fallback when no NVENC is present)
    5. Runs confirm_quick.ps1 and confirm_deep.ps1 -- both must PASS
    6. Asserts the sandbox sources are byte-identical afterward (nothing wrote
       to them)
    7. Cleans up the sandbox (always -- also on failure, unless -KeepSandbox)

  Exit 0 = all green. Runtime: roughly a minute; the x265-slow tier on a tiny
  4K clip is the slow part.
#>

[CmdletBinding()]
param(
  [switch]$KeepSandbox
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. "$repo\core\_common.ps1"

$pass = 0; $fail = 0
function Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) { $script:pass++; Write-Host ("  PASS  {0,-52} {1}" -f $Name, $Detail) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ("  FAIL  {0,-52} {1}" -f $Name, $Detail) -ForegroundColor Red }
}

$sandbox = Join-Path $env:TEMP ("encscripts_test_" + [guid]::NewGuid().ToString('N').Substring(0,8))

try {
  # ---------------------------------------------------------- 1. scaffold
  Write-Host ""
  Write-Host "=== sandbox: $sandbox ===" -ForegroundColor Cyan
  foreach ($d in @('sources\important','sources\regular\trip')) {
    New-Item -ItemType Directory -Path (Join-Path $sandbox $d) -Force | Out-Null
  }

  # ---------------------------------------------------------- 2. tiny clips
  function New-TestClip {
    param([string]$RelPath, [int]$Rate)
    $p = Join-Path $sandbox $RelPath
    $r = Invoke-FFmpegCapture -Arguments @(
      '-hide_banner','-nostdin','-v','error',
      '-f','lavfi','-i',"testsrc2=size=3840x2160:rate=$Rate`:duration=2",
      '-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=2',
      '-c:v','libx265','-preset','ultrafast','-crf','20','-pix_fmt','yuv420p','-tag:v','hvc1',
      '-c:a','aac','-b:a','256k','-ac','2',
      '-metadata','com.android.capture.fps=30.000000',
      '-metadata','location=+00.0000+000.0000/',
      '-video_track_timescale','90000','-movflags','+use_metadata_tags',
      $p)
    return ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $p))
  }
  Check 'important-tier test clip created'          (New-TestClip -RelPath 'sources\important\clip_hq.mp4' -Rate 30)
  Check 'regular-tier test clip created (nested)'   (New-TestClip -RelPath 'sources\regular\trip\clip_fast.mp4' -Rate 30)

  # a clip with NO audio stream (screen capture / timelapse case)
  $silent = Join-Path $sandbox 'sources\regular\clip_silent.mp4'
  $rs = Invoke-FFmpegCapture -Arguments @(
    '-hide_banner','-nostdin','-v','error',
    '-f','lavfi','-i','testsrc2=size=1920x1080:rate=30:duration=2',
    '-c:v','libx265','-preset','ultrafast','-crf','20','-pix_fmt','yuv420p','-tag:v','hvc1',
    '-video_track_timescale','90000', $silent)
  Check 'no-audio test clip created' ($rs.ExitCode -eq 0 -and (Test-Path -LiteralPath $silent))

  $srcHashes = @{}
  foreach ($f in (Get-ChildItem (Join-Path $sandbox 'sources') -Recurse -File -Filter '*.mp4')) {
    $srcHashes[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
  }

  # NVENC present? Decides what engine the regular tier is EXPECTED to use.
  $probe = Invoke-FFmpegCapture -Arguments @(
    '-hide_banner','-nostdin','-v','error',
    '-f','lavfi','-i','testsrc2=size=640x360:rate=30:duration=0.3',
    '-c:v','hevc_nvenc','-f','null','-')
  $hasNvenc = ($probe.ExitCode -eq 0)
  Write-Host ("  (NVENC available: {0} -- regular tier expected on {1})" -f $hasNvenc, $(if ($hasNvenc) { 'hevc_nvenc q30' } else { 'x265 CPU fallback' })) -ForegroundColor DarkGray

  # ---------------------------------------------------------- 3. encode
  Write-Host ""
  Write-Host "=== run_encode.ps1 against the sandbox ===" -ForegroundColor Cyan
  & "$repo\video\run_encode.ps1" -RepoRoot $sandbox | Out-Host
  Check 'run_encode exited 0' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

  # ---------------------------------------------------------- 4. outputs
  $outHq   = Join-Path $sandbox 'encoded_outputs\important\clip_hq.mp4'
  $outFast = Join-Path $sandbox 'encoded_outputs\regular\trip\clip_fast.mp4'
  Check 'important output exists at mirrored path' (Test-Path -LiteralPath $outHq)
  Check 'regular output exists at nested mirrored path' (Test-Path -LiteralPath $outFast)

  Check 'important tier used x265 q22' `
    (Test-Path -LiteralPath (Join-Path $sandbox 'encoded_outputs\important\encode-log-x265-q22.csv'))
  $expectedRegularLog = if ($hasNvenc) { 'encode-log-hevc_nvenc-q30.csv' } else { 'encode-log-x265-q22.csv' }
  Check "regular tier used $(if ($hasNvenc) { 'hevc_nvenc q30' } else { 'x265 fallback' })" `
    (Test-Path -LiteralPath (Join-Path $sandbox "encoded_outputs\regular\trip\$expectedRegularLog"))

  Check 'master manifest written' (Test-Path -LiteralPath (Join-Path $sandbox 'encoded_outputs\manifest.csv'))

  if ((Test-Path -LiteralPath $outHq) -and (Test-Path -LiteralPath $outFast)) {
    $iHq = Get-VideoInfo -Path $outHq
    $iF  = Get-VideoInfo -Path $outFast
    Check 'important output frame count = 60' ($iHq.Frames -eq 60) "$($iHq.Frames)"
    Check 'regular output frame count = 60'   ($iF.Frames -eq 60)  "$($iF.Frames)"
    Check 'metadata survived (location tag)'  ($iHq.Location -ne '') $iHq.Location
  }

  $outSilent = Join-Path $sandbox 'encoded_outputs\regular\clip_silent.mp4'
  Check 'no-audio clip encoded' (Test-Path -LiteralPath $outSilent)
  if (Test-Path -LiteralPath $outSilent) {
    $iS = Get-VideoInfo -Path $outSilent
    Check 'no-audio output has no audio stream' (-not $iS.AudioCodec)
  }

  # ---------------------------------------------------------- 5. confirms
  Write-Host ""
  Write-Host "=== confirm_quick.ps1 ===" -ForegroundColor Cyan
  & "$repo\video\confirm_quick.ps1" -RepoRoot $sandbox | Out-Host
  Check 'confirm_quick PASS' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

  Write-Host ""
  Write-Host "=== confirm_deep.ps1 ===" -ForegroundColor Cyan
  & "$repo\video\confirm_deep.ps1" -RepoRoot $sandbox -ScreenshotFiles 1 | Out-Host
  Check 'confirm_deep PASS' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

  $reviewPairs = @(Get-ChildItem (Join-Path $sandbox 'encoded_outputs\_review') -Filter '*.jpg' -ErrorAction SilentlyContinue)
  Check 'screenshot pairs produced' ($reviewPairs.Count -ge 2) "$($reviewPairs.Count) jpgs"

  # ---------------------------------------------------------- 6. sources untouched
  $unchanged = $true
  foreach ($k in $srcHashes.Keys) {
    if ((Get-FileHash -LiteralPath $k -Algorithm SHA256).Hash -ne $srcHashes[$k]) { $unchanged = $false }
  }
  Check 'sandbox sources byte-identical after everything' $unchanged

} finally {
  # ---------------------------------------------------------- 7. cleanup
  if ($KeepSandbox) {
    Write-Host ""
    Write-Host "sandbox kept for inspection: $sandbox" -ForegroundColor Yellow
  } elseif (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "==================== E2E TEST ====================" -ForegroundColor Cyan
Write-Host ("Passed: {0}    Failed: {1}" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
if ($fail) { exit 1 } else { exit 0 }
