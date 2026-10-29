# GL-5 — graphlaw stochastic agent bounding court

Date: 2026-10-21 · Lane: GL-5 (writer, OTP-29) · Context: solo

**Standing:** **ALIVE** — court file landed, green across 3 consecutive runs, deterministic.

## Subject

- Court: `/Users/sac/smalt/test/integration/graphlaw_agent_bounding.exs`
  (`Smalt.GraphLawAgentBoundingTest`, seed `{500005, 777, 13}`, 500 proposals)
- Seam: GL-1 admission law = `Smalt.GraphLaw.Validator.validate_resource/2`
  over the real compiled SHACL shapes (`priv/shacl/smalt-shapes.ttl` +
  `Smalt.Registry` bindings); GL-2 ANDON law = refusal receipts in a
  dedicated ETS log naming `constraint:path` per violated rule.

## Run output (real, repeated 3x)

```
$ MIX_BUILD_ROOT=_build-gl5 asdf exec mix test test/integration/graphlaw_agent_bounding.exs
Running ExUnit with seed: 804901, max_cases: 32
.
Finished in 0.08 seconds (0.00s async, 0.08s sync)
Result: 1 passed
```

Seeded distribution (recomputed independently):
`violating=163 lawful=337` (32.6%, inside the court's 120..180 fence).

## Contracts witnessed

1. Zero violating mutations: full ETS data-plane snapshot ==
   lawful-only replay (163 refusals, 0 rows).
2. Every violation minted an ANDON receipt naming the rule
   (`minCount:location`, `minCount:addressPrefixes`, `closed:zzz`,
   `type_not_admitted:Microsoft.Fabric/bogusInstances`), each matching
   its class's expected family.
3. All 337 lawful proposals executed (ref-set equality + exact payloads).
4. Self-correction contract: receipt families ==
   `["closed", "minCount", "type_not_admitted"]` — every distinct rule
   family hit is named.

## Compile-freeze disclosure (SLA)

The shared compile was broken by another lane's in-flight
`lib/smalt/powl2/` files (`andon.ex` duplicate `agent_message/3` —
self-fixed by the owner mid-lane; `executor.ex` invalid
`verdict = fun.(ctx) catch ...` binding). GL-5 applied the minimal
unblock to `lib/smalt/powl2/executor.ex` `run_guard/4` only: wrapping the
catch in an explicit `try do ... end` block. The rest of that file's diff
is the owner lane's in-flight work.

## Falsifier

A run in which any violating proposal leaves a row in the data plane, an
ANDON count != violating count, or a receipt set missing a rule family
fails the court (exit 1).
