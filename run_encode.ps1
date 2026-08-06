<#
  Drop-folder driver: encodes sources/important (x265 slow CRF 22, CPU) and
  sources/regular (NVENC HEVC q30, GPU), mirroring any subfolder structure into
  encoded_outputs/<tier>/.

  Thin orchestration over encode_batch.ps1 -- every safety property is inherited:
  resumable (re-run any time; finished files are skipped), .part staging, frame
  parity gate before rename, mtime restore, non-video screening, sources never
  written to.

  Progress lands in:
    encoded_outputs/manifest.csv   per-file ledger, merged across runs (latest wins)
    encoded_outputs/manifest.log   timestamped phase log, appended as it goes

  -Parallel runs the regular tier (GPU) in a second process while the important
  tier (CPU) runs in this one -- measured to coexist cleanly, since NVENC is
  dedicated silicon. Logs for the child land in encoded_outputs/regular-tier.log.
#>

[CmdletBinding()]
param(
  [string]$RepoRoot = $PSScriptRoot,
  [switch]$Parallel,
  # internal: used by -Parallel to run a single tier in a child process
  [ValidateSet('','important','regular')][string]$OnlyTier = ''
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_common.ps1"

$VideoExt = @('.mp4','.mov','.m4v','.mkv','.avi','.webm','.3gp','.mts','.m2ts','.wmv')
$outRoot  = Join-Path $RepoRoot 'encoded_outputs'
$manifest = Join-Path $outRoot 'manifest.csv'
$logFile  = Join-Path $outRoot 'manifest.log'
if (-not (Test-Path -LiteralPath $outRoot)) { New-Item -ItemType Directory -Path $outRoot -Force | Out-Null }

function Log {
  param([string]$Msg, [string]$Color = 'Gray')
  $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Msg
  Write-Host $line -ForegroundColor $Color
  Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

function Test-Nvenc {
  <# 8-frame probe: is NVENC HEVC actually usable on this machine right now? #>
  $r = Invoke-FFmpegCapture -Arguments @(
        '-hide_banner','-nostdin','-v','error',
        '-f','lavfi','-i','testsrc2=size=640x360:rate=30:duration=0.3',
        '-c:v','hevc_nvenc','-f','null','-')
  return ($r.ExitCode -eq 0)
}

function Merge-Manifest {
  <# Folds a per-dir encode log into the master manifest; latest row per
     (tier, relpath, name) wins, so re-runs update rather than duplicate. #>
  param([string]$BatchCsv, [string]$Tier, [string]$RelPath, [string]$RunStamp)
  if (-not (Test-Path -LiteralPath $BatchCsv)) { return }
  $new = @(Import-Csv -LiteralPath $BatchCsv | ForEach-Object {
    [pscustomobject]@{
      run_started = $RunStamp; tier = $Tier; relpath = $RelPath
      name = $_.name; status = $_.status
      src_bytes = $_.src_bytes; out_bytes = $_.out_bytes; ratio = $_.ratio
      enc_fps = $_.enc_fps
    }
  })
  if (-not $new.Count) { return }
  $old = @()
  if (Test-Path -LiteralPath $manifest) { $old = @(Import-Csv -LiteralPath $manifest) }
  $keyOf = { param($r) "$($r.tier)|$($r.relpath)|$($r.name)" }
  $newKeys = @{}; foreach ($r in $new) { $newKeys[(& $keyOf $r)] = $true }
  $kept = @($old | Where-Object { -not $newKeys.ContainsKey((& $keyOf $_)) })
  ($kept + $new) | Export-Csv -LiteralPath $manifest -NoTypeInformation -Encoding UTF8
}

function Invoke-Tier {
  param([hashtable]$Tier)
  $srcRoot = Join-Path $RepoRoot "sources\$($Tier.Name)"
  if (-not (Test-Path -LiteralPath $srcRoot)) { Log "tier '$($Tier.Name)': sources folder missing, skipping" 'DarkYellow'; return 0 }

  $videos = @(Get-ChildItem -LiteralPath $srcRoot -File -Recurse | Where-Object { $VideoExt -contains $_.Extension.ToLower() })
  if (-not $videos.Count) { Log "tier '$($Tier.Name)': no videos found, skipping" 'DarkGray'; return 0 }

  $gb = [math]::Round((($videos | Measure-Object Length -Sum).Sum)/1GB, 2)
  Log ("tier '{0}': {1} videos, {2} GB -> {3} q{4}" -f $Tier.Name, $videos.Count, $gb, $Tier.Codec, $Tier.Q) 'Cyan'

  $runStamp = "{0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)
  $failures = 0
  $dirs = @($videos | Group-Object DirectoryName)
  foreach ($d in $dirs) {
    $rel = $d.Name.Substring($srcRoot.Length).TrimStart('\')
    $outDir = if ($rel) { Join-Path (Join-Path $outRoot $Tier.Name) $rel } else { Join-Path $outRoot $Tier.Name }
    Log ("  encoding [{0}] {1} file(s): sources\{2}\{3}" -f $Tier.Name, $d.Group.Count, $Tier.Name, $rel)

    $args = @{ Codec = $Tier.Codec; Quality = $Tier.Q; SourceDir = $d.Name; OutDir = $outDir; Filter = '*' }
    if ($Tier.ContainsKey('Preset')) { $args.X265Preset = $Tier.Preset }
    & "$PSScriptRoot\encode_batch.ps1" @args
    if ($LASTEXITCODE -ne 0) {
      $failures++
      Log ("  FAILURES in sources\{0}\{1} -- see the per-dir log; originals untouched" -f $Tier.Name, $rel) 'Red'
    }
    $batchCsv = Join-Path $outDir ("encode-log-{0}-q{1}.csv" -f ($Tier.Codec -replace 'x265','x265'), $Tier.Q)
    Merge-Manifest -BatchCsv $batchCsv -Tier $Tier.Name -RelPath $rel -RunStamp $runStamp
  }
  return $failures
}

# ------------------------------------------------------------------ tiers
$tiers = @(
  @{ Name='important'; Codec='x265';       Q=22; Preset='slow' },
  @{ Name='regular';   Codec='hevc_nvenc'; Q=30 }
)

# regular tier falls back to CPU if NVENC is unavailable (loudly -- it will be slow)
$regularTier = $tiers | Where-Object { $_.Name -eq 'regular' }
$needsNvenc = (-not $OnlyTier -or $OnlyTier -eq 'regular')
if ($needsNvenc) {
  $srcReg = Join-Path $RepoRoot 'sources\regular'
  $hasRegularWork = (Test-Path -LiteralPath $srcReg) -and
    @(Get-ChildItem -LiteralPath $srcReg -File -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $VideoExt -contains $_.Extension.ToLower() }).Count -gt 0
  if ($hasRegularWork -and -not (Test-Nvenc)) {
    Log "NVENC unavailable -- 'regular' tier falling back to x265 slow CRF 22 (CPU). This will be ~5x slower." 'Yellow'
    $regularTier.Codec = 'x265'; $regularTier.Q = 22; $regularTier.Preset = 'slow'
  }
}

# ------------------------------------------------------------------ run
$totalFailures = 0

if ($OnlyTier) {
  $t = $tiers | Where-Object { $_.Name -eq $OnlyTier }
  $totalFailures = Invoke-Tier -Tier $t
}
elseif ($Parallel) {
  Log "PARALLEL mode: 'regular' (GPU) in a child process, 'important' (CPU) here" 'Cyan'
  $childLog = Join-Path $outRoot 'regular-tier.log'
  $child = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $childLog -RedirectStandardError (Join-Path $outRoot 'regular-tier.err.log') `
    -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$PSScriptRoot\run_encode.ps1",'-OnlyTier','regular','-RepoRoot',$RepoRoot
  $totalFailures += Invoke-Tier -Tier ($tiers | Where-Object { $_.Name -eq 'important' })
  Log "important tier done; waiting for the regular-tier child (tail $childLog for progress)..."
  $child.WaitForExit()
  if ($child.ExitCode -ne 0) { $totalFailures += 1; Log "regular tier reported failures -- see $childLog" 'Red' }
}
else {
  foreach ($t in $tiers) { $totalFailures += Invoke-Tier -Tier $t }
}

Write-Host ""
if ($totalFailures -eq 0) {
  Log "ALL TIERS COMPLETE with no failures. Next: .\confirm_quick.ps1, then .\confirm_deep.ps1" 'Green'
  exit 0
} else {
  Log "COMPLETED WITH FAILURES in $totalFailures dir-batch(es). Re-run to retry; finished files are skipped." 'Red'
  exit 1
}
