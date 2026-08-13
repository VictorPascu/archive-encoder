# Encoded outputs land here

`run_encode.ps1` writes encoded videos into this folder, mirroring whatever
structure you used under `sources/`:

```
encoded_outputs/
  important/...   <- x265 slow CRF 22 versions of sources/important/...
  regular/...     <- NVENC HEVC q30 versions of sources/regular/...
  manifest.csv    <- per-file ledger (see below)
  manifest.log    <- timestamped run log, appended as encoding progresses
  _review/        <- screenshot pairs written by confirm_deep.ps1
```

Filenames and file dates match the sources, so both trees sort identically.
A `*.part.mp4` here is a file mid-encode - it's renamed to its final name only
after passing a frame-count check, so anything without `.part` is complete.

## Verifying (run from the repo root)

| | `confirm_quick.ps1` | `confirm_deep.ps1` |
|---|---|---|
| Takes | seconds per file | minutes per file |
| Checks | every source has a counterpart; frame count, duration, orientation match; **audio bit-identical** | all of quick, plus: full decode, VMAF quality gates (mean ≥ 95 / 1%-low ≥ 92), and screenshot pairs saved to `_review/` with SSIM scores |
| Use it | after any encode run, or anytime | **before deciding you no longer need the raws** |

Quick PASS = coverage is complete and nothing is structurally wrong.
Deep PASS = every output is a measured, visually-lossless stand-in for its
source - and `_review/` holds side-by-side frames so you can see it yourself.
Deleting raws is always your manual action; no script here touches sources.

## The manifest

`manifest.csv` - one row per file, merged across runs (a re-run updates rows
rather than duplicating them):

| Column | Meaning |
|---|---|
| `run_started` | when the run that produced this row began |
| `tier` / `relpath` / `name` | which tier and mirrored path the file belongs to |
| `status` | `OK`, `SKIPPED_EXISTING` (already done - resume), or a failure kind |
| `src_bytes` / `out_bytes` / `ratio` | size before / after / shrink factor |
| `enc_fps` | encode throughput for that file |

`confirm-quick.csv` and `confirm-deep.csv` land here too, recording the latest
verification verdicts per file.
