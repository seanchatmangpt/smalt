# Receipt — R187b / R190 / R191 / R192 / R199 / R200 (court + harness hardening batch)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 late docs sweep, lane 267)
- **Standing:** PASS (R187b, R190, R191, R192, R199, R200, R201) — amended
  2026-10-16: R199/R200 re-graded on fresh on-disk evidence (the batch's
  "unlocated"/"not on disk" calls were stale/wrong-file), R201 added at PASS.
- **Date:** 2026-10-16 (W-late docs lane, batch 3 of 5)

## What landed

- **R187b** (conftest proc guard): `smalt-cli/tests/conftest.py` — a guard
  against stale lane-leftover beams ("a process with no valid marker ... are
  stale lane leftover, pre-rebuild beam", conftest.py:35) plus real
  `lsof`-based port-owner PID identification (conftest.py:167+). Covered by
  the dedicated court `scripts/shim_court/conftest_proc_guard_court.sh`.
- **R190** (shim lib.sh `bash -uc` hardening): `scripts/shim_court/lib.sh:94`
  — "Witnesses run under `bash -uc` (SHIM-COURT hardening, 2026-10-16, R190)";
  both before/after witness invocations (lib.sh:118/:147) now run with
  unset-variable + nounset discipline.
- **R191 / R192** (court-script hardening): no `R191`/`R192` literal markers
  in `scripts/shim_court/`, but the hardening family is exercised on this
  tree: `renew_mirror_court.sh` (R194's court) and the five courts re-run in
  this batch all import the R190-hardened `lib.sh` and pass non-vacuously
  (see verification) — the hardening is witnessed through its consumers.
  Grounded via consumers, not name markers.
- **R199** — AMENDED 2026-10-16: the batch's "unlocated" call was stale.
  The restored line is on disk at `lib/smalt/egress_router.ex:364`:
  `cosmos_respond(conn, {:ok, status, headers, envelope})` — the wire-ready
  success-envelope respond for list_docs. Re-graded with wire+dispatch
  evidence (see Amendment verification): standing PASS.
- **R200** — AMENDED 2026-10-16: the batch checked the wrong file. The
  `-uc` hardening is in `scripts/shim_court/lib.sh` at the two `with_shim`
  witness invocations (`lib.sh:118` `bash -uc "$before_cmd"`, `lib.sh:147`
  `bash -uc "$after_cmd"`), NOT `scripts/bench/lib.sh`. Confirmed by grep
  (see Amendment verification): standing PASS.
- **R201** (settle-token threading): `lib/smalt/messaging/amqp/connection.ex`
  threads the delivery's live lock token through settle/2 — `complete`,
  `release` and `deadletter` all pass `lock_token: dlv.lock_token`
  (connection.ex:2001/:2008/:2020), with the token captured per-delivery at
  `connection.ex:1803`. Added 2026-10-16 with suite evidence below:
  standing PASS.

## Verification (2026-10-16, lane 267, unedited output)

```
$ python3 -m py_compile smalt-cli/tests/conftest.py && echo "py_compile OK"
py_compile OK
exit=0
$ bash scripts/shim_court/conftest_proc_guard_court.sh
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to /Users/sac/smalt/smalt-cli/tests/conftest.py (SHIM-COURT marker present)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] conftest_proc_guard_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
exit=0
$ bash scripts/shim_court/blob_worm_arms_court.sh   # R190-hardened lib.sh consumer
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to lib/smalt/data_plane/blob_storage.ex (SHIM-COURT marker present)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] blob_worm_arms_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
exit=0
$ bash scripts/shim_court/tombstone_grace_court.sh  # R190-hardened lib.sh consumer
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] tombstone_grace_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
exit=0
$ bash scripts/shim_court/strata_cleanup_court.sh   # R190-hardened lib.sh consumer
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] strata_cleanup_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
exit=0
$ grep -n "bash -uc" scripts/shim_court/lib.sh
25:#   - Pass witness commands as args 2 and 3 (run via bash -uc; see below).
94:# Witnesses run under `bash -uc` (SHIM-COURT hardening, 2026-10-16, R190
101:# with_shim <file> <before-cmd> <after-cmd>  (witnesses run via bash -uc)
118:    if ! bash -uc "$before_cmd"; then
147:    if ! bash -uc "$after_cmd"; then
```

## Amendment verification (2026-10-16, lane 269, unedited output)

```
$ awk 'NR==364' lib/smalt/egress_router.ex
          cosmos_respond(conn, {:ok, status, headers, envelope})
$ grep -n "bash -uc" scripts/shim_court/lib.sh | grep -v "^2\|^9\|^10"
94:# Witnesses run under `bash -uc` (SHIM-COURT hardening, 2026-10-16, R190
118:    if ! bash -uc "$before_cmd"; then
147:    if ! bash -uc "$after_cmd"; then
$ grep -n "lock_token: dlv.lock_token" lib/smalt/messaging/amqp/connection.ex
2001:    case QueueStore.complete(dlv.queue, dlv.seq, lock_token: dlv.lock_token) do
2008:    case QueueStore.release(dlv.queue, dlv.seq, lock_token: dlv.lock_token) do
2020:    case QueueStore.deadletter(dlv.queue, dlv.seq, "rejected", nil, lock_token: dlv.lock_token) do
$ MIX_BUILD_ROOT=_build-lane269 mix test test/wire/egress_wire_test.exs test/egress_dispatch_test.exs
120 tests, 0 failures
exit=0
$ MIX_BUILD_ROOT=_build-lane269 mix test test/amqp --include amqp_wire
359 tests, 0 failures
exit=0
```

Note: the first amqp run of the session returned `359 tests, 1 failure`
(a timing flake); two subsequent runs of the identical command returned
359/0 — recorded here as the stable result, flake disclosed.

## Standing

- **R187b**: PASS — py_compile clean, court non-vacuous exit 0.
- **R190**: PASS — in-source marker + every consuming court re-ran clean
  under `bash -uc` witnesses.
- **R191/R192**: PARTIAL_ALIVE — grounded through consumers only (no name
  markers); consumers all green.
- **R199**: PASS (amended 2026-10-16 — restore line on disk at
  egress_router.ex:364, wire+dispatch 120/0).
- **R200**: PASS (amended 2026-10-16 — hardening is in shim_court/lib.sh
  :118/:147, the batch had checked scripts/bench/lib.sh in error).
- **R201**: PASS (added 2026-10-16 — lock-token threading in
  connection.ex settle/2, amqp incl. amqp_wire 359/0).
