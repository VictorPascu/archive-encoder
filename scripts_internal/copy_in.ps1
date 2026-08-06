<#
  Copy helper spawned by ui.ps1's "+" button, in its own console so multi-GB
  copies never freeze the window.

  Safety contract: files are COPIED (originals untouched), staged as
  <name>.copying and renamed only when complete -- so neither the UI's list nor
  the encoder can ever see a half-copied video -- and an existing file is never
  overwritten.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [Parameter(Mandatory)][ValidateSet('important','regular')][string]$Tier,
  [Parameter(ValueFromRemainingArguments)][string[]]$Files
)

$ErrorActionPreference = 'Continue'
$dest = Join-Path $RepoRoot "sources\$Tier"
if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

Write-Host ""
Write-Host "Copying $(@($Files).Count) file(s) into sources\$Tier ..." -ForegroundColor Cyan
$ok = 0; $skip = 0; $bad = 0

foreach ($src in $Files) {
  if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "  MISSING  $src" -ForegroundColor Red; $bad++; continue
  }
  $name  = [IO.Path]::GetFileName($src)
  $final = Join-Path $dest $name
  if (Test-Path -LiteralPath $final) {
    Write-Host "  SKIP     $name  (already exists -- never overwritten)" -ForegroundColor Yellow
    $skip++; continue
  }
  $tmp = "$final.copying"
  $mb  = [math]::Round((Get-Item -LiteralPath $src).Length / 1MB, 1)
  Write-Host "  copying  $name  ($mb MB) ..." -NoNewline
  try {
    Copy-Item -LiteralPath $src -Destination $tmp -Force -ErrorAction Stop
    Move-Item -LiteralPath $tmp -Destination $final -ErrorAction Stop
    Write-Host " done" -ForegroundColor Green
    $ok++
  } catch {
    Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    $bad++
  }
}

Write-Host ""
Write-Host ("Done: {0} copied, {1} skipped, {2} failed. Originals untouched." -f $ok, $skip, $bad) `
  -ForegroundColor $(if ($bad) { 'Red' } else { 'Green' })
if ($bad) { Write-Host "This window stays open so you can read the errors."; Read-Host 'Press Enter to close' }
else { Start-Sleep -Seconds 3 }
