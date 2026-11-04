# Module 43 Court — exit-checked self-verification

Run from the curriculum root: `python3 modules/43-process-control/court.py`
(exit 0 = every control-plan number re-derives from the Module 42 pilot data; exit 1 = mismatch).
The court re-derives: X-bar/R limits (A2/D3/D4 arithmetic), sigma-hat via d2 = 2.326, PCR,
p-chart limits, the day-1 rule-1 signal decision, and a vacuity mutation — it recomputes the
limits with the WRONG constant set (n=4 constants) and requires the check to detect the
difference (a court that cannot fail is refused).
