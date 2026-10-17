# Capability: finops avoided-spend calculator

Standing: PASS — pure deterministic surfaces, real runs green on both the
TypeScript original and the Elixir port.

## Surfaces

- TS original: `/Users/sac/smalt/workspace/lib/finops/calculator.ts`
  (Agent 14 finops lane). Pure functions over a run manifest, no
  substrate, no I/O. `RETAIL_TARIFFS` table cites published Azure retail,
  approximate; formula `count * (usdPerHour * avoidedHours + usdPerUnit)`;
  SHA-256 receipt over canonical-JSON inputs with honest
  `pqc_status: 'PQC_NOT_PROVISIONED'`.
- Elixir port: `/Users/sac/smalt/lib/smalt/fin_ops/calculator.ex` —
  moduledoc states the transcription discipline verbatim: tariffs and
  formula transcribed 1:1 from the TS source (730 h/mo proration); typed
  errors map `FinopsError('UNKNOWN_RESOURCE_TYPE')` →
  `{:error, :unknown_resource}`.
- Courts: `/Users/sac/smalt/workspace/test/finops_report.test.ts`
  (node:test, tsc-compile-and-run) and
  `/Users/sac/smalt/test/fin_ops_calculator_test.exs` (ExUnit).

## Honest-port disclosure (region extension)

The TS `computeAvoidedSpend` has no region dimension. The Elixir port's
`region/1` multiplier table (`:eastus` default 1.0; `:westus2`,
`:northeurope`, `:southeastasia`) is an Elixir-side extension, documented
as such in the port's moduledoc (`lib/smalt/fin_ops/calculator.ex`
lines 10-14) — not claimed as TS parity.

## Real runs

Elixir court (this lane, `MIX_BUILD_ROOT=_build-lane11` via
`scripts/fast_test.sh`):

```
$ scripts/fast_test.sh test/fin_ops_calculator_test.exs
...................
Finished in 0.05 seconds (0.05s async, 0.00s sync)
19 tests, 0 failures
[15:19:50] wall: 167s (build root: _build-ft-a9b6a3ad)
```

TS court (per the runner documented in the test header; tsc 5.7 needs
`--ignoreConfig --ignoreDeprecations 6.0` for the commandline-compile form):

```
$ node --test "$T/test/finops_report.test.js"
ℹ tests 9
ℹ pass 9
ℹ fail 0
ℹ skipped 0
ℹ duration_ms 96.514834
```

Combined: 19/0 Elixir + 9/0 TS. Deterministic golden total, key-order
independent digest, typed-error legs, and the
"PQC receipt honest PQC_NOT_PROVISIONED" leg all pass in the TS court.
