# Module 03 Court

**Verdict command** (exit 0 = PASS, exit 1 = FAIL), from the curriculum root
`/Users/sac/smalt/docs/dmedi-bb-curriculum`:

```bash
python3 modules/03-charter-mgpp-risk-comms/courts/court.py
```

## What the court checks (fail-closed, 28 checks)

1. **ED dataset** (`data/ed-door-to-provider-minutes.csv`): n 80; mean 53.1;
   median 52.0; sd 16.5; min 9; max 97; 75/80 = 93.8% over the 30-minute
   standard. These are the worksheet 04 charter numbers.
2. **Claims dataset** (`data/insurance-claims-cycle-time.csv`): 60 rows, all 60
   with cycle time, all 60 `closed_date` blank; mean 16.07; median 15.8;
   sd 4.88; max 26.6. These are the worksheet 03 UNVERIFIED-standing numbers.
3. **Pinned-constant arithmetic** cited in the filled charters: USL/LSL
   distances 2.16 / 4.59 sigma (adjudicated pair mu 12.009, sigma 7.407 um);
   allowable $30.00 x 0.95 = $28.50; gap $13.30; MGPP legs $13.30 x 10,000 =
   $133,000/yr and $11,083/month.
4. **Risk-register arithmetic** (worksheet 06): L x I scores for R1-R5 and the
   derived rank order R1 > R2 > R5 > R4 > R3 (the first draft's prose rank was
   wrong; the court caught it and the worksheet was corrected).
5. **Placeholder sweep**: no TBD/TODO/FIXME/XXX/Lorem in any module .md.

## Non-vacuity (mutation probes, each exits 1)

- Change any ED minute value → ED stats fail.
- Fill one `closed_date` → claims_blank_closed fails (and the teaching case's
  60/60 claim becomes false — that is intended).
- Change any risk's L or I in the court's table → score/rank fails; change the
  worksheet prose rank → rank check fails.
- Add a "TBD" to a worksheet → placeholder sweep fails.
