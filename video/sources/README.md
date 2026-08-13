# Drop your videos here

| Folder | For | Encoded with | Speed |
|---|---|---|---|
| `sources/important/` | Videos you want kept at the **highest quality** - irreplaceable stuff | x265 slow CRF 22 (CPU) | ~4–8 fps on 4K (slow - think overnight) |
| `sources/regular/` | Everything you just want **bulk-optimized** | NVENC HEVC q30 (GPU) | ~30 fps on 4K (~5× faster) |

Subfolders are fine - the structure is mirrored into `encoded_outputs/`.

Then, from the repo root:

```powershell
.\run_encode.ps1              # encode both tiers (resumable - re-run anytime)
.\run_encode.ps1 -Parallel    # CPU tier + GPU tier at the same time

.\confirm_quick.ps1           # fast: everything encoded? frames/duration/audio identical?
.\confirm_deep.ps1            # slow: full decode + VMAF gates + screenshot pairs to eyeball
```

**The goal:** when `confirm_deep.ps1` says PASS, every video in `sources/` has a
verified, visually-lossless encode in `encoded_outputs/`, and you can make an
informed decision about the originals. (Deleting them is *your* action - no script
here will ever touch a source file.)

Progress is tracked in `encoded_outputs/manifest.csv` and `manifest.log`.
