# 66 — DX Telemetry (DoD lane 13)

## What landed

- `scripts/dx_telemetry.sh` — sourceable helper; `dx_event <gate> <outcome> <elapsed_ms>
  [subject_sha]` appends one JSONL row to `posh/var/dx-events.jsonl` (append-only, never
  fails the caller, mkdir on first write, `backfilled:false` on live rows).
- `scripts/dx_report.py` — SPC query helper: per-gate n / pass-rate / fail / skip /
  p50 / p99 elapsed_ms, backfilled count split; loud `NO DATA` on missing/empty log.
  `just dx-report`.
- Hook wired: `scripts/posh_doctor.sh` (gaps/55 doctor) times each invocation and appends
  one dx-event on every exit path (`doctor` gate; degraded exit-2 mapped to `pass` — the
  schema is pass/fail/skip; warnings are not yet distinguishable in the event schema).

## ALIVE receipt

- Two real invocations landed real rows (subject 31c58e915febf8bfc23b8fc7369617abd54a80ce):
  - `{"ts":"2026-10-30T20:47:05Z","gate":"doctor","outcome":"fail","elapsed_ms":384,...}`
  - `{"ts":"2026-10-30T20:47:11Z","gate":"doctor","outcome":"fail","elapsed_ms":370,...}`
- `python3 scripts/dx_report.py` prints a real table over those rows (doctor: n=2,
  pass 0.0%, p50 377ms, p99 383.9ms).

## First measured SPC input (supersedes measure.md paper instruments for this slice)

- doctor: 2/2 FAIL (100% failure rate on this slice) — driven by DOCTOR-5 (kind node disk
  17.3GB < 20GB floor), a pre-existing environmental failure, not session-introduced.
  Remediation: `docker system prune` on the kind node.
- Time-to-green p50 ≈ 377ms per doctor run — cheap enough to gate per-PR.
- Median time-to-green (fail→pass recovery) is NOT MEASURABLE yet: zero pass transitions
  exist in the log. Requires a fixed→green remediation cycle to produce.

## Backfill

- Requested source `tmp/posh/andon.jsonl` does not exist in this repo (no `tmp/`, no posh
  SLA runner, no court receipts — the only pre-existing posh artifact here is
  `scripts/posh_doctor.sh`). Zero backfilled rows; nothing invented.

## Gaps / not landed (loud)

- No `run_with_sla` / `posh_sla.sh` exists in this repo — the SLA-runner hook edit named in
  the lane contract has no referent here. Doctor is the only wired gate.
- No posh-court, compat-check, or coverage scripts exist here — the 3-4 additional hook
  sites have no referents. Hooks for them land when those gates land; `dx_event` is the
  single insertion point (one source + one call per gate).
- Event schema has no `warn`/`degraded` outcome; doctor's exit-2 currently records `pass`.
  If degraded-vs-green distinction matters for SPC, extend the schema before the court.
