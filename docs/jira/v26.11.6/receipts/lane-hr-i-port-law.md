# Lane HR-I — port law + substrate delegation migration

Standing: PARTIAL_ALIVE

Date: 2026-11-04/05 · Repo: /Users/sac/smalt · Lane HR-I (repositioning wave)

## Landed (all on disk, parse-gated)

- `docs/reference/port_law.md` (new) — family table (b≤20, c≤48 with c48
  legacy-reserved "legacy-c3", v≤29 7-port with v14/v15 LEGACY-FROZEN),
  LEGACY literals, arcus reserved (4566/8085/9099), UDS note, LIVE_PICKS
  (v16 diagnostics, v17 ts-private).
- `scripts/port_registry_check.py` (new) — fail-closed exit 0/1/2. `--falsify`
  PASS (19 corpus cases: 39711→v2 refused, 39841→frozen-v14 member refused,
  39310/39250→c10 refused (c10=39300 pinned), 39720→v1/v14 refused, arcus
  9099 unclaimable, c48/v14 blocks refused; v3 = 39730-39736 pass, c10 =
  39300-39305 pass, b5/c5/front stay 6 ports, v13 kafka=39836). `--report`
  exit 0 with findings (v14/v15 LEGACY + live unregistered census);
  `--check` fail-closed green on clean machine.
- `scripts/lib/substrate_boot.sh` — v-case 7 ports (+kafka at +6); family
  caps (b≤20, c≤48 minus c48, v≤29 minus v14/v15); sb_spawn_substrate
  signature rework (log FIXED at arg 3; kafka arg 10; positional-mismatch
  defect fixed where a 7-port call put the log at ${11} and spawn died
  pre-ready with no log — witnessed twice); kafka_port put_env mirror;
  `sb_env_pin` + marker `env_pin` field + refusal law (marker env-pin
  mismatch = foreign incumbent → typed GUARD + exit 3, never swept);
  `SMALT_SB_MIX_NO_DEPS_CHECK=1` spawn gate (storm workaround, default off).
- `verification/py/conftest.py` — migration to substrate-ctl delegation:
  raw-flock internals retired (AST-verified: no _sweep/_listener_pids/
  _is_beamish/_ensure_boot/_kill/_mix_eval); anon→v3 anonymous,
  throttle→v4 + SMALT_ARM_RATE_LIMIT=20 (KD-110 bridge), mesg→v5 +
  SMALT_SB_SHARED_KEY pin; yield shapes IDENTICAL; env-pin guard inherited
  from the ctl path; teardown `down --mode sweep`.
- `verification/py/test_wf9_kafka.py` — minimal unblock (disclosed):
  wf9 imported the retired conftest internals; local copies of
  _sweep/_kill/_port_open/_listener_pids/_is_beamish inlined; wf9's own
  v9/v11 self-boots untouched.
- `verification/ts/run-all.mjs` PRIVATE_BLOCK v14→v17;
  `verification/ts/diagnostics.probe.mjs` v15→v16 (+ 7-slot formula and
  kafka_port pin so the block claim matches the v-law);
  `docs/how-to/dev-loop.md` + `verification/README.md` repointed to
  port_law.md; `scripts/bench/c10_affidavit_seal.exs` + REGISTRY.md c10
  drift fix (39250→39300 = c5's range, formula authoritative).
- `justfile.d/65-ports.just` (new) + root justfile import line —
  `just port-law` = --falsify + fail-closed --check.

## Falsifier receipts (real processes, real ctl path)

- registry --falsify PASS (19 cases) — repeated post-resume.
- kafka mirror: sb_block_ports v13 = 7 ports (kafka 39836); b5/c5/front
  stay 6 (counter-case witnessed); c10 = 39300 (registry-pinned).
- env-pin identity guard: live decoy LISTENER on v5 arm port + valid
  marker env_pin=X; up with pin Y → `GUARD ... env-pin mismatch ... —
  incumbent is foreign, refusing to sweep` + rc 3; refusal precedes sweep
  (decoy never swept). Same-pin up fell through to occupied-after-sweep
  → rc 3 fail-closed (partial-block decoy holds only the arm port) — both
  typed paths witnessed with real ctl runs.
- static gates: bash -n (boot lib, ctl, court), node --check (run-all,
  diagnostics), py_compile (registry, conftest, wf9) — all green.

## BLOCKED (typed, machine-level — evidence: sampled stacks)

- Full substrate boot hangs deterministically: `Application.ensure_all_
  started(:smalt)` → NIF `erts_load_nif` → dlopen → dyld4 mapSegments →
  `fcntl` — an exclusive file lock on the NIF dylib stalls the load
  (`sample` stacks captured at /tmp/hr-i/s5.txt s6.txt; reproduced ≥5×,
  foreground and spawned, before and after the fleet resume). Also bites
  pytest collection (was 0.38s, now >100s empty) and `just` shebang
  recipes (`/usr/bin/env bash` parked in _dyld_start). NOT lane code:
  the same binaries run fine outside the stall window (MIX-OK probe,
  mix compile rc=0, MIN-RUN-OK probe all passed mid-window).
- Consequently BLOCKED: decoy-court BEFORE leg (old-conftest sweep over a
  real beam), lock-manager pair (two real v5 boots), `just sdk-py`
  end-to-end. Court script is landed and runnable
  (`bash scripts/shim_court/conftest_sweep_court.sh`, loud SKIP exit 3 if
  /tmp/hr-i/conftest_old.py is gone); the AFTER leg's law (env-pin refusal
  rc=3, decoy survives) is independently witnessed in the falsifier
  receipts above.
- `just port-law` inherits the just-shebang hang; the gate is lawful via
  `python3 scripts/port_registry_check.py --falsify && python3 scripts/
  port_registry_check.py --check`.

## Divergences / notes

- venv was missing suite deps (pre-existing): installed requests,
  pytest-asyncio, aiohttp, pytest-timeout into verification/py/.venv.
- sb_spawn_substrate positional contract changed (log fixed at $3) —
  sole call site updated; no external consumers of the lib function.
- Old-conftest snapshot for the court: /tmp/hr-i/conftest_old.py
  (sha256 da6aa8c6…); court removes its conftest_old.py copy on exit.
- c48 legacy-reserved id "legacy-c3" per coordinator.
- MIX_BUILD_ROOT=_build-laneHRI cloned from _build-lane7 (lane lease for
  falsifier runs; delete at integration per cleanup law).

## Cross-lane disclosure

- `verification/ts/harness/substrate.ts` — additive edits outside this
  lane's lease, disclosed by the HC lane in
  `docs/jira/v26.11.6/receipts/lane-hc-kafka-real-clients.md` (7th-port
  slot in `blockPorts` (39700+10n+6), `:kafka_port` put_env in the
  bootPrivate eval list, kafka-aware `waitHealthy`, disclosed minimal
  unblock on bootPrivate only). HC lane's substrate.ts 7th-port/kafka
  put_env additive edits acknowledged; both-receipt disclosure completed
  here — this receipt touches substrate_boot.sh/conftest.py/run-all.mjs
  but never substrate.ts itself.
