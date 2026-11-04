# Module 35 Lab — DFMA the Gimbal Assembly

**Data**: `data/gimbal-teardown.csv` (authored teardown census; times are Boothroyd-Dewhurst-
style handling + insertion scores in seconds; no RNG).
**Deliverable**: receipt with all counts/seconds/dollars re-derived via `python3 courts/court.py`.

## Part 1 — Baseline teardown
1. Total part count before (sum qty_before).
2. Total assembly time before (sum qty x (handle + insert)).
3. Which single row carries the largest assembly-time share? Compute that share %.

## Part 2 — After-design
4. Total part count and assembly time after.
5. Part-count reduction % and assembly-time reduction % (net of the merged part's added time).

## Part 3 — Move-by-move quantification
6. For each of the three consolidation moves (fastener elimination, bracket merge,
   self-locating feature), compute: parts saved, gross seconds saved, net seconds saved.
7. Verify the three nets sum to the total assembly-time reduction.

## Part 4 — Cost roll-up (loaded labor $84/h)
8. Assembly labor before/after/saving.
9. Material saving (use unit_material_cost_before; merged part costs $4.60).
10. Total saving; as % of Lane 03's $13.30 unit-cost gap; residual amount and where it must
    come from.

## Part 5 — Theoretical minimum
11. Apply the three DFA minimum-part criteria (relative motion; different material; must be
    separate for service/disposal) to the after-design. State the minimum count and list the
    parts that qualify. Which surviving parts fail the criteria and are therefore residual
    DFMA targets?
