# images - bulk image optimization

The picture-side mini-app: drop image collections into two tiers, get a
smaller mirror with **stronger guarantees than video can ever offer** -
lossless conversions are proven **pixel-identical**, not merely "high quality".

## The drop-folder workflow

1. Drop images into **`sources_images/important/`** (strictly lossless) or
   **`sources_images/regular/`** (high-quality lossy allowed). Subfolders mirror.
2. `.\run_image_encode.ps1` - decides per file and records evidence in
   `encoded_images/images_manifest.csv`:
   - **important tier:** PNG/BMP/TIFF → **WebP-lossless, self-verified
     pixel-identical at encode time** (raw RGBA hash of both sides must match,
     else the original is copied instead - the tier structurally cannot ship a
     changed pixel). JPEG/HEIC are **kept as-is**: they're already lossy, so
     re-encoding could only lose quality - and keeping them preserves EXIF.
   - **regular tier:** tries WebP q90, kept only if **≥20% smaller AND
     SSIM ≥ 0.97**; otherwise falls back per-file to the lossless policy.
   - **only-if-smaller guard everywhere**: no output is ever larger than its
     source, and every decision carries its reason in the manifest.
3. `.\confirm_images_quick.ps1` - coverage + dimensions, seconds.
4. `.\confirm_images_deep.ps1` - the pre-delete check: **pixel-hash identity**
   for lossless conversions, **SHA-256** for kept copies, **SSIM + review
   pairs** (saved to `encoded_images/_review/`) for lossy.

## Which tier for what

For phone photos the **regular tier is the sensible default**: cameras spend
quality-95 bitrate regardless of how much detail a shot actually has, so
near-invisible loss buys disproportionate space. Measured on real 8–10 MB S24U
photos: **3.2× smaller at SSIM 0.984–0.990** at the default q90; drop
`-LossyQuality` to 85 for softer/bokeh-heavy collections and deeper cuts.

Reserve the **important tier** for images where provable pixel-identity
matters: scans, documents, screenshots, artwork masters. Flat-color
screenshots routinely compress 20×+ under WebP-lossless with mathematically
zero change.

## Color profiles are handled, not ignored

A real-photo finding, caught by human eyes rather than SSIM: **WebP cannot
carry an ICC profile**, and phones embed Display-P3 in every photo. Strip the
profile and color-managed viewers render the image visibly duller even though
the pixel *values* survived perfectly - structure metrics sit at 0.99 while
the teals wash out.

So the pipeline probes every image:

- **P3 sources in the lossy tier are gamut-mapped to sRGB** (zscale) - correct
  color in every viewer, no profile needed; verified numerically and visually
  on real photos
- **profiled sources in the lossless tier are copied rather than converted** -
  the profile is preserved because the conversion couldn't carry it
- **unknown wide-gamut profiles are refused loudly**
- SSIM and review pairs compare **in the mapped space**, so they measure
  encoding fidelity rather than punishing the deliberate colorspace change

## Format choice, stated honestly

Why WebP and not JPEG-XL/AVIF: WebP decodes essentially everywhere in 2026;
lossless AVIF is often *larger* than PNG; and JXL's killer feature - bit-exact
JPEG shrinking at ~−20% - requires `cjxl`, an extra dependency this repo
deliberately avoids. JXL support is the obvious future upgrade once it's
table-stakes in viewers.

⚠ **Converted WebP files don't carry EXIF/GPS** (kept copies do; file dates
always survive). Keep your originals if embedded metadata matters - which is
the operating model of this whole repo anyway.

## Script inventory

| Script | Role |
|---|---|
| `run_image_encode.ps1` | Per-file tiered optimizer with encode-time self-verification and evidence manifest |
| `confirm_images_quick.ps1` | Coverage + dimensions + kept-copy size checks, seconds per hundred files |
| `confirm_images_deep.ps1` | Pre-delete proof: pixel-hash identity / SHA-256 / mapped-space SSIM + review pairs |
