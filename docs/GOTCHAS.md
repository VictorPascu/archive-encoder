# Hard-won gotchas

Each of these cost real hours during development against real footage. They are
encoded into the pipeline; this ledger exists so they never get re-discovered.

1. **libvmaf pairs frames by TIMESTAMP, not index — the big one.** On VFR
   phone footage the encode's timestamps drift sub-frame vs the source until
   framesync slips one frame, and every later comparison is against the wrong
   reference. Symptom: VMAF collapses partway through (a perfect file scored
   mean 40 / 1%-low 8), N+1 frame pairs from N-frame inputs, bitrate-independent
   "quality floors". Fix (in `Invoke-Vmaf`): rewrite both sides' PTS to the frame
   ordinal — `settb=1/1000,setpts=N`. Control: source-vs-itself must score 100.00.
2. **PowerShell 5.1 + `$ErrorActionPreference='Stop'` kills scripts when a native
   exe writes to stderr** — and x265/NVENC print banners to stderr on success.
   All native calls must go through `Invoke-FFmpegCapture` / `Invoke-FFprobeJson`.
   (Related: `Out-String` wraps at console width, silently splitting long log
   lines mid-regex — capture with an explicit large `-Width`.)
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
11. **WebP cannot carry an ICC profile**, and phones tag photos Display-P3 —
    stripping the profile visibly desaturates in color-managed viewers while
    SSIM stays ~0.99. Caught by human eyes, not metrics. The image flow probes
    every file and gamut-maps P3 → sRGB in the lossy tier (copying instead of
    converting in the lossless tier); see `images/README.md`.
12. **VMAF is luma-dominant** — a 30% desaturation scored VMAF 97.99, passing
    both gates. The verifier therefore also computes per-plane chroma SSIM
    (same index pairing as #1), with the desaturation planted as a permanent
    negative-control case.
