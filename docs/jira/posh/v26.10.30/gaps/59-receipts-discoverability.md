# 59 — Receipts discoverability (unified index)

ALIVE — `just receipts` runs and produces a real table (command exit 0, output below).

## Problem

Receipts live in ≥6 places with no single surface. Adapted lane: the posh/smalt
paths named in the lane contract (docs/jira/posh/v26.10.30/receipts, posh/,
.ggen-v2/, tmp/posh/) do not exist in this repo (courtroom-platform-az, Terraform/
TS, no prior justfile). Index script treats every surface as optional but LOUD:
absence is printed per-surface (`MISSING`), never silently skipped.

## Landed

- `scripts/receipts_index.sh` — walks 6 surfaces; per row: date | subject/SHA
  (first 40-hex in file, else basename) | verdict (first status token:
  GREEN/RED/PLANNED/ALIVE/PARTIAL/BLOCKED/REFUSED/UNVERIFIED, else `-`) | path.
  Sorted date-desc. `--emit-index` regenerates `receipts/INDEX.md` (GENERATED
  banner at top — do not hand-edit).
- `justfile` — new; `just receipts` = `./scripts/receipts_index.sh --emit-index`.
  No pre-existing `receipts` recipe existed to conflict with (no justfile at all).

## Surface census at landing (2026-10-30, HEAD 31c58e9)

| surface | state |
|---|---|
| receipts/ | MISSING (created by --emit-index; contains only INDEX.md) |
| gaps/ | PRESENT (this file) |
| tmp/posh/ | MISSING |
| posh/var/andon.jsonl | MISSING |
| .ggen-v2/receipt-log.jsonl | MISSING |
| scripts/receipts/ | MISSING |

## Receipt

- Commands: `just receipts` (exit 0); `./scripts/receipts_index.sh --emit-index` (exit 0)
- Verification: real table output printed; INDEX.md regenerated with GENERATED banner;
  surfaces census printed on every run so missing surfaces are loud
- Standing: ALIVE (command + output witnessed this session)
