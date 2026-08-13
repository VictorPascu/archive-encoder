# video — tiered video encoding

The video mini-app: drop videos into two quality tiers, get a verified,
visually-lossless, dramatically smaller mirror. Proven on 754 real S24U files
(~276 GB → 41 GB) plus OBS screen recordings and no-audio captures.

## The drop-folder workflow

1. Drop videos into **`sources/important/`** (irreplaceable → x265 slow CRF 22)
   and/or **`sources/regular/`** (bulk → NVENC HEVC q30, ~5× faster).
   Subfolders are mirrored into the outputs.
2. `.\run_encode.ps1` — encodes both tiers into `encoded_outputs/<tier>/`.
   Resumable; re-run any time. `-Parallel` runs the CPU and GPU tiers
   simultaneously (measured to coexist cleanly — NVENC is separate silicon).
   Falls back to CPU loudly if no NVENC. Progress: `encoded_outputs/manifest.csv` + `.log`.
3. `.\confirm_quick.ps1` — seconds per file: every source has a counterpart,
   frame counts, durations, orientation, **bit-identical audio**.
4. `.\confirm_deep.ps1` — the pre-delete check: full decode, VMAF + chroma
   gates, plus source-vs-encode **screenshot pairs** at 20/50/80% saved to
   `encoded_outputs/_review/` with SSIM scores, so the final judgment is one
   your own eyes make.

When deep confirm says PASS, every input has a verified visually-lossless
encode. What you do with the raws is your decision — no script here deletes
anything, ever.

## Point-and-click: the UI

Double-click **`LaunchUI.bat`** — or run `..\core\make_shortcut.ps1` once to
generate a shortcut carrying the app icon (`-Desktop` for a Desktop copy).

The window shows both tiers with per-file encode status and sizes. **+ Files**
and **+ Folder** buttons *copy* videos in — a folder is mirrored with its
structure preserved (adding `D:\Videos9` to regular yields
`sources/regular/Videos9/...` and the encode lands in
`encoded_outputs/regular/Videos9/...`); every file is staged as `.copying` and
renamed when complete, so a half-copied video can never be seen by the encoder,
and originals are never moved or touched. **Run Encode** opens the encode in
its own console. Double-click a row to play the encoded version when it exists,
else the source (right-click for explicit choices).

**Quick Check** and **Deep Check** launch the confirm scripts, and when a deep
check finishes a **screenshot review window** opens automatically — each
source/encoded pair side by side, arrow keys to flip. **Review Pairs** reopens
it anytime.

The UI is deliberately a launcher + viewer: it owns no encoding process and
deletes nothing, so closing it mid-anything costs nothing. `ui.ps1 -SelfTest`
runs its headless checks.

## Choosing a tier: quality mode vs fast mode

Calibrated on real footage (dark high-motion indoor + bright fast daylight),
measured with frame-exact VMAF on the reference hardware:

| | important: x265 slow CRF 22 | regular: NVENC HEVC q30 |
|---|---|---|
| Runs on | CPU | NVIDIA GPU |
| Speed on 4K | 4–8 fps | ~30 fps (**≈5× faster**) |
| 100 GB of 4K takes | ~11–12 h | **~2.5 h** |
| Output size | ~10.4 GB per 100 GB | ~9.8 GB per 100 GB (comparable) |
| VMAF mean | ~97.5–98.5 | ~96.0–96.7 |
| Compatibility | HEVC — plays everywhere | HEVC — plays everywhere |

The trade is **quality margin, not compression**. Rule of thumb: irreplaceable
footage and an overnight window → important; everything else → regular. On
hard, noisy content the regular tier misses the strict gates more often —
the corpus run saw ~40% of general handheld footage need a q24 bit-boost to
pass formally; the confirm scripts catch exactly this and re-encoding the
flagged files is a one-liner per file.

