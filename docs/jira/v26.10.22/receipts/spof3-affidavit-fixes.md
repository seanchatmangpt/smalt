# SPOF-3.1 / SPOF-3.2 — Affidavit WasmEngine fixes (lane spof3)

**Standing:** **ALIVE** — both fixes landed and verified post-fix on the
real wasm artifact; the SPOF-3.1 "256MiB wedge" premise is CORRECTED (does not
reproduce on the pinned affidavit artifact; see Falsifier below). The PARTIAL
was pending BK-84's record correction, now landed: see
`docs/jira/v26.10.22/receipts/bk84-spofb-correction.md` (addendum in
`spofb-boundary-audit.md` supersedes the wedge classification; SPOF-3.2
stands; sweep found no other repeats) — closing authority for this flip.
Context: solo
Date: 2026-10-21
Repo: /Users/sac/smalt (main, dirty shared checkout; lane owns
`lib/smalt/affidavit/wasm_engine.ex` + new court `test/internal/spof3_affidavit_engine_court_test.exs`)

## Diff

`lib/smalt/affidavit/wasm_engine.ex` caller path — SPOF-3.2:
- `call/2` → `call(pid, request, timeout_ms \\ 5_000)`; the exit-catch
  classifies `{:timeout, _}` exits as the new typed `{:error, :engine_busy}`
  (engine live, serialized server occupied past caller budget — retryable)
  vs everything else `:engine_unavailable`. Same classification in
  `call_admit_and_seal/4` and `call_json/1`. `affi_admit_and_seal/1` passes
  `:engine_busy` through (was a `_` catch-all that would have swallowed it).
- Specs updated (`call_json`, `affi_admit_and_seal`).

`lib/smalt/affidavit/wasm_engine.ex` guest-block lifecycle — SPOF-3.1:
- `run_request/2`: input block `af_alloc(len)` is now freed on EVERY path via
  try/after (`execute_request/6` under `after free_block(...)`);
  over-cap refusals already refused pre-alloc (fence-2), zero-alloc
  refusals handled at the alloc site.
- `run_seal/5` → `run_seal` + `seal_with_delta` + `do_seal`: BOTH guest
  blocks (delta_ptr and out_ptr) freed via nested try/after on every path
  (nonzero machine code, invariant refusal, read failure, trap); `free_out`
  → `free_block` (best-effort, ignores result — a post-trap dead instance is
  the supervised-restart class).
- No double-free: the old inline `free_out` step removed from both with-chains.

## Falsifier court (test/internal/spof3_affidavit_engine_court_test.exs)

Real wasm artifact (`priv/wasm/affidavit_wasm.wasm`), real NIF, real
concurrent callers; bounded polls only, zero sleeps. Two legs:

1. **SPOF-3.1 leg**: 80 × (16MiB−1B) successful `call_json/1` requests
   (cumulative 1.31GiB, 5x the audit's projected 256MiB wedge point), every
   response non-empty guest JSON; then a 1KiB request admits and two
   consecutive seals return DETERMINISTIC identical typed answers
   (never :engine_unavailable).
2. **SPOF-3.2 busy leg**: occupy the engine with a real 16MiB af_call in one
   task; concurrent caller with 1ms budget observes typed
   `{:error, :engine_busy}`; engine pid unchanged, occupier completes with
   guest JSON, follow-up call admits — busy ≠ down witnessed on the same
   engine instance.

### BEFORE (pre-fix witness, HEAD wasm_engine.ex swapped in via snapshot-swap, sha-verified restore)

- 80 × 16MiB = 1.31GiB cumulative in 3093ms, 80/80 non-empty guest responses,
  post-drive 1KiB → `{:ok, "{\"error\":{\"code\":\"bad_json\"...\"ok\":false}"}`.
  **The projected 256MiB wedge does NOT reproduce**: the guest's `af_alloc`
  does not exhaust the way GWS-11 measured for graphlaw's `gl_alloc` — the
  256MiB outstanding-budget figure was measured on a DIFFERENT engine
  (`docs/jira/v26.10.21/receipts/gws11-wasm-memory-wall.md` subject), not the
  affidavit artifact's af_alloc. Fix retained as ABI-contract hygiene
  (af_free pairing per the module's own documented C-ABI), and the court
  pins the measured no-wedge bound.
- SPOF-3.2: no pre-fix witness leg possible (call/3 is new API); pre-fix
  behavior (catch-all `:exit → :engine_unavailable`) is committed code at
  wasm_engine.ex:168/248/270 on HEAD, unchanged here.

### AFTER (fixed engine)

- Court + lifecycle regression: `Result: 6 passed`, exit 0, 4.0s.
- Busy leg observes `{:error, :engine_busy}` while the 16MiB occupier is
  in flight; engine pid unchanged; next call admits.

## Commands / exits

```
MIX_BUILD_ROOT=_build-spof3 asdf exec mix compile                                       # exit 0
MIX_BUILD_ROOT=_build-spof3 asdf exec mix test test/internal/spof3_affidavit_engine_court_test.exs \
  test/internal/wasm_nif_lifecycle_test.exs          # exit 0 — Result: 6 passed (4.0s)
# pre-fix probe (HEAD engine swapped in, 80x16MiB): 1.31GiB in 3093ms, 80/80 nonempty,
#   1KiB admits, seal deterministic — wedge premise falsified (log /tmp/spof3-internal-run.log scratch)
# whole-dir census abort (pre-existing, NOT this lane):
MIX_BUILD_ROOT=_build-spof3 asdf exec mix test test/internal/   # exit 1 — compile-abort at
#   test/internal/ja15_error_logger_court_test.exs:235 (syntax error, JA-15b lane, clean at HEAD,
#   untouched here — a compile abort is not a failure count)
```

## Observations (pre-existing, out of scope, flagged)

1. **Seal invariant gate fails deterministically**: `call_admit_and_seal/4`
   on any probe delta returns `{:error, :invariant_violation}` (structural
   legs pass; the blake3 leg — b3sum installed — mismatches the CTRT
   [70..102] segment). No test in the tree exercises a SUCCESSFUL seal; the
   trust_profile PQC witness therefore always falls back to
   `:PQC_NOT_PROVISIONED`. Candidate KD row / court: the blake3 layout leg of
   the invariant gate vs the artifact's actual CTRT layout.
   **[AS-OF 2026-10-21, BK-85]** This observation is historical, superseded by
   `receipts/bk85-seal-invariant.md` + KD-164: the root cause was a CALLER bug
   (delta bytes never written to the guest block), not the blake3 layout leg —
   every seal was refusing for that reason. Fixed; successful seals are now
   witnessed (shim court + KD-164 CLOSED-WITH-EVIDENCE) and the
   `unverified_blake3_host`/`:PQC_NOT_PROVISIONED` fallback no longer fires.
2. **`test/internal/ja15_error_logger_court_test.exs:235`** is a syntax error
   at HEAD (JA-15b lane) — every whole-dir `test/internal/` run compile-aborts
   (exit 1, 0 tests) until that lands. Compile-abort ≠ failure count.
