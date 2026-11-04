# Module 34 scripts/ — provenance note

This directory intentionally holds no generator script. Module 34's dataset
(`data/gate-review-waits.csv`) and every solution-key number are re-derived by
the module court, `../courts/court.py` (exit 0 = 16/16 checks; see
`../keys/solution-key.md`, "all numbers python3-re-derived").

No seed is stated for this module because there is no RNG generator to pin:
the CSV is an authored 26-week program schedule, not a sampled dataset.
