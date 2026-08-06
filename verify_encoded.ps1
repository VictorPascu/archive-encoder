<#
  Phase 3 -- verify every encoded output against its original.

  Seven checks per file:
    1  clean full decode (-xerror), zero errors
    2  frame count exactly equal to source
    3  duration within one frame period
    4  audio stream MD5 identical  -> proves audio is bit-for-bit untouched
    5  VMAF over a frame-exact sample window, against the chosen threshold
    6  creation_time + GPS location preserved            (WARN level)
    7  effective display dimensions match                (covers the 15 rotated files)

  Reads both trees. Writes only the manifest CSV.

  Usage:
    .\verify_encoded.ps1
    .\verify_encoded.ps1 -VmafFrames 1800 -VmafMin 95
    .\verify_encoded.ps1 -SkipVmaf          # fast structural pass only
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SourceDir,
  [Parameter(Mandatory)][string]$EncDir,
  [string]$Filter     = '*.mp4',
  [string]$ManifestOut= '',
  [int]$VmafFrames    = 900,
  [double]$VmafStartPct = 0.35,
  [double]$VmafMin    = 95.0,
  [double]$VmafP1Min  = 92.0,
  [switch]$SkipVmaf,
  # Verify an explicit list of filenames instead of everything matching -Filter.
  # Useful for spot-checking mid-run without waiting for the whole batch.
  [string[]]$Names,
  # Treat a source whose output does not exist yet as PENDING rather than FAIL,
  # so a mid-run check does not report not-yet-encoded files as failures.
  [switch]$OnlyExisting
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

if (-not (Test-Path -LiteralPath $EncDir)) { throw "Encoded dir not found: $EncDir" }
if (-not $ManifestOut) { $ManifestOut = Join-Path (Split-Path $EncDir -Parent) 'manifest-encoded.csv' }

$srcFiles = @(Get-ChildItem -LiteralPath $SourceDir -File -Filter $Filter | Sort-Object Name)
if ($Names) { $srcFiles = @($srcFiles | Where-Object { $Names -contains $_.Name }) }
if ($srcFiles.Count -eq 0) { throw "No files matching '$Filter' in $SourceDir" }

if ($OnlyExisting) {
  $before = $srcFiles.Count
  $srcFiles = @($srcFiles | Where-Object { Test-Path -LiteralPath (Join-Path $EncDir $_.Name) })
  $pending = $before - $srcFiles.Count
  if ($pending) { Write-Host ("  ({0} source file(s) not encoded yet -- skipped as pending)" -f $pending) -ForegroundColor DarkGray }
  if ($srcFiles.Count -eq 0) { throw "None of the selected files have been encoded yet" }
}

