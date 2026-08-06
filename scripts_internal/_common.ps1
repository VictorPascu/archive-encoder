<#
  Shared helpers for the concert re-encode job. Dot-source this:
      . "$PSScriptRoot\_common.ps1"

  Nothing in here writes to a video file. Probing and measuring only.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------- paths / tools
$script:FFMPEG  = (Get-Command ffmpeg  -ErrorAction Stop).Source
$script:FFPROBE = (Get-Command ffprobe -ErrorAction Stop).Source

# Declared here because Set-StrictMode makes reading an unset variable fatal.
$script:VmafModelCached = $null

# ------------------------------------------------------- native-call plumbing
# Windows PowerShell 5.1 wraps every stderr line from a native executable in a
# NativeCommandError ErrorRecord. Under $ErrorActionPreference='Stop' that
# ABORTS THE SCRIPT even when the process exited 0 -- and both x265 and NVENC
# write informational banners to stderr as a matter of course. So every native
# invocation goes through these wrappers, which localise the preference and
# hand back stderr as ordinary data.

function Invoke-FFmpegCapture {
  <# Runs ffmpeg, returns exit code plus the merged stdout/stderr text. #>
  param([Parameter(Mandatory)][string[]]$Arguments)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $text = (& $script:FFMPEG @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $text }
  } finally { $ErrorActionPreference = $prev }
}

function Invoke-FFprobeJson {
  <# Runs ffprobe and returns stdout only -- stderr must NOT be merged here or
     it would contaminate the JSON payload. #>
  param([Parameter(Mandatory)][string[]]$Arguments)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    return ((& $script:FFPROBE @Arguments 2>$null) | Out-String)
  } finally { $ErrorActionPreference = $prev }
}

# --------------------------------------------------------------- ffprobe facts
function Get-VideoInfo {
  <# Returns one object describing a media file: dimensions, rotation, real
     frame count, duration, average fps, the phone's claimed capture fps,
     and audio parameters. #>
  param([Parameter(Mandatory)][string]$Path)

  $raw = Invoke-FFprobeJson -Arguments @(
            '-v','error','-print_format','json','-show_format','-show_streams','--',$Path)
  if ([string]::IsNullOrWhiteSpace($raw)) { throw "ffprobe returned nothing for: $Path" }
  $j = $raw | ConvertFrom-Json

  $v = $j.streams | Where-Object codec_type -eq 'video' | Select-Object -First 1
  $a = $j.streams | Where-Object codec_type -eq 'audio' | Select-Object -First 1
  if (-not $v) { throw "No video stream in: $Path" }

  # rotation lives in stream side data as a negative-degree display matrix
  $rot = 0
  if ($v.PSObject.Properties.Name -contains 'side_data_list') {
    foreach ($sd in $v.side_data_list) {
      if ($sd.PSObject.Properties.Name -contains 'rotation') { $rot = [int]$sd.rotation; break }
    }
  }

  $dur    = [double]$j.format.duration
  $frames = 0
  if ($v.PSObject.Properties.Name -contains 'nb_frames' -and $v.nb_frames) { $frames = [int]$v.nb_frames }

  $avgFps = if ($dur -gt 0 -and $frames -gt 0) { [math]::Round($frames / $dur, 3) } else { 0 }

  $capFps = $null
  if ($j.format.PSObject.Properties.Name -contains 'tags') {
    $t = $j.format.tags
    if ($t.PSObject.Properties.Name -contains 'com.android.capture.fps') {
      $capFps = [double]$t.'com.android.capture.fps'
    }
  }

  # effective on-screen dimensions after the rotation matrix is applied
  $dispW = $v.width; $dispH = $v.height
  if ([math]::Abs($rot) -eq 90 -or [math]::Abs($rot) -eq 270) { $dispW = $v.height; $dispH = $v.width }

  [pscustomobject]@{
    Path         = $Path
    Name         = Split-Path $Path -Leaf
    Bytes        = [int64]$j.format.size
    Codec        = $v.codec_name
    CodecTag     = $v.codec_tag_string
    Width        = [int]$v.width
    Height       = [int]$v.height
    DisplayW     = [int]$dispW
    DisplayH     = [int]$dispH
    Rotation     = $rot
    PixFmt       = $v.pix_fmt
    ColorTransfer= $(if ($v.PSObject.Properties.Name -contains 'color_transfer') { $v.color_transfer } else { '' })
    Frames       = $frames
    Duration     = $dur
    AvgFps       = $avgFps
    CaptureFps   = $capFps
    VfrRatio     = $(if ($capFps) { [math]::Round($avgFps / $capFps, 3) } else { $null })
    Mbps         = $(if ($dur -gt 0) { [math]::Round([int64]$j.format.size * 8 / $dur / 1e6, 1) } else { 0 })
    AudioCodec   = $(if ($a) { $a.codec_name } else { '' })
    AudioCh      = $(if ($a) { [int]$a.channels } else { 0 })
    CreationTime = $(if ($j.format.PSObject.Properties.Name -contains 'tags' -and
                         $j.format.tags.PSObject.Properties.Name -contains 'creation_time')
                     { $j.format.tags.creation_time } else { '' })
    Location     = $(if ($j.format.PSObject.Properties.Name -contains 'tags' -and
                         $j.format.tags.PSObject.Properties.Name -contains 'location')
                     { $j.format.tags.location } else { '' })
    Is4K         = ([int]$v.width -ge 3000)
  }
}

