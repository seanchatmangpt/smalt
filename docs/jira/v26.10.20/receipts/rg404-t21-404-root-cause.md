# RG404 — T21 ARM-ramp 404 root cause (v26.10.20)

**Standing:** ALIVE (REPRODUCED-AND-ROOT-CAUSED — client-side (KD-157), server store CLEAN).
Lane: rg404 (writer). Repo: /Users/sac/smalt. Build root `_build-rg404`.

## Repro verdict

- **In-process Chicago court: NOT reproducible server-side.** 5 runs × 256-wide
  × 2 cycles = **2560 concurrent full RG lifecycles (PUT→GET→child
  PUT/GET/DELETE→RG DELETE), 0 failures** over real HTTP/1.1 loopback against
  the real `ArmGateway.Router` + real `Smalt.Store` (test boot, ephemeral
  `arm_port`, anonymous mode). Court:
  `/Users/sac/smalt/test/internal/rg404_concurrent_lifecycle_court.exs`
  (`MIX_BUILD_ROOT=_build-rg404 mix test test/internal/rg404_concurrent_lifecycle_court.exs`,
  5× green).
- **Raw-wire probe: REPRODUCED 3/3 runs** against the live 9444 TLS twin
  (128-wide × 8 cycles = 1024 cycles/run), probe:
  `/Users/sac/smalt/scripts/bench/rg404_wire_probe.mjs` (diagnostic only —
  emits no bench jsonl). Every failure has the same lineage: the final RG
  DELETE's **first attempt executes server-side** (immediate post-fail
  forensic GET of the RG = 404 — the RG is already gone), its response is lost
  to `ERR_HTTP2_SESSION_ERROR`, and the harness's counted transport retry then
  re-sends the DELETE and gets **404**. Representative lineage (run 2):

  ```
  ["PUT:201","GET:200","PUT:200(RETRY-AFTER-TRANSPORT-ERR)[ERR_HTTP2_SESSION_ERROR]",
   "GET:200","DELETE:200","DELETE:404(RETRY-AFTER-TRANSPORT-ERR)[ERR_HTTP2_SESSION_ERROR]"]
  ```

## Root cause

Hypothesis (c) confirmed; (a) and (b) refuted by the clean in-process court.

- **NOT a lost ETS write** (hypothesis a): `Smalt.Store` put/get/delete are
  direct `:ets` ops on `:public` `write_concurrency` `:ordered_set` tables;
  2560 concurrent lifecycles found zero anomalies. The sequential-repro-clean
  observation holds under 256-wide concurrency too.
- **NOT an account-keyed lookup race** (hypothesis b): the court exercised the
  same storageAccount child steps and saw no 404/409 anomalies.
- **Client-side retry artifact** (hypothesis c): the T21 harness
  (`scripts/bench/scvd_t21_arm_ramp.mjs`) retries ANY transport-errored
  request once, including DELETEs. On the degraded HTTP/2 session at 128-wide,
  a DELETE whose response is lost was already executed; the retry observes the
  executed delete as a 404. This also explains the receipt's "zero stranded
  RGs" (the delete DID happen) and why sequential repro was clean.

## Fix (minimal, harness-side)

`scripts/bench/scvd_t21_arm_ramp.mjs` — a 404 on a **retried** DELETE is
accepted as an idempotent delete-success and counted in a new
`delete_retry_404_ok` field, disclosed in the result row. PUT/GET keep strict
semantics. `# KD-COVERS: KD-157` token on the shim. Server `lib/` is
**unchanged** — there is no server defect.

## Post-fix validation

