# SPC Gate Tier-Escalation Validation Receipt (lane 507, Ring 3)

Standing: **PASS with 1 open defect (F)** — 7/8 matrix rows PASS, 1/8 FAIL.

- Subject: `scripts/spc_gate.py` (gate) + `lib/smalt/spc/drift.ex` (emitter)
- Method: adversarial tier-escalation matrix via the `SMALT_SPC_SOURCES` /
  `SMALT_SPC_HISTORY` seams (temp history + source per case, real gate
  subprocess + real Elixir emitter against the real `:smalt_event_messages`
  ETS table). No mocks.
- Driver: `tmp/spc_audit8/driver.py` (scratch, re-runnable); raw outputs in
  `tmp/spc_audit8/<case>/`.
- 1σ probe calibration: rolling history 300 alternating 95/105 rows →
  center=100.0, sigma=5.09 (witnessed probe output).
- Bands history seed witnessed: `tmp/enclave-native.jsonl` contributes 2
  parse_ms points; the gate's rolling append is post-classification (the
  observation is never graded against itself).

## Escalation matrix (witnessed 2026-10-16, MIX_BUILD_ROOT=_build-lane507)

| # | Case | Injected observation | Exit | Verdict | Witnessed evidence |
|---|------|----------------------|------|---------|--------------------|
| A | baseline | parse_ms = center (z=0) | 0 | PASS | `verdict=PASS tier=0 seeded=True` (canonical receipts still in seed mode) |
| B | 1σ EVENT | center+1.5σ → z=1.5 | 0 | EVENT | `events=1`, event `{"spc_drift": ["native_stage_ms.parse", 1, 107.635]}` |
| B-emit | emitter loop closed | gate stdout → `Smalt.Spc.Drift.emit/1` | 0 | emitted | `B-EMIT-OK id=1d2667f5-...`; `Store.get(:smalt_event_messages, "spc.drift/<id>")` returned CloudEvents 1.0 row: `type="spc.drift"`, `specversion="1.0"`, `source="smalt://scripts/spc_gate.py"`, `topic="spc.drift"`, `data.tier=1`, `data.z` ∈ [1.0, 2.0) |
| C | 2σ DISPATCH | center+2.5σ → z=2.5 | 0 | DISPATCH | typed remediation row: `dispatch: bench-runner profile (2-sigma drift)` |
| D | 3σ FAIL-CLOSED | center+4σ → z=4.0 | **1** | FAIL | `orphaned_keys=[{metric: native_stage_ms.parse, value: 120.36, z: 4.0}]`, `[spc] FAIL-CLOSED 3-sigma` stderr line |
| D-emit | anti-laundering | FAIL receipt → `Drift.emit/1` | 0 | refused | `{:ok, :skipped}`; spc.drift row count in `:smalt_event_messages` 0→0 (`D-EMIT-OK skipped=true spc_rows=0==0`) — the 3σ observation produces ZERO telemetry |
| E | missing history | fresh nonexistent HISTORY file | 0 | SEEDED | metric row `verdict=SEEDED, n=4, no z key, note="seed mode: bands established from baseline"` — never a faked z |
| F | corrupted config | bands.yaml mutated to invalid YAML (restored byte-exact, sha256 match: True) | 1 | **DEFECT: crash, not typed** | unhandled `yaml.YAMLError` traceback on stderr (`expected ',' or ']', but got ':'`), exit 1 via exception — fails the "typed config error, not a crash" contract |

Overall: **FAIL by the letter of the matrix contract** (row F), PASS on every
escalation-tier law (A–E, B-emit, D-emit).

## Defect F (open, for repair lane)

`load_bands()` in `scripts/spc_gate.py` (line 55–58) calls
`yaml.safe_load` with no rescue; malformed `config/bands.yaml` surfaces as a
Python traceback (crash) instead of a typed config error with a clean
nonzero exit. Suggested shape: catch `yaml.YAMLError` and
`KeyError`/`TypeError` on the band schema, print a one-line
`[spc] CONFIG-ERROR: bands.yaml: <reason>` to stderr, exit nonzero (2 would
distinguish config-fail from the 3σ fail-closed 1). Pre-existing gate code
defect, witnessed this session, not introduced by this lane.

## Runner notes (harness, not defects)

- `mix run -e` must run `--no-start` while the substrate holds 9443
  (`:eaddrinuse`), and the `:smalt_event_messages` ETS table must be created
  in-eval (`:ets.new` mirroring `Smalt.Store.init/1` opts) because
  `Store.put` does not lazily create tables. Both handled in the driver.
- The gate APPENDS to `SMALT_SPC_HISTORY` even when the file did not exist —
  case E must start from a clean temp dir or a prior run's append pushes the
  series over `min_points` (8) and masks the seed law.

## Replay

```bash
MIX_BUILD_ROOT=_build-lane507 python3 tmp/spc_audit8/driver.py
```
