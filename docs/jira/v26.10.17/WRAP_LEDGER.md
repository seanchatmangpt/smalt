# WRAP_LEDGER — v26.10.17 wrap ledger

Standing: TYPED-RED terminal close (2026-10-17). The window's release gate
(`just court-x2`, WO-2) closed honest TYPED-RED after 3 attempts; two-green
was NOT reached. **Version stays 26.10.16 — no version bump anywhere this
window** (WO-4 was strictly gated on WO-2 two-green, which did not happen).
This ledger is the dated record of what landed, what the gate witnessed, and
what carries to the next window.

## 2026-10-17 — court RED closure (d092caa)

Commit `d092caa` — `fix(v26.10.17): court RED closure — blob HEAD
conditionals, header parity, seq re-domain, isolation leaks`. Root cause of
the court run-1 75-failure cluster (receipt r236) was typed as first-exposure
compliance corpus + cross-file isolation leaks, not product regressions.
Product fixes landed:

- blob HEAD arm mirrors GET's RFC 7232 engine (412/304/206/416); blob_route
  stamps `x-ms-request-id`/`x-ms-version` on every arm; `x-ms-range` wins
  over Range — **KD-97**, witness
  [r239-kd97-conditional-head-landing.md](receipts/r239-kd97-conditional-head-landing.md)
- eg1_publish re-domained onto the shared EventStream seq counter
  ([i20f-egmerge-fix.md](receipts/i20f-egmerge-fix.md)); EventGridTopicsArm
  readback merge total-ordered
- DetsMirror.sync/1 call timeout 5s→30s (measured 350x tail under load,
  [i20b-contention-mechanism.md](receipts/i20b-contention-mechanism.md))

Test isolation + premise fixes: mix_auth_scope_test `:auth_mode`
save/restore (the 401-cluster leaker); lro_test/zero_drift `lro_*` env
restore-on-exit; c2_keyvault corpus KD-15 challenge-bearer default + AKV
api-version (16/0); c1_arm re-pinned under KD-78 monotonic admission + 12
cite-drift re-anchors (291/0); c4_blob premise fixes + defensive header
asserts (49/0); c7_events fresh-partition uniqueness (157/0 corpus);
apiversion_matrix re-anchor for the egmerge line shift.

## 2026-10-17 — harness mechanisms from the r240 chain (7b42734)

Commit `7b42734` — `feat(harness): session-learned mechanisms`. Derived
directly from the court-x2 r240 failure chain (both attempts failed cold
run 1 on load faces, passed warm run 2; 32 prior gate invocations, 0
two-green at authoring time):

- `justfile.d/24-quiesce.just` + `scripts/quiet_check.py`: fail-closed court
  preconditions (stray beams, court ports, concurrent suites, load threshold)
  — `just quiet-check` / `just quiesce`
- `justfile.d/25-leak-court.just`: test-isolation leak court recipe; gate
  NOT wired into `just court` until the 122 flagged mutations are remediated
- `scripts/receipt_index.py`: NO-CONTEXT advisory flag per
  [RECEIPT_CONTEXT_LAW.md](RECEIPT_CONTEXT_LAW.md)
- `justfile.d/26-rewitness.just`: `just rewitness <KD-nn>` + `just kd-stale`
  (kd mtime-chain recovery; typed exit 3 for rows without a falsifier cell)
- `justfile.d/27-scratch-soak.just`: `just wt-scratch <sha>` (git-archive
  scratch, never worktrees) + `just corpus-soak <n>` load-condition gate
- CLAUDE.md conventions: corpus premise pins (KD-15 challenge handshake,
  KD-78 future-version refusals), Context law, court preconditions

## 2026-10-17 — court-x2 attempts 1-2 (r240, typed RED)

Receipt: [r240-court-x2-attempts12-typed-red.md](receipts/r240-court-x2-attempts12-typed-red.md),
standing RED (honest, per WO-2).

| Attempt | Run 1 | Run 2 | Failing face (run 1) |
|---|---|---|---|
| 1 | RED (1 failure) | GREEN (0 failures) | WasmEngineFailClosed "restart hammer" (affidavit_wasm_failclosed_test.exs:502) + test-sdk-smoke watchdog exit 124 |
| 2 | RED (1 failure) | GREEN (0 failures) | EgressDispatch "batch-list boundary" (egress_dispatch_test.exs:1221) |

