# Testing & trust

The pipeline's claims are only as good as the instruments that check them, so
the instruments are themselves tested — including proof that they can FAIL.

## Run after any change, or on any new machine

```powershell
.\tests\run_tests.ps1        # video e2e: builds tiny synthetic clips in a temp
                             # sandbox, runs the drop-folder flow + both confirms,
                             # asserts the right engine ran per tier and that
                             # sources are byte-identical afterward (~1 min)
.\tests\run_image_tests.ps1  # image e2e: lossless pixel-identity, kept-copy
                             # SHA-256, gated lossy, nested mirroring
.\tests\smoke_test.ps1       # 41 component checks: probing, all 3 encoders,
                             # mux, audio hashing, VMAF (incl. model override),
                             # filter-path escaping, write guards
.\tests\neg_control.ps1      # the important one -- see below
.\video\ui.ps1 -SelfTest     # headless UI checks: row building, play-target
                             # resolution, staged copy-in, XAML + controls
```

All suites sandbox themselves under `%TEMP%`, clean up after themselves, and
never touch real sources.

## The negative control

A verifier that has only ever said PASS proves nothing. `neg_control.ps1`
builds five deliberately defective encodes and asserts the verifier catches
each **by name**:

| Planted defect | Must be caught as |
|---|---|
| Crushed quality (CQ 51, starved bitrate) | `vmaf` |
| Audio silently re-encoded to 128k | `audio_not_identical` |
| Rotation matrix stripped without transposing | `orientation` |
| Truncated to 2 s | `frames` + `duration` |
| Desaturated 30% (passes VMAF at 97.99!) | `chroma_ssim` |

Any change to the verifier must keep this scorecard at 5/5. The control has
already earned its keep twice: it exposed a mis-designed rotation test during
development, and the desaturation case exists because VMAF provably cannot see
color damage on its own.

## Reading the results

Every suite prints PASS/FAIL per assertion and exits non-zero on any failure.
The e2e suites accept `-KeepSandbox` to preserve the temp tree for inspection
when something goes wrong.
