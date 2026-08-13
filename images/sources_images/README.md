# Drop your images here

| Folder | Policy |
|---|---|
| `sources_images/important/` | **Strictly lossless.** PNG/BMP/TIFF → WebP-lossless, and every conversion is verified **pixel-identical** before it is kept (any doubt → the original is copied instead). JPEG/HEIC are already lossy, so they are kept as-is - re-encoding them only loses quality. |
| `sources_images/regular/` | High-quality lossy allowed: everything → WebP q90, kept only if ≥20% smaller **and** SSIM ≥ 0.97; otherwise falls back to the lossless policy per file. |

Subfolders are mirrored. Converted files are named `<original>.webp` (e.g.
`shot.png.webp`); kept files keep their names. File dates are preserved.

```powershell
.\run_image_encode.ps1          # encode both tiers (resumable)
.\confirm_images_quick.ps1      # coverage + dimensions, seconds
.\confirm_images_deep.ps1       # pixel-hash identity / SSIM + review pairs
```

⚠ Converted WebP files do not carry EXIF/GPS metadata (kept JPEG copies do).
File dates survive; keep your originals if embedded metadata matters - which
is the operating model here anyway. Nothing ever deletes or modifies a source.
