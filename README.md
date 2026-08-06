# Video Encoding Scripts

A verified pipeline for re-encoding phone video into a compact archive **without
risking the originals and without unmeasured quality loss**. Battle-tested on a
corpus of **754 Samsung Galaxy S24 Ultra videos** (~276 GB, predominantly 4K at
up-to-60 fps variable-frame-rate capture): the first 108 GB tranche came out at
**11.5 GB — 9.4× smaller — with all 64 outputs formally verified** against their
sources, frame counts exact, audio bit-identical.

Everything here is Windows PowerShell 5.1 + ffmpeg. No other dependencies.

## What it produces

Given a folder of originals, you end up with:

- an **encoded twin folder** — same filenames, same file dates, visually lossless
  (VMAF mean ≥ 95 / 1%-low ≥ 92 on the 4K model), audio stream-copied
  **bit-for-bit**, all metadata (capture time, GPS, vendor tags) and rotation
  preserved
- a **SHA-256 manifest** proving your backup copy of the originals is byte-identical
- a **verification manifest** proving, per file, that the encode decodes cleanly,
  has the exact frame count and duration, identical audio hash, correct
  orientation, preserved metadata, and measured VMAF above the gates
- a closing **re-hash proof** that no original was touched by any of it

Nothing in the pipeline ever writes to, renames, or deletes a source file.
`Assert-NotSourceDrive` in `_common.ps1` hard-refuses output paths inside a
protected originals tree (edit its default root for your own setup).

## Choosing an encoder: quality mode vs fast mode

Both modes were calibrated on real footage from the test corpus (dark high-motion
indoor + bright fast daylight clips), measured with frame-exact VMAF.
Reference hardware: **AMD Ryzen 7 9800X3D (8C/16T) + NVIDIA RTX 5080**.

| | quality mode: `x265 -Quality 22` (`sources/important`) | fast mode: NVENC HEVC q30 (`sources/regular`) |
|---|---|---|
| Runs on | CPU | NVIDIA GPU |
| Speed on 4K | 4–8 fps | ~30 fps (**≈5× faster**) |
| 100 GB of 4K takes | ~11–12 h | **~2.5 h** |
| Output size | ~10.4 GB per 100 GB | ~9.8 GB per 100 GB (comparable) |
| VMAF mean | ~97.5–98.5 | ~96.0–96.7 |
| Compatibility | HEVC — plays everywhere | HEVC — plays everywhere |

The trade is **quality margin, not compression**: fast mode gives up ~1.5–2 VMAF
points while landing at comparable-or-smaller size, and still clears the
visually-lossless verification gates. Rule of thumb: irreplaceable footage and
an overnight window → x265; everything else → fast mode.

(AV1 NVENC was also measured: at settings matching fast-mode quality it came out
*larger* than NVENC HEVC on this corpus and plays on fewer devices — no win here.
x265's real edge is quality-per-bit: at *matched quality* it is ~2.5× smaller
than NVENC, which is why it remains the archival default.)

## Tuned for: Samsung S24 Ultra footage

Confirmed profile this pipeline was validated against (all 754 corpus files):

| Property | Value |
|---|---|
| Container / codec | mp4, HEVC (`hvc1`), Main profile |
| Pixel format | `yuv420p` (8-bit) — **the scripts force 8-bit output; do not point them at 10-bit/HDR sources unmodified** |
| Color | BT.709 SDR |
| Audio | exactly one AAC-LC stereo 256 kbps track (`-c:a copy` keeps it bit-exact) |
| Frame rate | **VFR.** The phone tags 60 fps but delivers anywhere from ~30 to 60; frame deltas alternate 1499/1500 on a 1/90000 timebase |
| Rotation | portrait files carry a −90° display matrix; encodes bake it into pixels (equivalent display, more compatible) |
| Bitrate | ~144 Mbps (4K), ~40 Mbps (1080-class) — heavily over-provisioned, which is why ~9× is recoverable |

**Beyond the phone profile**, the pipeline is proven on more than S24U footage:

