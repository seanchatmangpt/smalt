# ATTEMPT5-PROTOCOL — court-x2 attempt 5 gate discipline (v26.10.18 opening move)

Standing: ADOPTED (protocol; binding for every future court-x2 attempt)
Window: v26.10.17 (carried to v26.10.18 via WO-2 / NEXT_WINDOW WO-A)
Precedent chain: [r240](receipts/r240-court-x2-attempts12-typed-red.md) →
[r241](receipts/r241-court-x2-attempt3-typed-red.md) →
[r246](receipts/r246-attempt4-invalid-typed-red.md)

Purpose: attempt 4 (r246) was voided as two-green evidence not because either
leg failed but because the tree **changed between the legs** — the coordinator
landed `test/amqp/management_rpc_test.exs` (`async: true` → `false`,
receipts/i21d-store-clear-async.md) after run 1 and before run 2, so leg 1 and
leg 2 executed different trees and the gate's fresh-subject premise was
violated. This is the r246 invalidation class. The five rules below are the
mechanical checklist that makes that class unreachable.

The binding object of every rule is the interval `[court_x2.sh start →
COURT_X2_RC read]` — the gate window. Outside the gate window the normal lane
rules apply; inside it, the rules below are absolute.

---

## Rule 1 — FREEZE: zero tree writes inside the gate window

**Rule.** From `court_x2.sh` start until `COURT_X2_RC` is read, ZERO writes to
the working tree by anyone — coordinator, lanes, hooks, agents. All receipts
landed and committed BEFORE the gate. The coordinator touches nothing: no doc
edits, no receipt writes, no regenerations, no `mix format`, nothing under
`lib/`, `test/`, `docs/`, `config/`. A single pre-gate commit SHA is recorded
in the protocol run log (`tmp/attempt5-run-log.md`, created at gate start)
before `court_x2.sh` is invoked:

```
PRE-GATE-COMMIT: <sha>   (git status must be clean of tracked changes at record time)
GATE-START: <iso8601>
```

**Motivating witness — r246.** Attempt 4: the tree was edited between the two
legs (`management_rpc_test.exs` async flip, receipts/i21d-store-clear-async.md),
so the legs ran different subjects. The gate is a fresh-subject instrument: two
green legs on different trees prove nothing about either tree. r246 §"Why
attempt 4 is invalid": "The two-green claim would be unsound even if both legs
had passed." A single edit voids a ~14-minute gate; the SHA record makes the
violation mechanically detectable after the fact (post-gate
`git rev-parse HEAD` must equal the recorded SHA).

**Mechanics.**

- Land + commit everything before the gate; `git status --porcelain` clean of
  tracked changes (untracked scratch under `tmp/` is exempt — the court does
  not read `tmp/`).
- Post-gate: `git rev-parse HEAD` == recorded SHA, else the attempt is
  TYPED-INVALID regardless of RC (same disposition as r246).
- If a lane must land mid-gate: it does not. It queues and lands after
  `COURT_X2_RC` is read. No exceptions, including "it's only a test file" —
  r246's voiding edit was exactly a test file.

## Rule 2 — Warm-up in the court's OWN build root (default `_build`)

**Rule.** The warm-up leg absorbs cold-compile/profile noise, but only if the
court legs then compile warm — which requires the warm-up to run in the SAME
build root the court will use (`_build`), not a throwaway root. Patch to
[justfile.d/24-quiesce.just](../../../justfile.d/24-quiesce.just)
`quiesce-warm`:

```just
@quiesce-warm:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "[QUIESCE] warm-up: full offline suite pass (absorbs cold run-1 load faces)"
    # Warm the COURT's build root — a throwaway root warms itself, not the court.
    MIX_BUILD_ROOT="${MIX_BUILD_ROOT:-_build}" mix test 2>&1 | tail -2
    just quiet-check
    echo "[QUIESCE] machine settled — clear for court-x2"
```

(`rm -rf _build-warmup` is dropped; the fresh-test law is kept via `just
quiet-check` after the warm-up — a dirty tree still blocks the gate.)

**Motivating witness — r240 attempts 1-2.** The structure was constant: cold
run 1 trips one load face (attempt 1: `affidavit_wasm_failclosed_test.exs:502`
restart hammer + sdk-smoke watchdog exit 124; attempt 2:
`egress_dispatch_test.exs:1221`), warm run 2 green. The v26.10.17 quiesce
target (receipts r240 disposition) encoded a warm-up, but as written it warmed
`_build-warmup` and then DELETED it — the court legs still compiled cold in
`_build`, reproducing exactly the cold-run-1 class the warm-up exists to
prevent. A warm-up that warms a different root than the gate is a no-op against
the failure it targets. Warm in `_build`, and the court legs' compile cost is
already paid, removing the load face the cold compile adds to run 1.

## Rule 3 — Typed waiver for foreign noncontending beams

**Rule.** `scripts/quiet_check.py` may veto on a foreign beam. A waiver is
permitted only as a TYPED record with ALL of: private-port-only listener (no
court ports — 9443/8443/9444/5672/5673/9545), idle process (no CPU), and an
identified parent (live agent session or named owner). The waiver line is
written to `tmp/` and cited in the attempt receipt chain. Template:

