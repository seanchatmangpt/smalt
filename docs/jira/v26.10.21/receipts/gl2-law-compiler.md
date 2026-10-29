# GL-2 — shape→guard law compiler (LawCompiler)

- **Date**: 2026-10-21
- **Lane**: GL-2 (writer, OTP-29), repo `/Users/sac/smalt`, build root `_build-gl2`
**Standing**: PASS (court 10/10, twice, real TTL + real context maps; no mocks)
Context: solo

## Module

`/Users/sac/smalt/lib/smalt/powl2/law_compiler.ex` — `Smalt.POWL2.LawCompiler`

- `compile_shape/2` — `(shape_iri, ttl) → {:ok, guard_fun} | {:error, {:parse_error, _}} | {:error, {:unknown_shape, _}}` per the spec contract.
- `guard_fun.(ctx_map) → :ok | {:violation, rule_id, diagnostic}`; rule_id = `"<Shape>/<class>/<path>"` (e.g. `OrderShape/maxInclusive/orderTotal`).
- `compile_all/1` — every shape in a TTL to `%{local_name => guard_fun}`.
- `parse!/1` — TTL-subset parser in the `Validator.ShapeFile` token discipline (quote-aware comments, prefixed names, `<IRI>`s, string/int/float literals; `@prefix` lines skip as non-shape statements). Reuses the graphlaw substrate laws (KD-156 absent-minCount-is-optional, fail-closed missing value, typed non-conforming-type violation) without duplicating ShapeFile's statement grammar — disclosed: the shapes-file parser raises by design on `sh:maxInclusive`/`powl:notEquals`, so the law grammar is an adaptation, not a copy.

## Constraint classes (spec's three, all enforced)

- **maxInclusive**: numeric ceiling on a path. `order > 10k ⇒ sh:maxInclusive 10000` on `orderTotal`; passes at/below ceiling incl. the 10000 boundary; over/missing/non-numeric ⇒ violation, never a crash.
- **minCount** (GDPR consent): `sh:minCount 1` presence; absent/nil ⇒ violation; any non-nil value passes.
- **exclusion** (subject≠object): `powl:notEquals <peerPath>` in a `sh:property` block; equal values ⇒ violation; either side absent ⇒ not violated (presence is minCount's job, not the relation's — typed decision, pinned in moduledoc and court).

## Court

`/Users/sac/smalt/test/internal/powl2_law_compiler_court.exs` — 10 tests over 5 describes: maxInclusive (4), minCount (1), exclusion (2), typed compile errors (2), compile_all (1). Chicago discipline: real TTL text, real guard execution, no doubles.

## Court results (real output)

```
Finished in 0.07 seconds (0.00s async, 0.07s sync)
Result: 10 passed
```

Two consecutive green runs. An intermediate 9/10 was a court-side assertion defect (the shape's custom `sh:message` overrides the default diagnostic; the court had asserted default-diagnostic numbers against the override) — fixed forward, re-run green.

## Disclosed compile-freeze unblocks (other lanes' files, minimal)

1. `lib/smalt/powl2/executor.ex` `run_guard/4`: added `{:violation, rule_id, diag} → {:andon_refusal, rule_id, diag}` so LawCompiler verdicts normalize into GL-1's andon envelope instead of `:bad_guard_verdict`. GL-1 concurrently landed their own changes the same window.
2. `lib/smalt/data_plane/cosmos_query_metrics.ex` `int_in` defguardp: `is_integer(x, lo, hi)` does not compile as a guard on Elixir 1.20.4-otp-29; replaced with the semantically identical `is_integer(x) and x >= lo and x <= hi` chain (bignum arm clause still covers >= 0 above the ceiling).

`lib/smalt/tls.ex`, `lib/smalt/wasm/worker.ex`, `lib/smalt/powl2/andon_wire.ex` breakages during the window were owned-lane active edits (fresh mtimes) — NOT touched; polled until owners landed.

## Boundaries / falsifiers

- `String.split/3` with a list pattern requires explicit options `[]` on Elixir 1.20; `local_name/1` splits on `#`, `/`, and `:` so prefixed and full-IRI forms resolve to the same shape key and path key.
- Unsupported constraint keyword inside a property block, missing `sh:path`, mixed constraint classes per block, unterminated string/IRI — all typed `{:parse_error, _}`.
- Not a bench lane: no jsonl emitted; `scripts/bench/` shared infra, REGISTRY.md, and justfile.d untouched.
