# Receipt — HAVE-13: HAVE doc-tree integration (runbook, cross-links, recipes, DoD pin)

Date: 2026-10-19
Standing: ALIVE

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
