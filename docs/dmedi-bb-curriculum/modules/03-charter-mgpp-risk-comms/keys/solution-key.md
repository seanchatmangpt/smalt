# Module 03 — Solution Key

All numbers python3-derived from this module's CSVs; constants cited from the
pinned files named in each answer. Receipts at the end.

## Re-derivation script (verbatim)

```python
import csv, statistics as st

# ---- ED door-to-provider ----
ed = list(csv.DictReader(open('modules/03-charter-mgpp-risk-comms/data/ed-door-to-provider-minutes.csv')))
t = [float(r['door_to_provider_min']) for r in ed]
over30 = sum(1 for v in t if v > 30)
print('ED n', len(t), 'mean', round(st.mean(t), 1), 'median', round(st.median(t), 1),
      'sd', round(st.stdev(t), 1), 'min', min(t), 'max', max(t))
print('over 30 min:', over30, f'({100 * over30 / len(t):.1f}%)')

# ---- Insurance claims cycle time ----
cl = list(csv.DictReader(open('modules/03-charter-mgpp-risk-comms/data/insurance-claims-cycle-time.csv')))
cyc = [float(r['cycle_time_days']) for r in cl if r['cycle_time_days'].strip()]
blank_closed = sum(1 for r in cl if not r['closed_date'].strip())
print('claims rows', len(cl), 'with cycle time', len(cyc),
      'blank closed_date', blank_closed)
print('mean', round(st.mean(cyc), 2), 'median', round(st.median(cyc), 2),
      'sd', round(st.stdev(cyc), 2), 'max', max(cyc))
```

## Verified output (python3, exit 0)

```
ED n 80 mean 53.1 median 52.0 sd 16.5 min 9.0 max 97.0
over 30 min: 75 (93.8%)
claims rows 60 with cycle time 60 blank closed_date 60
mean 16.07 median 15.8 sd 4.88 max 26.6
```

## Keyed answers

1. Median **52.0 min**, sd **16.5 min**, **75/80 = 93.8%** over 30 min. Problem
   statement: "Door-to-provider time has a median of 52.0 minutes against a
   30-minute standard; 93.8% of sampled ED visits breach the standard (n = 80)."
   Every clause is checkable against the CSV.
2. Mean **16.07 d**, median **15.8 d**, sd **4.88 d**. Auditable fraction against
   a closed timestamp: **0/60** — `closed_date` is blank on every row. Standing
   of the number: UNVERIFIED as evidence (the metric is computed somewhere
   upstream, but no line in this file can be replayed against its own
   timestamps). Lawful charter response: a data-quality action row with an owner
   and a gate date, not a quoted baseline.
3. With mu = 12.009 mm and sigma = 7.407 um (RUNNING-CASE adjudicated pair):
   distance to USL = 12.025 - 12.009 = 0.016 mm = 2.16 sigma
   (0.016 / 0.007407); distance to LSL = 12.009 - 11.975 = 0.034 mm = 4.59 sigma
   (0.034 / 0.007407). **USL is the 2.16-sigma side; LSL is the 4.59-sigma
   side.** The upper limit binds, which is why the Cpk 0.72 baseline is an
   upper-tail problem (drift toward oversize) and why Module 09's USL-tail
   arithmetic (2.01e-2) is the escape driver. Round 4.59 to 4.60 only in prose;
   the derivation shows 4.59.
4. CTQ-2 trace: **Y** = order-to-ship lead time (baseline median 17.35 d,
   target <= 7 d). **OD** = OD-11 (CNC cycle timer, mean min/unit, op10+op20)
   or the order-level lead-time OD behind Module 02's CSV; name the one you
   use. **Candidate x's**: changeover duration (OD-13, clocked SMED sheet) and
   QC hold time (OD-9, first-article-submit to disposition). Both are upstream,
   measurable, and ownable — the definition of a scopeable x.
5. Model register (scores = L x I; any consistent scale is lawful, this is the
   keyed one):
   - Gauge drift on the bore gauge invalidates Cpk trend — L4 x I5 = **20**;
     mitigation: DC-02b gauge R&R gate (Module 27 CP-3); owner: quality eng.
   - Claims-class data integrity: a Define-phase metric cannot be replayed from
     its timestamps — L3 x I4 = **12**; mitigation: OD re-pin from ERP logs
     before W5; owner: ERP data steward.
   - Pilot data arrives late to the W21 gate — L2 x I4 = **8**; mitigation:
     Module 42 pilot schedule pulled into W19 buffer week; owner: program mgr.
   Lawful to vary risks and scores; not lawful to omit owners or scores.
6. The abandoned pin is **Cpk >= 1.33 sustained 30 days** — the Develop-gate
   capability work is what an 8-week cut removes (the cost and delivery legs
   have W15/W26 deliverables that survive a W15 stop only partially; the quality
   leg has no W15 substitute). Cost implication: the cut happens while the line
   still runs at $41.80/unit, so every unit shipped during the deferred window
   burns $13.30 of margin against the $28.50 ceiling — the gap is the per-unit
   price of the delay, and the register's cost row (Module 06) converts it to a
   program-level number using planned volume.

## Receipts

- Command: `python3 - <<'EOF' ... EOF` with the script above, run from
  `/Users/sac/smalt/docs/dmedi-bb-curriculum` — exit 0; the output block above
  is the captured result (2026-11-04 session).
- Pinned constants consumed (files cited, not re-derived):
  - $28.50 = $30.00 x (1 - 5% ROS), gap $13.30 — `modules/06-target-costing/
    README.md` and `courts/court.py` (Lane 03 constants; run, not edited).
  - Cpk 0.72 baseline, 1.33 target, mu 12.009, sigma 7.407 um — RUNNING-CASE.md
    adjudicated block (2026-11-04).
  - OD-1..OD-15 and CTQ->Y->x/gate weeks — `modules/07-scorecards/worksheets/
    02-operational-definitions.md` and `05-mgpp-traceability.md`.
