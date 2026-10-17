# spc

Statistical-process-control drift surface. Generated from the code surface.

## Modules

| module | file |
|---|---|
| `Smalt.Spc.Drift` | `lib/smalt/spc/drift.ex` |
| `scripts/spc_gate.py` | the verdict producer (non-Elixir; drives the emitter) |

## Laws (from `Smalt.Spc.Drift` moduledoc)

- Registry-gated: emission only when the projected closed vocabulary
  (`Smalt.Ocel.EventRegistry`) admits `"spc.drift"` — the emitter is inert
  if the pack regen has not landed.
- Fail-closed: a FAIL verdict (3σ, exit 1) is never laundered into
  telemetry. Only verdicts `EVENT` (1σ) and `DISPATCH` (2σ) emit.
- Matter-isolation: event `data` carries metric name, tier, z, and numeric
  value — never payloads, dumps, or raw keys. The 3σ orphaned-key dump
  stays out of the event plane.
- Fail-safe: nothing raises into the caller; malformed input is
  `{:ok, :skipped}` with a logged drop, never a crash.

Event shape: CloudEvents 1.0 rows in `:smalt_event_messages`
(`Smalt.Messaging.EventStream`, topic `"spc.drift"`), one per drifting
metric.

## Config keys

`lib/smalt/spc/drift.ex` reads no `Application.get_env` keys — the surface
is config-free by design; behavior is pinned by the laws above and the
registry gate.

## Refusal vocabulary

No typed refusals of its own; the emitter is non-raising. Refusal-shaped
outcomes: `{:ok, :skipped}` (malformed input / unadmitted topic) and the
upstream `scripts/spc_gate.py` exit 1 on a 3σ FAIL verdict.

## KD cross-links

No KD register rows name the SPC surface directly. The nearest coupling is
KD-90 (affidavit seal latency band — a latency drift source this gate would
emit on). No row cites `lib/smalt/spc/` today.

## See Also

- `docs/reference/receipt-ledger.md` (OCEL telemetry the drift events ride)
- `docs/BENCHMARKS.md`