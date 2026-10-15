# V261014-16 — OCEL RevOps surface: doc/receipt hardening

- **Release:** v26.10.14
- **Area:** `lib/smalt/ocel/revops/` + pack receipt + release notes
- **Status at open:** surface green — `mix test test/ocel_revops_test.exs` → 3 tests, 0 failures. Read-only law holds (all resources `Ash.DataLayer.Simple`, `defaults []`, no create/update/destroy). All items are documentation/receipt/hazard work, no behavior change.
- **Standing at close (target):** ALIVE_DOC — surface green, receipt matches executable truth, regeneration hazard fenced, moduledocs complete, release notes current. Admission/court gating of the surface itself remains explicitly not-done (unchanged scope).

## Owned files

| File | Items |
|---|---|
| `lib/smalt/ocel/revops/revops.ex` | (1), (4) |
| `lib/smalt/ocel/revops/ocel_trace.ex` | (4) — doc only |
| `lib/smalt/ocel/revops/ocel_deviation.ex`, `fitness_verdict.ex` | (3) — header fences only |
| `docs/PACK_INTEGRATION/ash-ocel-revops.md` | (2) |
| `docs/RELEASE_NOTES_v26.10.14.md` | (5) |

Out of scope: `gen/ash_resource.ex.eex` + `gen/revops_surface.ttl` type repair (option (a) — generator work, deferred); any new admission/court gating.

## Items

### (1) Fix moduledoc typo — `revops.ex:6`

"ProcessConendance" → "ProcessConformance" (the correct name already appears at line 8 of the same moduledoc). One-token edit.

### (2) Pack receipt drift — `docs/PACK_INTEGRATION/ash-ocel-revops.md`

**Drift.** The receipt's "Test subject" paragraph (:60-66) describes res-2 as a 3-event trace (`arm.resource.transition → blob.put → blob.custody.transition`) with fitness `0.833…` and first deviation `blob.put/missing_tokens`. The actual test fixture (`test/ocel_revops_test.exs:20`, exercised :97-101) is:

- 2-event trace: `[arm.resource.transition, blob.custody.transition]` (blob.put absent)
- fitness exactly `0.5833333333333334`
- 2 deviations; first (asserted) deviation `blob.custody.transition/missing_tokens` (:137)
- the emitted `deviations.jsonl` is written by real `DeviationAdmission.admit/2` over real `Conformance.check_trace/2`

**Action.** Rewrite the paragraph to restate the fixture exactly (fitness digits included). Re-run and re-stamp:

```sh
MIX_ENV=test mix test test/ocel_revops_test.exs      # expect: 3 tests, 0 failures
MIX_ENV=test mix test test/ocel_conformance_test.exs # expect: 6 tests, 0 failures
```

Append: "Re-verified v26.10.14 (V261014-16): gate re-run green; test-subject paragraph corrected to the actual fixture (2-event trace, fitness 0.5833333333333334)." Do not change the Standing section's substance.

### (3) Regeneration-clobber hazard — header fences (option (b), this window)

**Hazard.** `gen/ash_resource.ex.eex` (:24-25) renders attribute types verbatim from the TTL spec, and `gen/revops_surface.ttl` (:24-25) carries non-Ash types `string_array` and `utc`; the template also renders no primary key, no `allow_nil?`, no read action — and targets the **same `--out` path** as the shipped hand-adapted files. A well-meaning `mix ggen_igniter.sync` re-run would clobber the working resources with a non-compiling skeleton.

**Action.** Add an explicit `REGENERATION-CLOBBERS` fence to the header comment of all three shipped resources (`ocel_trace.ex`, `ocel_deviation.ex`, `fitness_verdict.ex`), immediately below the existing regenerate-command block:

```
# REGENERATION-CLOBBERS: re-running the command above overwrites this file
# in place with a non-compiling skeleton. The shipped gen/ template + TTL
# still carry non-Ash types (:string_array, :utc) and render no primary key /
# allow_nil?/read action; this file's atom names, real Ash types
# ({:array, :string}, :utc_datetime_usec), primary key, and read action are
# hand-adapted and NOT recoverable from gen/. Do not regenerate until the
# template/TTL are repaired (deferred generator work).
```

Option (a) — fix TTL + template to render real Ash types — deferred; noted in the fence so it is not lost.

### (4) Document `trace_groups/1` key semantics — moduledocs

Expand the `@doc` on `trace_groups/1` (`revops.ex:25-30`, key logic :56-61) and the `OcelTrace` moduledoc:

- Key = first `relationships` entry's `objectId`. Events with **no** relationships (or empty/missing objectId) fall under the positional key `trace-<index>` (0-based position in the source `ocel:events` list) — each forms its own singleton trace.
- Events whose **first** objectId is identical merge into one trace, in first-appearance order; group order is deterministic.
- Time-window caveat (`ocel_trace.ex:55-59`): `start_time`/`end_time` are min/max of the group's raw `"time"` strings after an **ISO-string sort** — correct only for same-format, same-precision ISO-8601; mixed formats/offsets sort lexically, not chronologically. Known caveat, not a bug to fix this window.

### (5) Release notes — `docs/RELEASE_NOTES_v26.10.14.md:74`

Line 74's bullet covers only the "OCEL event stack". Amend (or add an adjacent bullet) naming the Ash RevOps surface explicitly: `Smalt.Ocel.RevOps` domain with `OcelTrace` / `FitnessVerdict` / `OcelDeviation` read-only Ash resources over the real NDJSON sink and deviation ledger; reference the pack receipt `docs/PACK_INTEGRATION/ash-ocel-revops.md`.

## Acceptance criteria

1. `MIX_ENV=test mix test test/ocel_revops_test.exs` → 3/0.
2. Receipt "Test subject" paragraph matches the test fixture exactly (fitness digits included).
3. `REGENERATION-CLOBBERS` fence in all three resource headers.
4. `grep -r ProcessConendance lib/` → 0 hits.
5. `trace_groups/1` semantics + ISO-sort caveat documented.
6. Release notes name the RevOps Ash surface + cite the receipt.
7. No behavior change; read-only law intact (`grep -n "create\|update\|destroy" lib/smalt/ocel/revops/*.ex` shows no action definitions).

## Sequencing

1 → 4 (same file) → 3 (headers) → 2 (receipt re-run last) → 5.
