# Module 01 Court

**Verdict command** (exit 0 = PASS, exit 1 = FAIL), from the curriculum root
`/Users/sac/smalt/docs/dmedi-bb-curriculum`:

```bash
python3 modules/01-intro-dmedi/courts/court.py
```

## What the court checks (fail-closed)

1. **Dataset re-derivation** from `data/baseline-bore-diameter.csv` (50 runs):
   n 50; mu 12.00859 mm; s 5.82 um; USL gap 16.41 um; LSL gap 33.59 um;
   sample Cpk 0.9401; USL governs. These are the numbers the slides-outline
   keyed exercise, solution-key, and lab all cite.
2. **Pinned-pair arithmetic** (adjudicated 2026-11-04): (12.025 - 12.009) /
   (3 x 0.007407) = 0.72 exactly to 4 dp; z_usl 2.16, z_lsl 4.59; and a
   negative check proving the STALE 4.17 um sigma does NOT produce 0.72
   (it produces 1.279).
3. **Staleness sweep**: no module-01 artifact may carry "4.17" except inside a
   stale/adjudicated/contradiction framing (the honest-flag teaching note).
   An unframed 4.17 fails the court.
4. **Receipt grammar**: the five receipt fields (identity, authority,
   consequence, replay, standing) must appear in the slides outline — the
   zero-artifacts case study (Slide 5) is the reason this module, alone,
   courts its own vocabulary.

## Non-vacuity (mutation probes, each exits 1)

- Change any bore value in the CSV → mu/s/Cpk checks fail.
- Edit the pinned sigma to 4.17 in the pinned-pair block → pinned_cpk fails.
- Add an unframed "4.17" sentence to any module-01 file → staleness sweep fails.
- Delete a receipt field from the slides → receipt-grammar fails.

## The honesty case this court encodes

Slide 5's zero-artifacts precedent: a program receipted SUCCESS at its final
gate with zero implementable artifacts on disk, because every intermediate gate
was passed by narration and no check in the ladder could exit nonzero. This
court exists so module 01 cannot do the same: every number above re-derives
from raw data, and the command at the top can exit 1.
