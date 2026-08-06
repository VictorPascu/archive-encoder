<#
  Deep confirmation over the drop-folder layout -- the check to run BEFORE
  deciding the raws are no longer needed.

  Per file (via verify_encoded.ps1, the 7-check verifier):
    clean full decode, exact frame count, duration, bit-identical audio hash,
    VMAF against the visually-lossless gates (mean >= 95 / 1%-low >= 92),
    metadata preservation, orientation.

  Plus the human-reviewable part: for a random sample of files (and EVERY file
  that failed), frame pairs are extracted from source and encode at 20% / 50% /
  80% of the runtime and saved side by side under encoded_outputs/_review/,
  each pair scored with SSIM. Open them and look -- the point is that a PASS
  here is something you can also see with your own eyes.

  Exit 0 = every file passed every gate. Writes encoded_outputs/confirm-deep.csv.
#>

[CmdletBinding()]
param(
  [string]$RepoRoot = $PSScriptRoot,
  [int]$ScreenshotFiles = 8,                  # random sample size per tier
  [double[]]$Positions = @(0.2, 0.5, 0.8),
  [int]$Seed = 0                              # 0 = new sample each run
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\scripts_internal\_common.ps1"

$VideoExt = @('.mp4','.mov','.m4v','.mkv','.avi','.webm','.3gp','.mts','.m2ts','.wmv')
$outRoot   = Join-Path $RepoRoot 'encoded_outputs'
$reviewDir = Join-Path $outRoot '_review'
$sw        = [Diagnostics.Stopwatch]::StartNew()
$all       = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------- 1. verify
foreach ($tier in @('important','regular')) {
  $srcRoot = Join-Path $RepoRoot "sources\$tier"
  if (-not (Test-Path -LiteralPath $srcRoot)) { continue }
  $videos = @(Get-ChildItem -LiteralPath $srcRoot -File -Recurse | Where-Object { $VideoExt -contains $_.Extension.ToLower() })
  if (-not $videos.Count) { continue }

  Write-Host ""
  Write-Host "=== tier '$tier': verifying $($videos.Count) file(s) (7 checks incl. VMAF) ===" -ForegroundColor Cyan

  foreach ($d in ($videos | Group-Object DirectoryName)) {
    $rel    = $d.Name.Substring($srcRoot.Length).TrimStart('\')
    $encDir = if ($rel) { Join-Path (Join-Path $outRoot $tier) $rel } else { Join-Path $outRoot $tier }
    $tmpCsv = Join-Path $env:TEMP ("confirm_deep_" + [guid]::NewGuid().ToString('N') + ".csv")

    & "$PSScriptRoot\scripts_internal\verify_encoded.ps1" -SourceDir $d.Name -EncDir $encDir -Filter '*' `
        -Names @($d.Group.Name) -ManifestOut $tmpCsv | Out-Host

    if (Test-Path -LiteralPath $tmpCsv) {
      foreach ($r in (Import-Csv -LiteralPath $tmpCsv)) {
        $r | Add-Member -NotePropertyName tier    -NotePropertyValue $tier -Force
        $r | Add-Member -NotePropertyName relpath -NotePropertyValue $(if ($rel) { Join-Path $rel $r.name } else { $r.name }) -Force
        $r | Add-Member -NotePropertyName srcdir  -NotePropertyValue $d.Name -Force
        $r | Add-Member -NotePropertyName encdir  -NotePropertyValue $encDir -Force
        $all.Add($r)
      }
    }
  }
}

if (-not $all.Count) { Write-Host "`nNo videos found under sources\ -- nothing to confirm." -ForegroundColor Yellow; exit 0 }

# ---------------------------------------------------------------- 2. screenshots
if (-not (Test-Path -LiteralPath $reviewDir)) { New-Item -ItemType Directory -Path $reviewDir -Force | Out-Null }

function Measure-FramePairSsim {
  <# Extracts the frame at $Pos of the runtime from source and encode (same
     timestamp -- valid because the pipeline preserves timing exactly), saves a
     side-by-side pair for eyeballing, returns SSIM. #>
  param([string]$Src, [string]$Enc, [double]$Pos, [string]$PairBase)

  $dur = (Get-VideoInfo -Path $Src).Duration
  $t   = [math]::Round($dur * $Pos, 3)

  foreach ($side in @(@{P=$Src;S='src'}, @{P=$Enc;S='enc'})) {
    $null = Invoke-FFmpegCapture -Arguments @(
      '-hide_banner','-nostdin','-v','error','-ss',"$t",'-i',$side.P,
      '-frames:v','1','-q:v','2','-y',("{0}_{1}.jpg" -f $PairBase, $side.S))
  }

  $r = Invoke-FFmpegCapture -Arguments @(
    '-hide_banner','-nostdin','-ss',"$t",'-i',$Src,'-ss',"$t",'-i',$Enc,
    '-frames:v','1','-lavfi','[0:v][1:v]ssim','-f','null','-')
  if ($r.Text -match 'All:\s*([0-9.]+)') { return [double]$Matches[1] }
  return $null
}

$fails = @($all | Where-Object verdict -eq 'FAIL')
$rand  = if ($Seed -gt 0) { New-Object System.Random($Seed) } else { New-Object System.Random }
$shots = New-Object System.Collections.Generic.List[object]

foreach ($tier in @('important','regular')) {
  $tierRows = @($all | Where-Object { $_.tier -eq $tier -and $_.verdict -ne 'FAIL' })
  $sample   = @($tierRows | Sort-Object { $rand.Next() } | Select-Object -First $ScreenshotFiles)
  $targets  = @($sample) + @($fails | Where-Object tier -eq $tier)
  if (-not $targets.Count) { continue }

  Write-Host ""
  Write-Host "=== tier '$tier': screenshot pairs for $($targets.Count) file(s) ===" -ForegroundColor Cyan
  foreach ($row in $targets) {
    $src = Join-Path $row.srcdir $row.name
    $enc = Join-Path $row.encdir $row.name
    if (-not ((Test-Path -LiteralPath $src) -and (Test-Path -LiteralPath $enc))) { continue }
    $base = Join-Path $reviewDir ("{0}_{1}" -f $tier, ([IO.Path]::GetFileNameWithoutExtension($row.name)))
    foreach ($p in $Positions) {
      $pct  = [int]($p * 100)
      $ssim = Measure-FramePairSsim -Src $src -Enc $enc -Pos $p -PairBase ("{0}_p{1}" -f $base, $pct)
      $flag = if ($null -eq $ssim) { 'no-ssim' } elseif ($ssim -lt 0.85) { 'LOW' } else { 'ok' }
      Write-Host ("  {0,-38} @{1,3}%  SSIM {2}  [{3}]" -f $row.name, $pct, $(if ($null -ne $ssim) { '{0:N4}' -f $ssim } else { '  --  ' }), $flag) `
        -ForegroundColor $(if ($flag -eq 'ok') { 'Green' } elseif ($flag -eq 'LOW') { 'Yellow' } else { 'DarkYellow' })
      $shots.Add([pscustomobject]@{ tier=$tier; name=$row.name; pos_pct=$pct; ssim=$ssim; flag=$flag })
    }
  }
}

# ---------------------------------------------------------------- 3. verdict
$sw.Stop()
$csv = Join-Path $outRoot 'confirm-deep.csv'
$all | Select-Object tier, relpath, verdict, reasons, warnings, ratio, vmaf_mean, vmaf_p1low, audio_identical, orientation_ok |
  Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8

$pass = @($all | Where-Object verdict -in @('PASS','PASS_WARN'))
$lowShots = @($shots | Where-Object flag -eq 'LOW')

Write-Host ""
Write-Host "================ DEEP CONFIRM ================" -ForegroundColor Cyan
Write-Host ("verified    : {0} file(s) in {1:N1} min" -f $all.Count, $sw.Elapsed.TotalMinutes)
Write-Host ("pass        : {0}   fail: {1}" -f $pass.Count, $fails.Count)
Write-Host ("screenshots : {0} pairs in {1}" -f $shots.Count, $reviewDir)
Write-Host ("low SSIM    : {0} (informational -- eyeball those pairs)" -f $lowShots.Count)
Write-Host ("csv         : {0}" -f $csv)

if ($fails.Count) {
  Write-Host ""
  $fails | ForEach-Object { Write-Host ("  FAIL  {0}\{1}: {2}" -f $_.tier, $_.relpath, $_.reasons) -ForegroundColor Red }
  Write-Host ""
  Write-Host "GATE: FAIL -- do NOT delete any raws. Fix (often: re-encode that file at a lower q), re-run." -ForegroundColor Red
  exit 1
}
Write-Host ""
Write-Host "GATE: PASS -- every file decodes cleanly, matches its source structurally, has" -ForegroundColor Green
Write-Host "bit-identical audio, and measures visually lossless. Review the _review\ pairs" -ForegroundColor Green
Write-Host "with your own eyes; if satisfied, the encoded set is a faithful stand-in." -ForegroundColor Green
Write-Host "Deleting raws is YOUR action -- nothing here will ever do it." -ForegroundColor Green
exit 0
