# burn receipt schema (smalt-burn/v2)

Normative reference for one burn JSONL row. Canonical schema file:
`docs/jira/v26.10.18/burn/burn-row.schema.json` (draft 2020-12,
`$id https://chatmangpt.com/schema/smalt/burn-row/v2`). This page restates
the contract for readers; the JSON Schema is authoritative.

## File shape

A burn JSONL file carries three line kinds (`scripts/validate_burn.py`):

- `{"type": "run_header", ...}` — first line: run id + the EXPECTED matrix
  (containers x cycles x stages) that `--gate` checks every
  `(container, cycle, stage)` cell against. Without a declared matrix a
  dropped cycle is invisible (the AZB-03 falsifier), so `--gate` REFUSES a
  file whose header is missing.
- `{"type": "run_receipt", ...}` — one run summary, validated against
  `~/.zcode/dfcm/receipt.schema.json`.
- `{"schema": "smalt-burn/v2"}` — burn rows, validated against
  `docs/jira/v26.10.18/burn/burn-row.schema.json`.

Rows are written to `docs/jira/v26.10.18/burn/<run-id>.jsonl` (tracked,
never `tmp/` — avoids `R_missing_replay`). Never hand-edit rows.

## Required fields

`schema`, `subject_sha`, `image_digest`, `container`, `plane`, `cycle`,
`stage`, `verdict`, `t_start`, `t_end`, `exit_code`, `orphans`,
`crash_reports`, `evidence_path`, `broken_term`. `additionalProperties:
false` — an unregistered field is a validation failure.

## Field reference

| field | constraint |
|---|---|
| `schema` | const `smalt-burn/v2` |
| `subject_sha` | `^[0-9a-f]{7,64}$` or `unrecorded` |
| `image_digest` | string 1..128; `"unrecorded"` when the emitter could not see it |
| `plane` | `control \| data \| integration \| identity \| all` |
| `container` | non-empty string |
| `cycle` | integer >= 0 |
| `stage` | `boot \| probe \| chaos \| recover \| teardown \| soak` |
| `verdict` | `CLEAN \| ORPHAN_LISTENER \| ZOMBIE_BEAM \| UNHANDLED_EXIT \| DETS_UNREPAIRED \| TYPED_VOCAB_MISMATCH \| TIMEOUT_DEADLINE` |
| `t_start` / `t_end` | `YYYY-MM-DDTHH:MM:SSZ` |
| `exit_code` | integer |
| `orphans` | array of strings |
| `crash_reports` | integer >= 0 |
| `evidence_path` | non-empty string |
| `broken_term` | null or one of the ten DfCM terms: `mu_on_O`, `admission_vacuous`, `mu_unlawful`, `R_missing_identity`, `R_missing_authority`, `R_missing_consequence`, `R_missing_replay`, `R_missing_standing`, `R_not_fed_back` |
| optional | `lane`, `detail`, `recovery_ms` (>= 0), `clean` (bool), `tier`, `tests` (>= 0), `failures` (>= 0), `faces` (array of objects), `flood_conns`, `hogs` (>= 0), `note` |

## Conditional constraint (the coupling law)

`allOf`:

- verdict `CLEAN` ⇒ `broken_term` MUST be `null`.
- any non-CLEAN verdict ⇒ `broken_term` MUST be a non-empty string.

A CLEAN row with a broken term, or a violation row without one, is invalid.

## Gate

```bash
python3 scripts/validate_burn.py --gate <file.jsonl> [...]
```

Exit 0 valid / 1 validation failure (schema violation, `MISSING_CELL`,
`DIRTY_ROW`, receipt-schema mismatch) / 2 usage or IO error. Rows land
tracked under `docs/jira/v26.10.18/burn/` — see
`docs/how-to/how-to-run-burn.md` for the lanes that emit them.

## See Also

- `docs/jira/v26.10.18/burn/burn-row.schema.json` (authoritative)
- `docs/jira/v26.10.18/burn/README.md`
- `docs/how-to/how-to-run-burn.md`
- `docs/jira/v26.10.18/receipts/azb-03-burn-schema.md`