Both faces solo-green 3/3 on the same tree; both run 1s started within
minutes of heavy machine activity. Failure IDENTITY shifted between
attempts (the court_x2.sh shifting-failure alarm pattern) while the
structure (cold run 1 trips one load face, warm run 2 green) was constant.
Court ledger at r240 time: 32 prior invocations, 0 two-green. Disposition
pre-registered: if attempt 3 goes RED on the same class, WO-2 closes honest
typed-RED with NEXT_WINDOW carrying the gate.

## 2026-10-17 — pre-mortem, gate attempt 3, and the skeptic catch (r241)

Receipt: [r241-court-x2-attempt3-typed-red.md](receipts/r241-court-x2-attempt3-typed-red.md),
standing TYPED-RED. Attempt 3 ran the full pre-mortem protocol before
launching:

1. `just quiet-check` — RC=0: `QUIET-CHECK: clear (beams ok, ports free,
   no concurrent suites, load 6.3 < 16)`
2. `just quiesce` warm-up — RC=2: the warm-up full offline suite itself
   FAILED (1 failure, 2655 tests, 302.5s) before court-x2 launched
3. `just quiet-check` — RC=0: `load 9.0 < 16`
4. `bash scripts/court_x2.sh` — FAILED: run 1 = 4 failures, run 2 = 1
   failure, both legs test-offline exit 2, gate RC=1
   (`tmp/court-x2-v17-wrap3.log`).

**Pre-mortem outcomes**: the quiet-check preconditions held (clear both
passes); the warm-up mitigation did NOT hold (the warm-up itself failed,
and run 1 still tripped 4 faces — warm-start clears machine load, it does
not de-conflict the async teardown race); two-green did NOT hold.

**Skeptic catch — receipt corrected in place**: an earlier draft of r241
claimed the court_x2 log tails "carry no test identities" and that there
were "zero repeats of a full (test, mode) face between the two court legs."
The skeptic pass found both claims false: the tails DO carry full identities
(wrap3.log lines 66-78), and fence 10 — WasmEngineFailClosed "restart
hammer" (:502) — failed in BOTH legs (run 1 at log line 68, run 2 at line
72). The receipt was corrected contemporaneously; the corrected reading
upgrades fence 10 from CONTENTION to **PERSISTENT-FLAKE** (repeats under
court load, solo-green) — it needs a real fix (timing-bound slack or harness
de-parallelization), not a warm-up. Correction is recorded in the receipt
body, not silently rewritten.

### Gate terminal disposition — TYPED-RED (no version bump)

Per the r240 fallback and WORK_ORDERS.md WO-2, the gate closes honest
**TYPED-RED**: not cleared this window;
[NEXT_WINDOW.md](NEXT_WINDOW.md) carries it with the r240→r241 chain.
Aggregate: **3 attempts this window, 0 two-green** (34 prior invocations
across windows, also 0 two-green). Faces at close:

- **fence 10** (WasmEngineFailClosed :502, 129ms-vs-bound timing face):
  PERSISTENT-FLAKE — solo-green, repeats under court load
- **EgressDispatch setup ETS `:smalt_subscriptions` teardown race** (victims
  :1474/:975): contention-class, shared mechanism named — setup seeds via
  `Smalt.Store.seed_default_subscription/0` (lib/smalt/store.ex:194) racing
  another async module's Store teardown
- **Lro :543 op-record store miss** (`:error` vs Succeeded): contention-class

Every tripped face is solo-green on the same tree. Repair surfaces named for
the next window (not landed here): fence 10 bound slack / harness
serialization; EgressDispatch async-module isolation. No product defect is
asserted beyond the receipts.

**Standing consequences (enforced)**: no version bump anywhere — version
remains 26.10.16; WO-4 never executed; no TWO-GREEN claim exists in this
window's artifacts; the release-receipt mint class remains gated on a
future real two-green court and was not attempted.

## Carried to the next window

- The court-x2 gate itself (r240→r241 chain), with the three face classes
  and repair surfaces above.
- Leak-court gate wiring (blocked: 122 flagged mutations to remediate).
- `just court-x2` preconditions now mechanical: `just quiet-check` clear +
  quiesce warm-up green BEFORE the gate; a warm-up failure is itself a stop
  signal (attempt 3 evidence), not a hurdle to push through.
