# Module 44 Court — exit-checked self-verification

Run from the curriculum root: `python3 modules/44-implementation-planning/court.py`
(exit 0 = roadmap arithmetic proven, handoff checklist items exist on disk, training/audit registers complete).

The court checks, and refuses on any failure:
1. Roadmap week arithmetic: pilot starts week-16 day 4 and ends week 20.8 (16.5 + 30/7 = 20.8 ≤ gate 21; counterfactual week-17 start = 21.29, which misses the gate — the court proves both); phases cover weeks 16–26 with no gaps/overlaps; boundaries land on gate weeks 21/26.
2. Handoff checklist existence: every one of the 7 items must EXIST as an artifact on disk (Module 42/43/44 keys and labs, Module 11 MSA dir). A missing item names the gap and exits 1 — the refusal law enforced mechanically.
3. Training register arithmetic: 12+3+3+1+1 = 20 role slots.
4. Cross-module numbers: replay of the Module 42 and Module 43 courts must exit 0 (subprocess, real re-derivation).
5. Non-vacuity mutation: removing a checklist artifact from the existence check must be detectable (the check counts 7, not fewer).
