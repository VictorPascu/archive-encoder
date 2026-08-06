<#
  Phase 2 -- batch encode all originals with the setting chosen in Phase 1.

  Safety properties:
    * Reads H: only. Refuses to write anywhere under the originals tree.
    * Encodes to "<name>.part.mp4" and renames on success, so an interrupted
      run can never leave a truncated file that looks finished.
    * Resumable: an existing output whose frame count already matches its
      source is skipped.
    * Never deletes or modifies a source file. Nothing is deleted at all.

  Usage:
    .\encode_batch.ps1 -Codec hevc_nvenc -Quality 26
    .\encode_batch.ps1 -Codec x265 -Quality 22 -X265Preset slow
    .\encode_batch.ps1 -Codec hevc_nvenc -Quality 26 -DryRun
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('x265','hevc_nvenc','av1_nvenc')][string]$Codec,
  [Parameter(Mandatory)][int]$Quality,
  [Parameter(Mandatory)][string]$SourceDir,
  [Parameter(Mandatory)][string]$OutDir,
  [string]$Filter     = '*.mp4',
  [string]$X265Preset = 'slow',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

Assert-NotSourceDrive -OutputPath $OutDir
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ------------------------------------------------------------------ survey
Write-Host ""
Write-Host "Surveying source..." -ForegroundColor Cyan
$srcFiles = @(Get-ChildItem -LiteralPath $SourceDir -File -Filter $Filter | Sort-Object Name)
if ($srcFiles.Count -eq 0) { throw "No files matching '$Filter' in $SourceDir" }

# Screen out anything that is not actually a movie before committing hours to it.
# A filter without an extension (e.g. '20251112_1*') happily matches JPEGs, and
# ffprobe reports a still image as a video stream with 1 frame -- so without this
# guard the batch cheerfully "encodes" photographs and reports them as failures.
$stillCodecs = @('mjpeg','png','bmp','gif','tiff','webp','jpegls','jpeg2000','ppm','pgm','targa','dpx')
$infos = @(); $notVideo = @()
foreach ($f in $srcFiles) {
  $i = $null
  try { $i = Get-VideoInfo -Path $f.FullName }
  catch { $notVideo += [pscustomobject]@{ Name=$f.Name; Why='no readable video stream' }; continue }

  if ($stillCodecs -contains $i.Codec) {
    $notVideo += [pscustomobject]@{ Name=$f.Name; Why="still image (codec=$($i.Codec))" }; continue
  }
  if ($i.Frames -le 1) {
    $notVideo += [pscustomobject]@{ Name=$f.Name; Why="single frame (codec=$($i.Codec), frames=$($i.Frames))" }; continue
  }
  $infos += $i
}

if ($notVideo.Count) {
  Write-Host ""
  Write-Host ("  Excluded {0} non-video file(s) matched by the filter '{1}':" -f $notVideo.Count, $Filter) -ForegroundColor Yellow
  $notVideo | Group-Object Why | ForEach-Object {
    Write-Host ("    {0,5} x {1}" -f $_.Count, $_.Name) -ForegroundColor DarkYellow
  }
  Write-Host "    (add an extension to -Filter, e.g. '*.mp4', to avoid matching these)" -ForegroundColor DarkGray
}
if ($infos.Count -eq 0) { throw "Filter '$Filter' matched no actual video files in $SourceDir" }

$totalBytes  = ($infos | Measure-Object Bytes  -Sum).Sum
$totalFrames = ($infos | Measure-Object Frames -Sum).Sum

Write-Host ("  {0} files, {1}, {2:N0} frames" -f $infos.Count, (Format-Bytes $totalBytes), $totalFrames)
Write-Host ""
Write-Host ("Encoder : {0}  q={1}{2}" -f $Codec, $Quality, $(if ($Codec -eq 'x265') { "  preset=$X265Preset" } else { '' })) -ForegroundColor Cyan
Write-Host ("Output  : {0}" -f $OutDir)
Write-Host ""
Write-Host "Preservation contract applied to every file:" -ForegroundColor DarkGray
Write-Host "  -fps_mode passthrough        keeps original VFR timestamps (29.8-60.0 fps range)" -ForegroundColor DarkGray
Write-Host "  -video_track_timescale 90000 matches source timebase, no rounding drift" -ForegroundColor DarkGray
Write-Host "  -c:a copy                    audio stays bit-for-bit identical" -ForegroundColor DarkGray
Write-Host "  -map_metadata 0 +use_metadata_tags   creation_time, GPS, com.samsung.*" -ForegroundColor DarkGray
Write-Host ""

