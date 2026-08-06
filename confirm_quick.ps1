<#
  Rapid equivalency check over the drop-folder layout. Answers, in seconds per
  file rather than minutes: "does EVERY video under sources/ have an encoded
  counterpart that is structurally the same recording?"

  Per file:
    1  encoded counterpart exists at the mirrored path
    2  frame count matches (container metadata -- deep check decodes for real)
    3  duration within one frame period
    4  effective display dimensions match (catches rotation mistakes)
    5  audio stream hash IDENTICAL (bit-for-bit; skip with -SkipAudioHash)

  What it does NOT do: decode the video or measure quality. That is
  confirm_deep.ps1's job. PASS here means "coverage is complete and nothing is
  structurally wrong" -- run the deep check before deleting anything.

  Exit 0 = all pass. Writes encoded_outputs/confirm-quick.csv.
#>

[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [switch]$SkipAudioHash
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty in param defaults under `powershell -File` -- resolve here.
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
. "$PSScriptRoot\scripts_internal\_common.ps1"

$VideoExt = @('.mp4','.mov','.m4v','.mkv','.avi','.webm','.3gp','.mts','.m2ts','.wmv')
$outRoot  = Join-Path $RepoRoot 'encoded_outputs'
$rows     = New-Object System.Collections.Generic.List[object]
$sw       = [Diagnostics.Stopwatch]::StartNew()

foreach ($tier in @('important','regular')) {
  $srcRoot = Join-Path $RepoRoot "sources\$tier"
  if (-not (Test-Path -LiteralPath $srcRoot)) { continue }
  $videos = @(Get-ChildItem -LiteralPath $srcRoot -File -Recurse | Where-Object { $VideoExt -contains $_.Extension.ToLower() })
  if (-not $videos.Count) { continue }

  Write-Host ""
  Write-Host "=== tier '$tier': $($videos.Count) source video(s) ===" -ForegroundColor Cyan

  foreach ($v in $videos) {
    $rel = $v.FullName.Substring($srcRoot.Length).TrimStart('\')
    $enc = Join-Path (Join-Path $outRoot $tier) $rel
    Write-Host ("  {0,-42} " -f $rel) -NoNewline

    if (-not (Test-Path -LiteralPath $enc)) {
      Write-Host "MISSING" -ForegroundColor Red
      $rows.Add([pscustomobject]@{ tier=$tier; relpath=$rel; verdict='MISSING'; reasons='no encoded counterpart' })
      continue
    }

    $fails = New-Object System.Collections.Generic.List[string]
    try {
      $si = Get-VideoInfo -Path $v.FullName
      $oi = Get-VideoInfo -Path $enc

      if ($oi.Frames -ne $si.Frames) {
        # nb_frames can overcount (OBS: last packet decodes to nothing). Only a
        # mismatching file pays for a real decode, so the common case stays fast.
        $decodedSrc = Get-DecodedFrameCount -Path $v.FullName
        if (-not ($decodedSrc -ge 0 -and $oi.Frames -eq $decodedSrc)) {
          $fails.Add("frames($($oi.Frames)vs$($si.Frames))")
        }
      }

      $tol = if ($si.AvgFps -gt 0) { 2.0 / $si.AvgFps } else { 0.1 }
      if ([math]::Abs($oi.Duration - $si.Duration) -gt $tol) {
        $fails.Add(("duration({0:N3}s)" -f ($oi.Duration - $si.Duration)))
      }

      if ($oi.DisplayW -ne $si.DisplayW -or $oi.DisplayH -ne $si.DisplayH) {
        $fails.Add("orientation($($oi.DisplayW)x$($oi.DisplayH)vs$($si.DisplayW)x$($si.DisplayH))")
      }

      if (-not $SkipAudioHash -and $si.AudioCodec) {
        $mSrc = Get-AudioStreamMd5 -Path $v.FullName
        $mEnc = Get-AudioStreamMd5 -Path $enc
        if (-not ($mSrc -and $mEnc -and $mSrc -eq $mEnc)) { $fails.Add('audio_not_identical') }
      }
    } catch {
      $fails.Add("probe_error($($_.Exception.Message))")
    }

    $verdict = if ($fails.Count) { 'FAIL' } else { 'OK' }
    Write-Host $verdict -ForegroundColor $(if ($fails.Count) { 'Red' } else { 'Green' })
    if ($fails.Count) { Write-Host ("      " + ($fails -join ', ')) -ForegroundColor Red }
    $rows.Add([pscustomobject]@{ tier=$tier; relpath=$rel; verdict=$verdict; reasons=($fails -join '; ') })
  }
}

$sw.Stop()
if (-not $rows.Count) { Write-Host "`nNo videos found under sources\ -- nothing to confirm." -ForegroundColor Yellow; exit 0 }

$csv = Join-Path $outRoot 'confirm-quick.csv'
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

$bad = @($rows | Where-Object verdict -ne 'OK')
Write-Host ""
Write-Host "================ QUICK CONFIRM ================" -ForegroundColor Cyan
Write-Host ("checked : {0} file(s) in {1:N1} min" -f $rows.Count, $sw.Elapsed.TotalMinutes)
Write-Host ("ok      : {0}" -f ($rows.Count - $bad.Count))
Write-Host ("problems: {0}" -f $bad.Count)
Write-Host ("csv     : {0}" -f $csv)
if ($bad.Count) {
  $bad | ForEach-Object { Write-Host ("  {0}\{1}  {2}: {3}" -f $_.tier, $_.relpath, $_.verdict, $_.reasons) -ForegroundColor Red }
  Write-Host ""
  Write-Host "GATE: FAIL -- do not delete anything. Re-run .\run_encode.ps1 (it resumes), then re-check." -ForegroundColor Red
  exit 1
}
Write-Host ""
Write-Host "GATE: PASS -- coverage complete, structure verified. Run .\confirm_deep.ps1 before deleting raws." -ForegroundColor Green
exit 0
