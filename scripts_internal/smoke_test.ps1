<#
  Toolchain smoke test. Validates the machinery the real job depends on,
  using a synthetic clip so no user footage is read or written.

  Covers:
    * Get-VideoInfo populates every field it promises
    * Get-EncoderArgs produces args ffmpeg actually accepts, for all 3 codecs
      (this is where hevc_nvenc / av1_nvenc option names get proven on this GPU)
    * the preservation tail muxes without error
    * frame-count parity through an encode
    * Get-AudioStreamMd5 detects identical vs re-encoded audio
    * Invoke-Vmaf: Windows path escaping, model selection, JSON parsing
#>

[CmdletBinding()]
param([string]$WorkDir = "$PSScriptRoot\smoke")

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

$pass = 0; $fail = 0
function Check {
  param([string]$Name, [bool]$Ok, [string]$Detail = '')
  if ($Ok) { $script:pass++; Write-Host ("  PASS  {0,-42} {1}" -f $Name, $Detail) -ForegroundColor Green }
  else     { $script:fail++; Write-Host ("  FAIL  {0,-42} {1}" -f $Name, $Detail) -ForegroundColor Red }
}

# ---------------------------------------------------------------- 0. synth src
Write-Host ""
Write-Host "=== Building synthetic 4K source (2s, HEVC + AAC) ===" -ForegroundColor Cyan
$src = Join-Path $WorkDir 'synth_src.mp4'
if (Test-Path -LiteralPath $src) { Remove-Item -LiteralPath $src -Force }

$null = Invoke-FFmpegCapture -Arguments @(
  '-hide_banner','-nostdin','-v','error',
  '-f','lavfi','-i','testsrc2=size=3840x2160:rate=60:duration=2',
  '-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=2',
  '-c:v','libx265','-preset','ultrafast','-crf','18','-pix_fmt','yuv420p','-tag:v','hvc1',
  '-c:a','aac','-b:a','256k','-ac','2',
  '-video_track_timescale','90000',
  $src)

Check 'synthetic source created' (Test-Path -LiteralPath $src)
if (-not (Test-Path -LiteralPath $src)) { Write-Host "Cannot continue."; exit 1 }

# ---------------------------------------------------------------- 1. probe
Write-Host ""
Write-Host "=== Get-VideoInfo ===" -ForegroundColor Cyan
$si = Get-VideoInfo -Path $src
Check 'width/height parsed'   ($si.Width -eq 3840 -and $si.Height -eq 2160) "$($si.Width)x$($si.Height)"
Check 'frame count parsed'    ($si.Frames -gt 100)                          "$($si.Frames) frames"
Check 'duration parsed'       ($si.Duration -gt 1.5)                        "$([math]::Round($si.Duration,2))s"
Check 'avg fps computed'      ($si.AvgFps -gt 50)                           "$($si.AvgFps) fps"
Check 'display dims computed' ($si.DisplayW -eq 3840)                       "rot=$($si.Rotation)"
Check 'audio detected'        ($si.AudioCodec -eq 'aac' -and $si.AudioCh -eq 2) "$($si.AudioCodec) $($si.AudioCh)ch"
Check 'Is4K flag'             ($si.Is4K -eq $true)

# ---------------------------------------------------------------- 2. audio md5
Write-Host ""
Write-Host "=== Get-AudioStreamMd5 ===" -ForegroundColor Cyan
$md5a = Get-AudioStreamMd5 -Path $src
Check 'audio md5 returned' ([bool]$md5a) $md5a

# ---------------------------------------------------------------- 3. VMAF model
Write-Host ""
Write-Host "=== VMAF model detection ===" -ForegroundColor Cyan
$model = Get-VmafModel
Check 'model resolved' ([bool]$model) $model
$escaped = ConvertTo-FilterPath 'L:\Some Dir\vmaf out.json'
Check 'filter path escaping' ($escaped -eq 'L\\:/Some Dir/vmaf out.json') $escaped

# ---------------------------------------------------------------- 4. encoders
Write-Host ""
Write-Host "=== Encoders (args + mux + frame parity + audio copy + VMAF) ===" -ForegroundColor Cyan

$cases = @(
  @{ Codec='x265';       Q=24; Preset='ultrafast' },   # fast preset: proving args, not speed
  @{ Codec='hevc_nvenc'; Q=28; Preset='slow'      },
  @{ Codec='av1_nvenc';  Q=34; Preset='slow'      }
)

