# Module 26 — Exercises: DFMEA (anchored scales)

Work from `data/dfmea-worksheet.csv` and the anchored scale tables in
`scales-anchored.md`. Every rating you assign must be classified against
an anchor (observable outcome, PPM band, or named control) — no
"7 = customer dissatisfied" generic scoring. Verify every computed value
with `python3 scripts/derive_keys.py` (the court re-derives all 12 RPNs,
ranks, and AP classes from the worksheet; exit 0 = 109 checks green).

## E1. Anchor or refuse (written, ~10 min)

A teammate rates a new failure mode "severity 7" and cites only the
generic phrase "major customer dissatisfaction." Using ONLY the anchored
severity table in `scales-anchored.md`, state whether severity 7 is a
lawful rating for that justification and what evidence the rater must
supply instead (the CPPC-specific observable outcome the anchor names).
Then do the same for an occurrence rating of 4 justified as "occasional"
and a detection rating of 4 justified as "moderate detection."

## E2. FM-01 defense (code + written, ~10 min)

FM-01 (progressive tool wear, bore oversize) is pinned by the court at
severity 10, RPN pre-action 360 (10/6/6) — rank 1 of 12. Answer:

1. Why can no detection action de-escalate FM-01 below AP High?
   (Re-read the post-action law: severity never improves without a
   design change, and S=10 never de-escalates.)
2. The pre-action detection control is end-of-line CMM sample n=3/shift
   (D6). Re-rate it as if the AE tool monitor + in-process gauge with
   auto offset (D3, the post-action control) had been in place
   pre-action. Recompute RPN (10/6/3 = 180). Does FM-01 stay rank 1?
   (Verify against the court's ranking; the court must still exit 0 on
   the unmodified worksheet — you are reasoning on a copy, not editing
   the registered CSV.)
3. The action DC-01 spends the C6 acoustic-emission monitor + C1
   compensated gauge on O 6→3 and D 6→3, moving RPN 360→90. Compute
   the percent reduction (75%). Is RPN reduction the right success
   measure here, given AP stays High?

## E3. RPN-vs-AP split (code + written, ~10 min)

The court pins the computed split: FM-09 (S=4, RPN 224) outranks FM-05
(S=9, RPN 216) under pure RPN while the AP table puts FM-05 at High and
FM-09 at Medium. Write a short routing memo: which mode gets the next
action budget under (a) RPN-only ranking and (b) AP-first ranking, and
why the module teaches AP-first for severity-carrying modes (S=9
tool breakage scores the bore and likely scraps the part; S=4 burrs are
reworkable). State the one worksheet column that encodes this choice.

## E4. Court-fence exercise (code, ~10 min)

The court (`scripts/derive_keys.py`, 109 checks) re-derives every value
from the raw CSV — the key is a projection, never the authority. On a
COPY of the worksheet, make each mutation below and run the court on
the copy; predict the failure first:

1. FM-01 severity 10 → 9 (RPN 360 → 324): which checks fail first?
   (This is exactly the mutation `court.py` runs as its non-vacuity
   gate — it must exit 1 on the mutation and restore byte-exact.)
2. FM-05 detection_pre 8 → 3: which post-action law breaks?
3. Swap the ranks of FM-09 and FM-05 in a re-derived ranking without
   changing any rating: why is this mutation impossible to make stick?
   (Ranks are derived, not stored.)

After each mutation on your copy, restore byte-exact (the registered
CSV is checksummed in `datasets/MANIFEST.md`; sha256
`6ffde1dbd447...`) and confirm `python3 court.py` exits 0 with the
mutation court line "FM-01 severity 10->9 flipped exit 1".

## E5. Forward links (written, ~10 min)

1. DC-01..DC-12 trace to Lane 06 TRIZ concepts (C1-C8, with C8/C4
   parked with stated feasibility). For FM-10 (thermal growth), the
   action is C7 thermal-error model + offset with C4 cryo cooling
   PARKED (feasibility 2). Write the gate-review sentence for why the
   parked concept is documented rather than dropped.
2. FM-11's DOE factor is coolant concentration — the DOE factor itself.
   Name the pinned DOE factors the worksheet forwards to (spindle
   speed, feed, coolant %, coating) and which failure modes motivated
   each.
3. FM-12 is flagged as the PFMEA boundary: explain in two sentences why
   a wrong-program/offset failure is a process failure mode, not a
   design failure mode, and what changes when it moves to the PFMEA.
