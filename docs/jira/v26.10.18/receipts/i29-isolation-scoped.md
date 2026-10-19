# i29 isolation court — scoped (clean-scope) leak figure

Date: 2026-10-18.

Context: solo(scoped 11-file serial run, private build root `_build-ft-scoped12`, no git operations, no edits).

## Question

The runtime twin (`scripts/isolation_court.py --runtime-only`) counted 12 leaked
modules against a 101-failure concurrent-load background; the failure count
pollutes the leak figure. Isolate the true-leak figure in a clean scope.

## Method

`scripts/isolation_court.py` exposes no per-module mode (`--help`: `--runtime`,
`--static-only`, `--self-check`, `--runtime-only`; `cmd_runtime()` hard-codes the
full suite). So per step 3: serial scoped run of the 11 files covering the 12
named modules, with the twin's own formatter and the court's own classifier:

```
MIX_BUILD_ROOT=_build-ft-scoped12 mix test --formatter SmaltTest.IsolationFormatter \
  --max-cases 1 \
  test/canonical_projection_test.exs test/amqp/r129_session_gate_test.exs \
  test/semantic_epoch_test.exs test/mix_auth_scope_test.exs \
  test/azsim/integration_plane_test.exs test/azsim/dr_scenarios_test.exs \
  test/smalt_services_test.exs test/enclave_doctor_env_test.exs \
  test/amqp/cbs_router_test.exs test/court_ocel_test.exs test/amqp/sas_verifier_test.exs
```

The formatter diffs at ExUnit.TestCase boundaries (snapshot of
`Process.registered()/0` + `Application.get_all_env(:smalt)` at case_started,
diff at the NEXT case_started), so a scoped serial run is structurally valid:
each module gets its own baseline. Classification applied
`isolation_court.classify_leaks` with the live 14-pattern exemption list
(`test/support/isolation_runtime_exemptions.exs`); env deltas are never
exemptable, and every counted block here carries one.

## Pre-condition: Lane C dirt

`git status --porcelain test/ | wc -l` = **16** (15 modified + 1 untracked,
`test/e2e/s2_byok/s2_run.patch.py`). Lane C is still dirty — noted, untouched.

## Result

Two runs of the identical command: run 1 summary `modules_leaked=5`,
run 2 `modules_leaked=6`; both `tests=121 failures=0`, `mix exit=0` — all 11
files pass clean in scope, so no flag can be attributed to failure-adjacent
noise. Full log: `/tmp/scoped12_full.log` (court-formatter LEAK blocks inline).

Counted (court-rule) leak figure scoped: **6 modules**, stable across both
runs except one flap (below):

| module | verdict | deltas |
|---|---|---|
| EnclaveDoctorEnvTest | LEAK (true) | env `:auth_mode` :enforce/:anonymous |
| Smalt.Telemetry.CourtOcelTest | LEAK (true) | env `:sb_shared_key` set/nil |
| Smalt.Amqp.CbsRouterTest | LEAK (true) | env `:sb_shared_key` nil/set |
| Smalt.CanonicalProjectionTest | LEAK (true) | env 6 port keys (ephemeral ports) |
| Smalt.Amqp.R129SessionGateTest | LEAK (true, flaps) | env `:sb_shared_key`; name `Smalt.Amqp.CbsRouter` (exempt-matched, env counts) |
| SmaltServicesTest | LEAK (true) | env `:maa_measurement_baseline`; name `Smalt.Security.LedgerWriter` (exempt-matched, env counts) |
| Projection.IdentityTest | CLEAN | no block |
| MixAuthScopeTest | CLEAN | no block |
| IntegrationPlaneTest | CLEAN | no block |
| DrScenariosTest | CLEAN | no block |
| SasVerifierTest | CLEAN | no block |
| SasPinnedFallbackTest | CLEAN | no block |

## Finding

**True-leak figure: 6 of the 12** — six modules self-leak Application-env
deltas even in a clean scope with zero test failures. The other 6 named
modules show no leak in scope; their full-suite flags are cross-module
boundary attribution (the twin attributes shared-tree shifts to whichever
module spans the boundary) or concurrent-load pollution, not self-leaks.

Run-to-run variance: `Smalt.Amqp.R129SessionGateTest` appeared in run 2 only
(run 1: 5). Its `Smalt.Amqp.CbsRouter` name delta is exempt-matched
(`Smalt.Amqp.*`); only the env delta counts, and its presence flapped between
runs — a boundary-timing sensitivity, flagged for the repair lane.

Standing: PARTIAL_ALIVE — scoped true-leak count is measured and receipted;
the 6 env-delta self-leaks are unfixed (that is the repair lane's work).
