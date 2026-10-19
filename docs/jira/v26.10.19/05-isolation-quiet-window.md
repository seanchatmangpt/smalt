# V261019-05 — Isolation runtime5 quiet-window rerun

- **Release:** v26.10.19
- **Lane:** isolation-court
- **Base:** HEAD `502c4ed`
- **Status:** ready-for-work (blocked on a quiet window — `just quiesce` precondition)
- **Source WO:** `docs/jira/v26.10.19/WORK_ORDERS.md` WO-5

## Objective

Land the quiet-window falsifier for the runtime5 isolation court. Standing is
**PARTIAL_ALIVE — quiet-run falsifier OPEN** per
`docs/jira/v26.10.18/receipts/i29-isolation-runtime5.md`: machine load was
22–28 during the run, so the residual is load-shaped, not behavior-shaped. The
fix is mechanical: re-run `python3 scripts/isolation_court.py --runtime-only`
under `just quiesce` discipline (quiet window; `just quiet-check` precondition
per the receipt-context law — `justfile.d/24-quiesce.just` encodes the v26.10.17
r240 lesson that cold-run load faces are mechanical, hence the
quiet-check → warm-up → quiet-check sequence).

## Files owned

- `docs/jira/v26.10.19/receipts/isolation-runtime5-quiet.md` (new receipt; no
  code changes expected — this WO is a rerun, not a repair)
- Register row flip (isolation runtime5 row → falsifier landed) on receipt
- Carry-item: the typed-expiry note in
  `docs/jira/v26.10.18/receipts/i29-isolation-runtime5.md`
  §"settle_snapshot/2 deadline path silent" — flagged for the owning lane;
  picked up here ONLY if that lane does not close it

## Tasks

### T1 — precondition: establish the quiet window

1. `just quiet-check` (`python3 scripts/quiet_check.py`) exits 0 — no stray
   beams, court ports free, no concurrent suites/courts.
2. `just quiesce` (quiet-check + warm-up full offline suite absorbing
   cold-compile/profile noise + quiet-check again) — mandatory because the
   prior run's residual is load-shaped; a court run on a busy box re-produces
   the same PARTIAL_ALIVE.

### T2 — the rerun

1. `python3 scripts/isolation_court.py --runtime-only` under the settled
   window (the `--runtime-only` flag is a real
   `isolation_court.py:381` argument — the same shape that produced the
   i29 receipt).
2. Capture full output into the receipt file with load context (the
   quiet-check passing state immediately prior).

### T3 — falsifier disposition + register flip

1. Quiet-window run counts 0 → the falsifier lands; flip the register row
   PARTIAL_ALIVE → CLOSED (receipt-gated).
2. Quiet-window run does NOT count 0 → the residual is NOT load-shaped; the
   PARTIAL_ALIVE stands with a new, behavior-shaped evidence line and the
   register row stays open (this is a real result, not a lane failure).
3. Secondary (only if the owning lane is silent): triage the
   `settle_snapshot/2` deadline-path silence per the i29 receipt's typed-expiry
   note — determine whether the deadline branch returns without a typed expiry
   verdict, and either file it to the owning lane or take it as a carry item.

## Acceptance falsifiers

- [ ] Receipt cites a `just quiet-check` exit 0 immediately before the
      `--runtime-only` run (a rerun without the precondition is INVALID and
      does not flip anything — reproduce the 22–28 load and the court count
      rises: that contrast is the falsifier that load was the residual).
- [ ] Register row flips ONLY on a receipt whose run counts 0; any non-zero
      quiet-window count leaves the row open with the new evidence attached.
- [ ] The typed-expiry carry item is either closed by the owning lane or
      explicitly tracked — it must not silently vanish from the register.
- [ ] No code changes land under this WO unless T3.3 triggers; if code changes
      land, they get their own WO/receipt, not a rider on this one.
