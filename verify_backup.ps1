<#
  Phase 0 verification — pairwise SHA-256 of concert originals vs the K: backup.

  READ-ONLY BY CONSTRUCTION: every file is opened with FileAccess::Read and
  FileShare::Read. This script cannot write to, lock, or alter either side.
  The only thing it writes is the manifest CSV.

  Usage:
    .\verify_backup.ps1
    .\verify_backup.ps1 -BackupDir 'K:\SomeOtherFolder' -Filter '*.mp4'
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SourceDir,   # folder holding the original videos
  [Parameter(Mandatory)][string]$BackupDir,   # your independent copy of them
  [string]$ManifestOut = '',
  [string]$Filter      = '*.mp4'
)

$ErrorActionPreference = 'Stop'

function Get-Sha256Fast {
  param([string]$Path)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fs  = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,      # <- cannot write
            [System.IO.FileShare]::Read)       # <- cannot lock others out
  try   { return [System.BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-','') }
  finally { $fs.Dispose(); $sha.Dispose() }
}

# ---------- resolve paths ----------
if (-not (Test-Path -LiteralPath $SourceDir)) { throw "Source dir not found: $SourceDir" }
if (-not (Test-Path -LiteralPath $BackupDir)) { throw "Backup dir not found: $BackupDir  (pass -BackupDir if you used a different folder)" }
if (-not $ManifestOut) { $ManifestOut = Join-Path (Split-Path $BackupDir -Parent) 'manifest-originals.csv' }

$srcFiles = @(Get-ChildItem -LiteralPath $SourceDir -File -Filter $Filter | Sort-Object Name)
if ($srcFiles.Count -eq 0) { throw "No files matching '$Filter' in $SourceDir" }

# index the backup recursively, so a nested layout still resolves
$bakIndex = @{}
foreach ($b in (Get-ChildItem -LiteralPath $BackupDir -File -Recurse -ErrorAction SilentlyContinue)) {
  if (-not $bakIndex.ContainsKey($b.Name)) { $bakIndex[$b.Name] = $b }
}

$totalBytes = ($srcFiles | Measure-Object Length -Sum).Sum
Write-Host ""
Write-Host "Source : $SourceDir"
Write-Host "Backup : $BackupDir"
Write-Host "Files  : $($srcFiles.Count)   Total: $([math]::Round($totalBytes/1GB,2)) GB per side ($([math]::Round($totalBytes*2/1GB,2)) GB to read)"
Write-Host ""

# ---------- compare ----------
$rows    = New-Object System.Collections.Generic.List[object]
$swAll   = [System.Diagnostics.Stopwatch]::StartNew()
$done    = 0
$doneB   = 0

foreach ($s in $srcFiles) {
  $done++
  $pct = [math]::Round(100 * $doneB / [double]$totalBytes, 1)
  Write-Host ("[{0,2}/{1}] {2,-24} {3,7:N2} GB  (overall {4,5:N1}%)" -f `
              $done, $srcFiles.Count, $s.Name, ($s.Length/1GB), $pct) -NoNewline

  $bak = $bakIndex[$s.Name]

  if (-not $bak) {
    Write-Host "  -> MISSING IN BACKUP" -ForegroundColor Red
    $rows.Add([pscustomobject]@{
      name = $s.Name; bytes_source = $s.Length; bytes_backup = $null
      sha256_source = ''; sha256_backup = ''
      size_match = $false; hash_match = $false; status = 'MISSING_IN_BACKUP'
      backup_path = ''
    })
    $doneB += $s.Length
    continue
  }

  $sizeOk = ($s.Length -eq $bak.Length)

  if (-not $sizeOk) {
    # size already differs -- hash adds nothing, and reading is expensive
    Write-Host ("  -> SIZE MISMATCH (backup {0:N0} vs source {1:N0})" -f $bak.Length, $s.Length) -ForegroundColor Red
    $rows.Add([pscustomobject]@{
      name = $s.Name; bytes_source = $s.Length; bytes_backup = $bak.Length
      sha256_source = ''; sha256_backup = ''
      size_match = $false; hash_match = $false; status = 'SIZE_MISMATCH'
      backup_path = $bak.FullName
    })
    $doneB += $s.Length
    continue
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $hSrc = Get-Sha256Fast -Path $s.FullName
  $hBak = Get-Sha256Fast -Path $bak.FullName
  $sw.Stop()

  $hashOk = ($hSrc -eq $hBak)
  $mbps   = if ($sw.Elapsed.TotalSeconds -gt 0) { ($s.Length*2/1MB) / $sw.Elapsed.TotalSeconds } else { 0 }

  if ($hashOk) {
    Write-Host ("  -> OK  ({0:N0} MB/s)" -f $mbps) -ForegroundColor Green
  } else {
    Write-Host "  -> HASH MISMATCH  ** CORRUPT COPY **" -ForegroundColor Red
  }

  $rows.Add([pscustomobject]@{
    name = $s.Name; bytes_source = $s.Length; bytes_backup = $bak.Length
    sha256_source = $hSrc; sha256_backup = $hBak
    size_match = $true; hash_match = $hashOk
    status = $(if ($hashOk) { 'OK' } else { 'HASH_MISMATCH' })
    backup_path = $bak.FullName
  })

  $doneB += $s.Length
}

$swAll.Stop()

# ---------- extras present in backup but not in source ----------
$srcNames = @{}; foreach ($s in $srcFiles) { $srcNames[$s.Name] = $true }
$extras = @($bakIndex.Keys | Where-Object { -not $srcNames.ContainsKey($_) } | Sort-Object)

# ---------- write manifest ----------
$rows | Export-Csv -LiteralPath $ManifestOut -NoTypeInformation -Encoding utf8

# ---------- summary ----------
$ok      = @($rows | Where-Object status -eq 'OK')
$bad     = @($rows | Where-Object status -in @('HASH_MISMATCH','SIZE_MISMATCH'))
$missing = @($rows | Where-Object status -eq 'MISSING_IN_BACKUP')

Write-Host ""
Write-Host "================ PHASE 0 RESULT ================"
Write-Host ("Verified OK        : {0}/{1}" -f $ok.Count, $rows.Count)
Write-Host ("Corrupt / mismatch : {0}" -f $bad.Count)
Write-Host ("Missing in backup  : {0}" -f $missing.Count)
Write-Host ("Extra files on K:  : {0}" -f $extras.Count)
Write-Host ("Elapsed            : {0:N1} min" -f $swAll.Elapsed.TotalMinutes)
Write-Host ("Manifest           : {0}" -f $ManifestOut)

if ($bad.Count)     { Write-Host ""; Write-Host "MISMATCHED:"; $bad     | ForEach-Object { Write-Host "  $($_.name)  [$($_.status)]" -ForegroundColor Red } }
if ($missing.Count) { Write-Host ""; Write-Host "MISSING:";    $missing | ForEach-Object { Write-Host "  $($_.name)" -ForegroundColor Yellow } }
if ($extras.Count)  { Write-Host ""; Write-Host "EXTRA ON K: (informational):"; $extras | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" } }

Write-Host ""
if ($bad.Count -eq 0 -and $missing.Count -eq 0) {
  Write-Host "GATE: PASS -- backup is byte-identical. Safe to proceed to Phase 1." -ForegroundColor Green
  exit 0
} else {
  Write-Host "GATE: FAIL -- do NOT proceed. Re-copy the affected files and re-run." -ForegroundColor Red
  exit 1
}