# ------------------------------------------------------------- encoder recipes
function Get-EncoderArgs {
  <# Video-codec arguments only. The preservation tail is added by Get-CommonTailArgs. #>
  param(
    [Parameter(Mandatory)][ValidateSet('x265','hevc_nvenc','av1_nvenc')][string]$Codec,
    [Parameter(Mandatory)][int]$Quality,      # CRF for x265, CQ for NVENC
    [string]$X265Preset = 'slow'
  )

  switch ($Codec) {
    'x265' {
      @('-c:v','libx265','-preset',$X265Preset,'-crf',"$Quality",
        '-pix_fmt','yuv420p',
        '-x265-params','aq-mode=3:aq-strength=0.9:limit-sao=1:bframes=5:rc-lookahead=40',
        '-tag:v','hvc1')
    }
    'hevc_nvenc' {
      @('-c:v','hevc_nvenc','-preset','p7','-tune','hq',
        '-rc','vbr','-cq',"$Quality",'-b:v','0','-maxrate','80M','-bufsize','160M',
        '-spatial-aq','1','-temporal-aq','1','-rc-lookahead','32',
        '-bf','4','-b_ref_mode','middle',
        '-pix_fmt','yuv420p','-tag:v','hvc1')
    }
    'av1_nvenc' {
      @('-c:v','av1_nvenc','-preset','p7','-tune','hq',
        '-rc','vbr','-cq',"$Quality",'-b:v','0','-maxrate','80M','-bufsize','160M',
        '-spatial-aq','1','-temporal-aq','1','-rc-lookahead','32','-bf','3',
        '-pix_fmt','yuv420p')
    }
  }
}

function Get-CommonTailArgs {
  <# The preservation contract. Every one of these matters -- see the plan.
       fps_mode passthrough  : keeps the original VFR timestamps exactly
       video_track_timescale : matches the source 1/90000 timebase, no rounding drift
       c:a copy              : audio stays bit-for-bit identical
       map_metadata + movflags: carries creation_time, GPS, com.samsung.* tags
       faststart             : moves the moov atom up front for smooth playback #>
  @('-c:a','copy',
    '-fps_mode','passthrough',
    '-video_track_timescale','90000',
    '-map_metadata','0',
    '-movflags','+use_metadata_tags+faststart')
}

# ------------------------------------------------------------------- VMAF
function Get-VmafModel {
  <# Prefer the 4K-viewing model; fall back to the 1080p default if this
     ffmpeg build does not embed it. Probed once, cached. #>
  if ($script:VmafModelCached) { return $script:VmafModelCached }

  $r = Invoke-FFmpegCapture -Arguments @(
          '-hide_banner','-nostdin',
          '-f','lavfi','-i','testsrc2=size=256x256:rate=1:duration=1',
          '-f','lavfi','-i','testsrc2=size=256x256:rate=1:duration=1',
          '-lavfi','[0:v][1:v]libvmaf=model=version=vmaf_4k_v0.6.1:n_threads=2',
          '-f','null','-')
  $probe = $r.Text

  $script:VmafModelCached = if ($r.ExitCode -ne 0 -or
                                $probe -match 'Could not read model' -or
                                $probe -match 'Unsupported model' -or
                                $probe -match 'could not.*model') {
    'version=vmaf_v0.6.1'
  } else {
    'version=vmaf_4k_v0.6.1'
  }
  return $script:VmafModelCached
}

function ConvertTo-FilterPath {
  <# ffmpeg filter args treat ':' as an option separator and '\' as an escape,
     so a Windows path must be rewritten before it can be embedded in a
     filtergraph. Forward slashes, and the drive colon needs a DOUBLE backslash
     -- it passes through two escaping layers (filtergraph, then option value).
     A single backslash terminates the value early and yields
     "No option name near '/Users/...'". Verified against ffmpeg 8.0.1. #>
  param([Parameter(Mandatory)][string]$Path)
  return ($Path -replace '\\','/') -replace ':','\\:'
}

