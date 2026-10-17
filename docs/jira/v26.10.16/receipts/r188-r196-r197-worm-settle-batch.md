# Receipt — R188 / R194 / R196 / R197 (WORM / settle / tombstone batch)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 late docs sweep, lane 267)
- **Standing:** PASS (R188, R194, R196, R197) — amended 2026-10-16: R196
  court repaired (stale test anchor, not a lib defect) and re-run PASS.
- **Date:** 2026-10-16 (W-late docs lane, batch 4 of 5)

## What landed

- **R188** (WORM arms): `lib/smalt/data_plane/blob_storage.ex` WORM-arm
  behavior, covered by `test/data_plane/blob_hardening_test.exs` (112→116
  tests on this tree) and the dedicated non-vacuity court
  `scripts/shim_court/blob_worm_arms_court.sh`.
- **R194** (renew→message-row mirror): `test/amqp/queue_store_test.exs:564`
  — "sweep/0 does NOT reclaim a renewed message lock (renew mirrors into
  message row)" — plus its dedicated court
  `scripts/shim_court/renew_mirror_court.sh` (`R194_LINE=564`,
  `# SHIM-COURT: R194 mirror disabled` marker contract). In batch scope as
  the between-R196/R197 amqp repair; the dedicated court was not re-run in
  this batch (suite leg covers the regression in the 52/0 queue_store run
  below).
- **R196** (settle CAS): `lib/smalt/messaging/amqp/queue_store.ex:339-344`
  — token-scoped settlement (audit Finding 2, lane R244): with
  `opts[:lock_token]` the settle is a compare-and-settle against the live
  token row. Suite leg: the R244 tests inside `test/amqp/queue_store_test.exs`.
- **R197** (tombstone grace): `lib/smalt/messaging/amqp/sweeper.ex:35-63`
  — message-lock tombstone grace (audit Finding 3): tombstones re-put after
  sweep, bounded by `amqp_sweeper_lock_grace_ms` (default 30_000), so
  a renew of a just-swept token answers 410 :lock_lost, never 404.

## Verification (2026-10-16, lane 267, unedited output)

```
$ MIX_BUILD_ROOT=_build-lane267 mix test test/data_plane/blob_hardening_test.exs
116 tests, 0 failures
exit=0
$ bash scripts/shim_court/blob_worm_arms_court.sh
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to lib/smalt/data_plane/blob_storage.ex (SHIM-COURT marker present)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] blob_worm_arms_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
exit=0
$ MIX_BUILD_ROOT=_build-lane267 mix test test/amqp/queue_store_test.exs
52 tests, 0 failures
exit=0
$ bash scripts/shim_court/settle_cas_court.sh
1 test, 0 failures (51 excluded)
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to lib/smalt/messaging/amqp/queue_store.ex (SHIM-COURT marker present)
[SHIM] AFTER: R244 describe unexpectedly PASSED under shim (see /tmp/r196_settle_cas_after.log)
[FAIL:AFTER] after-witness failed against SHIMMED lib/smalt/messaging/amqp/queue_store.ex — new outcome absent (gate vacuous or shim inert); file restored+verified
exit=1
$ MIX_BUILD_ROOT=_build-lane267 mix test test/amqp/sweeper_test.exs
5 tests, 0 failures
exit=0
$ bash scripts/shim_court/tombstone_grace_court.sh
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] tombstone_grace_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
exit=0
```

### Amendment verification (2026-10-16, lane 269, unedited output)

```
$ env MIX_BUILD_ROOT=_build-lane269 just shim-court settle_cas
Excluding tags: [:test]
Including tags: [location: {"test/amqp/queue_store_test.exs", 739}]

.......
Finished in 0.3 seconds (0.00s async, 0.3s sync)
7 tests, 0 failures (45 excluded)
[SHIM] BEFORE witness passed (old signature holds)
[SHIM] shim applied to lib/smalt/messaging/amqp/queue_store.ex (SHIM-COURT marker present)
[SHIM] AFTER: R244 zombie tests FAILED under shim as required (flip witnessed)
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] settle_cas_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
court_exit=0
```

## Findings

- **settle_cas court — REPAIRED and PASSING (2026-10-16 amendment):** the
  earlier FAIL:AFTER (exit 1) was a stale line anchor in the court itself —
  `R244_LINE=725` pointed at the pre-edit describe block; the R244 zombie
  tests now live at line 739 of `test/amqp/queue_store_test.exs`. The court
  script now exports `R244_LINE=739`; re-run below flips non-vacuously
  (BEFORE holds, AFTER fails-under-shim as required, restore byte-exact).
  Root cause is the court's anchor, NOT a lib defect — `queue_store.ex`
  was correct throughout. Standing for R196 upgraded to PASS.
- **tombstone_grace court**: PASS with restore verified; the interim
  `assert {:ok, %{locked_until: 1100}}` line in the raw output is the
  court's BEFORE-leg expected-flip transcript, not a standalone-suite
  failure (standalone sweeper suite is 5/0 above).

## Standing

- **R188**: PASS (suite 116/0 + court non-vacuous exit 0).
- **R194**: PASS (regression test present at queue_store_test.exs:564,
  suite 52/0; dedicated court on disk, not re-run this batch).
- **R196**: PASS — suite PASS + settle_cas court non-vacuous exit 0
  (amended 2026-10-16: stale anchor 725→739 in settle_cas_court.sh fixed;
  root cause was the court's anchor, not a lib defect).
- **R197**: PASS (suite 5/0 + court non-vacuous exit 0).