foreach ($c in $cases) {
  Write-Host ""
  Write-Host ("--- {0} q={1} ---" -f $c.Codec, $c.Q) -ForegroundColor White
  $out = Join-Path $WorkDir ("synth_{0}_q{1}.mp4" -f $c.Codec, $c.Q)
  if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }

  $ffArgs = @('-hide_banner','-nostdin','-v','error','-i',$src,'-map','0:v:0','-map','0:a:0') +
            (Get-EncoderArgs -Codec $c.Codec -Quality $c.Q -X265Preset $c.Preset) +
            (Get-CommonTailArgs) + @($out)

  $sw  = [Diagnostics.Stopwatch]::StartNew()
  $err = (Invoke-FFmpegCapture -Arguments $ffArgs).Text
  $sw.Stop()

  $made = Test-Path -LiteralPath $out
  Check 'encode + mux succeeded' $made ("{0:N1}s" -f $sw.Elapsed.TotalSeconds)
  if (-not $made) {
    $firstLines = (($err.Trim() -split "`r?`n") | Select-Object -First 3) -join ' | '
    Write-Host ("        ffmpeg said: " + $firstLines) -ForegroundColor DarkRed
    continue
  }

  $oi = Get-VideoInfo -Path $out
  Check 'frame count preserved' ($oi.Frames -eq $si.Frames) "$($oi.Frames) vs $($si.Frames)"
  Check 'duration preserved'    ([math]::Abs($oi.Duration - $si.Duration) -lt 0.1) `
        ("delta {0:N4}s" -f ($oi.Duration - $si.Duration))

  $md5b = Get-AudioStreamMd5 -Path $out
  Check 'audio bit-identical'   ($md5a -and $md5b -and $md5a -eq $md5b) `
        $(if ($md5a -eq $md5b) { 'hashes match' } else { "$md5a vs $md5b" })

  $v = Invoke-Vmaf -Distorted $out -Reference $src -HwDecode
  Check 'VMAF computed'         ([bool]$v) `
        $(if ($v) { "mean $($v.Mean)  1%low $($v.P1Low)  min $($v.Min)  over $($v.FrameCount) fr  in $($v.Seconds)s" } else { 'returned null' })
  if ($v) {
    Check 'VMAF in sane range'   ($v.Mean -gt 40 -and $v.Mean -le 100) "mean $($v.Mean)"
    Check 'VMAF frames = clip'   ($v.FrameCount -eq $si.Frames) "$($v.FrameCount) vs $($si.Frames)"
    Check 'VMAF used 4k model'   ($v.Model -like '*4k*') $v.Model

    # the two models are different scales -- prove the override works and that
    # we are not silently reading a 1080p-viewing score for 4K content
    $v1080 = Invoke-Vmaf -Distorted $out -Reference $src -HwDecode -Model 'version=vmaf_v0.6.1'
    Check 'model override honoured' ($v1080 -and $v1080.Mean -ne $v.Mean) `
          $(if ($v1080) { "4k=$($v.Mean)  1080p=$($v1080.Mean)" } else { 'null' })
  }

  Write-Host ("        size {0}  ({1} Mbps)" -f (Format-Bytes $oi.Bytes), $oi.Mbps) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- 5. re-encoded audio must be DETECTED as different
Write-Host ""
Write-Host "=== Negative control: re-encoded audio must NOT hash equal ===" -ForegroundColor Cyan
$reAudio = Join-Path $WorkDir 'synth_reaudio.mp4'
if (Test-Path -LiteralPath $reAudio) { Remove-Item -LiteralPath $reAudio -Force }
$null = Invoke-FFmpegCapture -Arguments @(
    '-hide_banner','-nostdin','-v','error','-i',$src,'-map','0:v:0','-map','0:a:0',
    '-c:v','copy','-c:a','aac','-b:a','128k',$reAudio)
if (Test-Path -LiteralPath $reAudio) {
  $md5c = Get-AudioStreamMd5 -Path $reAudio
  Check 'detects re-encoded audio as different' ($md5c -ne $md5a) "$md5c"
} else {
  Check 'negative control built' $false
}

# ---------------------------------------------------------------- 6. guard rail
Write-Host ""
Write-Host "=== Assert-NotSourceDrive guard ===" -ForegroundColor Cyan
$blocked = $false
try { Assert-NotSourceDrive -OutputPath 'H:\Grand Archives\Great Big Picture Collection III\3 Apr 2026\x.mp4' }
catch { $blocked = $true }
Check 'refuses to write into originals tree' $blocked
$allowed = $true
try { Assert-NotSourceDrive -OutputPath 'L:\Witcher-Concert-2025-11-12\encoded\x.mp4' } catch { $allowed = $false }
Check 'allows the L: output tree' $allowed

# ---------------------------------------------------------------- done
Write-Host ""
Write-Host "==================== SMOKE TEST ====================" -ForegroundColor Cyan
Write-Host ("Passed: {0}    Failed: {1}" -f $pass, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
Write-Host ("Artifacts: {0}" -f $WorkDir) -ForegroundColor DarkGray
if ($fail) { exit 1 } else { exit 0 }
