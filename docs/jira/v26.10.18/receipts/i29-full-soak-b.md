# i29-b — Full soak leg B: `mix test` (stress excluded)

Standing: **PASS with 1 KNOWN rotating face** (acceptance met: no new deterministic faces; one compile-abort recurrence, foreign in-flight file).

Date: 2026-10-18 (~22:00–22:25 PDT). Subject: /Users/sac/smalt @ main, HEAD moved mid-leg: `dda0bf5` (at dispatch) → `6eec1453b1aaa0cccaa37bf01591128e25c2e7fe` (at close). Working tree dirty with foreign in-flight edits owned by other lanes. This lane made no lib/test edits, no git actions.

Context: full.

## Identities (verbatim)

```
Erlang/OTP 28 [erts-16.2] [source] [64-bit] [smp:16:16] [ds:16:16:10] [async-threads:1] [jit]

Elixir 1.19.5 (compiled with Erlang/OTP 28)
```

```
{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}
```

```
dda0bf5c504268a6d3b620c691520d97c1c384ac   # HEAD at dispatch
6eec1453b1aaa0cccaa37bf01591128e25c2e7fe   # HEAD at close (coordinator commits landed mid-leg)
```

## Method

Leg B as dispatched: `MIX_BUILD_ROOT=_build-ft-fs5 mix test` — run 1. Result:
**compile abort**, zero tests executed. Same face as leg A
(`receipts/i29-full-soak.md`): `test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1`
requires `/burn-evidence/test/support/assert_eventually.ex` — nonexistent mount.
The file is UNTRACKED, foreign in-flight (the dda0bf5 fix repaired only the
azure_common_issues copy, not this one). Per the W672 compile-abort law this is
not a failure count.

To get soak signal despite the abort (invocation-only workaround, no edits):
run 2 and run 3 over ALL test files EXCEPT that one:

```
MIX_BUILD_ROOT=_build-ft-fs5 mix test $(find test -name '*_test.exs' \
  -not -path '*sovereign_midnight*' | sort | tr '\n' ' ')
```

- Run 2: `1 doctest, 7 properties, 2710 tests, 1 failure (93 excluded)` — finished 158.0 s (failure identity lost to a `tail -60` pipe; lane error, disclosed).
- Run 3 (full log `/tmp/fs5b-full.log`): `1 doctest, 7 properties, 2710 tests, 1 failure (93 excluded)` — finished 221.3 s.
- Solo confirmation: `MIX_BUILD_ROOT=_build-ft-fs5 mix test test/azsim/dets_recovery_test.exs`
  → `5 tests, 0 failures`, exit 0.

## Run 3 single failure (verbatim)

```
1) test graphlaw/WasmEngine killed mid-request: caller receives :engine_unavailable as HTTP 503 typed body, nothing admitted (SmaltTest.Azsim.DetsRecoveryTest)
   test/azsim/dets_recovery_test.exs:237
   eventually("WasmEngine restarted after kill"): not satisfied within 5000ms (after 29 pass(es)) — last value: :down
   code: SmaltTest.Env.with(
   stacktrace:
     (smalt 26.10.16) test/support/assert_eventually.ex:55: SmaltTest.AssertEventually.loop/8
     test/azsim/dets_recovery_test.exs:277: anonymous fn/0 in SmaltTest.Azsim.DetsRecoveryTest."test graphlaw/WasmEngine killed mid-request: caller receives :engine_unavailable as HTTP 503 typed body, nothing admitted"/1
     (smalt 26.10.16) test/support/env.ex:24: SmaltTest.Env.with/2
     test/azsim/dets_recovery_test.exs:251: (test)
```

## Classification vs FLAKE_LEDGER / i27 bisect

The run 3 failure is `test/azsim/dets_recovery_test.exs` — **KNOWN
ROTATING-LOAD face**, already classified in `receipts/i27-rotating-bisect.md`
(solo-green 2/2, shared-teardown signature). Re-confirmed this leg: solo run
`5 tests, 0 failures`, exit 0. Not a new deterministic face.

## Verdict vs acceptance

Acceptance was "clean or only KNOWN rotating faces."

- Suite body (2710 tests, everything except the foreign aborting file): **only
  known rotating faces — acceptance MET**. All prior deterministic faces from
  i24–i29 (deterministic pair, azure_common require, c1 standalone) did not
  recur.
- Plain `mix test` remains BLOCKED by the foreign untracked
  `test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1`
  (`/burn-evidence` require) — falsifier (b) of `receipts/i28-stress-verify.md`
  is still open. Recurrence of the /burn-evidence class, NEW FACE, different
  file than dda0bf5's.

## Follow-up (owning lane / coordinator)

- Apply the dda0bf5 fix shape (`__DIR__`-relative require) to
  `test/azsim/sovereign_midnight/sovereign_midnight_test.exs` and its mirror
  `docs/jira/v26.10.18/burn/sovereign_midnight_test.exs` (both untracked,
  foreign in-flight; compile-freeze SLA disclosure: this lane applied nothing).
- DetsRecovery rotating face stays on ledger probation (F-class), no new row.

## Cleanup

`_build-ft-fs5` (343 MB) deleted by this lane at close, per lane build-root
cleanup law.