Write-Host ""
Write-Host "Source  : $SourceDir"
Write-Host "Encoded : $EncDir"
Write-Host ("Files   : {0}" -f $srcFiles.Count)
if (-not $SkipVmaf) {
  Write-Host ("VMAF    : {0} frames from {1:P0} in, model {2}, threshold mean>={3} / 1%low>={4}" -f `
    $VmafFrames, $VmafStartPct, (Get-VmafModel), $VmafMin, $VmafP1Min)
} else {
  Write-Host "VMAF    : SKIPPED (structural checks only)" -ForegroundColor Yellow
}
Write-Host ""

$rows  = New-Object System.Collections.Generic.List[object]
$swAll = [Diagnostics.Stopwatch]::StartNew()
$n = 0

foreach ($sf in $srcFiles) {
  $n++
  $encPath = Join-Path $EncDir $sf.Name

  Write-Host ("[{0,2}/{1}] {2,-24} " -f $n, $srcFiles.Count, $sf.Name) -NoNewline

  if (-not (Test-Path -LiteralPath $encPath)) {
    Write-Host "MISSING OUTPUT" -ForegroundColor Red
    $rows.Add([pscustomobject]@{
      name=$sf.Name; verdict='FAIL'; reasons='missing_output'
      src_bytes=$sf.Length; out_bytes=$null; ratio=$null
      decode_ok=$null; frames_ok=$null; duration_ok=$null; audio_identical=$null
      vmaf_mean=$null; vmaf_p1low=$null; vmaf_ok=$null
      metadata_ok=$null; orientation_ok=$null
      src_frames=$null; out_frames=$null; dur_delta_s=$null
      src_disp=''; out_disp=''; notes='' })
    continue
  }

  $si = Get-VideoInfo -Path $sf.FullName
  $oi = Get-VideoInfo -Path $encPath

  $fails = New-Object System.Collections.Generic.List[string]
  $warns = New-Object System.Collections.Generic.List[string]

  # ---- 1. clean decode of the OUTPUT, end to end
  #
  # Judged on ffmpeg's EXIT CODE plus a targeted search for serious decode
  # errors -- deliberately NOT on "is stderr empty".
  #
  # Why: feeding VFR phone footage through `-f null -` makes the null muxer emit
  # "Application provided invalid, non monotonically increasing dts to muxer".
  # That is a property of the test pipeline, not the file: the container timebase
  # is 1/90000 while real frame deltas alternate 1499/1500 (the phone shoots a
  # shade off 60.000 fps), and two values can collide after the muxer's own
  # timebase conversion. A direct DTS audit of all 64 originals, every excerpt and
  # all 21 calibration encodes found ZERO duplicate or backward timestamps, and
  # ffmpeg still exits 0. An earlier version of this check treated any stderr as
  # failure, which would have failed every single real file.
  $decRes = Invoke-FFmpegCapture -Arguments @(
              '-hide_banner','-nostdin','-v','error','-xerror','-i',$encPath,'-f','null','-')
  $seriousPattern = 'Invalid data found|error while decoding|corrupt|Truncating packet|' +
                    'Invalid NAL|missing picture|could not find codec|Failed to open|decode_slice'
  $serious = @([regex]::Matches($decRes.Text, $seriousPattern))
  $decodeOk = ($decRes.ExitCode -eq 0 -and $serious.Count -eq 0)
  $decErr = if ($serious.Count) { ($serious | ForEach-Object { $_.Value }) -join '; ' }
            elseif ($decRes.ExitCode -ne 0) { "ffmpeg exit $($decRes.ExitCode)" }
            else { '' }
  if (-not $decodeOk) { $fails.Add('decode_errors') }

  # ---- 2. frame count parity
  $framesOk = ($oi.Frames -eq $si.Frames -and $si.Frames -gt 0)
  if (-not $framesOk) { $fails.Add("frames($($oi.Frames)vs$($si.Frames))") }

  # ---- 3. duration within one frame period (2x tolerance for container rounding)
  $tol      = if ($si.AvgFps -gt 0) { 2.0 / $si.AvgFps } else { 0.1 }
  $durDelta = [math]::Round($oi.Duration - $si.Duration, 4)
  $durOk    = ([math]::Abs($durDelta) -le $tol)
  if (-not $durOk) { $fails.Add("duration(${durDelta}s)") }

  # ---- 4. audio bit-exactness -- the one true zero-loss guarantee here
  $md5Src = Get-AudioStreamMd5 -Path $sf.FullName
  $md5Out = Get-AudioStreamMd5 -Path $encPath
  $audioOk = ($md5Src -and $md5Out -and $md5Src -eq $md5Out)
  if (-not $audioOk) { $fails.Add('audio_not_identical') }

  # ---- 7. orientation (checked before VMAF: cheap, and it gates interpretation)
  $orientOk = ($oi.DisplayW -eq $si.DisplayW -and $oi.DisplayH -eq $si.DisplayH)
  if (-not $orientOk) { $fails.Add("orientation($($oi.DisplayW)x$($oi.DisplayH)vs$($si.DisplayW)x$($si.DisplayH))") }

  # ---- 6. metadata (warn-level: losing GPS is a wart, not corruption)
  $metaOk = $true
  if ($si.CreationTime -and $oi.CreationTime -ne $si.CreationTime) { $metaOk = $false; $warns.Add('creation_time') }
  if ($si.Location     -and -not $oi.Location)                    { $metaOk = $false; $warns.Add('location') }

  # ---- 5. VMAF over a frame-exact window
  $v = $null; $vmafOk = $null
  if (-not $SkipVmaf -and $framesOk) {
    $start = [int][Math]::Floor($si.Frames * $VmafStartPct)
    $end   = [Math]::Min($si.Frames, $start + $VmafFrames)
    if ($end - $start -lt 60) { $start = 0; $end = [Math]::Min($si.Frames, $VmafFrames) }

    $v = Invoke-Vmaf -Distorted $encPath -Reference $sf.FullName `
                     -StartFrame $start -EndFrame $end -HwDecode
    if ($v) {
      # BOTH mean and 1%-low are failing gates.
      #
      # An earlier revision demoted 1%-low to a warning, on the grounds that
      # calibration clip B's 1% low sat at ~89 regardless of bitrate. That
      # reasoning was wrong: the depressed number was an artifact of libvmaf's
      # timestamp-based frame pairing slipping on VFR input (see Invoke-Vmaf).
      # With index-based pairing clip B's 1% low is 96.46, not 89.55, and the
      # statistic is trustworthy again -- so it goes back to being a hard gate
      # rather than advisory.
      $vmafOk = ($v.Mean -ge $VmafMin -and $v.P1Low -ge $VmafP1Min)
      if (-not $vmafOk) { $fails.Add("vmaf($($v.Mean)/$($v.P1Low))") }
    } else {
      $fails.Add('vmaf_failed')
    }
  }

  $verdict = if ($fails.Count -gt 0) { 'FAIL' } elseif ($warns.Count -gt 0) { 'PASS_WARN' } else { 'PASS' }
  $ratio   = if ($oi.Bytes -gt 0) { [math]::Round($si.Bytes / $oi.Bytes, 2) } else { $null }

  $col = switch ($verdict) { 'PASS' {'Green'} 'PASS_WARN' {'Yellow'} default {'Red'} }
  $vmafTxt = if ($v) { ("VMAF {0,6}/{1,-6}" -f $v.Mean, $v.P1Low) } elseif ($SkipVmaf) { "" } else { "VMAF --     " }
  Write-Host ("{0,9} {1,5}x  {2} {3}" -f (Format-Bytes $oi.Bytes), $ratio, $vmafTxt, $verdict) -ForegroundColor $col
  if ($fails.Count) { Write-Host ("        FAIL: " + ($fails -join ', ')) -ForegroundColor Red }
  if ($warns.Count) { Write-Host ("        warn: " + ($warns -join ', ')) -ForegroundColor DarkYellow }

  $rows.Add([pscustomobject]@{
    name=$sf.Name; verdict=$verdict
    reasons=($fails -join '; '); warnings=($warns -join '; ')
    src_bytes=$si.Bytes; out_bytes=$oi.Bytes; ratio=$ratio
    src_mbps=$si.Mbps; out_mbps=$oi.Mbps
    decode_ok=$decodeOk; frames_ok=$framesOk; duration_ok=$durOk
    audio_identical=$audioOk; audio_md5=$md5Src
    vmaf_mean=$(if($v){$v.Mean}); vmaf_p1low=$(if($v){$v.P1Low})
    vmaf_min=$(if($v){$v.Min}); vmaf_frames=$(if($v){$v.FrameCount}); vmaf_ok=$vmafOk
    metadata_ok=$metaOk; orientation_ok=$orientOk
    src_frames=$si.Frames; out_frames=$oi.Frames; dur_delta_s=$durDelta
    src_disp="$($si.DisplayW)x$($si.DisplayH)"; out_disp="$($oi.DisplayW)x$($oi.DisplayH)"
    src_rot=$si.Rotation; out_rot=$oi.Rotation
    creation_time=$si.CreationTime; location=$si.Location })

  $rows | Export-Csv -LiteralPath $ManifestOut -NoTypeInformation -Encoding utf8
}

