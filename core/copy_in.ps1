<#
  Copy helper spawned by ui.ps1's "+" buttons, in its own console so multi-GB
  copies never freeze the window.

  Accepts FILES and/or FOLDERS. A folder is copied recursively with its
  structure preserved: sources\<tier>\<folderName>\<relative-path> -- so adding
  "D:\Videos9" to the regular tier yields sources\regular\Videos9\... and the
  encode mirrors it into encoded_outputs\regular\Videos9\...

  Safety contract: everything is COPIED (originals untouched), each file staged
  as <name>.copying and renamed only when complete -- so neither the UI's list
  nor the encoder can ever see a half-copied video -- and an existing file is
  never overwritten.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [Parameter(Mandatory)][ValidateSet('important','regular')][string]$Tier,
  [switch]$Quiet,   # used by self-tests: no console theatrics, no sleeps
  [Parameter(ValueFromRemainingArguments)][string[]]$Items
)

$ErrorActionPreference = 'Continue'
$destRoot = Join-Path $RepoRoot "sources\$Tier"
if (-not (Test-Path -LiteralPath $destRoot)) { New-Item -ItemType Directory -Path $destRoot -Force | Out-Null }

$script:ok = 0; $script:skip = 0; $script:bad = 0

function Copy-OneFile {
  param([string]$Src, [string]$Final)
  if (Test-Path -LiteralPath $Final) {
    if (-not $Quiet) { Write-Host "  SKIP     $(Split-Path $Final -Leaf)  (already exists -- never overwritten)" -ForegroundColor Yellow }
    $script:skip++; return
  }
  $dir = Split-Path $Final -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = "$Final.copying"
  $mb  = [math]::Round((Get-Item -LiteralPath $Src).Length / 1MB, 1)
  if (-not $Quiet) { Write-Host "  copying  $($Final.Substring($destRoot.Length).TrimStart('\'))  ($mb MB) ..." -NoNewline }
  try {
    Copy-Item -LiteralPath $Src -Destination $tmp -Force -ErrorAction Stop
    Move-Item -LiteralPath $tmp -Destination $Final -ErrorAction Stop
    if (-not $Quiet) { Write-Host " done" -ForegroundColor Green }
    $script:ok++
  } catch {
    if (-not $Quiet) { Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red }
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    $script:bad++
  }
}

if (-not $Quiet) {
  Write-Host ""
  Write-Host "Copying $(@($Items).Count) item(s) into sources\$Tier ..." -ForegroundColor Cyan
}

foreach ($src in $Items) {
  if (-not (Test-Path -LiteralPath $src)) {
    if (-not $Quiet) { Write-Host "  MISSING  $src" -ForegroundColor Red }
    $script:bad++; continue
  }
  $item = Get-Item -LiteralPath $src
  if ($item.PSIsContainer) {
    # folder: mirror it under sources\<tier>\<folderName>\...
    $base = Join-Path $destRoot $item.Name
    foreach ($f in (Get-ChildItem -LiteralPath $item.FullName -File -Recurse)) {
      $rel = $f.FullName.Substring($item.FullName.Length).TrimStart('\')
      Copy-OneFile -Src $f.FullName -Final (Join-Path $base $rel)
    }
  } else {
    Copy-OneFile -Src $item.FullName -Final (Join-Path $destRoot $item.Name)
  }
}

if (-not $Quiet) {
  Write-Host ""
  Write-Host ("Done: {0} copied, {1} skipped, {2} failed. Originals untouched." -f $script:ok, $script:skip, $script:bad) `
    -ForegroundColor $(if ($script:bad) { 'Red' } else { 'Green' })
  if ($script:bad) { Write-Host "This window stays open so you can read the errors."; Read-Host 'Press Enter to close' }
  else { Start-Sleep -Seconds 3 }
}
if ($script:bad) { exit 1 } else { exit 0 }
