# Receipt — HAVE-13: HAVE doc-tree integration (runbook, cross-links, recipes, DoD pin)

Date: 2026-10-19
Standing: ALIVE
Context: solo(just have-self-check / have-heartbeat / have-cycle / docs-dod-check gates; no mix test invocation)

## Scope

HAVE (L1 supervisory engine, `scripts/have/`) integrated into the doc tree
per HAVE-13:

- `docs/reference/have-runbook.md` — new Diataxis reference page (HAVE-10
  pin): components, telemetry catalog (ledger row kinds +
  `have_worker_fleet_active_count` severity ladder SEV1-SEV4), jidoka
  alert contract, `just have:*` recipes, crontab templates, 15-court
  self-check.
- `justfile.d/31-have.just` — new recipes module (`have-cycle`,
  `have-heartbeat`, `have-read`, `have-append`, `have-sanitize`,
  `have-self-check`); imported from root `justfile` after `30-burn.just`.
- `docs/reference/courts.md` — Budget/burn/azsim court table gains the
  HAVE self-check row; See Also link added.
- `README.md` — Courts ladder gains the `just have-self-check` row; new
  "HAVE supervisory engine" subsection (telemetry catalog + jidoka
  alerts pointer).
- `CLAUDE.md` — Conventions gains the one HAVE bullet (supervisory
  engine, `just have:*` recipes, crontab templates).
- `justfile.d/12-docs-dod.just` — pins `docs/reference/have-runbook.md`.

## Commands and output

```
$ just have-self-check; echo "exit=$?"
PASS saturated-pool-ok
PASS no-alert-at-target
PASS no-dispatch-at-target
PASS heartbeat-touched
PASS first-deficit-sev3
PASS alert-row-typed
PASS alert-row-deficit
PASS dispatch-request-deficit
PASS sustained-deficit-sev2
PASS sev2-sustained-flag
PASS midband-sev4
PASS counter-fail-typed
PASS counter-fail-sev1
PASS recovery-ok
PASS no-dispatch-on-recovery

self-check: 0 failure(s)
exit=0

$ just have-heartbeat; echo "exit=$?"
heartbeat age=0.001s
exit=0

$ just have-cycle; echo "cycle-exit=$?"
{"deficit": 14, "severity": "SEV2", "status": "DEFICIT", "target_pool": 20, "ts": "2026-10-19T04:33:56Z", "workers": 6}
cycle-exit=0

$ just docs-dod-check > /tmp/dod.out 2>&1; echo "dod-exit=$?"
dod-exit=0
$ grep -c "^OK" /tmp/dod.out
60
$ grep "^MISS" /tmp/dod.out
(no matches)
```

Note: the `have-cycle` DEFICIT/SEV2 row is real (6 workers vs target 20 on
this host) and is the jidoka alert firing as designed — exit 0, signal in
the ledger row.

## Verification ladder

- Recipe parse/run: `just --list` shows all six `have-*` recipes; three
  executed for real above (self-check 15/15 PASS, heartbeat, cycle).
- Gate: `just docs-dod-check` exit 0, 60 OK / 0 MISS, including the new
  `docs/reference/have-runbook.md` pin.
- Cross-links verified present: courts.md table row + See Also; README
  ladder row + subsection; CLAUDE.md conventions bullet.

## Boundary

No git (operator instruction). `docs/reference/have-runbook.md` and
`justfile.d/31-have.just` are new files; `justfile`, `courts.md`,
`README.md`, `CLAUDE.md`, `12-docs-dod.just` are minimal edits. No GAP/KD
token flips. Receipt is full-command-output embedded; not SUSPECT.

## Addendum — HAVE-9 recipe-section sync (2026-10-19)

`docs/reference/have-runbook.md` listed stale recipe names
(`have-cycle`, `have-sanitize`, `have-read`, `have-heartbeat` — none exist
in `justfile.d/31-have.just`). Synced to the 9 real recipes:
have-guard / have-watchdog / have-telemetry / have-rp01..rp04 /
have-install-crontab / have-status.

Changes:
- Section 5: added the 9-recipe table (recipe -> script -> exit contract);
  RP-01/RP-02/RP-02b/RP-03 prose re-pointed to `have-rp01`, `have-guard`,
  `have-status`; stale names removed (grep: zero matches).
- RP-04 landing note flipped from "NOT yet runnable" to runnable —
  `scripts/have/petri_net.json` is landed (keys: description, final_marking,
  initial_marking, name, places, transitions); `have-rp04` skips loudly
  (exit 0, `[SKIP]`) when no OCEL projection exists.
- New section 5b: HAVE_ENFORCE semantics (watchdog dry-run default,
  HAVE_ENFORCE=1 arms RP-01 automation).
- Section 6: crontab section re-anchored on print-only
  `just have-install-crontab`; added the 30m watchdog line and `just have-guard`
  equivalent.

Verification (real output, this session):

```
$ just have-status   (tail)
== HAVE status @ 2026-10-19T04:46:09Z ==
-- telemetry snapshot --
{"metric": "have_worker_fleet_active_count", "severity": "nominal", ..., "value": 15.0, ...}
{"metric": "have_petri_net_token_drift", "severity": "nominal", "value": 0.0, ...}
-- heartbeat --
heartbeat age=0.001s
-- alert summary --
state_ledger.jsonl: 10 rows; kinds={'alert': 10}; severities={'SEV3': 1, 'SEV2': 8, 'SEV4': 1}
EXIT=0

$ just docs-dod-check   (tail)
OK    README.md
EXIT=0
```

Standing: PASS (doc-sync; both gates exit 0 on the real tree).
