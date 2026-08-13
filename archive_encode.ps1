<#
  archive-encoder -- the umbrella entry point.

  Runs both mini-apps over their drop folders and prints one combined summary:
    video\   sources -> encoded_outputs   (x265 archival / NVENC fast tiers)
    images\  sources_images -> encoded_images (lossless-proven / quality-gated lossy)

  Each mini-app skips cleanly when its sources are empty, so this is safe to run
  with anything from one video to a mixed pile of both. All safety properties
  are the mini-apps' own: copies never moves, resumable, per-file verification
  evidence, nothing ever deleted.

    .\archive_encode.ps1              # both flows, sequential
    .\archive_encode.ps1 -Parallel    # video tiers use CPU+GPU simultaneously

  Then confirm before trusting:
    .\video\confirm_quick.ps1   .\video\confirm_deep.ps1
    .\images\confirm_images_quick.ps1   .\images\confirm_images_deep.ps1
#>

[CmdletBinding()]
param([switch]$Parallel)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$fails = 0

Write-Host ""
Write-Host "=============== archive-encoder: VIDEO flow ===============" -ForegroundColor Cyan
& "$root\video\run_encode.ps1" -RepoRoot "$root\video" -Parallel:$Parallel
if ($LASTEXITCODE -ne 0) { $fails++ }

Write-Host ""
Write-Host "=============== archive-encoder: IMAGE flow ===============" -ForegroundColor Cyan
& "$root\images\run_image_encode.ps1" -RepoRoot "$root\images"
if ($LASTEXITCODE -ne 0) { $fails++ }

Write-Host ""
if ($fails -eq 0) {
  Write-Host "ARCHIVE ENCODE COMPLETE -- both flows clean. Run the confirm scripts before trusting." -ForegroundColor Green
} else {
  Write-Host "ARCHIVE ENCODE finished with failures in $fails flow(s) -- see above; re-runs resume." -ForegroundColor Red
}
exit $fails
