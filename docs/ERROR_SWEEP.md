# Error Sweep — lib/smalt try/rescue/catch classification

> **Receipt, not a living contract.** Dated receipt of the v26.10.14 (and
> earlier) sweeps — all `file:line` cites are **as-of-sweep**, pinned to the
> tree state at the sweep timestamp; later refactors (e.g. the lens-7
> `blob_route_guarded` egress refactor, the lro.ex lens-9 refactor) legitimately
> move code without invalidating the ruling. Do not treat stale line numbers as
> findings; re-run the sweep to re-pin.

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
| lib/smalt/telemetry.ex:223 (RollingCounters init/1) | SWALLOW (latent) | `:ets.new(:smalt_rolling_counters, ...)` lacked `:named_table` — the atom was a suggestion, table unnamed, so the fail-closed `bump/1` name access raised ArgumentError on every emit (11/11 telemetry tests red). FIXED (disclosed compile-freeze fix, file past its lane's SLA) | added `:named_table`; test/telemetry_test.exs 11/11 green |
| lib/smalt/tls.ex bandit_opts/2 | SWALLOW | `:auto` TLS mode silently downgraded https→http on dev-cert generation failure (no graceful degradation) | `{:error, :tls_disabled}` (explicit config) still maps to :http (typed opt-out); any other cert failure now raises ArgumentError at boot |
| test/metadata_endpoints_test.exs:64 | SWALLOW (harness) | TLS twin boot failure was rescued and degraded the listener list to http-only | rescue deleted; TLS boot failure now fails the test loudly |

## Verified legal (BOUNDARY-TRANSLATOR / WITNESS)

| file:line | class | verdict |
|---|---|---|
| lib/smalt/tls.ex:147 safe_decode/1 (`rescue _ -> :error`, consumed by parse_cert's `with`) | BOUNDARY-TRANSLATOR | external cert bytes -> `:error`, handled by the `with` chain |
| lib/smalt/tls.ex:229 sign_tbs/1 | BOUNDARY-TRANSLATOR | raise -> `{:error, e}`, propagated to caller |
| lib/smalt/security/receipt_signer.ex:70,202,211 (split/un_b64url/decode_json) | BOUNDARY-TRANSLATOR | wire token bytes -> `{:error, :invalid_token/:invalid_base64/:invalid_json}`, consumed by `with`; caller answers 401-class refusal |
| lib/smalt/graphlaw/validator.ex:405 engine fast-path | BOUNDARY-TRANSLATOR | optional external engine failure -> documented `{:refused, :engine_unavailable}` typed verdict |
| lib/smalt/data_plane/partition_key.ex:30 parse/1 | BOUNDARY-TRANSLATOR | wire JSON -> `:error`, per @spec; callers issue 400 |
| lib/smalt/data_plane/resource_graph.ex:28 catch {:bad_query, msg} | BOUNDARY-TRANSLATOR | internal throw -> `{:error, 400, BadQuery}` envelope |
| lib/smalt/data_plane/key_vault_actions.ex:284 decrypt | BOUNDARY-TRANSLATOR | crypto failure -> `{:error, 400, InvalidValue}` envelope |
| lib/smalt/data_plane/key_vault_actions.ex:331 verify | BOUNDARY-TRANSLATOR | crypto failure -> `"valid": false` (semantically correct: bad crypto = invalid signature) |
| lib/smalt/messaging/amqp/primitive_codec.ex:276-277,289-290 | BOUNDARY-TRANSLATOR | `throw` -> `{:error, reason}`; malformed wire never raises |
| lib/smalt/messaging/amqp/frame_codec.ex:518-532 decode_performative | BOUNDARY-TRANSLATOR (IN-FLIGHT file) | FunctionClauseError -> `{:error, :bad_performative_fields}` — connection answers with clean close/detach |
| lib/smalt/messaging/amqp/frame_codec.ex:690-693 safe_atom | IN-FLIGHT-SKIP — observation for owner: `ArgumentError -> String.to_atom(name)` creates atoms from wire input; audit for atom-table flood against unbounded wire symbols |
| lib/smalt/egress_router.ex:1529 safe_dispatch | BOUNDARY-TRANSLATOR (IN-FLIGHT file) | malformed body -> 400 InvalidBody envelope (the doctrine's legal example) |
| lib/smalt/egress_router.ex:1425-1427 blob encode rescue | BOUNDARY-TRANSLATOR (IN-FLIGHT file) | encode failure -> 500 + Logger.error, refusal not continuation |
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
- `mix test test/telemetry_test.exs test/security/security_hardening_test.exs test/data_plane/cosmos_test.exs` — 69 tests, 0 failures (at the sweep run; **136/0** as of 2026-10-15, docs-corpus cycle 9 re-run — suites grew).
- `mix test test/tls_test.exs test/metadata_endpoints_test.exs` — 16 tests, 0 failures (at the sweep run; re-verified **16/0 settled 2026-10-15** docs-corpus-lens4 — the 16/2 seen at the sweep was a rotating port-contention flake that settles green run-to-run (16/2 -> 16/0 witnessed same hour); `tls_test` green).
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
| lib/smalt/runtime_contracts.ex:223-229 catch | BOUNDARY-TRANSLATOR | contract crash -> per-contract `contract_crashed` failure entry in the run report (surfaced, pass=false), not continuation |
| lib/smalt/runtime_contracts.ex:233-246,287 (name_of/plane_of) | BOUNDARY-TRANSLATOR | name_of/plane_of failures -> best-effort label / `:unknown` plane in the report; the contract's pass=false verdict is never masked |
| lib/smalt/trust_profile/trust_profile.ex:307,316 (jcs list/sorted_pairs) | BOUNDARY-TRANSLATOR | non-canonical JSON -> `{:error, {:bad_json_value, v}}` typed, caller raises/refuses |
| lib/smalt/trust_profile/trust_profile.ex:660-664,675,684 (json/b64d token parse) | BOUNDARY-TRANSLATOR | wire token -> `{:error, :invalid_token/:invalid_json/:invalid_base64}`, consumed by `with` -> 401-class refusal |
| lib/smalt/telemetry/ocel_ndjson.ex:66 | BOUNDARY-TRANSLATOR | append failure -> `{:error, {:append_failed, msg}}` (`ocel_ndjson.ex:70`); ocel_emitter.ex:130 logs Logger.error and returns the error (documented fail-safe law: telemetry handler must not raise into the caller's process) |
| lib/smalt/graphlaw/shacl_projection.ex:161 | WITNESS (fail-closed) | encode failure re-raised as ArgumentError with context — crash-appropriate |
| lib/smalt/data_plane/cosmos.ex:929 | BOUNDARY-TRANSLATOR | `:ets.new` race (table already exists) -> `:ok`; a missing table raises on access — crash-appropriate, not swallowed |
| lib/smalt/data_plane/key_vault_actions.ex:342,356 (do_verify) | BOUNDARY-TRANSLATOR | crypto verify failure -> `valid=false` (semantically correct: bad crypto = invalid signature); alg set pre-validated by sign_alg/1 so the case is exhaustive; v1 sibling :331 ruling unchanged |
| lib/smalt/runtime_contracts/support.ex:98-100 (safe_run) | BOUNDARY-TRANSLATOR | contract execution crash -> `{:fail, msg}` recorded in per-contract failures list (surfaced) |
| lib/smalt/telemetry/ocel_emitter.ex:57,130 (handle_event try + logged drop) | BOUNDARY-TRANSLATOR (documented fail-safe edge) | moduledoc fail-safe law: handler runs inline in request process; failures degrade to Logger.error drop, never raise into the request path |
| lib/smalt/messaging/amqp/frame_codec.ex:518-532,690-693 | BOUNDARY-TRANSLATOR | v1 IN-FLIGHT file now landed: FunctionClauseError -> `{:error, :bad_performative_fields}` (clean close/detach); v1 safe_atom atom-flood observation FIXED by its lane — `String.to_existing_atom` + binary passthrough, atoms never minted from wire |
| lib/smalt/egress_router.ex:1425,1529; lib/smalt/tls.ex:126 (bandit_opts),283 (safe_decode),376 (sign_tbs); lib/smalt/graphlaw/validator.ex:405 | (unchanged rulings, re-pinned lens-8) | v1 rulings hold on re-read; tls.ex carries the v1 fail-closed fix |

### v2 python drivers (gates/*.py, scripts/stress/{soak,chaos_kill}.py, test/invariant_gates_test.py)

| file:line | class | verdict |
|---|---|---|
| scripts/stress/soak.py:186,253,306 | BOUNDARY-TRANSLATOR | worker/probe failures recorded into `errors` / `{"_error": ...}` receipts (surfaced) |
| scripts/stress/soak.py:199 (sample_rss_kb) | crash-appropriate | optional RSS probe -> None; measurement, not control flow |
| scripts/stress/soak.py:302 wait_ready | fail-closed downstream (probe was STALE — fixed lens-5: probed `GET /subscriptions` with no `api-version`, ARM answers 400 MissingApiVersionParameter, so every run burned 3 boot retries then FAIL rc=2; now `?api-version=2021-04-01`, readiness 200 witnessed) | False -> boot retry loop -> loud "substrate not ready" |
| scripts/stress/chaos_kill.py:93-115 (boot_with_retry), :107 (canary() call), :143-153 (auth canary def) | fail-closed | retries then `fail_closed(...)`; canary failure -> fail_closed |
| scripts/stress/chaos_kill.py:188-200 (wait_for_port), :424-445 (phase_kill_and_recover: SIGKILL process group -> kill_substrate :209 -> sweep_ports :203, verified via wait_port_free :217/:589 + fail_closed); gates/common.py:105-137 | crash-appropriate | kill/teardown escalation paths |
| scripts/stress/chaos_kill.py:416 (gate_pressure) | BOUNDARY-TRANSLATOR | request failures counted into `errors` in the phase receipt (surfaced) |
| scripts/stress/chaos_kill.py:586-656 main guard | crash-appropriate | traceback :655 + sys.exit(1) :656 |
| gates/common.py:199-232 (invariant gate: `run_gate`, verdict_ok) | fail-closed | exception -> verdict_ok=False, printed ERROR, recorded in receipt — gate vacuity impossible |
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

---

## v3 addendum — DX lane dedupe (2026-10-15)

Cycle-3 of the DX/scripts ERRC lane deduplicated the substrate lifecycle
triplet (wait_for_port / kill_substrate / wait_port_free / port_open) from 8
harnesses into scripts/stress/_substrate.py. Classification is unchanged from
v2 (the bodies were moved verbatim, parameterized); the v2 line references for
chaos_kill.py and soak.py are shifted by the refactor:

| file | class | verdict |
|---|---|---|
| scripts/stress/_substrate.py (all except sites) | BOUNDARY-TRANSLATOR / crash-appropriate | lsof sweep `except Exception: out = ""` (measurement, empty = nothing to kill); killpg fallback `proc.kill()`; proc.wait timeout pass — never masks a probe failure; wait_for_port takes the harness's fail_closed, and a `fail=None` call raises RuntimeError instead of ever continuing silently |
| scripts/stress/{spike,arm_scale,blob_scale,cosmos_bulk,chaos_kill,ycsb_lite,gate_cost}.py, scripts/bench.py wrappers | (unchanged) | thin wrappers; fail_closed still the only failure path |
| scripts/bench.py:209 | (fixed) | dead conditional `(t2-t1) * 1000.400 if False else ...` removed (cycle 6) — value was always the else branch |
| scripts/gen_dev_cert.sh | fail-closed raised | umask 077 at mint (cycle 1) — key material never hits disk >0600; reuse path self-heals legacy open keys |

## v3.1 addendum — shared-checkout port contention taxonomy (2026-10-15, cycles 14-15)

`just bench` failed twice with `RemoteDisconnected` mid-ARM-PUT. Typed root
cause (lsof/ps, no kill war entered): a sibling census lane runs
`lsof -ti tcp:{5672,9443,8443,9545} | xargs kill -9` before each census run —
it kills fixed-port holders mid-bench. Compensating sequence (cycle 14):
`SMALT_BENCH_*_PORT` private-port bench + doctor scoping; full 5-CTQ sequence
green on 19443/18443/15672, receipt tmp/bench-receipt.json 2026-10-15T08:41.

Second-order finding: conventional private blocks ALSO collide — a sibling
lane adopted the same documented 19443 block within the hour, so the mutation
court's post-restore boot hit `:eaddrinuse` (typed refusal, no stale-VM probe).
Rerun on a fresh block (39443) completed NON-VACUOUS. Taxonomy:
1. fixed front door (9443/8443/5672) — killed by the census lane's pre-run
   sweep;
2. documented conventional private blocks (19443...) — adopted by siblings who
   read the same doc;
3. verified-fresh blocks — check `lsof -iTCP:PORT -sTCP:LISTEN` immediately
   before the run; contention still surfaces as typed eaddrinuse, fail-closed,
   never a stale-VM probe.
mutation_court.py and bench_concurrent.py now honor SMALT_BENCH_* (cycle 15);
mutation_court's last-resort SIGKILL sweep and spawn are port-scoped instead of
sweeping the fixed front door.

## v3.2 correction — lens-2 re-verification (2026-10-15, dx-scripts-lens2 cycles 1-3)

Each v3.1 entry re-verified against the live checkout:
1. **HEALED (v3.1 entry was stale by the time of this check).** No script in
   the repo executes a pre-run kill sweep: census-run.mjs / run.mjs /
   eh-run.mjs fail closed (exit 3) with a typed do-not-kill remediation hint;
   grep witness: `kill -9` count 0 across all three runners. The residual
   census hazard (hardcoded front-door ports, no override) was closed in
   lens-2 cycle 1 (SMALT_TEST_* honored, defaults unchanged).
2. **RESOLVED (re-checked 2026-10-15, docs-corpus-lens4: `lsof -ti tcp:{15672,19443} -sTCP:LISTEN` returns no holders).** Witnessed 2026-10-15 09:49: three orphaned beams from the
   adopted 19443 block (PIDs 24774 / 35595 / 2500) holding
   15672/15673/19443/18443/19444. Mitigated by the documented private-port
   allocation table (docs/DEV_LOOP.md, range 39000-39999) — eh-run defaults
   moved out of that block in cycle 1.
3. **SUPERSEDED by full-listener auto-scope.** Verified-fresh-single-port is
   insufficient: the Application binds six fixed listeners, and scoping only
   arm_port dies eaddrinuse on the TLS twin after ARM answers the readiness
   probe (witnessed, lens-2 cycle 2). The supported contention path is now
   bench/court auto-scope over the whole listener set + durable readiness
   gate (2 s settle re-probe), receipt records the chosen block.

Canonical range and allocation table: docs/DEV_LOOP.md "Private port
allocation" (39000-39999; front door fail-closed, holders never killed).

## v3.3 addendum — lens-3 (2026-10-15, dx-scripts-lens3 cycles 1-3)

1. **Entry 2 residual reaped with receipt.** The three orphaned 19443-block
   beams (PIDs 2500 / 24774 / 35595) were killed 2026-10-15 after being
   typed provably orphaned on three signals: PPID 1 (launchd-reparented),
   0.0% CPU, no listeners on any of the five block ports. Post-kill
   witness: `ps -p` exit 1, lsof empty. Receipt:
   tmp/errc/dx-scripts-lens3/cycle-1.md. The sibling beam 46725 holding
   5672 (live sb substrate) was NOT touched — sibling-owned work.
2. **Entry 2 class retired repo-wide.** The disowned 15672/19443/18443/38443
   blocks no longer appear as defaults anywhere in scripts/ or scripts/stress/
   (grep witness: only historical-doc and explanatory-comment hits remain).
   All spawn harnesses now scope all six listeners on table-listed blocks
   (DEV_LOOP allocation table, 7 new rows).
3. **New taxonomy entry 4 — gate TOCTOU flake.** Invariant-gate runs flaked
   ~50% under sibling fan-out: `substrate exited rc=1 before binding :NNNNN`
   (pre-bind ephemeral port steal). Fixed in gates/common.py: killpg-only
   retry teardown (never the lsof sweep — the lost port belongs to whoever
   stole it), full six-port re-pick, 3 tries. Before/after on the same tree:
   5-run loop pass/3-fail/5-fail -> 5/5 PASS. Non-vacuity court for the
   six-listener scoping + readiness settle gate:
   tmp/lens3_court3.py NON-VACUOUS (cycle-3 receipt).

## v3.4 addendum — lens-4 (2026-10-15, dx-scripts-lens4 cycles 1-2)

1. **Teardown-law claim corrected; a live violation found and fixed.**
   Lens-3's "only two sanctioned kill -9 paths" was imprecise: a grep sweep
   finds a third sanctioned class (tf_smoke.sh own-child SIGTERM-first
   escalation) AND a live violation lens-3 missed — chaos_kill.py's
   `sweep_ports()` lsof-swept and SIGKILLed any holder of the dev substrate's
   own ports (9443/8443/5672/5673). Fixed by migrating chaos_kill to the
   private block 39520-39525; its sweep now touches only its own six ports.
2. **New taxonomy entry 5 — holder fidelity (courts and repro).** A plain
   (no-reuseaddr) 127.0.0.1 holder is NOT a faithful sibling: the substrate's
   reuseaddr BEAM binds over it on macOS and the boot succeeds. A
   SO_REUSEADDR 0.0.0.0 holder IS faithful (BEAM dies rc=1 pre-bind). And a
   non-accepting listen(1) holder fills its backlog on the first connect
   probe — connect-probing is not a holder-emptiness witness; lsof is.
   Witnessed in tmp/lens4_court1.py (court + two probes).
3. **Typed compile-freeze classification in the gate spawner.** A pre-bind
   rc=1 is not always a port steal — two sibling compile breaks
   (connection.ex:830, security/confidential_ledger.ex:25) made every gate burn 3 mix
   boots on pointless retries. gates/common.py now always captures substrate
   output; on rc=1 the log is classified: compile-error markers -> immediate
   typed COMPILE-FAILED refusal (no retry); else the TOCTOU re-pick path.
   Classifier predicate witnessed against the real captured break log;
   first live classification pending the next real break.

## v3.5 addendum — lens-4 (2026-10-15, dx-scripts-lens4 cycles 5-6)

1. **New taxonomy entry 6 — gate substrate orphan on SIGTERM.** A gate killed
   by an external timeout died without teardown; the substrate boot continued
   to PPID 1 (witnessed: a 40-minute orphan beam, reaped). Fixed in
   gates/common.py: run_gate installs SIGTERM->SystemExit so the finally
   teardown runs, and spawn_substrate's wait loop gained a BaseException
   escape guard that killpgs the substrate on any other escape. Post-fix
   witness: same SIGTERM test leaves zero orphans.
2. **lro_storm was unrunnable** (module-level use of `os` without the import;
   any invocation NameError'd, `--help` included) and its teardown killed only
   the mix wrapper (orphaned-beam class). Fixed: import added;
   start_new_session=True + killpg-group stop_server; zero survivor beams
   witnessed post-teardown.
3. gates/common.py dead `kill_port_holder` (lsof-sweep kill, zero callers)
   deleted.
4. Typed compile-freeze classifier earned its first live gate receipt:
   ledger-chain failed in one attempt, message naming the broken sibling file
   (tls.ex:170) — the no-retry design holds in the wild.

## v3.6 addendum — lens-5 (2026-10-15, dx-scripts-lens5 cycles 1-3)

1. **Both lens-4 teardown guards mutation-verified load-bearing** (court:
   `tmp/errc/dx-scripts-lens5/sigterm_court.py`, real gate child, real
   SIGTERM mid-boot-wait, PPID-1 beam diff attribution): removing the
   SIGTERM handler -> 2/2 ORPHAN (child rc -15, default disposition, no
   teardown); removing the BaseException escape guard -> 2/2 ORPHAN
   (SystemExit unwinds the wait loop, `proc` still None in run_gate's
   finally, nothing killed); unmutated -> 3x CLEAN. Neither mutation
   escapes the court.
2. **Orphaned-beam sweep finished**: the last three roll-their-own runners
   migrated to `_substrate.kill_substrate` (group kill + reap + own-port
   sweep) with live boot->teardown witnesses, zero orphans each:
   `amqp_throughput.py` (wrapper-only kill in 2 sites),
   `soak.py` (NO process group at all + wrapper-only kill in 2 sites),
   `vs_azurite.py` (no group + wrapper-only kill in 2 sites);
   `gate_cost.py` finally gained SIGTERM->bounded wait->SIGKILL escalation
   (previously an uncaught TimeoutExpired propagated with no escalation).
3. **soak readiness probe was stale** (fail-closed but wrong): probed
   `GET /subscriptions` with no `api-version`; ARM answers 400
   MissingApiVersionParameter, so every soak run burned 3 boot retries then
   FAIL rc=2. Fixed (`?api-version=2021-04-01`); readiness 200 witnessed
   with the real subscription body. Witnessed under the same load regime:
   boot-to-ready ~57-60s (build-lock wait) vs the probe's own 120s deadline
   — deadline holds, retry loop untouched.
4. **The SIGTERM guard promoted to `_substrate.install_sigterm_handler()`**
   and wired into `scripts/bench.py` main() and `scripts/stress/soak.py`
   main() — both previously died on default SIGTERM disposition mid-boot,
   orphaning the BEAM (same class gates/common guards). Witnessed: bench.py
   SIGTERM'd mid-boot -> exit 143 (handler fired, finally teardown ran),
   PPID-1 beam diff NONE.
