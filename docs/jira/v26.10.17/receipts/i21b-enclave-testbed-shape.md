# i21b — enclave testbed leak-court residual: non-literal put_env shape fix

- **Date**: 2026-10-17
- **Lane**: i21b (lease: `test/enclave-testbed/enclave_testbed.exs`)
- **Repo**: /Users/sac/smalt (canonical checkout, no worktrees)
- **Build root**: `MIX_BUILD_ROOT=_build-ft-encl`, `MIX_ENV=test`
- **Standing**: ALIVE — gate clean for the leased file; suite 9/9 PASS solo, exit 0
- **Court**: `gates/test_isolation_leak_gate.py`

## Scope

Residual disclosed in i21-leak-batch2: `test/enclave-testbed/enclave_testbed.exs:20`
`Enum.each` + `Application.put_env(:smalt, k, v)` with non-literal key `k` — the
gate hard-refuses non-literal keys ("unresolved"); no save/restore shape clears it.

## Fix (code SHAPE, behavior identical)

1. Unrolled the `Enum.each` pin loop into five LITERAL `Application.put_env(:smalt, <key>, <port>)`
   calls (`:amqp_port` 29440, `:event_hubs_port` 29441, `:arm_port` 29442,
   `:egress_port` 29443, `:arm_tls_port` 29444).
2. Each key carries a literal save-prev (`prev_x = Application.get_env(:smalt, :x)`,
   carried across the try-scope seam via the process dictionary per the
   i21-leak-batch2 gotcha) and a conditional delete/put restore inside a try
   `after` region.
3. The try is BOOT-SCOPED: body = app boot (`ensure_all_started`) only;
   `defmodule Enclave.Testbed` and `Enclave.Testbed.main()` stay at top level
   (the HEAD shape). A whole-run try wrapper was tried first and deterministically
   lost ALL of main's phase output on the `System.stop(0)` path (exit 0, zero
   phase lines, three consecutive runs; the unwrapped shape prints everything) —
   boot-scope restore is also behaviorally safe because the listeners are already
   bound when it fires. Helper behavior (pins applied BEFORE app boot) unchanged.
4. All other put_env sites in the file were already literal (`:lro_delay_ms`
   save/after-restore from i21-leak-batch2 at line ~594/632; phase_f3 literal at
   ~830 covered by the same per-file save + after-restore). No other non-literal
   put_env/delete_env/persistent_term sites exist in the file (grep in receipt).

## Phase B law re-pin (disclosed, same leased file)

Phase B asserted "create under active legal hold ADMITTED" (ENCLAVE-1 disposition,
2026-10-15). That disposition is SUPERSEDED by d092caa ("court RED closure — blob
HEAD conditionals"): the current lib law is an existence-scoped WORM arm — an
active legal hold blocks BOTH overwrite AND create (`lib/smalt/data_plane/blob_storage.ex`
`worm_blocked?(container_meta, if(existing_blob?(...) "overwrite" else "create"), now)`,
KD-52 comment; commit_block_list same arm). `test/data_plane/blob_hardening_test.exs`
(116 tests, 0 failures, run this session in `_build-ft-encl`) pins it. Per the
parity-defect rule the premise was checked against the current pinned law, not
the stale comment. Phase B now asserts `{:error, :worm_locked, _}` for both the
existing-blob-name put and the fresh-blob create under an active hold.

## Verification (real output)

Gate — zero findings for the leased file:

```
$ python3 gates/test_isolation_leak_gate.py | grep enclave_testbed
(no output; grep exit 1)
```

Enclave testbed solo run (MIX_BUILD_ROOT=_build-ft-encl, MIX_ENV=test,
ENCLAVE_PRIVATE_PORTS=1, exit 0), twice (pre- and post-format):

```
PASS  A: SKR attest->release->replay
PASS  B: WORM legal-hold + immutability
PASS  C: Confidential Ledger chain
PASS  D: Governance (Purview/Sentinel/RG)
PASS  E1: Cosmos 500-doc cross-partition
PASS  E2: 50x LRO + sweeper convergence
PASS  F1: SB sessions + DLQ under EH load
PASS  F2: EH producer/consumer + CAS contention
PASS  F3: chaos — sweeper child kill
9 passed, 0 failed
```

blob-hardening confirmation run (same build root):

```
116 tests, 0 failures
```

## Out-of-lease finding (disclosed, NOT fixed)

`test/enclave-testbed/run.sh` (dev env, default) can no longer boot a FRESH
build root: commit 248e119 ("B1 CLOSED — ex4pm hex-only") pins
`{:ex4pm, "~> 26.10.8"}` in mix.exs while the locked `ash_ex4pm 26.10.4`
requires `{:ex4pm, "26.10.1"}` — Mix refuses with "Unchecked dependencies" in
every env. Verified with a fresh dev-env run (exit 1, exact resolver output
captured in session log). Workaround used here: `MIX_ENV=test` +
`--no-deps-check`. Owner: the B1/ex4pm lane or coordinator (fix is
`mix deps.update ash_ex4pm` to a version allowing ex4pm 26.10.8, or
`override: true`).

## Replay

```
cd /Users/sac/smalt
python3 gates/test_isolation_leak_gate.py | grep enclave_testbed   # empty
MIX_BUILD_ROOT=_build-ft-encl MIX_ENV=test mix deps.compile
MIX_BUILD_ROOT=_build-ft-encl MIX_ENV=test ENCLAVE_PRIVATE_PORTS=1 \
  mix run --no-start --no-deps-check test/enclave-testbed/enclave_testbed.exs
```

No git (per lease).