function Invoke-Vmaf {
  <# Frame-exact VMAF between a distorted file and its reference.

     Alignment: both streams are trimmed by FRAME INDEX (not by input seek),
     because input seeking lands on keyframes that differ between the source
     and the re-encode, which would silently compare mismatched frames.

     Returns mean / min / harmonic mean / 1%-low, or $null on failure. #>
  param(
    [Parameter(Mandatory)][string]$Distorted,
    [Parameter(Mandatory)][string]$Reference,
    [int]$StartFrame = 0,
    [int]$EndFrame   = 0,        # 0 = to the end
    [int]$Threads    = 0,        # 0 = let libvmaf pick
    [switch]$HwDecode,
    [string]$LogPath,
    [string]$Model               # e.g. 'version=vmaf_v0.6.1'; default = best available
  )

  if (-not $LogPath) { $LogPath = Join-Path $env:TEMP ("vmaf_" + [guid]::NewGuid().ToString('N') + ".json") }
  $model   = if ($Model) { $Model } else { Get-VmafModel }
  $logEsc  = ConvertTo-FilterPath $LogPath
  if ($Threads -le 0) { $Threads = [Math]::Max(1, [Environment]::ProcessorCount - 2) }

  $trim = if ($EndFrame -gt 0) { "trim=start_frame=$StartFrame`:end_frame=$EndFrame," }
          elseif ($StartFrame -gt 0) { "trim=start_frame=$StartFrame," }
          else { '' }

  # 'settb=1/1000,setpts=N' forces INDEX-BASED frame pairing, and is load-bearing.
  #
  # libvmaf joins its two inputs through ffmpeg's framesync, which matches frames
  # by TIMESTAMP. These sources are VFR -- frame deltas alternate 1499/1500 on a
  # 1/90000 timebase because the phone shoots a shade off 60.000 fps -- and the
  # encode's timestamps, regenerated by -fps_mode passthrough, differ from the
  # source's by sub-frame amounts. That drift accumulates until it passes half a
  # frame interval, whereupon framesync slips one frame and every later comparison
  # is against the WRONG reference.
  #
  # Measured on 20251112_151941 (626 frames): the old 'setpts=PTS-STARTPTS' form
  # emitted 627 pairs and scored mean 60.54 / 1%low 8.25, collapsing from frame
  # ~305 onward, while the file is in fact perfect -- index pairing gives mean
  # 99.52 / 1%low 97.46 over the correct 626 pairs. The same artifact depressed
  # calibration clip B's 1% low from 96.46 to 89.55 and produced the "unexplained
  # tail decline" that survived five other hypotheses.
  #
  # Rewriting PTS to the frame ordinal on BOTH sides makes frame k always meet
  # frame k. A source-vs-itself control returns exactly 100.00 under this form.
  $sync = 'settb=1/1000,setpts=N'

  $lavfi = "[0:v]${trim}${sync}[dist];" +
           "[1:v]${trim}${sync}[ref];" +
           "[dist][ref]libvmaf=model=$model" +
           ":log_path=$logEsc`:log_fmt=json:n_threads=$Threads"

  $pre = @()
  if ($HwDecode) { $pre = @('-hwaccel','cuda') }

  $ffArgs = @('-hide_banner','-nostdin','-v','error') +
            $pre + @('-i', $Distorted) +
            $pre + @('-i', $Reference) +
            @('-lavfi', $lavfi, '-f','null','-')

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $null = Invoke-FFmpegCapture -Arguments $ffArgs
  $sw.Stop()

  if (-not (Test-Path -LiteralPath $LogPath)) { return $null }

  try {
    $vj = Get-Content -LiteralPath $LogPath -Raw | ConvertFrom-Json
  } catch { return $null }

  $scores = @($vj.frames | ForEach-Object { [double]$_.metrics.vmaf })
  if ($scores.Count -eq 0) { return $null }

  $sorted = $scores | Sort-Object
  $idx1   = [Math]::Max(0, [int][Math]::Floor($sorted.Count * 0.01) - 1)

  [pscustomobject]@{
    Mean         = [math]::Round($vj.pooled_metrics.vmaf.mean, 3)
    Min          = [math]::Round($vj.pooled_metrics.vmaf.min, 3)
    HarmonicMean = [math]::Round($vj.pooled_metrics.vmaf.harmonic_mean, 3)
    P1Low        = [math]::Round($sorted[$idx1], 3)
    FrameCount   = $scores.Count
    Model        = $model
    Seconds      = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    LogPath      = $LogPath
  }
}