```
WAIVER: foreign-checkout beam pid <pid> (checkout <name>, parent=<identified parent>),
private port <port> only, no court ports, idle <n>min — noncontending;
quiet-check cwd veto waived (typed, this receipt chain)
```

**Motivating witness — attempt 4's warm-up leg 0.** r246's warm-up pass (2655
tests, 0 failures, 406.7s) ran under
`tmp/quiet-waiver-attempt4.txt`: a foreign ex4pm beam, pid 32927, private port
49895 only, idle 80 min, parent = live agent session — noncontending by every
court-relevant measure. The unwaived quiet-check cwd veto would have blocked a
legitimate run over a provably noncontending process. Without the typed form,
waivers drift toward silent skips; the typed record keeps the skip loud
(CLAUDE.md: "a skip is loud, never a fake pass"). A beam touching any court
port, or busy, or with an unidentified parent is NOT waivable — it is a stop
signal (kill via `scripts/port_sweep.sh -y` or wait, then re-check).

## Rule 4 — Failure-set diff read within 60s of RC

**Rule.** Within 60 seconds of reading `COURT_X2_RC`, read the failure-set
diff section of the gate log (court_x2.sh already prints run-1/run-2 failing
sets and their diff, plus the SHIFTING-FAILURE alarm) and classify each face
against the flake-face ledger (v26.10.17 taxonomy:
[COUNTERS_SNAPSHOT.md](COUNTERS_SNAPSHOT.md) §PERSISTENT-FLAKE, and the
WRAP_LEDGER.md face table):

- **PERSISTENT-FLAKE** — same face in both legs (fence 10 in both attempt-3
  legs; r241 skeptic catch). Needs a real fix (bound slack /
  de-parallelization), never a warm-up.
- **CONTENTION / rotating load face** — solo-green, different faces per leg
  (r240 attempts 1-2: fence 10 leg 1, egress :1221 leg 1, warm leg 2 green).
  Quiesce/warm-up class.
- **NEW face** — not in the ledger: opens a ledger row, no
  disposition without solo-green 3/3 verification.

**Motivating witness — r241.** The r241 skeptic catch fired because the diff
was read late and misread: the first draft claimed "zero repeats of a full
(test, mode) face between the two court legs" — FALSE, fence 10 repeated in
both legs, upgrading it CONTENTION → PERSISTENT-FLAKE. The diff decays in
value with delay (logs age out of `/tmp` mktemp dirs — court_x2.sh's `trap`
deletes `LOGDIR` on exit, so the gate log is the ONLY durable copy of the
failure sets); a late read is a misread, and a misread classified the wrong
class for a full window. 60s, same session as the RC read, against the ledger.

## Rule 5 — On RED: no mid-gate fixes, ever

**RED is a receipt, not a repair trigger.** On gate RED: record `COURT_X2_RC`,
write the receipt (typed RED, faces + classification per Rule 4), commit the
receipt. Only AFTER the receipt lands may diagnosis lanes dispatch. The
10-minute finish loop stops at its charter boundary; the repair becomes the
next window's opening move (r246 disposition: "attempt 5 on a frozen tree ...
with every precondition already green").

**Motivating witness — r246.** Attempt 4's voiding edit was itself a mid-gate
repair (the `management_rpc_test.exs` async fix landed between legs because
someone fixed a face while the gate was running). The impulse is correct — the
fix is real (4/4 post-fix full-suite runs clean of the clear-race class,
per r246) — but the timing voided a legitimate gate. Mid-gate fixing converts
a typed RED into a typed INVALID: the evidence is destroyed for both outcomes.
A red leg costs ~14 minutes; a voided gate costs the whole attempt PLUS the
next one (attempt 5 must re-run on the frozen tree to make the fix admissible
as two-green evidence). No mid-gate fixes, ever — diagnosis lanes dispatch
only after the receipt lands.

---

## Attempt-5 preconditions checklist (all before gate start)

1. `management_rpc_test.exs` async fix committed (landed, 6d84ca7) — attempt 5
   runs it in BOTH legs.
2. `just quiet-check` GREEN (typed waiver per Rule 3 if a foreign beam is
   present and noncontending).
3. `just quiesce` GREEN (warm-up in `_build` per Rule 2; a warm-up failure is
   a stop signal, not a hurdle — r241).
4. Pre-gate commit SHA recorded in `tmp/attempt5-run-log.md` (Rule 1).
5. All receipts landed and committed; `git status --porcelain` clean of
   tracked changes.
6. No diagnosis/repair lanes dispatched; none may dispatch until
   receipt-after-RED per Rule 5.

## See Also

- [r246](receipts/r246-attempt4-invalid-typed-red.md) — the r246 invalidation class
- [r240](receipts/r240-court-x2-attempts12-typed-red.md) — cold-run-1 load faces
- [r241](receipts/r241-court-x2-attempt3-typed-red.md) — PERSISTENT-FLAKE skeptic catch
- [COUNTERS_SNAPSHOT.md](COUNTERS_SNAPSHOT.md) — flake-face taxonomy
- `scripts/court_x2.sh` — the gate; `scripts/quiet_check.py` — the veto