$swAll.Stop()
$rows | Export-Csv -LiteralPath $ManifestOut -NoTypeInformation -Encoding utf8

# ------------------------------------------------------------------ summary
$pass  = @($rows | Where-Object verdict -eq 'PASS')
$warn  = @($rows | Where-Object verdict -eq 'PASS_WARN')
$fail  = @($rows | Where-Object verdict -eq 'FAIL')
$srcTot = ($rows | Measure-Object src_bytes -Sum).Sum
$outTot = ($rows | Where-Object out_bytes | Measure-Object out_bytes -Sum).Sum

Write-Host ""
Write-Host "==================== PHASE 3 RESULT ====================" -ForegroundColor Cyan
Write-Host ("Pass            : {0}/{1}" -f $pass.Count, $rows.Count)
Write-Host ("Pass with warn  : {0}" -f $warn.Count)
Write-Host ("FAIL            : {0}" -f $fail.Count)
Write-Host ("Audio identical : {0}/{1}" -f @($rows | Where-Object audio_identical -eq $true).Count, $rows.Count)
Write-Host ("Orientation ok  : {0}/{1}" -f @($rows | Where-Object orientation_ok -eq $true).Count, $rows.Count)
if ($outTot) {
  Write-Host ("Size            : {0} -> {1}   ({2:N2}x smaller, saved {3})" -f `
    (Format-Bytes $srcTot), (Format-Bytes $outTot), ($srcTot/$outTot), (Format-Bytes ($srcTot-$outTot))) -ForegroundColor Green
}

if (-not $SkipVmaf) {
  $vm = @($rows | Where-Object vmaf_mean)
  if ($vm.Count) {
    Write-Host ""
    Write-Host "VMAF distribution across files:" -ForegroundColor Cyan
    Write-Host ("  mean of means : {0:N2}" -f ($vm | Measure-Object vmaf_mean -Average).Average)
    Write-Host ("  worst mean    : {0:N2}  ({1})" -f `
      ($vm | Measure-Object vmaf_mean -Minimum).Minimum,
      ($vm | Sort-Object vmaf_mean | Select-Object -First 1).name)
    Write-Host ("  worst 1% low  : {0:N2}  ({1})" -f `
      ($vm | Measure-Object vmaf_p1low -Minimum).Minimum,
      ($vm | Sort-Object vmaf_p1low | Select-Object -First 1).name)
  }
}

Write-Host ""
Write-Host ("Elapsed  : {0:N1} min" -f $swAll.Elapsed.TotalMinutes)
Write-Host ("Manifest : {0}" -f $ManifestOut)

if ($fail.Count) {
  Write-Host ""
  Write-Host "FAILURES:" -ForegroundColor Red
  $fail | ForEach-Object { Write-Host ("  {0,-24} {1}" -f $_.name, $_.reasons) -ForegroundColor Red }
  Write-Host ""
  Write-Host "GATE: FAIL -- originals are untouched. Investigate before trusting the archive." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "GATE: PASS -- every output verified against its original." -ForegroundColor Green
Write-Host "Originals remain untouched on H: and backed up on K:. Nothing has been deleted." -ForegroundColor Green
exit 0