- **OBS screen recordings (h264)** — validated end to end, including the
  nb_frames off-by-one their containers carry (gotcha #9)
- **Videos with no audio track** (screen captures, timelapses) — encoded and
  verified, flagged `no_audio_in_source` for honesty
- Any **8-bit SDR** source with at most one audio stream rides the same rails:
  every file is probed individually, nothing assumes a homogeneous folder
- **10-bit / HDR sources are refused loudly** rather than silently squashed to
  8-bit — they need deliberate handling; the batch lists them as skipped

For anything else, run `survey.ps1` first and check bit depth (`pix_fmt`), color
transfer, audio codec, and stream counts before encoding.

## Point-and-click: the UI

Double-click **`LaunchUI.bat`** — or run `scripts_internal\make_shortcut.ps1`
once to generate **`Video Encoding.lnk`** (same launcher with the app icon;
`-Desktop` also puts a copy on your Desktop). The icon itself is drawn in code
(`scripts_internal\make_icon.ps1` → `assets\icon.ico`), so it's reproducible
and license-free, and it appears on the window title bar and taskbar too.

You get a small window over the drop-folder flow:
both tiers listed with per-file encode status and sizes, a **+** button that
*copies* videos in (staged + renamed, so a half-copied file can never be seen
by the encoder; originals never moved or touched), a **Run Encode** button that
opens the encode in its own console window, and double-click-to-play (encoded
version when it exists, else the source — right-click for explicit choices).

**Quick Check** and **Deep Check** buttons launch the confirm scripts in their
own consoles, and when a deep check finishes, a **screenshot review window**
opens automatically: each source/encoded pair side by side, arrow keys to flip
through, so the final "looks identical to me" judgment is made with your own
eyes. **Review Pairs** reopens it anytime.

The UI is deliberately a launcher + viewer: it owns no encoding process and
deletes nothing, so closing it mid-anything costs nothing. `ui.ps1 -SelfTest`
runs its headless checks.

## Easiest path: the drop-folder workflow

For the common case — "here's a pile of videos, make me a verified compact copy" —
you don't need to drive the phase scripts yourself:

1. Drop videos into **`sources/important/`** (irreplaceable → x265 slow CRF 22) and/or
   **`sources/regular/`** (bulk → NVENC HEVC q30, ~5× faster). Subfolders are mirrored.
2. `.\run_encode.ps1` — encodes both tiers into `encoded_outputs/<tier>/`.
   Resumable; re-run any time. `-Parallel` runs the CPU and GPU tiers simultaneously.
   Falls back to CPU (loudly) if no NVENC. Progress: `encoded_outputs/manifest.csv` + `.log`.
3. `.\confirm_quick.ps1` — seconds per file: every source has a counterpart, frame
   counts, durations, orientation, **bit-identical audio**.
4. `.\confirm_deep.ps1` — the pre-delete check: full decode, VMAF gates, plus
   source-vs-encode **screenshot pairs** at 20/50/80% saved to `encoded_outputs/_review/`
   with SSIM scores, so the final judgment is one your own eyes make.

When deep confirm says PASS, every input has a verified visually-lossless encode.
What you do with the raws is your decision — no script here deletes anything, ever.

## The image flow

The picture-side sibling of the video flow — same shape, stronger guarantees
(images can be proven **pixel-identical**, which video never can):

1. Drop images into **`sources_images/important/`** (strictly lossless) or
   **`sources_images/regular/`** (high-quality lossy allowed).
2. `.\run_image_encode.ps1` — per file: PNG/BMP/TIFF → **WebP-lossless,
   self-verified pixel-identical at encode time** (raw RGBA hash of both sides
   must match, else the original is copied); JPEG/HEIC in the important tier are
   **kept as-is** (they're already lossy — re-encoding only loses quality);
   the regular tier tries WebP q90, kept only if ≥20% smaller *and* SSIM ≥ 0.97.
   Every decision + evidence lands in `encoded_images/images_manifest.csv`.
3. `.\confirm_images_quick.ps1` — coverage + dimensions, seconds.
4. `.\confirm_images_deep.ps1` — the pre-delete check: pixel-hash identity for
   conversions, SHA-256 for copies, SSIM + review pairs for lossy.

For phone photos the **regular tier is the sensible default**: cameras spend
quality-95 bitrate regardless of how much detail a shot actually has, so
near-invisible loss buys disproportionate space. Measured on real 8–10 MB
S24U photos: **3.2× smaller at SSIM 0.984–0.990** at the default q90; drop
`-LossyQuality` to 85 for softer/bokeh-heavy collections and deeper cuts.
Reserve the important tier for images where provable pixel-identity matters
(scans, documents, screenshots, masters).

**Color profiles are handled, not ignored** (a real-photo finding, caught by
eye, not by SSIM): WebP cannot carry an ICC profile, and stripping a
Display-P3 profile — which Samsung phones embed in every photo — makes managed
viewers render the image visibly duller even with perfect pixel values. So the
pipeline probes every image: P3 sources in the lossy tier are **gamut-mapped
to sRGB** (correct color in every viewer; verified numerically and visually on
real S24U photos), profiled sources in the lossless tier are **copied rather
than converted** (profile preserved), and unknown wide-gamut profiles are
refused loudly. SSIM and review pairs compare in the mapped space, so they
measure encoding fidelity, not the deliberate colorspace change.

Why WebP and not JPEG-XL/AVIF: WebP decodes essentially everywhere in 2026;
JXL's killer feature (bit-exact JPEG shrinking, ~-20%) needs `cjxl`, an extra
dependency — a clean future option, noted here deliberately. ⚠ Converted WebP
files don't carry EXIF/GPS (kept copies do; file dates always survive) — keep
originals if embedded metadata matters, which is the operating model anyway.

## The phase workflow (full control)

The phase scripts live under `scripts_internal\` — they are the engine the
drop-folder flow drives, callable directly when you need full control:

```powershell
# Phase 0 — verify your backup BEFORE anything else (the real risk is single-copy
# originals, not the transcode). Writes manifest CSV next to the backup dir.
.\scripts_internal\verify_backup.ps1 -SourceDir 'X:\originals' -BackupDir 'Y:\backup-copy'

# Survey — know what you're encoding; triages worth-encoding vs already-efficient
.\scripts_internal\survey.ps1 -SourceDir 'X:\originals'

# Phase 1 (optional, recommended for new content types) — measure, don't guess.
# Cuts real excerpts, runs x265/NVENC-HEVC/NVENC-AV1 across a quality ladder,
# reports VMAF + size so the codec/CRF choice comes from data.
.\scripts_internal\calibrate.ps1 -SourceDir 'X:\originals' -WorkDir 'Z:\calibration'

# Phase 2 — the batch encode. Resumable (skips outputs whose frame count already
# matches), stages to .part files, restores file mtimes, excludes non-videos.
.\scripts_internal\encode_batch.ps1 -Codec x265 -Quality 22 -SourceDir 'X:\originals' -OutDir 'Z:\encoded'
#   ...or ~5x faster on an NVIDIA GPU at slightly lower quality margin:
.\scripts_internal\encode_batch_fast.ps1 -SourceDir 'X:\originals' -OutDir 'Z:\encoded'

# Phase 3 — verify EVERY output against its source (7 checks, fails loudly).
.\scripts_internal\verify_encoded.ps1 -SourceDir 'X:\originals' -EncDir 'Z:\encoded'

# Phase 4 — prove the originals are byte-identical to the Phase 0 baseline.
.\scripts_internal\rehash_originals.ps1 -SourceDir 'X:\originals' -ManifestIn 'Y:\manifest-originals.csv'
```

Note from the corpus run: a handful of noisy 1080-class clips missed the VMAF
gate at x265 CRF 22. The fix is to re-encode just those files with more bits
(`-Filter '<name>.mp4' -Quality 18`) and re-verify — minutes, not hours.

## Script inventory

**Root — the normal user flow:**

| Script | Role |
|---|---|
| `run_encode.ps1` | Drop-folder driver: `sources/important` → x265, `sources/regular` → NVENC, mirrored into `encoded_outputs/`; `-Parallel` runs both tiers at once |
| `confirm_quick.ps1` | Coverage check: counterpart exists, frames/duration/orientation match, audio bit-identical |
| `confirm_deep.ps1` | Pre-delete check: full 7-check verify + VMAF gates + reviewable screenshot pairs with SSIM |
| `ui.ps1` / `LaunchUI.bat` | WPF front-end: tier lists with status, safe copy-in, Run Encode launcher, double-click to play |

**`scripts_internal\` — the engine and power tools:**

| Script | Role |
|---|---|
| `_common.ps1` | Shared library (dot-sourced by all): ffprobe wrapper, encoder arg sets, VMAF harness, audio-hash, guards |
| `verify_backup.ps1` | Pairwise SHA-256 of originals vs backup → manifest. **Gate for everything else** in the phase workflow |
| `survey.ps1` | ffprobe sweep: codec/bit-depth/HDR/audio/rotation distribution + bits-per-pixel triage |
| `calibrate.ps1` | Encoder/quality ladder on real excerpts, dual-model VMAF, projected totals |
| `encode_batch.ps1` | The batch encoder. Resumable, `.part` staging, frame-parity gate before rename, mtime restore |
| `encode_batch_fast.ps1` | GPU fast mode: NVENC HEVC q30 preset of the above (~5× faster, ~2 VMAF points lower) |
| `verify_encoded.ps1` | 7 checks per file; `-Names`/`-OnlyExisting` for mid-run spot checks |
| `rehash_originals.ps1` | Closing proof the source tree is unchanged |
| `make_corpus.ps1` / `smoke_test.ps1` / `neg_control.ps1` | Component test harness — see below |

**`tests\`:**

| Script | Role |
|---|---|
| `run_tests.ps1` | End-to-end test: sandboxed drop-folder flow, both tiers, both confirms, sources-untouched proof |

## Trust, and how it's maintained

Run these after any change to the pipeline, on any new machine:

```powershell
.\tests\run_tests.ps1                 # END-TO-END: builds tiny S24U-format clips in a temp
                                      # sandbox, runs run_encode + both confirms against it,
                                      # asserts the right engine ran per tier, sources untouched.
                                      # ~1 minute, cleans up after itself. Run this one first.

.\scripts_internal\smoke_test.ps1     # 41 checks: probing, all 3 encoders, mux, audio-hash, VMAF, guards
.\scripts_internal\make_corpus.ps1    # synthetic S24U-like corpus (VFR ratio 0.667, -90 rotation, GPS tags)
.\scripts_internal\neg_control.ps1    # plants 4 defects (crushed quality, re-encoded audio, sideways
                                      # video, truncation) and PROVES the verifier catches each by name
```

A verifier that has only ever said PASS proves nothing — `neg_control.ps1` is the
evidence it can fail things. It caught a mis-designed test of its own during
development (see gotcha #6).

## Hard-won gotchas (each of these cost real hours)

1. **libvmaf pairs frames by TIMESTAMP, not index — this is the big one.** On VFR
   phone footage the encode's timestamps drift sub-frame vs the source until
   framesync slips one frame, and every later comparison is against the wrong
   reference. Symptom: VMAF collapses partway through (a perfect file scored
   mean 40 / 1%-low 8), N+1 frame pairs from N-frame inputs, bitrate-independent
   "quality floors". Fix (in `Invoke-Vmaf`): rewrite both sides' PTS to the frame
   ordinal — `settb=1/1000,setpts=N`. Control: source-vs-itself must score 100.00.
2. **PowerShell 5.1 + `$ErrorActionPreference='Stop'` kills scripts when a native
   exe writes to stderr** — and x265/NVENC print banners to stderr on success.
   All native calls must go through `Invoke-FFmpegCapture` / `Invoke-FFprobeJson`.
3. **The null muxer emits a benign "non monotonically increasing dts" warning on
   VFR input** (`-f null -` timebase conversion collides two timestamps). It is not
   a file defect. Never treat "stderr non-empty" as decode failure; judge exit code
   + serious-error patterns. Sources, excerpts, and encodes can all audit clean
   on actual DTS while still triggering it.
4. **ffprobe CSV field order ignores your `-show_entries` order** (`pts` comes
   before `dts` regardless), and values can carry a **trailing comma** when side
   data is present. Query ONE field at a time; parse forgivingly. Misreading this
   manufactured a phantom "520 backward DTS" defect during development.
5. **Windows filter-graph paths need a DOUBLE backslash before the drive colon**
   (`L\\:/dir/file.json`) — single-escape truncates the option value silently and
   VMAF just returns nothing.
6. **`-noautorotate` is NOT a rotation defect** — it keeps the matrix, so the file
   still displays correctly. The real defect is a stripped matrix without
   transposition (`-display_rotation 0`). Verify orientation by comparing effective
   DISPLAY dimensions, which accepts both valid representations.
7. **exFAT mtimes look frozen while a file handle is open** — a `.part` file can
   show "last written 19 minutes ago" while actively growing. Liveness = size
   growth, never mtime. (exFAT also rounds timestamps to 2 s — robocopy re-runs
   may claim files are "modified" that are byte-identical; hashes settle it.)
8. **A filter without an extension matches photos** (a `foo_1*` filter pulls in
   JPGs, which ffprobe happily reports as 1-frame MJPEG "videos").
   `encode_batch.ps1` screens by codec + frame count; still, write filters with
   extensions.
9. **`nb_frames` is container metadata, not truth** — fine on phone mp4s, absent or
   wrong elsewhere. Concrete case: **OBS recordings claim one more frame than the
   stream decodes** (the final packet, cut mid-GOP when recording stops, yields no
   displayable frame — the container says 154, the decoder produces 153, zero
   errors). The frame gates therefore use `nb_frames` as the fast path and, on any
   disagreement, decode the source for real (`Get-DecodedFrameCount`) and judge
   the encode against that count — an encode holding every decodable frame is
   complete. Only mismatching files pay the decode cost.
10. **VMAF's 4K and 1080p models differ by 3–4 points on identical content.**
    Gates only mean something relative to a fixed model (this pipeline: the 4K
    model, everywhere). Changing models silently re-defines your threshold.

## Safety invariants (non-negotiable)

- Originals are **read-only** end to end; hash-proven unchanged at the end.
- No destructive flags anywhere; nothing is ever deleted (superseded outputs are
  renamed `.bak`, mismatches are held aside for inspection).
- Every phase gates the next; any FAIL halts with the evidence printed.
- Encode writes to `.part`, renames only after the frame-count check passes —
  an interrupted run can't leave a truncated file that looks finished.

## Requirements

The complete dependency list — everything else used is in-box on Windows 10/11:

| Dependency | Needed for | Notes |
|---|---|---|
| **ffmpeg + ffprobe ≥ 8.0, FULL build** | everything | Must include `libx265` (encoding) **and `libvmaf` (verification)**. ⚠ The "essentials" ffmpeg build **lacks libvmaf** — encodes would work but every quality gate would fail to run. `winget install ffmpeg` installs the full Gyan build, which is correct; verify with `ffmpeg -filters` showing `libvmaf`. Must be on `PATH`. |
| PowerShell 5.1+ | all scripts | In-box. Deliberately built against 5.1's quirks; PowerShell 7 also works. |
| .NET Framework 4.7+ (WPF, System.Drawing) | `ui.ps1`, icon generation | In-box on Windows 10/11 — no install. |
| NVIDIA GPU + current driver | fast mode / NVENC only | Optional. `run_encode.ps1` probes for NVENC and falls back to CPU loudly. x265 (CPU) is the archival-quality path and needs no GPU. |

No internet access, no package managers, no Python, no external VMAF model files
(the full ffmpeg build embeds them), nothing installed system-wide. Copy the
folder, have ffmpeg on PATH, run.

---

*All numbers above are measured, not guessed: 754-file S24U corpus, August 2026,
on the reference hardware listed.*
