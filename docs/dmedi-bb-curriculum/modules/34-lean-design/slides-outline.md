# Module 34 — Lean Design: Flow Applied to Development (Slides Outline)

**Module**: 34-lean-design
## Learning objectives

After this module the candidate can:
1. Apply flow principles (takt, pull, small batches, WIP limits) to a DEVELOPMENT process, using
   the CPPC DMEDI program itself as the process under analysis.
2. Build a text-form "program VSM" of the 26-week DMEDI program and compute its flow efficiency.
3. Run a gate-review wait analysis: quantify the wait embedded in each of the 5 gate reviews.
4. Use a design-for-flow checklist to convert wait findings into program-design changes.
5. Quantify the calendar saved by a redesigned gate cadence.

**Timing estimate**: 3.5 h (slides 1.0 h, lab 1.0 h, exercises 1.0 h, court 0.5 h).

---

## Slide 1 — The DMEDI program is a process too (10 min)
- Module 33 analyzed the PRODUCT stream (order-to-ship). This module turns the same lens on the
  PROGRAM that designs the line: the 26-week DMEDI program with gates at weeks 5/9/15/21/26.
- Same law applies: calendar = work + internal wait + gate wait. Development is not exempt from
  queue math.

## Slide 2 — The program VSM, in text form (20 min)
From `data/gate-review-waits.csv` (130 working days = 26 weeks x 5):

```
Define(18d work, 4d wait) --3d gate--> Measure(14d, 3d) --3d gate--> Explore(22d, 5d)
--3d gate--> Develop(21d, 6d) --3d gate--> Implement(17d, 5d) --3d gate--> Sustain
```
- Totals: work 92 d, internal wait 23 d, gate wait 15 d -> 130 d (checks exactly).

## Slide 3 — Flow efficiency of the program (15 min)
- Flow efficiency = 92/130 = **70.8%**. Better than the product stream's 4.2%, but the wait
  terms (38 d = 29% of the program) are still 10 working weeks of idle calendar.
- Gate wait is 15 d = 11.5% of the program: five gates x 3 d average wait for the scheduled
  review slot. This wait buys NOTHING — the package is done; the calendar is the queue.

## Slide 4 — Why development queues form (20 min)
1. Batch reviews: packages accumulate until the monthly/phase-end review (batch = queue).
2. Decision latency: unreviewed packages block the next phase (dependency WIP).
3. Rework loops: a failed gate re-opens the phase (like the Op50->Op20 defect loop).
4. Resource unknowns: SME availability is development's "machine downtime".
- Lean-design countermeasures: single-piece gate packages (review when ready), WIP limit on
  open work packages, decision SLA (e.g. 1 working day), small pilot batches in Implement.

## Slide 5 — Design-for-flow checklist (15 min)
1. Can the phase output be a single-piece package instead of a batch?
2. Is every dependency queue visible (name, count, age)?
3. Does every wait have a named owner and a decision SLA?
4. Is rework bounded (gate fail -> scoped fix, not phase re-open)?
5. Does cadence match takt of decisions (weekly) rather than calendar convenience (monthly)?
6. Is WIP capped per lane? (Fan-out lanes are WIP; unowned lanes are queues.)

## Slide 6 — The redesigned program (15 min)
- Scenario F (taught in lab): gate wait 3 -> 1 d (review-when-ready), internal waits cut
  4->2, 3->1, 5->2, 6->3, 5->2 (WIP limits + visible queues).
- New totals: work 92 d + wait 10 d + gate 5 d = 107 d = 21.4 weeks -> **23 working days
  (4.6 weeks) of calendar saved** with zero additional engineering effort.
- Teaching point: the program finishes 23 days earlier without one extra hour of work content.
