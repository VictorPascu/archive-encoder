# Optimized images land here

Written by `run_image_encode.ps1`, mirroring `sources_images/`:

- `<name>.webp` - converted (lossless for the important tier, verified
  pixel-identical at encode time; quality-gated lossy for the regular tier)
- `<name>` (original name) - kept as-is, byte-identical, because conversion
  would have lost quality or not paid for itself
- `images_manifest.csv` - one row per image: action taken, reason, sizes,
  pixel-identity / SSIM evidence
- `confirm-images-quick.csv` / `confirm-images-deep.csv` - verification verdicts
- `_review/` - side-by-side JPEG pairs for lossy conversions, for your eyes

Verification: `confirm_images_quick.ps1` (coverage + dimensions, fast) and
`confirm_images_deep.ps1` (pixel-hash identity for lossless, SHA-256 for
copies, SSIM for lossy - the pre-delete check).
