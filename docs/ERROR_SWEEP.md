# Error Sweep — lib/smalt try/rescue/catch classification

Sweep 2026-10-14, canonical checkout ~/smalt, concurrent-lane aware
(files modified within 15 min of sweep time were skipped and are listed IN-FLIGHT).

Classification:
- BOUNDARY-TRANSLATOR: typed refusal at a protocol edge (legal).
- SWALLOW / LOG-AND-CONTINUE: degradation — fixed fail-closed.
- WITNESS: rescue that converts a failure into an explicit test failure — legal.

## Fixed this sweep

| file:line (pre-fix) | class | verdict | fix applied |
|---|---|---|---|
| lib/smalt/messaging/amqp/sweeper.ex (whole module) | LOG-AND-CONTINUE | tolerate-absence + log-once-and-skip retired; all sibling sweeps (LockManager.sweep/1, QueueStore.sweep/0, CbsRouter.gc/1, EventHubs.sweep/0) now called directly; a sibling failure raises and crashes the GenServer (supervisor restart = honest signal) | rewritten fail-closed; witness: test/amqp/broker_facade_test.exs "run_pass/0 calls every sibling sweep directly" (retired helpers must be undefined, every sibling exported, real pass :ok). The first green run of that test exposed the previously-swallowed missing-ETS-table failure inside QueueStore→LockManager sweep, now handled by starting the real Smalt.Store in setup |
| lib/smalt/telemetry.ex:209 (RollingCounters init/1) | SWALLOW (latent) | `:ets.new(:smalt_rolling_counters, ...)` lacked `:named_table` — the atom was a suggestion, table unnamed, so the fail-closed `bump/1` name access raised ArgumentError on every emit (11/11 telemetry tests red). FIXED (disclosed compile-freeze fix, file past its lane's SLA) | added `:named_table`; test/telemetry_test.exs 11/11 green |
| lib/smalt/tls.ex bandit_opts/2 | SWALLOW | `:auto` TLS mode silently downgraded https→http on dev-cert generation failure (no graceful degradation) | `{:error, :tls_disabled}` (explicit config) still maps to :http (typed opt-out); any other cert failure now raises ArgumentError at boot |
| test/metadata_endpoints_test.exs:64 | SWALLOW (harness) | TLS twin boot failure was rescued and degraded the listener list to http-only | rescue deleted; TLS boot failure now fails the test loudly |

## Verified legal (BOUNDARY-TRANSLATOR / WITNESS)

| file:line | class | verdict |
|---|---|---|
| lib/smalt/tls.ex:147 safe_decode/1 (`rescue _ -> :error`, consumed by parse_cert's `with`) | BOUNDARY-TRANSLATOR | external cert bytes -> `:error`, handled by the `with` chain |
| lib/smalt/tls.ex:229 sign_tbs/1 | BOUNDARY-TRANSLATOR | raise -> `{:error, e}`, propagated to caller |
| lib/smalt/security/receipt_signer.ex:80,184,193 (split/un_b64url/decode_json) | BOUNDARY-TRANSLATOR | wire token bytes -> `{:error, :invalid_token/:invalid_base64/:invalid_json}`, consumed by `with`; caller answers 401-class refusal |
| lib/smalt/graphlaw/validator.ex:373 engine fast-path | BOUNDARY-TRANSLATOR | optional external engine failure -> documented `{:refused, :engine_unavailable}` typed verdict |
| lib/smalt/data_plane/partition_key.ex:30 parse/1 | BOUNDARY-TRANSLATOR | wire JSON -> `:error`, per @spec; callers issue 400 |
| lib/smalt/data_plane/resource_graph.ex:28 catch {:bad_query, msg} | BOUNDARY-TRANSLATOR | internal throw -> `{:error, 400, BadQuery}` envelope |
| lib/smalt/data_plane/key_vault_actions.ex:284 decrypt | BOUNDARY-TRANSLATOR | crypto failure -> `{:error, 400, InvalidValue}` envelope |
| lib/smalt/data_plane/key_vault_actions.ex:331 verify | BOUNDARY-TRANSLATOR | crypto failure -> `"valid": false` (semantically correct: bad crypto = invalid signature) |
| lib/smalt/messaging/amqp/primitive_codec.ex:247,260 | BOUNDARY-TRANSLATOR | `throw` -> `{:error, reason}`; malformed wire never raises |
| lib/smalt/messaging/amqp/frame_codec.ex:484 decode_performative | BOUNDARY-TRANSLATOR (IN-FLIGHT file) | FunctionClauseError -> `{:error, :bad_performative_fields}` — connection answers with clean close/detach |
| lib/smalt/messaging/amqp/frame_codec.ex:629 safe_atom | IN-FLIGHT-SKIP — observation for owner: `ArgumentError -> String.to_atom(name)` creates atoms from wire input; audit for atom-table flood against unbounded wire symbols |
| lib/smalt/egress_router.ex:1173 safe_dispatch | BOUNDARY-TRANSLATOR (IN-FLIGHT file) | malformed body -> 400 InvalidBody envelope (the doctrine's legal example) |
| lib/smalt/egress_router.ex:1056 blob encode rescue | BOUNDARY-TRANSLATOR (IN-FLIGHT file) | encode failure -> 500 + Logger.error, refusal not continuation |
| test/kv_tls_test.exs:235,248 pkix_equal?/rsa_self_verify | WITNESS | rescue -> false makes the assertion fail (typed false) |
| test/amqp/queue_store_test.exs:431,464 | WITNESS | `rescue e -> flunk(...)` converts raise into test failure |
| test/test_helper.exs:73, test/metadata_endpoints_test.exs teardown catch | WITNESS | teardown escalation: stop -> catch -> kill, verified-gone |
| scripts/doctor.py, bench*.py, mutation_court.py | BOUNDARY-TRANSLATOR | worker `except Exception as exc` records `err=` into the reported result (surfaced, not silent); kill/teardown paths verify port release and escalate to SIGKILL, fail-closed (`fail_closed(...)`) on stuck ports |

## IN-FLIGHT-SKIP list (files modified within 15 min of sweep; not edited)

At sweep time 21:47–22:11: lib/smalt/messaging/amqp/queue_store.ex (21:47),
lib/smalt/telemetry.ex (21:46 — fixed after its SLA expired; see above),
lib/smalt/egress_router.ex (21:41), lib/smalt/messaging/amqp/connection.ex (21:38),
lib/smalt/messaging/amqp/frame_codec.ex (21:36),
lib/smalt/messaging/amqp/primitive_codec.ex (21:33), lib/smalt/store.ex (21:32).
No additional swallow found in those files beyond the frame_codec safe_atom note.

## Gate receipts

- `mix compile` — 0 errors.
- `mix test test/telemetry_test.exs test/security/security_hardening_test.exs test/data_plane/cosmos_test.exs` — 69 tests, 0 failures.
- `mix test test/tls_test.exs test/metadata_endpoints_test.exs` — 16 tests, 0 failures.
- `mix test test/amqp/broker_facade_test.exs` — 4 tests, 0 failures (contains the sweeper fail-closed witness).
- Behavior witnesses: telemetry emit path (11 tests), TLS fail-closed raise path
  (metadata_endpoints https twin boots real Bandit https listener),
  sweeper direct-call pass (broker facade test).

---

## v2 sweep — post-lane-101 landing (2026-10-14 23:1x, sweep agent)

Re-sweep after ~20 integration/stress lanes landed past lane 101's ~22:00
landing. Scope: every lib/smalt `try/rescue/catch` in files with mtime
> 2026-10-14 22:00, plus python bare/broad `except` in new gates/ and
scripts/stress/ drivers. IN-FLIGHT-SKIP (mtime within 15 min of sweep):
lib/smalt/ash_extension/generated_verify.ex (23:06).

**Result: 0 confirmed SWALLOW-class swallows introduced after lane 101.**
Every site re-classified below. No lib/smalt edits were required.

### v2 classification (all post-22:00 rescue/catch sites)

| file:line | class | verdict |
|---|---|---|
| lib/smalt/runtime_contracts.ex:89 catch | BOUNDARY-TRANSLATOR | contract crash -> per-contract `contract_crashed` failure entry in the run report (surfaced, pass=false), not continuation |
| lib/smalt/runtime_contracts.ex:105,116 | BOUNDARY-TRANSLATOR | name_of/plane_of failures -> best-effort label / `:unknown` plane in the report; the contract's pass=false verdict is never masked |
| lib/smalt/trust_profile/trust_profile.ex:249,278 (jcs list/sorted_pairs) | BOUNDARY-TRANSLATOR | non-canonical JSON -> `{:error, {:bad_json_value, v}}` typed, caller raises/refuses |
| lib/smalt/trust_profile/trust_profile.ex:450,459,468 (json/b64d token parse) | BOUNDARY-TRANSLATOR | wire token -> `{:error, :invalid_token/:invalid_json/:invalid_base64}`, consumed by `with` -> 401-class refusal |
| lib/smalt/telemetry/ocel_ndjson.ex:66 | BOUNDARY-TRANSLATOR | append failure -> `{:error, {:append_failed, msg}}`; ocel_emitter.ex:130 logs Logger.error and returns the error (documented fail-safe law: telemetry handler must not raise into the caller's process) |
| lib/smalt/graphlaw/shacl_projection.ex:161 | WITNESS (fail-closed) | encode failure re-raised as ArgumentError with context — crash-appropriate |
| lib/smalt/data_plane/cosmos.ex:586 | BOUNDARY-TRANSLATOR | `:ets.new` race (table already exists) -> `:ok`; a missing table raises on access — crash-appropriate, not swallowed |
| lib/smalt/data_plane/key_vault_actions.ex:342,356 (do_verify) | BOUNDARY-TRANSLATOR | crypto verify failure -> `valid=false` (semantically correct: bad crypto = invalid signature); alg set pre-validated by sign_alg/1 so the case is exhaustive; v1 sibling :331 ruling unchanged |
| lib/smalt/runtime_contracts/support.ex:98-100 (safe_run) | BOUNDARY-TRANSLATOR | contract execution crash -> `{:fail, msg}` recorded in per-contract failures list (surfaced) |
| lib/smalt/telemetry/ocel_emitter.ex:57,130 (handle_event try + logged drop) | BOUNDARY-TRANSLATOR (documented fail-safe edge) | moduledoc fail-safe law: handler runs inline in request process; failures degrade to Logger.error drop, never raise into the request path |
| lib/smalt/messaging/amqp/frame_codec.ex:486,643 | BOUNDARY-TRANSLATOR | v1 IN-FLIGHT file now landed: FunctionClauseError -> `{:error, :bad_performative_fields}` (clean close/detach); v1 safe_atom atom-flood observation FIXED by its lane — `String.to_existing_atom` + binary passthrough, atoms never minted from wire |
| lib/smalt/egress_router.ex:1056,1173; lib/smalt/tls.ex:154,236; lib/smalt/graphlaw/validator.ex:369-375 | (unchanged) | v1 rulings hold on re-read; tls.ex carries the v1 fail-closed fix |

### v2 python drivers (gates/*.py, scripts/stress/{soak,chaos_kill}.py, test/invariant_gates_test.py)

| file:line | class | verdict |
|---|---|---|
| scripts/stress/soak.py:186,253,306 | BOUNDARY-TRANSLATOR | worker/probe failures recorded into `errors` / `{"_error": ...}` receipts (surfaced) |
| scripts/stress/soak.py:205 (sample_rss_kb) | crash-appropriate | optional RSS probe -> None; measurement, not control flow |
| scripts/stress/soak.py:328 wait_ready | fail-closed downstream | False -> boot retry loop -> loud "substrate not ready" |
| scripts/stress/chaos_kill.py:99,126 (boot retry/canary) | fail-closed | retries then `fail_closed(...)`; canary failure -> fail_closed |
| scripts/stress/chaos_kill.py:187-208,436-440; gates/common.py:105-137 | crash-appropriate | kill/teardown escalation paths (SIGKILL -> kill_port_holder -> sweep, verified via wait_port_free + fail_closed at chaos_kill.py:593-597) |
| scripts/stress/chaos_kill.py:416 (gate_pressure) | BOUNDARY-TRANSLATOR | request failures counted into `errors` in the phase receipt (surfaced) |
| scripts/stress/chaos_kill.py:656-658 main guard | crash-appropriate | traceback + sys.exit(1) |
| gates/common.py:204 (invariant gate) | fail-closed | exception -> verdict_ok=False, printed ERROR, recorded in receipt — gate vacuity impossible |
| test/invariant_gates_test.py, scripts/stress/*.py OSError sites | crash-appropriate | port-probe loops, exit-code-checked subprocesses |

### v2 gate receipts

- `MIX_BUILD_ROOT=_build-laneerr2 mix compile` — 0 errors ("Generated smalt app";
  no `error:` lines). Pre-existing lane-introduced warnings only (unused alias
  lib/smalt/projection/admission.ex:39, unused vars, clause grouping) — none from
  this sweep; no lib/smalt file was edited.
- `mix test test/telemetry_test.exs test/security/security_hardening_test.exs` —
  30 tests, 0 failures.
- Sweep-set census: files >22:00 = 46; files with try/rescue/catch = 13 Elixir
  + 3 python; IN-FLIGHT-SKIP = 1 (ash_extension/generated_verify.ex, 23:06).