if ($DryRun) {
  Write-Host "DRY RUN -- showing the command for the first file, then exiting." -ForegroundColor Yellow
  $i = $infos[0]
  $o = Join-Path $OutDir $i.Name
  $a = @('-hide_banner','-nostdin','-i',$i.Path,'-map','0:v:0','-map','0:a:0') +
       (Get-EncoderArgs -Codec $Codec -Quality $Quality -X265Preset $X265Preset) +
       (Get-CommonTailArgs) + @($o)
  Write-Host ""
  Write-Host "ffmpeg $($a -join ' ')"
  Write-Host ""
  exit 0
}

# ------------------------------------------------------------------ encode
$rows      = New-Object System.Collections.Generic.List[object]
$swAll     = [Diagnostics.Stopwatch]::StartNew()
$n         = 0
$doneFrames = 0
$outBytesTotal = 0
$csv = Join-Path $OutDir ("encode-log-{0}-q{1}.csv" -f $Codec, $Quality)

foreach ($i in $infos) {
  $n++
  $out     = Join-Path $OutDir $i.Name
  $partOut = Join-Path $OutDir ([IO.Path]::GetFileNameWithoutExtension($i.Name) + '.part.mp4')

  Write-Host ("[{0,2}/{1}] {2,-24} {3,9} {4,5}x{5,-5} {6,6} fr  " -f `
    $n, $infos.Count, $i.Name, (Format-Bytes $i.Bytes), $i.Width, $i.Height, $i.Frames) -NoNewline

  # ---- resume: accept an existing output only if its frame count matches
  if (Test-Path -LiteralPath $out) {
    $existing = $null
    try { $existing = Get-VideoInfo -Path $out } catch { }
    if ($existing -and $existing.Frames -eq $i.Frames) {
      $doneFrames    += $i.Frames
      $outBytesTotal += $existing.Bytes
      Write-Host ("SKIP (already done, {0})" -f (Format-Bytes $existing.Bytes)) -ForegroundColor DarkGray
      $rows.Add([pscustomobject]@{
        name=$i.Name; status='SKIPPED_EXISTING'
        src_bytes=$i.Bytes; out_bytes=$existing.Bytes
        ratio=[math]::Round($i.Bytes/$existing.Bytes,2)
        src_frames=$i.Frames; out_frames=$existing.Frames
        src_mbps=$i.Mbps; out_mbps=$existing.Mbps
        enc_sec=$null; enc_fps=$null })
      continue
    } else {
      # a mismatched output is set aside, never deleted
      $aside = Join-Path $OutDir ($i.Name + '.mismatched-' + (Get-Random) + '.bak')
      Move-Item -LiteralPath $out -Destination $aside
      Write-Host "(set aside prior mismatched output) " -NoNewline -ForegroundColor Yellow
    }
  }

  if (Test-Path -LiteralPath $partOut) { Remove-Item -LiteralPath $partOut -Force }  # our own temp only

  $encArgs = @('-hide_banner','-nostdin','-v','error','-i',$i.Path,'-map','0:v:0','-map','0:a:0') +
             (Get-EncoderArgs -Codec $Codec -Quality $Quality -X265Preset $X265Preset) +
             (Get-CommonTailArgs) + @($partOut)

  $sw  = [Diagnostics.Stopwatch]::StartNew()
  $err = (Invoke-FFmpegCapture -Arguments $encArgs).Text
  $sw.Stop()

  if (-not (Test-Path -LiteralPath $partOut)) {
    Write-Host "FAILED" -ForegroundColor Red
    if ($err.Trim()) { Write-Host "        $($err.Trim())" -ForegroundColor DarkRed }
    $rows.Add([pscustomobject]@{
      name=$i.Name; status='ENCODE_FAILED'
      src_bytes=$i.Bytes; out_bytes=$null; ratio=$null
      src_frames=$i.Frames; out_frames=$null
      src_mbps=$i.Mbps; out_mbps=$null
      enc_sec=[math]::Round($sw.Elapsed.TotalSeconds,1); enc_fps=$null })
    $doneFrames += $i.Frames
    continue
  }

  $oi = Get-VideoInfo -Path $partOut

  # Frame parity gate before the file is promoted to its final name.
  #
  # nb_frames is container metadata, not truth (README gotcha #9): OBS
  # recordings routinely claim one more frame than the stream decodes -- the
  # final packet, cut mid-GOP when recording stops, yields no displayable
  # frame. Metadata comparison is the fast path; on disagreement the source is
  # actually DECODED and the encode is judged against that real count. An
  # encode holding every decodable frame is complete, whatever the index says.
  $parityOk = ($oi.Frames -eq $i.Frames)
  $parityNote = ''
  if (-not $parityOk) {
    $decoded = Get-DecodedFrameCount -Path $i.Path
    if ($decoded -ge 0 -and $oi.Frames -eq $decoded) {
      $parityOk = $true
      $parityNote = " (container claims $($i.Frames), stream decodes to $decoded -- metadata overcount, encode complete)"
    }
  }
  if (-not $parityOk) {
    $bad = Join-Path $OutDir ($i.Name + '.FRAMEMISMATCH.bak')
    Move-Item -LiteralPath $partOut -Destination $bad -Force
    Write-Host ("FRAME MISMATCH {0} vs {1} -- held aside" -f $oi.Frames, $i.Frames) -ForegroundColor Red
    $rows.Add([pscustomobject]@{
      name=$i.Name; status='FRAME_MISMATCH'
      src_bytes=$i.Bytes; out_bytes=$oi.Bytes; ratio=$null
      src_frames=$i.Frames; out_frames=$oi.Frames
      src_mbps=$i.Mbps; out_mbps=$oi.Mbps
      enc_sec=[math]::Round($sw.Elapsed.TotalSeconds,1)
      enc_fps=[math]::Round($oi.Frames/$sw.Elapsed.TotalSeconds,1) })
    $doneFrames += $i.Frames
    continue
  }

  Move-Item -LiteralPath $partOut -Destination $out -Force

  # keep the archive sorting chronologically
  $srcItem = Get-Item -LiteralPath $i.Path
  $outItem = Get-Item -LiteralPath $out
  $outItem.LastWriteTime = $srcItem.LastWriteTime
  try { $outItem.CreationTime = $srcItem.CreationTime } catch { }

  $doneFrames    += $i.Frames
  $outBytesTotal += $oi.Bytes
  $encFps = [math]::Round($oi.Frames / [Math]::Max($sw.Elapsed.TotalSeconds, 0.001), 1)
  $ratio  = [math]::Round($i.Bytes / $oi.Bytes, 2)

  # ETA from frames completed so far
  $eta = ''
  if ($doneFrames -gt 0) {
    $secPerFrame = $swAll.Elapsed.TotalSeconds / $doneFrames
    $remain      = ($totalFrames - $doneFrames) * $secPerFrame
    $eta         = "  ETA {0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds($remain)
  }

  Write-Host ("{0,9}  {1,5}x  {2,5} Mbps  {3,5} fps{4}{5}" -f `
    (Format-Bytes $oi.Bytes), $ratio, $oi.Mbps, $encFps, $eta, $parityNote) -ForegroundColor Green

  $rows.Add([pscustomobject]@{
    name=$i.Name; status='OK'
    src_bytes=$i.Bytes; out_bytes=$oi.Bytes; ratio=$ratio
    src_frames=$i.Frames; out_frames=$oi.Frames
    src_mbps=$i.Mbps; out_mbps=$oi.Mbps
    enc_sec=[math]::Round($sw.Elapsed.TotalSeconds,1); enc_fps=$encFps })

  $rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding utf8   # incremental
}