(AV1 NVENC was also measured: at settings matching fast-mode quality it came
out *larger* than NVENC HEVC on this corpus and plays on fewer devices. x265's
real edge is quality-per-bit: at *matched quality* it is ~2.5× smaller than
NVENC, which is why it remains the archival default.)

## What sources are supported

Validated profile (all 754 corpus files — Samsung S24 Ultra):

| Property | Value |
|---|---|
| Container / codec | mp4, HEVC (`hvc1`), Main profile |
| Pixel format | `yuv420p` (8-bit) — **output is forced 8-bit; 10-bit/HDR sources are refused loudly, never silently squashed** |
| Color | BT.709 SDR — tags carried through to the output bitstream, chroma verified per-plane |
| Audio | AAC-LC stereo (`-c:a copy` keeps it bit-exact) |
| Frame rate | **VFR.** The phone tags 60 fps but delivers ~30–60; handled exactly via `-fps_mode passthrough` |
| Rotation | portrait files carry a −90° display matrix; encodes bake it into pixels (equivalent display, more compatible) |

Beyond that profile, proven end to end: **OBS screen recordings** (h264,
including their nb_frames off-by-one — root README gotcha #9), **videos with
no audio track** (encoded, verified, flagged `no_audio_in_source`), and any
**8-bit SDR** source with at most one audio stream — every file is probed
individually, nothing assumes a homogeneous folder. For anything else, run
`..\core\survey.ps1` first and check bit depth, color transfer, audio codec,
and stream counts.

## The phase workflow (full control)

The engine scripts under `..\core\` are directly callable for the classic
archival sequence (run from the repo root):

```powershell
# Phase 0 — verify your backup BEFORE anything else (the real risk is single-copy
# originals, not the transcode). Writes manifest CSV next to the backup dir.
.\core\verify_backup.ps1 -SourceDir 'X:\originals' -BackupDir 'Y:\backup-copy'

# Survey — know what you're encoding
.\core\survey.ps1 -SourceDir 'X:\originals'

# Phase 1 (optional, recommended for new content types) — measure, don't guess:
# x265/NVENC-HEVC/NVENC-AV1 across a quality ladder on real excerpts
.\core\calibrate.ps1 -SourceDir 'X:\originals' -WorkDir 'Z:\calibration'

# Phase 2 — the batch encode (resumable, .part staging, mtime restore)
.\core\encode_batch.ps1 -Codec x265 -Quality 22 -SourceDir 'X:\originals' -OutDir 'Z:\encoded'
.\core\encode_batch_fast.ps1 -SourceDir 'X:\originals' -OutDir 'Z:\encoded'   # NVENC

# Phase 3 — verify EVERY output against its source (8 checks, fails loudly)
.\core\verify_encoded.ps1 -SourceDir 'X:\originals' -EncDir 'Z:\encoded'

# Phase 4 — prove the originals are byte-identical to the Phase 0 baseline
.\core\rehash_originals.ps1 -SourceDir 'X:\originals' -ManifestIn 'Y:\manifest-originals.csv'
```

Corpus note: noisy/dark/slow-mo clips can miss the VMAF gates at CRF 22 even
though nothing visible is lost — grain is genuinely unencodable at sane
bitrates. Re-encode flagged files with more bits
(`-Filter '<name>.mp4' -Quality 18`), and for files that *still* miss on
1%-low only, look at the review evidence before spending more electricity:
the worst frames are usually near-black grain or motion blur the camera
itself produced.

## Script inventory

| Script | Role |
|---|---|
| `run_encode.ps1` | Drop-folder driver: important → x265, regular → NVENC, mirrored outputs; `-Parallel` runs both tiers at once |
| `confirm_quick.ps1` | Coverage check: counterpart exists, frames/duration/orientation match, audio bit-identical |
| `confirm_deep.ps1` | Pre-delete check: full verify incl. VMAF + chroma gates + reviewable screenshot pairs |
| `ui.ps1` / `LaunchUI.bat` | WPF front-end: tier lists, safe copy-in, launchers, click-to-play, review viewer |
