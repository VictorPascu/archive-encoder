<#
  Phase 1 -- encoder calibration.

  Cuts short excerpts losslessly from the real footage, encodes each through a
  matrix of codec/quality settings, and measures VMAF against the excerpt it
  came from. Produces a comparison table plus the sample files themselves so
  the quality/size tradeoff is chosen from measurements, not from priors.

  Reads from H: only. Writes exclusively under -WorkDir on L:.

  Usage:
    .\calibrate.ps1
    .\calibrate.ps1 -Seconds 20 -SkipX265        # fast pass, NVENC only
    .\calibrate.ps1 -Seconds 45                  # more thorough
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SourceDir,
  [Parameter(Mandatory)][string]$WorkDir,     # scratch + sample output (NOT under the source tree)
  [string]$Filter    = '*.mp4',
  [int]$Seconds      = 30,
  # Shortest source clip eligible to be a calibration subject. 20s keeps the
  # real run from picking a 3-second fragment; lowered only by the test harness.
  [int]$MinClipSeconds = 20,
  [switch]$SkipX265,
  [string]$X265Preset = 'slow',
  # Report both VMAF models. The 4k model is correct for 4K-viewed content but
  # scores ~3-4 points higher than the 1080p-viewing default, so a threshold
  # means different things on each scale. Costs a second VMAF pass per encode.
  [bool]$DualModel = $true
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

Assert-NotSourceDrive -OutputPath $WorkDir

