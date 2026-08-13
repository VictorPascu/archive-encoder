<#
  Surveys every video in a folder before the general-purpose encode run.

  The concert job was homogeneous (Samsung 8-bit HEVC, AAC stereo, mp4). The
  wider folder may not be. This sweep answers, per file:
    - container/codec/pix_fmt (bit depth!), resolution, fps, rotation
    - color transfer (HDR/HLG would need different handling)
    - stream count, audio codec, audio presence
    - bits per pixel per frame -- the "is re-encoding even worth it" number

  Output: a CSV + a distribution summary + a worth-encoding triage.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SourceDir,
  [string]$OutCsv    = "$PSScriptRoot\survey.csv",
  [string]$ExcludePattern = '',
  [string[]]$VideoExt = @('.mp4','.mov','.m4v','.mkv','.avi','.webm','.3gp','.mts','.m2ts','.wmv')
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_common.ps1"

$files = @(Get-ChildItem -LiteralPath $SourceDir -File -Recurse | Where-Object { $VideoExt -contains $_.Extension.ToLower() } | Sort-Object Name)
Write-Host ""
Write-Host ("Found {0} video files, {1:N2} GB total" -f $files.Count, (($files | Measure-Object Length -Sum).Sum/1GB)) -ForegroundColor Cyan

$rows = New-Object System.Collections.Generic.List[object]
$n = 0
foreach ($f in $files) {
  $n++
  if ($n % 100 -eq 0) { Write-Host "  probed $n/$($files.Count)..." }
  $raw = Invoke-FFprobeJson -Arguments @('-v','error','-print_format','json','-show_format','-show_streams','--',$f.FullName)
  if ([string]::IsNullOrWhiteSpace($raw)) {
    $rows.Add([pscustomobject]@{ name=$f.Name; bytes=$f.Length; probe='FAILED' }); continue
  }
  $j = $raw | ConvertFrom-Json
  $v = $j.streams | Where-Object codec_type -eq 'video' | Where-Object { $_.PSObject.Properties.Name -notcontains 'disposition' -or -not $_.disposition.attached_pic } | Select-Object -First 1
  $a = @($j.streams | Where-Object codec_type -eq 'audio')
  $other = @($j.streams | Where-Object { $_.codec_type -notin @('video','audio') })

  if (-not $v) { $rows.Add([pscustomobject]@{ name=$f.Name; bytes=$f.Length; probe='NO_VIDEO' }); continue }

  $dur = 0.0; try { $dur = [double]$j.format.duration } catch { }
  $frames = 0; if ($v.PSObject.Properties.Name -contains 'nb_frames' -and $v.nb_frames -match '^\d+$') { $frames = [int]$v.nb_frames }
  $fps = if ($dur -gt 0 -and $frames -gt 0) { $frames/$dur } else {
    if ($v.avg_frame_rate -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -ne 0) { [int]$Matches[1]/[int]$Matches[2] } else { 0 }
  }
  $rot = 0
  if ($v.PSObject.Properties.Name -contains 'side_data_list') {
    foreach ($sd in $v.side_data_list) { if ($sd.PSObject.Properties.Name -contains 'rotation') { $rot = [int]$sd.rotation } }
  }
  $bps = 0; try { $bps = [double]$j.format.bit_rate } catch { }
  $bpp = if ($fps -gt 0 -and $v.width -gt 0) { $bps / ($v.width * $v.height * $fps) } else { 0 }

  $trc = ''; if ($v.PSObject.Properties.Name -contains 'color_transfer') { $trc = $v.color_transfer }

  $rows.Add([pscustomobject]@{
    name       = $f.Name
    ext        = $f.Extension.ToLower()
    bytes      = $f.Length
    mb         = [math]::Round($f.Length/1MB,1)
    dur_s      = [math]::Round($dur,1)
    vcodec     = $v.codec_name
    pix_fmt    = $v.pix_fmt
    width      = [int]$v.width
    height     = [int]$v.height
    fps        = [math]::Round($fps,2)
    rot        = $rot
    color_trc  = $trc
    mbps       = [math]::Round($bps/1e6,1)
    bpp        = [math]::Round($bpp,4)
    n_audio    = $a.Count
    acodec     = ($a | Select-Object -First 1).codec_name
    n_other    = $other.Count
    probe      = 'OK'
    excluded   = ($ExcludePattern -and $f.Name -like $ExcludePattern)
  })
}

$rows | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding utf8

$ok = @($rows | Where-Object probe -eq 'OK')
$rest = @($ok | Where-Object { -not $_.excluded })

Write-Host ""
Write-Host "==================== SURVEY (after exclusions) ====================" -ForegroundColor Cyan
Write-Host ("files {0}   total {1:N2} GB" -f $rest.Count, (($rest | Measure-Object bytes -Sum).Sum/1GB))
Write-Host ""
Write-Host "--- video codec x pixel format ---"
$rest | Group-Object vcodec, pix_fmt | Sort-Object Count -Descending | ForEach-Object {
  "  {0,5} files  {1,9:N2} GB   {2}" -f $_.Count, (($_.Group | Measure-Object bytes -Sum).Sum/1GB), $_.Name }
Write-Host ""
Write-Host "--- color transfer ---"
$rest | Group-Object color_trc | Sort-Object Count -Descending | ForEach-Object { "  {0,5} x  '{1}'" -f $_.Count, $_.Name }
Write-Host ""
Write-Host "--- resolution ---"
$rest | Group-Object width, height | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object {
  "  {0,5} files  {1,9:N2} GB   {2}" -f $_.Count, (($_.Group | Measure-Object bytes -Sum).Sum/1GB), $_.Name }
Write-Host ""
Write-Host "--- audio ---"
$rest | Group-Object n_audio, acodec | Sort-Object Count -Descending | ForEach-Object { "  {0,5} x  n_audio,codec = {1}" -f $_.Count, $_.Name }
$multi = @($rest | Where-Object { $_.n_other -gt 0 })
Write-Host ("  files with extra non-A/V streams: {0}" -f $multi.Count)
Write-Host ""
Write-Host "--- container ---"
$rest | Group-Object ext | Sort-Object Count -Descending | ForEach-Object { "  {0,5} x  {1}" -f $_.Count, $_.Name }
Write-Host ""
Write-Host "--- worth-encoding triage (bits/pixel/frame; <0.08 = already efficient) ---"
$worth   = @($rest | Where-Object { $_.bpp -ge 0.08 })
$already = @($rest | Where-Object { $_.bpp -gt 0 -and $_.bpp -lt 0.08 })
$unknown = @($rest | Where-Object { $_.bpp -le 0 })
Write-Host ("  re-encode candidates : {0,5} files  {1,9:N2} GB" -f $worth.Count, (($worth | Measure-Object bytes -Sum).Sum/1GB))
Write-Host ("  already efficient    : {0,5} files  {1,9:N2} GB  (copy as-is)" -f $already.Count, (($already | Measure-Object bytes -Sum).Sum/1GB))
Write-Host ("  bpp unknown          : {0,5} files  {1,9:N2} GB  (probe individually)" -f $unknown.Count, (($unknown | Measure-Object bytes -Sum).Sum/1GB))
$fail = @($rows | Where-Object probe -ne 'OK')
if ($fail.Count) {
  Write-Host ""
  Write-Host "--- probe failures / no video stream ---" -ForegroundColor Yellow
  $fail | ForEach-Object { "  {0}  [{1}]" -f $_.name, $_.probe }
}
Write-Host ""
Write-Host "CSV: $OutCsv"
