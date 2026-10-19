# W15 residual review — workqueue group 14

Date: 2026-10-18. Context: solo lane. Contract: review 6 files
(`/tmp/rewrite-workqueue.json` group 14) vs NO-SLEEP-DOCTRINE, canonicalize
where defective, PRESERVE receipted assertions verbatim. Foundations landed
(AssertEventually / Store.resilient / Env / PortEnv in `test/support/`).

Standing: **PASS** — 95 tests across the 6 files, 0 failures, two green
Context: slice(6-file batch, 95 tests 0 failures, x2)
passes (MIX_BUILD_ROOT=_build-ft-w15 via scripts/fast_test.sh).

## Findings + actions (per file)

### test/chaos/crash_isolation_test.exs — CONVERTED (4 sleep sites)
Law 1: three wait-for-condition sleeps collapsed onto
`SmaltTest.AssertEventually.eventually/2` (the sleep now lives only in the
one audited poll implementation):

- `wait_listener/1` (was 100×30ms attempt-sleep loop) → `wait_listener/0`,
  eventually-poll on the ARM-port observable, deadline 5s, backoff 30ms.
- `wait_connect/1` (was 300×30ms) → `wait_connect/0`, deadline 10s,
  backoff 30ms. Caller fixed to `assert sock = wait_connect(); assert
  is_port(sock)` (eventually/2 unwraps `{:ok, value}` -> value).
- `wait_for_new_store/2` (was 20ms sleep recursion with custom flunk) →
  eventually-poll on `Process.whereis(Store)`, deadline 5s, backoff 20ms;
  the 5s budget and the "restarted under supervision" claim are preserved
  in the `:observable` message.
- `listener_stayed_up?/2`: KEPT with a classification comment — the
  interval sleep is the sampling cadence of the fence itself (probes
  distributed across the ~1s kill window is part of the claim being
  fenced), bounded by construction (25×40ms) inside the one audited
  implementation. Not wait-for-condition coordination.

All fail-closed assertions preserved verbatim (full-tree kill, ETS
recreation, reseed, put/get through restarted Store, AMQP listener probe,
`refute Process.alive?(old_pid)`).

### test/data_plane/r5_repair_repro_test.exs — CONVERTED (setup)
No sleeps. Defect: bare `ensure_store_up(); Store.clear()` setup — the
exact pattern `SmaltTest.Store.resilient_setup/0` replaces (FLAKE_LEDGER
F2-F5/F10 ensure→clear window race). Converted; removed now-unused
`alias Smalt.Store`. The module-local `:smalt_blob_policy` wipe is kept
(owned table, no race). All 3 refusal-shape assertions verbatim
(`:worm_locked` + "legal hold", release-then-admit, parse_block_list_xml
typed map). Zero assertion edits.

### test/kd78_child_lattice_wire_test.exs — CONVERTED (setup)
No sleeps. Same bare `ensure_store_up(); Store.clear()` defect. Converted
to `SmaltTest.Store.resilient_setup/0`; removed unused `alias Smalt.Store`.
All 6 lattice assertions verbatim (2024-01-01 admitted, 2021-04-01
monotonic, 2099 -> 400 InvalidApiVersionParameter naming
Registry.latest_version/1, for both SB queue and EH eventhub). Zero
assertion edits.

### test/amqp/atom_bridge_test.exs — CONVERTED (setup)
No sleeps. Defect: guarded single-table wipe (`if :ets.info(:smalt_resources)
!= :undefined do delete_all_objects`) in setup — the ensure→wipe window
races async sibling teardown (F2-F5 class). Converted to
`SmaltTest.Store.resilient_setup/0`. All wire assertions verbatim (201/200/
404/405 table, bounded no-hang pins). Zero assertion edits.

Pre-existing (noted, NOT introduced, not sleep-law scope): the test-owned
accept-loop task logs `CaseClauseError {:error, :einval}` /
`WithClauseError {:error, :bad_content_length}` when the harness closes
sockets mid-loop — logged noise from unlinked Tasks, tests stay green.
Repair candidate for a future cycle, out of this lane's contract.

### test/security/lens6_fuzz_test.exs — ALREADY-COMPLIANT
No `Process.sleep`/`:timer.sleep`; no Store/env/time coordination anywhere.
All 4 waves are deterministic hostile-input matrices over the real
`SKR.release/2` (Chicago, final-state typed-tuple asserts), plus the
receipted lens-8 replay court (403 TokenReplay) and lens-9 split-placement
precedence pin — preserved verbatim. Note: the file has no setup and
relies on the app self-boot's Store being up, same as the pre-edit file;
out of sleep-law scope.

### test/trust_profile_test.exs — ALREADY-COMPLIANT
No sleeps; no shared-Store use; all env/persistent_term mutations are
try/after restored with nil-preservation (auth_mode, tls_certfile/
tls_keyfile, receipt_signing_key, TrustProfile/ReceiptSigner keypair refs)
— already the canonical restore discipline. Fixture certs are written under
tmp with cleaned `after` blocks (two use `:rand.uniform(1_000_000)` names —
bounded collision window, reclaimed in `after`; observation only, within
cleanup-law compliance). Oracle tier is `@describetag :oracle` (excluded by
default; the two oracle parity tests carry their own utf8-sort non-vacuity
mutation arms — "court vacuous" flunks). All receipted pins preserved
verbatim (fence-order totality, alg-confusion, numedge 1-ulp windows,
key-leak sweep, typ asymmetric-boundary closure).

## Session-introduced fix
Initial `wait_connect` conversion returned the eventually value unwrapped;
caught by pass-1 red (`assert {:ok, sock} = wait_connect()` match error on
`#Port<0.29>`), fixed to `assert sock = wait_connect()`. Final two passes
green.

## Verification (real output, two passes)

Pass 1 (after the unwrap fix):

```
Finished in 22.1 seconds (0.00s async, 22.1s sync)
95 tests, 0 failures
[14:16:28] wall: 27s (build root: _build-ft-0cac6d0b)
```

Pass 2:

```
Finished in 31.2 seconds (0.00s async, 31.2s sync)
95 tests, 0 failures
[14:17:26] wall: 50s (build root: _build-ft-0cac6d0b)
```

(First pass-1 attempt, before the unwrap fix: `95 tests, 1 failure` —
CrashIsolationTest match error; fixed forward, no reset.)