$refDir = Join-Path $WorkDir 'reference'
$encDir = Join-Path $WorkDir 'encodes'
foreach ($d in @($WorkDir,$refDir,$encDir)) {
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ============================================================ 1. survey source
Write-Host ""
Write-Host "Surveying source files..." -ForegroundColor Cyan
$all = @()
foreach ($f in (Get-ChildItem -LiteralPath $SourceDir -File -Filter $Filter | Sort-Object Name)) {
  $all += Get-VideoInfo -Path $f.FullName
}
Write-Host ("  $($all.Count) files, $(Format-Bytes (($all | Measure-Object Bytes -Sum).Sum))")

# ============================================================ 2. choose clips
# The discriminator is VfrRatio (realised fps / fps the phone claimed), NOT raw
# fps: the set mixes nominal-30 and nominal-60 captures, so a raw sort would
# pick a healthy 30 fps clip instead of the 60 fps clip that dropped a third of
# its frames in the dark. Falls back to raw fps only if the capture tag is absent.
$k4        = @($all | Where-Object { $_.Is4K -and $_.Duration -gt $MinClipSeconds })
if ($k4.Count -eq 0) { throw "No 4K files over ${MinClipSeconds}s found in $SourceDir" }
$haveRatio = @($k4 | Where-Object { $_.VfrRatio })

# prefer a long subject so the excerpt sits inside sustained performance footage
$longPref = [Math]::Max($MinClipSeconds, 120)
$midPref  = [Math]::Max($MinClipSeconds, 90)

if ($haveRatio.Count -ge 2) {
  # A: worst case -- most frames dropped relative to what was claimed (dark, noisy)
  $clipA = $haveRatio | Where-Object { $_.Duration -gt $longPref } | Sort-Object VfrRatio | Select-Object -First 1
  if (-not $clipA) { $clipA = $haveRatio | Sort-Object VfrRatio | Select-Object -First 1 }

  # B: the opposite -- sustained full frame rate, i.e. bright and fast-moving.
  # Prefer an UNROTATED subject: rotation is clip C's job, and letting B pick a
  # rotated file duplicates C and wastes a third of the matrix.
  $poolB = @($haveRatio | Where-Object { $_.Name -ne $clipA.Name })
  $poolBflat = @($poolB | Where-Object { $_.Rotation -eq 0 })
  if ($poolBflat.Count) { $poolB = $poolBflat }
  $clipB = $poolB | Where-Object { $_.Duration -gt $midPref } | Sort-Object VfrRatio -Descending | Select-Object -First 1
  if (-not $clipB) { $clipB = $poolB | Sort-Object VfrRatio -Descending | Select-Object -First 1 }
} else {
  Write-Host "  (no com.android.capture.fps tag found -- falling back to realised fps)" -ForegroundColor DarkYellow
  $clipA = $k4 | Sort-Object AvgFps | Select-Object -First 1
  $clipB = $k4 | Where-Object { $_.Name -ne $clipA.Name } | Sort-Object AvgFps -Descending | Select-Object -First 1
}

# C: a rotated file, to prove orientation survives the encode. Prefer 4K, and
# prefer one not already used as A or B.
$chosen = @($clipA, $clipB | Where-Object { $_ } | ForEach-Object { $_.Name })
$rotAll = @($all | Where-Object { $_.Rotation -ne 0 })
$clipC = $rotAll | Where-Object { $_.Is4K -and $chosen -notcontains $_.Name } |
         Sort-Object Duration -Descending | Select-Object -First 1
if (-not $clipC) { $clipC = $rotAll | Where-Object { $_.Is4K } | Sort-Object Duration -Descending | Select-Object -First 1 }
if (-not $clipC) { $clipC = $rotAll | Sort-Object Duration -Descending | Select-Object -First 1 }
if (-not $clipC) { Write-Host "  (no rotated files found -- skipping orientation clip)" -ForegroundColor DarkYellow }

$clips = @()
if ($clipA) { $clips += [pscustomobject]@{ Tag='A_dark_vfr';   Info=$clipA; FullMatrix=$true  } }
if ($clipB) { $clips += [pscustomobject]@{ Tag='B_bright_fast';Info=$clipB; FullMatrix=$true  } }
if ($clipC) { $clips += [pscustomobject]@{ Tag='C_rotated';    Info=$clipC; FullMatrix=$false } }

Write-Host ""
Write-Host "Calibration clips:" -ForegroundColor Cyan
foreach ($c in $clips) {
  $i = $c.Info
  Write-Host ("  {0,-14} {1}  {2}x{3} rot={4}  {5}s  avg {6} fps (claimed {7})  ratio {8}" -f `
    $c.Tag, $i.Name, $i.Width, $i.Height, $i.Rotation,
    [math]::Round($i.Duration,0), $i.AvgFps, $i.CaptureFps, $i.VfrRatio)
}

# ============================================================ 3. cut references
Write-Host ""
Write-Host "Cutting lossless reference excerpts ($Seconds s each)..." -ForegroundColor Cyan
foreach ($c in $clips) {
  $i   = $c.Info
  $len = [Math]::Min($Seconds, [Math]::Floor($i.Duration) - 2)
  $start = [Math]::Max(0, [Math]::Floor($i.Duration * 0.45))
  if ($start + $len -gt $i.Duration) { $start = [Math]::Max(0, [Math]::Floor($i.Duration - $len - 1)) }

  $refPath = Join-Path $refDir "$($c.Tag).mp4"
  if (Test-Path -LiteralPath $refPath) { Remove-Item -LiteralPath $refPath -Force }

  # -c copy keeps the excerpt bit-identical to the source frames it spans.
  $null = Invoke-FFmpegCapture -Arguments @(
      '-hide_banner','-nostdin','-v','error',
      '-ss',"$start",'-t',"$len",'-i',$i.Path,
      '-map','0:v:0','-map','0:a:0','-c','copy',
      '-avoid_negative_ts','make_zero','-video_track_timescale','90000',
      $refPath)

  if (-not (Test-Path -LiteralPath $refPath)) { throw "Failed to cut reference for $($c.Tag)" }

  $ri = Get-VideoInfo -Path $refPath
  $c | Add-Member -NotePropertyName RefPath  -NotePropertyValue $refPath  -Force
  $c | Add-Member -NotePropertyName RefInfo  -NotePropertyValue $ri       -Force
  Write-Host ("  {0,-14} start {1,4}s  {2} frames  {3}  {4} Mbps  rot={5}" -f `
    $c.Tag, $start, $ri.Frames, (Format-Bytes $ri.Bytes), $ri.Mbps, $ri.Rotation)
}

# ============================================================ 4. build matrix
$matrixFull = @()
if (-not $SkipX265) { $matrixFull += @(
  @{ Codec='x265'; Q=20 }, @{ Codec='x265'; Q=22 }, @{ Codec='x265'; Q=24 } ) }
$matrixFull += @(
  @{ Codec='hevc_nvenc'; Q=22 }, @{ Codec='hevc_nvenc'; Q=26 }, @{ Codec='hevc_nvenc'; Q=30 },
  @{ Codec='av1_nvenc';  Q=28 }, @{ Codec='av1_nvenc';  Q=32 }, @{ Codec='av1_nvenc';  Q=36 } )

# the rotated clip only needs one setting per codec -- it is an orientation check
$matrixSpot = @( @{ Codec='hevc_nvenc'; Q=26 }, @{ Codec='av1_nvenc'; Q=32 } )
if (-not $SkipX265) { $matrixSpot = @(@{ Codec='x265'; Q=22 }) + $matrixSpot }

$jobs = @()
foreach ($c in $clips) {
  foreach ($m in $(if ($c.FullMatrix) { $matrixFull } else { $matrixSpot })) {
    $jobs += [pscustomobject]@{ Clip=$c; Codec=$m.Codec; Q=$m.Q }
  }
}

Write-Host ""
Write-Host ("Matrix: {0} encodes. VMAF model: {1}" -f $jobs.Count, (Get-VmafModel)) -ForegroundColor Cyan
if (-not $SkipX265) {
  Write-Host "  Note: libx265 -preset $X265Preset at 4K runs ~3 fps on 8 cores. It is the slow part." -ForegroundColor DarkYellow
}
Write-Host ""

# ============================================================ 5. run
$results = New-Object System.Collections.Generic.List[object]
$n = 0
$swAll = [Diagnostics.Stopwatch]::StartNew()

foreach ($job in $jobs) {
  $n++
  $c   = $job.Clip
  $ri  = $c.RefInfo
  $out = Join-Path $encDir ("{0}_{1}_q{2}.mp4" -f $c.Tag, $job.Codec, $job.Q)

  Write-Host ("[{0,2}/{1}] {2,-14} {3,-11} q={4,-3} " -f $n, $jobs.Count, $c.Tag, $job.Codec, $job.Q) -NoNewline

  if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }

  $encArgs = @('-hide_banner','-nostdin','-v','error','-i',$c.RefPath,'-map','0:v:0','-map','0:a:0') +
             (Get-EncoderArgs -Codec $job.Codec -Quality $job.Q -X265Preset $X265Preset) +
             (Get-CommonTailArgs) + @($out)

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $encErr = (Invoke-FFmpegCapture -Arguments $encArgs).Text
  $sw.Stop()

  if (-not (Test-Path -LiteralPath $out)) {
    Write-Host "ENCODE FAILED" -ForegroundColor Red
    if ($encErr.Trim()) { Write-Host "        $($encErr.Trim())" -ForegroundColor DarkRed }
    $results.Add([pscustomobject]@{
      clip=$c.Tag; codec=$job.Codec; q=$job.Q; status='ENCODE_FAILED'
      out_bytes=$null; ref_bytes=$ri.Bytes; ratio=$null; mbps=$null
      vmaf_mean=$null; vmaf_p1low=$null; vmaf_min=$null; vmaf_hmean=$null
      vmaf_model=$null; vmaf1080_mean=$null; vmaf1080_p1low=$null
      enc_sec=[math]::Round($sw.Elapsed.TotalSeconds,1); enc_fps=$null
      frames_ref=$ri.Frames; frames_out=$null; rot_ref=$ri.Rotation; rot_out=$null
      dispw_ref=$ri.DisplayW; disph_ref=$ri.DisplayH; dispw_out=$null; disph_out=$null
      path=$out })
    continue
  }

  $oi     = Get-VideoInfo -Path $out
  $encFps = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($oi.Frames / $sw.Elapsed.TotalSeconds,1) } else { 0 }
  $ratio  = if ($oi.Bytes -gt 0) { [math]::Round($ri.Bytes / $oi.Bytes, 2) } else { 0 }

  Write-Host ("{0,9}  {1,5}x  {2,5} Mbps  {3,6}s @{4,5} fps  " -f `
    (Format-Bytes $oi.Bytes), $ratio, $oi.Mbps, [math]::Round($sw.Elapsed.TotalSeconds,0), $encFps) -NoNewline

  # frame-count parity is a precondition for VMAF being meaningful
  $framesOk = ($oi.Frames -eq $ri.Frames)
  if (-not $framesOk) {
    Write-Host ("FRAME COUNT {0} vs {1}" -f $oi.Frames, $ri.Frames) -ForegroundColor Red
  }

  $v = Invoke-Vmaf -Distorted $out -Reference $c.RefPath -HwDecode
  $v10 = $null
  if ($DualModel -and $v) {
    $v10 = Invoke-Vmaf -Distorted $out -Reference $c.RefPath -HwDecode -Model 'version=vmaf_v0.6.1'
  }
  if ($v) {
    $col = if ($v.Mean -ge 95) { 'Green' } elseif ($v.Mean -ge 93) { 'Yellow' } else { 'Red' }
    $extra = if ($v10) { (" [1080p model {0}]" -f $v10.Mean) } else { '' }
    Write-Host ("VMAF4k {0,6} (1% low {1,6}){2}" -f $v.Mean, $v.P1Low, $extra) -ForegroundColor $col
  } else {
    Write-Host "VMAF FAILED" -ForegroundColor Red
  }

  $results.Add([pscustomobject]@{
    clip=$c.Tag; codec=$job.Codec; q=$job.Q
    status=$(if ($framesOk) { 'OK' } else { 'FRAME_MISMATCH' })
    out_bytes=$oi.Bytes; ref_bytes=$ri.Bytes; ratio=$ratio; mbps=$oi.Mbps
    vmaf_mean=$(if($v){$v.Mean}); vmaf_p1low=$(if($v){$v.P1Low})
    vmaf_min=$(if($v){$v.Min});   vmaf_hmean=$(if($v){$v.HarmonicMean})
    vmaf_model=$(if($v){$v.Model})
    vmaf1080_mean=$(if($v10){$v10.Mean}); vmaf1080_p1low=$(if($v10){$v10.P1Low})
    enc_sec=[math]::Round($sw.Elapsed.TotalSeconds,1); enc_fps=$encFps
    frames_ref=$ri.Frames; frames_out=$oi.Frames
    rot_ref=$ri.Rotation; rot_out=$oi.Rotation
    dispw_ref=$ri.DisplayW; disph_ref=$ri.DisplayH
    dispw_out=$oi.DisplayW; disph_out=$oi.DisplayH
    path=$out })
}
$swAll.Stop()

# ============================================================ 6. report
$csv = Join-Path $WorkDir 'calibration-results.csv'
$results | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding utf8

Write-Host ""
Write-Host "==================== CALIBRATION RESULTS ====================" -ForegroundColor Cyan
Write-Host ("Elapsed: {0:N1} min    CSV: {1}" -f $swAll.Elapsed.TotalMinutes, $csv)

foreach ($tag in ($results.clip | Select-Object -Unique)) {
  Write-Host ""
  Write-Host "--- $tag ---" -ForegroundColor Cyan
  $results | Where-Object clip -eq $tag |
    Sort-Object codec, q |
    Format-Table -AutoSize @{n='codec';e={$_.codec}}, @{n='q';e={$_.q}},
      @{n='size';e={ if($_.out_bytes){Format-Bytes $_.out_bytes}else{'-'} }},
      @{n='shrink';e={ if($_.ratio){"$($_.ratio)x"}else{'-'} }},
      @{n='Mbps';e={$_.mbps}},
      @{n='VMAF4k';e={$_.vmaf_mean}}, @{n='1% low';e={$_.vmaf_p1low}}, @{n='min';e={$_.vmaf_min}},
      @{n='VMAF1080';e={$_.vmaf1080_mean}},
      @{n='enc fps';e={$_.enc_fps}}, @{n='status';e={$_.status}}
}

# ---- orientation verdict for the rotated clip
$rotRows = @($results | Where-Object { $_.clip -like 'C_*' -and $_.status -eq 'OK' })
if ($rotRows.Count) {
  Write-Host ""
  Write-Host "--- ORIENTATION CHECK (rotated clip) ---" -ForegroundColor Cyan
  foreach ($r in $rotRows) {
    $same = ($r.dispw_out -eq $r.dispw_ref -and $r.disph_out -eq $r.disph_ref)
    $how  = if ($r.rot_out -eq 0 -and $r.rot_ref -ne 0) { 'rotation baked into pixels' }
            elseif ($r.rot_out -eq $r.rot_ref)          { 'matrix carried through' }
            else                                        { "matrix changed $($r.rot_ref) -> $($r.rot_out)" }
    $verdict = if ($same) { 'OK' } else { 'WRONG ORIENTATION' }
    Write-Host ("  {0,-11} q={1,-3} displays {2}x{3} on both sides -- {4}  [{5}]" -f `
      $r.codec, $r.q, $r.dispw_ref, $r.disph_ref, $how, $verdict) -ForegroundColor $(if ($same) { 'Green' } else { 'Red' })
  }
  Write-Host "  Display dimensions are the invariant that matters -- a source stored 3840x2160" -ForegroundColor DarkGray
  Write-Host "  with a -90 matrix and an output stored 2160x3840 with none look IDENTICAL to a" -ForegroundColor DarkGray
  Write-Host "  player, and the baked-in form is the more compatible of the two. Confirm visually." -ForegroundColor DarkGray
}

