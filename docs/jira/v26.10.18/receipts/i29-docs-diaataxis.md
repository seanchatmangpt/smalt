# I29 — Diátaxis structure audit, docs landed this window

Standing: PASS (with reported, unfixed structural items)
Date: 2026-10-18
Scope: the 10 Diátaxis-layout docs landed/updated in v26.10.18

## Method

- Read all 10 files in full.
- Checked: H1 vs filename, H2 sections, ≤100-char lines (awk length),
  kebab-case, every backticked path/link resolved on disk, every
  referenced `just` recipe against `just --summary`, every `mix` alias
  against `mix.exs`, fenced-code language tags.
- Mechanical fixes applied in place (3); structural items reported only.

## Mechanical fixes applied

- `docs/reference/have-runbook.md:13` — fence tagged `text` (ASCII tier diagram)
- `docs/reference/have-runbook.md:238` — fence tagged `text` (triage tree)
- `docs/tutorials/planes-profiles.md:76` — fence tagged `text` (typed-refusal output)

## Verification (real output)

```
$ just --summary | tr ' ' '\n' | sort   # 30 recipe names probed
-> 0 NORECIPE   (have-guard, burn-ring, sleep-gate, isolation-court,
   test-compliance-wire, relay-env, quiet-check ... all present)
$ ls <60 cited path targets>
-> only probe miss was my own wrong-window path (v26.10.18 vs .17);
   every path cited by the docs exists on disk
$ awk 'length>100' over all 10 files
-> overruns confined to markdown TABLE rows (see report)
$ mix.exs aliases: test.amqp_wire / test.cross_seat / test.compliance
   all present (mix.exs:45-47,66)
```

## Per-file findings (violations reported, not fixed)

### docs/reference/have-runbook.md
- L56-60, 69-72, 81-84, 92-100, 208, 230: table/cron lines >100 chars
  (22 lines; longest 288 at :230). Report-only: table rewrap is
  content-shifting, not mechanical.

### docs/NO_SLEEP_DOCTRINE.md
- L93-95: table rows >100 chars.
- L63: trailing whitespace after `GenServer.call`,`.

### docs/reference/test-isolation-law.md
- L47-53: tag-vocabulary table rows 148-513 chars. Report-only.
- L6: says it "adds the ... runtime exemption registry" while §7
  registry counts and TEST_ISOLATION.md §6 say "14 patterns" vs §7
  listing three classes — counts consistent; no action.

### docs/reference/burn-receipt-schema.md
- L43, 49-50: table rows >100 chars.
- L49: `broken_term` row says "one of the ten DfCM terms" but lists 9.
  Factual drift; report-only (which term is tenth needs the schema file
  as authority — the doc itself defers to the JSON Schema).

### docs/tutorials/planes-profiles.md
- L28-31: plane table rows >100 chars.

### docs/how-to/how-to-run-burn.md
- L23-27: lane table rows >100 chars.

### docs/how-to/how-to-write-tests.md
- Clean: no violations.

### docs/how-to/how-to-add-config-key.md
- L52-53: garbled quote — 'the test comment says: "census pin updated
  with the ticket, not" silently' — truncated sentence reads as an
  editing artifact. Report-only.

### docs/explanation/no-sleep.md
- Clean: no violations.

### docs/TEST_ISOLATION.md
- L1/L7: two H1s (`# TEST_ISOLATION` and `# Smalt Test Isolation
  Contract`) — Diátaxis one-H1 violation; structural (legacy banner +
  legacy body). Report-only.
- L41: typo "ownered exception" (should be "owned").
- L286-293 (§7 SleepWindows): stale facts vs `test/support/sleep_windows.ex`
  — lists `fixed_window_rollover_ms/0` (actual `/1`),
  `lro_retention_elapse_ms/1` (function does not exist; actual
  `lro_deadline_elapse_ms/1`), `sweeper_grace_elapse_ms/0` (actual `/2`),
  `mcp_idle_gap_ms/0` (actual `/1`); also claims consumers include
  `test/mcp_wire_test.exs`, `test/smalt_arm_gateway_test.exs` — not
  re-verified against grep. Report-only: content correction, not
  mechanical.
- L46-53: table rows >100 chars.

## Link/recipe/alias integrity

- 0 broken relative links across all 10 files (the `i21d-store-clear-async`
  citation correctly points at v26.10.17, which exists).
- 0 missing `just` recipes (against `just --summary`).
- 0 missing mix aliases.
- `docs/reference/courts.md`, `docs/reference/ports-and-planes.md`,
  `docs/explanation/ggen-projection-law.md` all exist.

## Receipt context

Context: solo

## Conclusion

Structure conforms to the v26.10.14 exemplar shape (H1/H2/See Also,
kebab-case). All violations found are: over-100-char markdown table rows
(7 files), one two-H1 legacy file, and four content-drift items
(burn-schema "ten vs 9" count, add-config-key truncated quote,
TEST_ISOLATION.md §7 stale SleepWindows arities, "ownered" typo) —
reported for owner-lane follow-up, none fixed unilaterally.
