# V261014-18 — Mutation Courts: wire-tier sweep + engine-kill court + probe-protocol decision

- **Release:** v26.10.14 · **Status:** READY
- **Type:** release work order (test hardening + receipt update)
- **In-scope files:** new `test/wire_tier_refusal_sweep_test.exs`; new describe in `test/egress_dispatch_test.exs` (or standalone file); `docs/BENCHMARKS.md`
- **Out of scope:** `lib/` product code (both gaps are verification gaps — if either test FAILS, that is a found defect to be filed, not patched here); `scripts/mutation_court.py`; upgrading the six probes this release.

## 1. Background

Exactly one full-court mutation protocol exists: `scripts/mutation_court.py` — BEFORE/AFTER/restore, sha256 byte-exact restore, exit 2 = BLOCKED. Receipt at `docs/BENCHMARKS.md:115-139`, NON-VACUOUS (7 rows PASS).

Six one-shot mutation-probe claims exist without the protocol:

| Probe claim | Location |
|---|---|
| cosmos continuation forged-check | DEV_LOOP refresh-6 row |
| auth criticality fence | DEV_LOOP refresh-6 row |
| blob If-Match precheck | `docs/DEV_LOOP.md:24` ("3/3 non-vacuous") |
| typ-header court | `docs/WIRE_PARITY.md:121` |
| tee-admit jti | `docs/WIRE_PARITY.md:113` |
| LRO lens-9 | `docs/WIRE_PARITY.md:94` |

### Verified coverage gaps

**Gap 1 — wire-tier malformed-payload refusal not swept across all admitted types.** Unit tier only (`test/smalt_graphlaw_validator_test.exs:290`, 38 types × per-property deletion, against `Validator.shapes()` directly) + court M2/M3 (2 types wire-tier). No test asserts every type in `Smalt.Registry.admitted_resource_types()` (~38, `lib/smalt/registry.ex:17`, accessor :142) answers malformed payload with `400 InvalidResourceShape` over real dispatch. ARM never 422; a type slipping through with 422/500/202 is invisible to both layers.

**Gap 2 — no court kills the live engine for the 503 law.** `RouteNotReady` 503 fail-closed is pinned at dispatch tier by *simulating* module-not-compiled (`egress_dispatch_test.exs:1402,1499,1557,1578,1619`; `egress_router.ex:1356-1380` `with_modules`). No test kills the real engine and proves real HTTP fails closed 503, never 201/200.

**Gap 3 — the six probes are unprotocol'd.** Deferred decision, §3.3.

**Benign-noise note (no work):** Spark DSL warnings in test output are EXPECTED refusals from `ash_extension` `generated_verify.ex:40-57,:66-116`, exercised deliberately by `test/ash_extension_test.exs:108-133` (`compile_refused` under `Code.with_diagnostics`). Do not file, silence, or "fix."

## 2. Scope

## 3. Implementation plan

### 3.1 Wire-tier refusal sweep (`test/wire_tier_refusal_sweep_test.exs`)

1. Enumerate types **dynamically**: `Smalt.Registry.admitted_resource_types()` — no hardcoded 38. Sanity tripwire `assert length(types) >= 30`.
2. Boot the real server on an ephemeral port (`SMALT_BENCH_ARM_PORT` auto-scope per `docs/BENCHMARKS.md:101-104`).
3. For each admitted type, resolve its ARM path via the router's own type→path resolver (`router.ex:1048` does the reverse lookup — reuse the admitted-type table, not a copy); PUT a malformed body (missing a required top-level property — invert the lens-2 conforming generator at `smalt_graphlaw_validator_test.exs:295-300`).
4. Assert per type: 400 + `"InvalidResourceShape"`, never 422, never 2xx.
5. Gate-visible in plain `mix test` (no tag gating).
6. Contrast row (vacuity guard): for ONE type also issue a conforming PUT and assert admitted (2xx) — proves the sweep catches a validator that refuses everything.

### 3.2 Engine-kill court

1. Boot server, capture a valid baseline: real `:gen_tcp` request → 2xx (BEFORE).
2. Kill the engine for real, in preference order: (a) terminate/kill the module-holding supervisor child if one exists; (b) purge/unload the graphlaw module (`:code.delete/1` + `:code.purge`) so `not_ready?/2`'s `Code.ensure_loaded?/1` genuinely fails — for a functional engine, module unload IS the live-engine kill, materially different from the existing seam-faked tests.
3. Same request over real `:gen_tcp` HTTP: assert 503 + `"RouteNotReady"`; write `refute status in [200, 201]` alongside `assert status == 503` so the failure message states the law.
4. Restore (reload/recompile or restart the child) and issue a third request: 2xx (AFTER — proves the kill was real and the court non-vacuous).
5. Isolation: follow the detached-process discipline at `egress_dispatch_test.exs:1523` ("a detached … collateral 503'd sibling tests at some shuffle seeds") — run the kill against an isolated child so shuffled siblings don't inherit a broken engine.

### 3.3 Probe-protocol decision (documentation only)

**Recommendation: DEFER full-court upgrade of the six probes; stamp them as dated one-shot receipts in `docs/BENCHMARKS.md`.** The two real courts above close the substantive coverage gaps; the probe upgrade is bounded follow-up (V261014-18a if pursued). Each probe gets: name, doc pin, one-shot date, "one-shot — not full-court protocol" stamp. Never label them "courts" anywhere.

### 3.4 Receipt update (`docs/BENCHMARKS.md`)

- Rows for the wire-tier sweep: N types × malformed → 400 InvalidResourceShape + conforming contrast row, with run date.
- Rows for the engine-kill court: BEFORE 2xx / KILL → 503 RouteNotReady / RESTORE 2xx, verdict NON-VACUOUS, run date.
- One-shot receipt stamp block from §3.3.
- Carry the existing disclosure style (cf. the "first court attempt FAILED" disclosure at :130-139): any failed first run is disclosed, not silently re-run.

## 4. Sequencing

1. Wire-tier sweep (independent; largest value).
2. Engine-kill court (land with its isolation discipline worked out).
3. Receipt update last, after both green in a settled tree.

## 5. Risks / notes

- **The sweep may surface real defects** — if any type answers 422/500/2xx to a malformed payload, file it; do not weaken the assertion or special-case the type.
- Module unload mutates global code state — restore and verify before the test ends.
- Type→path resolution is the main unknown; if some admitted types have no ARM route (internal-only), assert exactly that set explicitly rather than silently skipping — an unexplained skip is a vacuity hole.
- The `>= 30` tripwire is a floor, not a pin.

## 6. Acceptance criteria

1. Sweep iterates `admitted_resource_types()` dynamically — zero hardcoded type counts/names.
2. Per type, over real dispatch: 400 + `InvalidResourceShape`, never 422/2xx.
3. Engine-kill court over real `:gen_tcp` HTTP: 503 `RouteNotReady`, refutes 201/200, restore-verify phase proves non-vacuity.
4. Both tests pass in plain `mix test` (gate-visible).
5. `docs/BENCHMARKS.md` receipt updated: dated rows for both courts + one-shot stamps for the six probes; no probe labeled "court."
6. Spark DSL warnings noted as benign in the receipt; no silencing work performed.