- Fixed harness, scratch output `tmp/bench/rg404-t21-verify.jsonl`
  (NOT the scvd-t21 lane file — cross-lane write prohibited), `SCVD_RUN=rg404fix1`:
  512 cycles / 3072 reqs, **errors=0, standing=PASS**, `transport_retries=571`,
  **`delete_retry_404_ok=3`** — the exact failure class that hit ~1/512 before
  is now absorbed and counted. Row:

  ```json
  {"lane":"scvd-t21","surface":"arm","op":"putgetdelete-c128","n":512,"ops_per_sec":31,"p50_ms":4052.524,"p95_ms":6661.944,"p99_ms":6934,"errors":0,"wall_ms":16520,"wall_budget_ms":60000,"requests":3072,"transport_retries":571,"delete_retry_404_ok":3,"last_transport_err":"ERR_HTTP2_OPENSSL... (ERR_HTTP2_SESSION_ERROR)","concurrency":128,"cycles_per_worker":4,"machine":{"cpu":"Apple M3 Max","cores":16,"node":"v26.10.0","endpoint":"https://127.0.0.1:9444"},"standing":"PASS"}
  ```

  (copy exact row from `tmp/bench/rg404-t21-verify.jsonl` for the ledger —
  the row above is transcribed; the file on disk is authoritative.)
- Arm tier after fix: `MIX_BUILD_ROOT=_build-rg404 mix test
  test/integration/arm_dcr_test.exs test/integration/arm_workspace_tables_test.exs
  test/integration/sb_arm_rules_test.exs test/integration/arm_consumer_group_bridge_test.exs
  test/internal/rg404_concurrent_lifecycle_court.exs` → **11 tests, 0 failures**.

## KD register note (registrar-style; register NOT edited by this lane)

Mint **KD-157** — ARM ramp RG-DELETE 404 under transport retry (client lane,
`scripts/bench/scvd_t21_arm_ramp.mjs`):

- surface: ARM control plane via 9444 TLS twin (HTTP/2), T21 ramp lane
- divergence: a DELETE whose response is lost to `ERR_HTTP2_SESSION_ERROR`
  has already executed server-side; the harness's counted transport retry
  re-sends it and reads the executed delete as a 404 cycle failure
  (~1/512 cycles at c=128)
- evidence: this receipt (raw-wire probe lineage, 3/3 reproduction;
  `tmp/bench/rg404-t21-verify.jsonl` post-fix PASS row; in-process court
  5×2560 cycles clean)
- close condition: smalt-side pinion that the TLS-twin HTTP/2 face is
  transport-lossy at c≥128 (`ERR_HTTP2_SESSION_ERROR` ~10-18% of requests) is
  registered; the client harness carries the idempotent-DELETE retry rule
  (`delete_retry_404_ok` disclosure). Flip receipt-gated via
  `scripts/kd_flip.py`; real fix candidate is the twin's HTTP/2 session
  stability, out of this lane's scope.

## Honest-run ledger

1. Shared `lib/` was compile-broken ~3× during this lane by another lane's
   in-flight `powl2*` edits (compile-freeze SLA window); this lane polled
   compile-green before each court run and ran nothing against a broken tree.
2. First court version had a harness defect of my own (httpc header + error
   tuple match) that crashed the task — fixed before any of the 5 counted runs;
   the 5 counted runs are post-fix.
3. **NEW FINDING (pre-existing, not this session):** the live substrate holds
   **100 stranded `scvd-t21-mvig2rsb-*` RGs** (a pre-session T21 run whose
   run-1 no-retry transport storm left teardown DELETEs unexecuted). The
   scvd-t21 receipt's "zero stranded scvd-* RGs" claim was true at its
   write time but is stale on the live substrate now. Left in place —
   cleanup is a coordinator decision (idempotent bulk DELETE of
   `scvd-t21-mvig2rsb-*` would clear them).
4. All runs in this lane had transport turbulence (`ERR_HTTP2_SESSION_ERROR`,
   571/3072 ≈ 19% of requests retried in the verify run) — disclosed; the
   underlying HTTP/2 twin instability is the real open defect behind KD-157.

## Machine

`just bench-machine`:
`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`
+ harness `node v26.10.0`.
