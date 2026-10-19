# Receipt — docker/burn boot-burn + chaos-kill scripts

Standing: PARTIAL_ALIVE — syntax + envelope validated; all four chaos
Context: solo(docker/burn boot-burn.sh + chaos-kill.sh host executions vs real app; no suite context)
scenarios witnessed green against the real app on the host (real kills, real
supervisors); not yet run against a real container image (in-image
`smalt:local` predates v26.10.18).

## Subject

- `/Users/sac/smalt/docker/burn/boot-burn.sh`
- `/Users/sac/smalt/docker/burn/chaos-kill.sh`
- Envelope contract:
  `/Users/sac/smalt/docs/jira/v26.10.18/burn/burn-row.schema.json` (sibling
  lane, uncommitted at receipt time)
- Validator: `/Users/sac/smalt/scripts/validate_burn.py` (sibling lane)

## Design (coordinator-approved)

### boot-burn.sh — 50-cycle boot/probe/teardown burn

- In-container only: fails loud `[SKIP] rc=3` when
  `SMALT_BIN=/opt/smalt/bin/smalt` is not executable.
- Cycle: `bin/smalt start` (nohup) → deadline poll (90s budget, ~50ms cadence)
  all 6 ports (9443/9444/8443/5672/5673/9545) → SIGTERM
  stop → fail-closed zero-listener assertion via /proc/net/tcp{,6} LISTEN scan
  PLUS /dev/tcp cross-check (fail-closed on both channels).
- Every 10th cycle: `kill -9` the beam (pid from `bin/smalt pid`), poll the
  process gone (ZOMBIE_BEAM fails the run), then dets_recovery_check in the
  kill→restart window (all ports free, so the eval's app boot binds cleanly).
- dets_recovery_check (release eval, real app boot): every mirrored .dets file
  opens with `repair: false` (no needs_repair unresolved — same fail-closed
  rule as `Smalt.Store.DetsMirror.start_link`), Store put/get roundtrip,
  `Smalt.Telemetry.dump()` answers (rolling-counter surface post-boot). The
  eval exits nonzero on any assertion (bare `true = ...` matches).
- Overclaim fence: with `RELEASE_DISTRIBUTION=none` there is no cross-VM rpc,
  so row-survival-across-restart is NOT asserted here (fenced by the host
  dets_mirror test suite); asserting it would be an overclaim.
- Receipts: JSONL `smalt-burn/v2` (AZB-03) to
  `docs/jira/v26.10.18/burn/boot-burn.jsonl` (in-container default
  `/smalt/...`, `SMALT_BURN_DIR` override). Header (expected matrix
  containers×cycles×stages probe/recover/teardown) opens the file; every cycle
  emits all three stage rows so the matrix closes; run_receipt (DfCM R)
  appended only with a real 40-hex `SMALT_BURN_SUBJECT_SHA` — without it the
  file cannot gate green (loud R_missing_identity, never a faked pass).
- Typed verdicts (burn-row.schema enum): CLEAN / ORPHAN_LISTENER /
  ZOMBIE_BEAM / DETS_UNREPAIRED / TIMEOUT_DEADLINE vocabulary in the schema;
  the emitter currently maps rc!=0 → UNHANDLED_EXIT (mu_unlawful).

### chaos-kill.sh — kill-the-collaborator chaos scenarios

- In-container only (`[SKIP] rc=3` without the release bin).
- Each scenario runs `bin/smalt eval` (real app, real supervisors — Chicago).
- s1 store-kill: kill `Smalt.Store` mid-write → supervisor restart → deadline
  poll → Store.put green on the restarted pid. Witnessed green on the host
  (below).
- s2 lro-flip: kill `Smalt.ArmGateway.LRO.Sweeper` mid-flip, race a read-path
  flip against the kill, then sweep_now to one-terminal convergence; two
  further sweeps must be byte-idempotent (same status + same endTime).
- s3 wasm-seal: kill `Smalt.Affidavit.WasmEngine` mid-seal; each kill/attempt
  round must observe the typed `{:error, :engine_unavailable}` while the
  engine is genuinely down (a round that sees `{:ok,_}` loses the race and
  re-kills, up to 5 rounds; zero witnessed refusals fails the stage); then a
  deadline poll until `Seal.admit_and_seal` succeeds post-restart.
- s4 amqp-capacity: 4096 enqueues then #4097 → `{:error, :capacity}` typed
  refusal; queue_info capacity 4096 asserted; wire mapping
  `amqp:link-message-size-exceeded` (connection.ex error_close).
- Gates stage: in-image there is no python3/mix. Host-assisted mode
  (`SMALT_GATES_HOST=1 SMALT_GATES_DIR=<repo>`): runs the real gate binaries
  (cosmos_etag_cas, blob_worm, ledger_chain, queue_capacity, lock_clamp,
  test_isolation_leak) — each self-boots and must exit 0. Without host gates,
  loud `BURN_GATES_UNAVAILABLE_IN_IMAGE` rc=3, exit 3 — never a faked pass.
- Envelope: header (cycles [0], stages chaos/probe) + run_receipt withheld
  without a 40-hex subject sha.

## Validation performed

- `bash -n` both scripts: SYNTAX-OK (2026-10-18).
- Envelope gate, positive: emitter simulation (real emit functions) with a
  real commit sha → `validate_burn.py --gate` **OK, exit 0**:
  ```
  [VALIDATE-BURN] /tmp/emit_test4.jsonl: OK
  validator exit: 0
  ```
- Envelope gate, negative (non-vacuity of the gate run): one dirty row →
  ```
  [VALIDATE-BURN] ... DIRTY_ROW ... verdict=UNHANDLED_EXIT broken_term=mu_unlawful
  validator exit: 1
  ```
- Chaos s1 host witness (real app, `mix run --no-start`, real kill):
  ```
  14:43:44.486 [info] [amqp] eh listener bound on port 5673
  CHAOS_OK s1 store-restarted-write-path-green
  ```
- Chaos s2 host witness (real sweeper kill mid-flip, sweep_now convergence):
  ```
  CHAOS_OK s2 lro-terminal=Succeeded idempotent
  ```
- Chaos s3 host witness (real engine kill mid-seal; first attempt with an
  unpaced poll loop failed at `true = sealed?` — the supervisor restart
  outlived 600 zero-delay iterations; fixed to a paced deadline poll, then
  green — the fix itself witnesses that the poll, not a sleep, carries the
  claim):
  ```
  CHAOS_OK s3 engine_unavailable-witnessed-then-seal-ok
  ```
- Chaos s4 host witness (first attempt crashed on `queue_info/1` returning
  `{:ok, map}`, not a bare map — fixed to `{:ok, info} =` then green):
  ```
  CHAOS_OK s4 capacity-4096-refused-4097-typed
  ```
- Witness port discipline: runs used private ports 39610-39615 and a private
  `dets_dir` (`tmp/burn-witness-dets`) via `Application.put_env` — no
  collision with the concurrent lane's substrate on the shared checkout; the
  `_build-burn` lane build root (697 MB) was deleted at integration.

## Honest limits

- No container run yet (image `smalt:local` is 2026-10-14, pre-v26.10.18);
  the scripts are in-container lanes and require a rebuilt image to execute.
- The 6 invariant gates re-run is host-assisted by design; in-image the gates
  stage is a loud rc=3 skip, not a pass.
- Rolling-counter window contents are in-memory; only table liveness is
  asserted post-kill (contents surviving kill -9 would be an overclaim).
- Concurrent lanes landed `burn-row.schema.json` + `validate_burn.py`
  mid-window; emitters migrated to smalt-burn/v2 and validated against them.
