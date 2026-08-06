<#
  Fast-mode wrapper around encode_batch.ps1.

  Uses the GPU (NVENC HEVC, quality 30) instead of CPU x265. Measured on the
  reference corpus (S24U 4K, Ryzen 9800X3D + RTX 5080):

                        x265 slow CRF22     THIS SCRIPT (hevc_nvenc q30)
    speed on 4K         4-8 fps             ~30 fps  (~5x faster)
    100 GB takes        ~11-12 h            ~2.5 h
    output size         ~10.4 GB/100GB      ~9.8 GB/100GB  (comparable)
    VMAF mean           ~97.5-98.5          ~96.0-96.7

  What you trade: ~1.5-2 VMAF points of quality margin, NOT compression -- at
  these settings the GPU output is comparable-or-smaller. Both clear the
  visually-lossless verification gates (mean >= 95 / 1%-low >= 92). Use x265
  (encode_batch.ps1 -Codec x265 -Quality 22) when the footage is irreplaceable
  and an overnight run is acceptable; use this for everything else.

  Requires an NVIDIA GPU (Turing or newer for decent HEVC NVENC quality).
  All other parameters pass straight through to encode_batch.ps1.

  Usage:
    .\encode_batch_fast.ps1 -SourceDir 'X:\originals' -OutDir 'Z:\encoded'
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$SourceDir,
  [Parameter(Mandatory)][string]$OutDir,
  [string]$Filter = '*.mp4',
  [int]$Quality   = 30,
  [switch]$DryRun
)

& "$PSScriptRoot\encode_batch.ps1" -Codec hevc_nvenc -Quality $Quality `
    -SourceDir $SourceDir -OutDir $OutDir -Filter $Filter -DryRun:$DryRun
exit $LASTEXITCODE