# ------------------------------------------------------- real decoded frames
function Get-DecodedFrameCount {
  <# Counts frames by ACTUALLY DECODING the stream. nb_frames is container
     metadata and can lie -- OBS recordings routinely claim one more frame than
     the stream yields, because the final packet (cut mid-GOP at recording stop)
     produces no displayable frame. Costs a full decode; use as the tie-breaker
     when metadata counts disagree, not as the fast path. Returns -1 on failure. #>
  param([Parameter(Mandatory)][string]$Path)
  $r = Invoke-FFmpegCapture -Arguments @(
          '-hide_banner','-nostdin','-i',$Path,'-map','0:v:0','-f','null','-')
  $m = [regex]::Matches($r.Text, 'frame=\s*(\d+)')
  if ($m.Count) { return [int]$m[$m.Count-1].Groups[1].Value }
  return -1
}

# ----------------------------------------------------------- image color info
function Get-ImageColorInfo {
  <# Detects an embedded ICC profile and its primaries. WebP cannot carry ICC
     (verified: ffmpeg drops it, with or without iccgen), and dropping a
     Display-P3 profile visibly desaturates the photo in color-managed viewers
     even when the pixel VALUES survive perfectly -- caught by the operator's
     eyes on real S24U photos, not by SSIM. #>
  param([Parameter(Mandatory)][string]$Path)
  $raw = Invoke-FFprobeJson -Arguments @('-v','error','-select_streams','v:0',
           '-show_frames','-read_intervals','%+#1','--',$Path)
  $hasIcc = ($raw -match 'ICC profile')
  $prim = ''; $matrix = ''; $range = ''
  if ($hasIcc) {
    $r = Invoke-FFmpegCapture -Arguments @('-hide_banner','-nostdin','-v','info','-i',$Path,
          '-frames:v','1','-vf','iccdetect,showinfo','-f','null','-')
    $prim   = [regex]::Match($r.Text, 'color_primaries:(\w+)').Groups[1].Value
    $matrix = [regex]::Match($r.Text, 'color_space:(\w+)').Groups[1].Value
    $range  = [regex]::Match($r.Text, 'color_range:(\w+)').Groups[1].Value
  }
  [pscustomobject]@{ HasIcc = $hasIcc; Primaries = $prim; Matrix = $matrix; Range = $range }
}

function Get-P3MapFilter {
  <# zscale filter that gamut-maps Display-P3 pixels to sRGB, so the untagged
     WebP renders with CORRECT color in every viewer (verified on real photos:
     numeric SAT 18.66 -> 22.13, matching the P3 rendering intent). Slightly
     lossy for colors outside sRGB entirely -- lossy tier only. #>
  param([Parameter(Mandatory)]$ColorInfo)
  $mIn = switch ($ColorInfo.Matrix) { 'bt470bg' {'470bg'} 'smpte170m' {'170m'} 'bt709' {'709'} default {'470bg'} }
  $rIn = if ($ColorInfo.Range -eq 'tv') { 'limited' } else { 'full' }
  return "zscale=rangein=$rIn`:primariesin=smpte432:transferin=iec61966-2-1:matrixin=$mIn`:primaries=709:transfer=iec61966-2-1:matrix=170m:range=full"
}

# ---------------------------------------------------------- audio bit-exactness
function Get-AudioStreamMd5 {
  <# MD5 of the COPIED audio packets. Identical source/output hashes prove the
     audio was never re-encoded -- a guarantee the video side cannot have. #>
  param([Parameter(Mandatory)][string]$Path)
  $r = Invoke-FFmpegCapture -Arguments @(
          '-hide_banner','-nostdin','-v','error','-i',$Path,
          '-map','0:a:0','-c','copy','-f','md5','-')
  if ($r.Text -match 'MD5=([0-9a-fA-F]+)') { return $Matches[1].ToLower() }
  return $null
}

# ------------------------------------------------------------------- utility
function Format-Bytes {
  param([Parameter(Mandatory)][double]$Bytes)
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes/1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes/1MB)) }
  return ('{0:N0} KB' -f ($Bytes/1KB))
}

function Assert-NotSourceDrive {
  <# Hard guard: refuse to write anywhere under the originals tree. Called by
     every script that produces output. #>
  param(
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ProtectedRoot = 'H:\Grand Archives'
  )
  $full = [System.IO.Path]::GetFullPath($OutputPath)
  if ($full.StartsWith($ProtectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "REFUSING to write inside the protected originals tree: $full"
  }
}
