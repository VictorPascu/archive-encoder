# archive-encoder

A verified pipeline for re-encoding a media archive into a compact copy
**without risking the originals and without unmeasured quality loss**.
Battle-tested on **754 real phone videos (~276 GB → 41 GB, 6.6×)** with every
file either formally verified or human-reviewed against extracted evidence —
frame counts exact, audio bit-identical, colors measured.

Windows PowerShell 5.1 + ffmpeg. Nothing else. Copy the folder and run.

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

## Quickstart

```powershell
# drop videos into video\sources\{important,regular}\
# drop images into images\sources_images\{important,regular}\
.\archive_encode.ps1          # encode everything (-Parallel: CPU+GPU video tiers)

# verify before trusting:
.\video\confirm_quick.ps1   ; .\video\confirm_deep.ps1
.\images\confirm_images_quick.ps1 ; .\images\confirm_images_deep.ps1
```

Or point-and-click: **`video\LaunchUI.bat`**.

`important` tiers maximize quality (x265 slow / proven-lossless WebP);
`regular` tiers trade a sliver of margin for ~5× speed or deeper savings.
Full guidance, measured numbers, and supported formats live in each mini-app's
README: **[video](video/README.md)** · **[images](images/README.md)**.

## The contract

- **Sources are read-only, always.** Nothing writes to, renames, or deletes an
  original; deleting raws is your manual act, after proof. Optional belt and
  braces: set `ARCHIVE_ENCODER_PROTECTED_ROOT` and the engine hard-refuses to
  write anywhere under it.
- **Every output is proven, per file.** Videos: clean decode, exact frame
  count, duration, bit-identical audio hash, orientation, metadata, VMAF gates,
  per-plane chroma SSIM. Images: raw-pixel hash identity (lossless), SHA-256
  (copies), SSIM + review pairs (lossy). All decisions land in CSV manifests.
- **Interruption-safe.** Encodes stage to `.part` and rename only after a
  frame-count check; every batch resumes; superseded outputs are set aside as
  `.bak`, never deleted.
- **The verifiers are themselves verified** — a five-defect negative control
  must stay at 5/5 catches: [docs/TESTING.md](docs/TESTING.md).

## Requirements

| Dependency | Notes |
|---|---|
| **ffmpeg + ffprobe ≥ 8.0, FULL build**, on PATH | ⚠ the "essentials" build lacks `libvmaf` — encodes would work but verification couldn't run. `winget install ffmpeg` installs the correct full Gyan build. |
| PowerShell 5.1+ | in-box; PowerShell 7 also works |
| .NET Framework 4.7+ | in-box; UI + icon generation only |
| NVIDIA GPU | optional — fast modes only; CPU paths fall back loudly |

## Deeper reading

- **[docs/GOTCHAS.md](docs/GOTCHAS.md)** — the 12-entry ledger of hard-won
  ffmpeg/VMAF/PowerShell traps this pipeline encodes the answers to (VFR
  framesync mispairing, ICC-stripping desaturation, container frame-count lies,
  and friends). Worth reading before modifying anything.
- **[docs/TESTING.md](docs/TESTING.md)** — the test suites and the
  negative-control philosophy.
- **[video/README.md](video/README.md)** — tiers, UI, phase workflow, supported
  sources, calibration numbers.
- **[images/README.md](images/README.md)** — pixel-identity guarantees, color
  management, format rationale.

---

*All numbers are measured, not guessed: 754-file corpus, August 2026, on
AMD Ryzen 7 9800X3D + NVIDIA RTX 5080. MIT licensed.*
