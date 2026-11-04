# Module 02 Court

**Verdict command** (exit 0 = PASS, exit 1 = FAIL), from the curriculum root
`/Users/sac/smalt/docs/dmedi-bb-curriculum`:

```bash
python3 modules/02-define-overview/courts/court.py
```

## What the court checks (fail-closed, 20 checks)

1. **CTQ-1 DPMO ladder** from `data/bore-inspection-dpmo.csv`: 20 days,
   4,048 units, 49 defects; DPU 0.01210; DPMO(1 opp) 12,104.7; DPMO(6 opp)
   2,017.5; DPO 0.0020175; z 2.875; sigma level 4.38 (6 opp) and 3.75 (1 opp).
2. **CTQ-2 lead time** from `data/order-lead-time.csv`: n 40; mean 17.8;
   median 17.35; sd 4.35; min 9.1; max 26.3; P90 24.1; over-target 40/40
   (100.0%); SE of the mean 0.69 (the sampling-noise explanation for
   17.8 vs the pinned 18.4).

## Drift caught by this court (2026-11-04)

The first court run FAILED on `z_3dp` and `sigma_level_1opp`: the README and
solution-key carried z 2.878 / 3.76 where the re-derivation gives 2.875 / 3.75.
Fixed in the source docs; the court keeps the check so the drift cannot return.

## Non-vacuity (mutation probes, each exits 1)

- Change any `defects_found` value → defects/DPU/DPMO ladder fails.
- Change any `lead_time_days` value → median/P90/%-over fails.
- Change the opportunities constant 6 → DPMO_6opp and both sigma levels fail.
