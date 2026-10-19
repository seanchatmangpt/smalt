# docimpl-2 — docs-audit D3 reference-surface implementation receipt

Standing: PASS (all 7 findings implemented; gates below run for real).
Context: solo(docs-audit D2 implementation verification greps + just gates; no mix test invocation)

Date: 2026-10-19 @ HEAD 6681746. Audit source:
`docs/jira/v26.10.18/docs-audit/d3-reference.md`. No git actions taken.

## Findings -> edits

1. **courts.md** — `test_isolation_leak_gate.py` added to the gates table
   (with the explicit note it is NOT one of the six `just invariant-gates`
   gates; runs via `just leak-court`/`isolation-court`); shim court list
   corrected to 26 scripts incl. `sleep_gate` (count re-derived
   `ls scripts/shim_court/*_court.sh | wc -l` = 26); new "Budget / burn /
   azsim court surfaces" section (budget gate `test-budget` +
   `test_budgets.json`, burn suite + burn-boot stop-the-line rows,
   overlap-court anti-vacuity, azsim-sdk via `justfile.d/14-sdk-matrix.just`).
2. **NO_SLEEP_DOCTRINE.md** — lib census re-derived on disk: 3 sites
   (`doctor.ex:186`, `doctor.ex:265`, `state.ex:169`); router/wasm_engine/
   pplan rows removed with redesign pointer; B1 count 13 -> 20 with the
   on-disk per-file distribution; adoption step 4 rewritten to resolve the
   contradiction (AZB-21 section is current: `just sleep-gate` enforces
   green — see live output below; verify_all keeps the legacy
   `SLEEP_GATE_ENFORCE=1` opt-in loud-skip pending default flip); step 5
   repair WOs marked drained (0 unclassified).
3. **kd-register.md** — counts re-derived from
   `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` at 6681746:
   rows 95 (`grep -c '^| KD-'` = 95), CLOSED-WITH-RECEIPT 14,
   CLOSED-SIMULATED 18, CLOSED total 32, OPEN 63; derivation date stated.
4. **just-recipes.md** — inventory 29 modules, imports `justfile` lines
   221-254 (re-read on disk); `invariant-gates` = 6 gates (gate names
   listed, from `test/invariant_gates_test.py` GATES_UNDER_TEST);
   cli-test venv claim fixed (only `.venv-cli` real; `.venv` does not
   exist, ADR-PY-002 — verified against `justfile.d/03-cli-wiring.just`
   and `ls smalt-cli`); `lane-clean` sweep claim fixed (every repo-root
   `_build*` except canonical `_build`, live-referenced skip — from
   `justfile.d/06-lane-cleanup.just`); new rows for modules 23-30 and the
   unlisted 22-native recipes (preflight/fix-start/fix-end/spc-check).
5. **ets-tables.md** — source of truth -> `lib/smalt/store_tables.ex`
   (`Smalt.StoreTables`, `mix smalt.gen`-generated); count 33 -> 53 stated
   as 33 owned + 19 shadow (52 registered) + lazy `:smalt_egress_guard`
   (`egress_router.ex:3799`, unregistered) = 53 distinct named tables;
   DETS-mirror section added (`Smalt.Store.DetsMirror`: poll-based mirror,
   drift window, `restore/0`, `open_typed` repair + telemetry
   `[:smalt, :store, :dets_repaired]`, persisted set =
   `persisted_tables/0`, 6 tables).
6. **arm-gateway.md** — `Smalt.ArmGateway.LRO.Notifier` module row +
   signal-hub prose (from `lro_notifier.ex` moduledoc); `:arm_port` pin ->
   `config/config.exs:31`; `:arm_tls_port` default -> `Smalt.Config`
   (`lib/smalt/config.ex:554`), test pin `config/test.exs:46`;
   OperationRecordIncomplete pin `lro.ex:184` -> `lro.ex:430` (fail-closed
   variant at `:354`).
7. **ports-and-planes.md** — new "Plane selection (SMALT_PLANES, AZB-04)"
   section: input forms, known planes, runtime.exs resolution timing,
   `{:invalid_plane, name}` refusal, profile opt-in law, plane-aware
   supervisors; pin `config/config.exs:40-44`.

## Verification (real output)

```
$ python3 scripts/sleep_gate.py; echo exit=$?
[SLEEP-GATE] PASS — 330 files, 0 unclassified sleep primitives
exit=0

$ grep -c '^| KD-' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md
95
$ grep -oE '\| CLOSED-[A-Z-]+' docs/jira/v26.10.14/KNOWN_DIVERGENCES.md | sort | uniq -c
  18 | CLOSED-SIMULATED
  14 | CLOSED-WITH-RECEIPT

$ ls scripts/shim_court/*_court.sh | wc -l
      26

$ grep -cE '^\s+:smalt_' <(sed -n '36,136p' lib/smalt/store_tables.ex); \
  grep -cE '^\s+:smalt_' <(sed -n '137,195p' lib/smalt/store_tables.ex)
33
19

$ just docs-dod-check; echo "dod-exit=$?"
...61 OK lines, 0 MISS...
OK    docs/reference/ets-tables.md
OK    docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md
OK    README.md
dod-exit=0
```

Falsifier note: the 53rd-table claim is falsifiable — if
`:smalt_egress_guard` is ever registered in `store_tables.ex` or another
`:smalt_*` named table appears in `lib/`, the count sentence must be
re-derived. kd counts: any flip via `kd_flip.py --apply` dates this table.