# ---- projected whole-job size, extrapolated per setting
$totalSrc = ($all | Measure-Object Bytes -Sum).Sum
Write-Host ""
Write-Host "--- PROJECTED TOTAL FOR ALL 64 FILES ($(Format-Bytes $totalSrc) today) ---" -ForegroundColor Cyan
$proj = $results | Where-Object { $_.status -eq 'OK' -and $_.clip -notlike 'C_*' -and $_.ratio } |
  Group-Object codec, q | ForEach-Object {
    $avgRatio = ($_.Group | Measure-Object ratio -Average).Average
    $avgVmaf  = ($_.Group | Measure-Object vmaf_mean -Average).Average
    $minP1    = ($_.Group | Measure-Object vmaf_p1low -Minimum).Minimum
    [pscustomobject]@{
      setting   = $_.Name -replace ', ',' q'
      avg_shrink= "{0:N2}x" -f $avgRatio
      projected = Format-Bytes ($totalSrc / $avgRatio)
      avg_vmaf  = [math]::Round($avgVmaf,2)
      worst_p1  = [math]::Round($minP1,2)
      verdict   = if ($avgVmaf -ge 95 -and $minP1 -ge 92) { 'visually lossless' }
                  elseif ($avgVmaf -ge 93) { 'very good' }
                  else { 'visible loss likely' }
    }
  }
$proj | Sort-Object { [double]($_.avg_shrink -replace 'x','') } | Format-Table -AutoSize
Write-Host "  Approximate: extrapolates the two 4K clips' average shrink across the whole set," -ForegroundColor DarkGray
Write-Host "  which also contains 26 smaller 1080-class files. Treat as a range, not a promise." -ForegroundColor DarkGray

Write-Host ""
Write-Host "Sample files to watch:" -ForegroundColor Cyan
Write-Host "  reference: $refDir"
Write-Host "  encodes  : $encDir"
Write-Host ""
Write-Host "Compare a candidate against its reference side by side, e.g.:" -ForegroundColor DarkGray
Write-Host "  ffplay `"$refDir\A_dark_vfr.mp4`"" -ForegroundColor DarkGray
Write-Host "  ffplay `"$encDir\A_dark_vfr_hevc_nvenc_q26.mp4`"" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Decision rule: VMAF mean >= 95 with 1% low >= 92 is visually lossless." -ForegroundColor DarkGray
Write-Host "Pick the largest q (smallest file) that still clears that bar." -ForegroundColor DarkGray
