<#
  Phase 4 closing check -- prove the originals were never altered.

  Re-hashes every file on H: and compares against the SHA-256 recorded in the
  Phase 0 manifest. Any difference means something wrote to the source tree
  during the job, which should be impossible and would be a serious finding.

  Read-only: opens files with FileAccess::Read. Writes nothing.

  Usage:
    .\rehash_originals.ps1
    .\rehash_originals.ps1 -ManifestIn 'K:\Witcher-Concert-2025-11-12\manifest-originals.csv'
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SourceDir,
  [Parameter(Mandatory)][string]$ManifestIn   # the manifest verify_backup.ps1 produced
)

$ErrorActionPreference = 'Stop'

function Get-Sha256Fast {
  param([string]$Path)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fs  = [System.IO.File]::Open($Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read)
  try   { return [System.BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-','') }
  finally { $fs.Dispose(); $sha.Dispose() }
}

if (-not (Test-Path -LiteralPath $ManifestIn)) { throw "Phase 0 manifest not found: $ManifestIn" }
$manifest = @(Import-Csv -LiteralPath $ManifestIn | Where-Object { $_.sha256_source })
if ($manifest.Count -eq 0) { throw "Manifest has no source hashes to compare against: $ManifestIn" }

Write-Host ""
Write-Host "Re-hashing $($manifest.Count) originals in $SourceDir"
Write-Host "Comparing against $ManifestIn"
Write-Host ""

$changed = New-Object System.Collections.Generic.List[object]
$gone    = New-Object System.Collections.Generic.List[string]
$ok = 0; $n = 0
$sw = [Diagnostics.Stopwatch]::StartNew()

foreach ($m in $manifest) {
  $n++
  $p = Join-Path $SourceDir $m.name
  Write-Host ("[{0,2}/{1}] {2,-24} " -f $n, $manifest.Count, $m.name) -NoNewline

  if (-not (Test-Path -LiteralPath $p)) {
    Write-Host "GONE FROM SOURCE" -ForegroundColor Red
    $gone.Add($m.name); continue
  }

  $item = Get-Item -LiteralPath $p
  if ([int64]$item.Length -ne [int64]$m.bytes_source) {
    Write-Host ("SIZE CHANGED  {0:N0} -> {1:N0}" -f [int64]$m.bytes_source, $item.Length) -ForegroundColor Red
    $changed.Add([pscustomobject]@{ name=$m.name; kind='size'; was=$m.bytes_source; now=$item.Length })
    continue
  }

  $h = Get-Sha256Fast -Path $p
  if ($h -eq $m.sha256_source) {
    Write-Host "unchanged" -ForegroundColor Green
    $ok++
  } else {
    Write-Host "HASH CHANGED" -ForegroundColor Red
    $changed.Add([pscustomobject]@{ name=$m.name; kind='hash'; was=$m.sha256_source; now=$h })
  }
}
$sw.Stop()

Write-Host ""
Write-Host "================ ORIGINALS INTEGRITY ================" -ForegroundColor Cyan
Write-Host ("Unchanged : {0}/{1}" -f $ok, $manifest.Count)
Write-Host ("Changed   : {0}" -f $changed.Count)
Write-Host ("Missing   : {0}" -f $gone.Count)
Write-Host ("Elapsed   : {0:N1} min" -f $sw.Elapsed.TotalMinutes)

if ($changed.Count -or $gone.Count) {
  Write-Host ""
  foreach ($c in $changed) { Write-Host ("  CHANGED  {0}  [{1}]" -f $c.name, $c.kind) -ForegroundColor Red }
  foreach ($g in $gone)    { Write-Host ("  MISSING  {0}" -f $g) -ForegroundColor Red }
  Write-Host ""
  Write-Host "GATE: FAIL -- the source tree was modified. Restore from the K: backup." -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "GATE: PASS -- all originals byte-identical to the Phase 0 baseline." -ForegroundColor Green
exit 0
