# archive-encoder

A verified pipeline for re-encoding a media archive into a compact copy
**without risking the originals and without unmeasured quality loss**.
Battle-tested on **754 real phone videos (~276 GB to 41 GB, 6.6x)** with every
file either formally verified or human-reviewed against extracted evidence:
frame counts exact, audio bit-identical, colors measured.

The video flow is tested primarily against footage from a Samsung Galaxy S24
Ultra filming at 4K 60 FPS in its default encoding format (HEVC/H.265 in mp4),
plus OBS screen recordings; other 8-bit SDR sources ride the same rails.
See [video/README.md](video/README.md) for the full compatibility picture.

Dependencies: Windows PowerShell 5.1+ and ffmpeg (see
[Requirements](#requirements)). No installation; run from the folder.

## Layout

```
archive_encode.ps1   umbrella: runs both flows, one combined summary
video/               mini-app: tiered video encoding      -> video/README.md
images/              mini-app: image optimization         -> images/README.md
core/                shared engine: ffmpeg wrappers, VMAF/chroma/pixel-hash
                     verification, encoders, guards
tests/               e2e suites + negative controls       -> docs/TESTING.md
docs/                the technical ledger                 -> docs/GOTCHAS.md
```

## Quickstart (Windows)

The easiest way in is the UI: double-click **`video\LaunchUI.bat`**. It shows
your two quality tiers, copies videos in safely (never moves them), runs the
encode in a visible console, and opens a side-by-side review window when a
deep check finishes. Add files or whole folders, click Run Encode, done.

Prefer the command line? Same flow, three commands:

```powershell
# drop videos into video\sources\{important,regular}\
# drop images into images\sources_images\{important,regular}\
.\archive_encode.ps1          # encode everything (-Parallel: CPU+GPU video tiers)

# verify before trusting:
.\video\confirm_quick.ps1   ; .\video\confirm_deep.ps1
.\images\confirm_images_quick.ps1 ; .\images\confirm_images_deep.ps1
```

The `important` tiers maximize quality (x265 slow / proven-lossless WebP);
the `regular` tiers trade a sliver of margin for ~5x speed or deeper savings.
Full guidance, measured numbers, and supported formats live in each mini-app's
README: **[video](video/README.md)** and **[images](images/README.md)**.

## How it works

1. **You sort, it encodes.** Files dropped into an `important` tier get the
   slow, maximum-quality-per-bit treatment; `regular` tier files get the fast
   or deeper-saving treatment. Folder structure is mirrored into the outputs,
   filenames and file dates are preserved, and every batch is resumable.
2. **Sources are never written to.** The pipeline only reads your originals.
   Encodes go to a separate output tree, staged as `.part` files and renamed
   only after a frame-count check, so an interrupted run cannot leave a
   truncated file that looks finished. Superseded outputs are set aside as
   `.bak`, never deleted. Optionally set `ARCHIVE_ENCODER_PROTECTED_ROOT` to
   your originals folder and the engine will refuse to write under it at all.
3. **Every output is then proven against its source.** Videos: clean decode,
   exact frame count, duration, bit-identical audio hash, orientation,
   metadata, VMAF quality gates, and per-plane chroma SSIM. Images: raw-pixel
   hash identity for lossless conversions, SHA-256 for kept copies, SSIM plus
   side-by-side review images for lossy. Every decision and measurement lands
   in a CSV manifest you can audit.
4. **The last word is yours.** The deep confirm saves source-vs-encode
   screenshot pairs so the final "looks identical to me" judgment is made with
   your own eyes, and deleting your raws is always your manual act. The
   verification tools are themselves tested by a five-defect negative control
   that must stay at 5/5 catches: [docs/TESTING.md](docs/TESTING.md).

## Requirements

| Dependency | Notes |
|---|---|
| **ffmpeg + ffprobe (version 8+, FULL build)** | See below for a 2-minute install. ffprobe ships inside every ffmpeg package; there is nothing separate to get. |
| PowerShell 5.1+ | already on every Windows 10/11 machine |
| .NET Framework 4.7+ | already on every Windows 10/11 machine (UI + icon only) |
| NVIDIA GPU | optional: fast modes only; CPU paths fall back loudly |

### Getting ffmpeg (non-technical version)

1. Open the Start menu, type `powershell`, press Enter.
2. Paste this and press Enter:

   ```powershell
   winget install ffmpeg
   ```

3. Close that window, open a new one, and check it worked:

   ```powershell
   ffmpeg -version
   ```

   If a version banner appears, you are done. This installs the full "Gyan"
   build, which includes both ffprobe and the libvmaf quality-measurement
   engine this pipeline depends on.

One warning for manual downloaders: builds labeled **"essentials"** lack
`libvmaf`. Encoding would still work, but none of the quality verification
could run. If installing by hand from [gyan.dev/ffmpeg/builds](https://www.gyan.dev/ffmpeg/builds/),
take the **full** build and add its `bin` folder to your PATH.

## Deeper reading

- **[docs/GOTCHAS.md](docs/GOTCHAS.md)**: the 12-entry ledger of hard-won
  ffmpeg/VMAF/PowerShell traps this pipeline encodes the answers to (VFR
  framesync mispairing, ICC-stripping desaturation, container frame-count
  lies, and friends). Worth reading before modifying anything.
- **[docs/TESTING.md](docs/TESTING.md)**: the test suites and the
  negative-control philosophy.
- **[video/README.md](video/README.md)**: tiers, UI, phase workflow, supported
  sources, calibration numbers.
- **[images/README.md](images/README.md)**: pixel-identity guarantees, color
  management, format rationale.

---

*All numbers are measured, not guessed: 754-file corpus, August 2026, on
AMD Ryzen 7 9800X3D + NVIDIA RTX 5080. MIT licensed.*