$swAll.Stop()
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding utf8

# ------------------------------------------------------------------ summary
$ok      = @($rows | Where-Object status -in @('OK','SKIPPED_EXISTING'))
$failed  = @($rows | Where-Object status -in @('ENCODE_FAILED','FRAME_MISMATCH'))

Write-Host ""
Write-Host "==================== PHASE 2 RESULT ====================" -ForegroundColor Cyan
Write-Host ("Encoded OK   : {0}/{1}" -f $ok.Count, $rows.Count)
Write-Host ("Failed       : {0}" -f $failed.Count)
Write-Host ("Source total : {0}" -f (Format-Bytes $totalBytes))
Write-Host ("Output total : {0}" -f (Format-Bytes $outBytesTotal))
if ($outBytesTotal -gt 0) {
  Write-Host ("Reduction    : {0:N2}x  (saved {1})" -f `
    ($totalBytes/$outBytesTotal), (Format-Bytes ($totalBytes - $outBytesTotal))) -ForegroundColor Green
}
Write-Host ("Elapsed      : {0:N1} min" -f $swAll.Elapsed.TotalMinutes)
Write-Host ("Log          : {0}" -f $csv)

if ($failed.Count) {
  Write-Host ""
  Write-Host "FAILED FILES (originals untouched, partial outputs held aside as .bak):" -ForegroundColor Red
  $failed | ForEach-Object { Write-Host "  $($_.name)  [$($_.status)]" -ForegroundColor Red }
  Write-Host ""
  Write-Host "GATE: FAIL -- resolve these before Phase 3." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "GATE: PASS -- run verify_encoded.ps1 next." -ForegroundColor Green
exit 0
