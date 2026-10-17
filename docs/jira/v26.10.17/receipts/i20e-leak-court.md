# Receipt — i20e (mechanical test-isolation leak court)

- **Subject**: `/Users/sac/smalt` working tree @ `main` `650a8ff`; new file
  `gates/test_isolation_leak_gate.py` (this lane's only edit; no lib/ changes)
- **Date**: 2026-10-17
- **Standing**: gate mechanics ALIVE (non-vacuous, 3/3 fixtures); tree verdict
  FAIL-TREE-LEAKS — honest nonzero first run, offender table below. NOT wired
  into `just court`/`invariant-gates` (coordinator owns integration).

## Command + exit (real output, full table in the receipt JSON)

```bash
python3 gates/test_isolation_leak_gate.py
# exit 1 (expected: tree leaks)
```

```
== test-isolation-leak court ==
scanned 153 .exs files under test/ (1 allowlisted)

-- positive: KNOWN-clean discipline fixtures --
PASS fixture:clean-intact-save-plus-on_exit (expected PASS, scanner said PASS)
PASS fixture:on_exit-stripped (expected REFUSE, scanner said REFUSE; L6 env mutation `smalt.:probe_key` (no restore in on_exit/after))
PASS fixture:literal-restore-no-save (expected REFUSE, scanner said REFUSE; L8 env mutation `smalt.:probe_key` (no save of prev value))

-- allowlist --
ALLOWED test/tls_test.exs (4 tracked mutations, exempt: hand-verified restore)

verdict=FAIL-TREE-LEAKS tree=LEAKS offenders=56 fixtures_refused=True receipt=/Users/sac/smalt/tmp/invariant-gates/test-isolation-leak-receipt.json
EXIT=1
```

## Design

Static scan of `test/**/*.exs` for global substrate mutations:
`Application.put_env/delete_env(:smalt|:logger, ...)`, `:persistent_term.put/2`,
`:ets.new(<literal>, [... :named_table ...])`. A mutation is COVERED only when
the same file (a) SAVES the previous value (`x = Application.get_env(...)`,
keyword-style `key: Application.get_env(...)` bindings included; bare reads and
`==` comparisons do not count) and (b) RESTORES inside an `on_exit` block or a
`try/after` `after` region — literal-key restore, variable-key restore
(`for {k,v} <- prev`), or the house whole-env helper
`SmaltTest.Lifecycle.restore_app/0`. Named-ETS tables are covered by a literal
or catchall `:ets.delete` in a restore region.

## Non-vacuity (fail-closed contract)

Three self-contained fixtures run through the SAME scanner:

1. `clean-intact-save-plus-on_exit` — must PASS (positive control).
2. `on_exit-stripped` — clean file with the `on_exit` block deleted → REFUSED.
3. `literal-restore-no-save` — on_exit restoring a hardcoded literal with no
   save of the previous value (the mcp_test doctor_supervisor class) → REFUSED.

Two scanner bugs were caught BY the fixtures during authoring and fixed:
(a) save-key prefix mismatch made the intact-clean fixture FAIL;
(b) bare `get_env` reads counted as saves, which let fixture 3 pass —
the negative fixtures are the load-bearing proof, not prose.

## Offender table (56 files, 122 mutations uncovered) — first-run honest red

Confirmed named offenders: `test/mcp_test.exs:901` (doctor_supervisor, on_exit
restores literal `Smalt.Supervisor`, no save), `test/data_plane/audit_planes_test.exs`
(sentinel_dcr_strict / rg_token_preserve_options / event_stream_dedup_ids —
delete_env-only restores, no save), `test/enclave-testbed/enclave_testbed.exs:423`
(no restore region at all). `test/lro_test.exs` is CLEAN (fixed upstream; no
longer flagged) and `test/tls_test.exs` is allowlisted (hand-verified
map-save + conditional after-restore discipline the scanner cannot yet express
per-key).

Largest leak classes in the table: port shifts without save
(`arm_port/egress_port/amqp_port/event_hubs_port` in wire/flow/compliance/chaos
suites restored via `restore_app` but never saved first), and feature-flag
puts (`auth_mode`, `sb_shared_key`, `lro_delay_ms`, `maa_measurement_baseline`,
`sentinel_dcr_strict`, …) with no save + no region restore. Full per-line table
embedded in `tmp/invariant-gates/test-isolation-leak-receipt.json` (verdict
field `FAIL-TREE-LEAKS`, `offender_count: 56`).

## Falsifier / replay

`python3 gates/test_isolation_leak_gate.py` — exits 0 only when the tree is
green (offenders fixed or allowlisted with named justification in ALLOWLIST)
AND the three fixtures stay correct. Wiring into justfile court is deferred to
the coordinator per lane contract.
