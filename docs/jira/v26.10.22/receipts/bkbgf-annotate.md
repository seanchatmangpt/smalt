# BK-BGF — F1 close: pb4_merkle_dual.exs BENCH-CLASS annotation

**Standing**: ALIVE
**Context**: solo
**Date**: 2026-10-22 (UTC)
**Lane**: BK-BGF · Repo: `/Users/sac/smalt`
**Closes**: F1 of `bkgwsskep-wave-audit.md` (BENCH-14 gate red on current tree)

## Change

`scripts/bench/pb4_merkle_dual.exs` — the two `:timer.tc` sites (ticket lines
255/266) annotated with `# BENCH-CLASS: probe` on the same line as the call
(the gate's `BENCH_CLASS_RE` matches per-line; a preceding-line comment does
not count). This is the correct classification — bounded identity probe, not a
timing bench — and the frozen allowlists were NOT widened.

## Gate before (honest red, exit 1)

```
$ just bench-framework-gate; echo exit=$?
   benchee allowlist : 1 file(s), frozen
   :timer.tc probes  : 3 file(s), frozen (BENCH-9 classified)
   VERDICT: FAIL (2 violation(s))
     - TIMER-TC scripts/bench/pb4_merkle_dual.exs:255: unannotated :timer.tc …
     - TIMER-TC scripts/bench/pb4_merkle_dual.exs:266: unannotated :timer.tc …
exit=1
```

## Gate after (exit 0) + non-vacuity court (exit 0)

```
$ just bench-framework-gate; echo exit=$?
   benchee allowlist : 1 file(s), frozen
   :timer.tc probes  : 3 file(s), frozen (BENCH-9 classified)
   VERDICT: PASS
exit=0

$ just bench-framework-gate-court; echo court_exit=$?
== bench-framework gate census (/Users/sac/.cache/tmp/bench_framework_gate_selfcheck_p92ns0h6)
   VERDICT: FAIL (3 violation(s))   <- temp-copy shim: injected benchee dep +
     - BENCHEE-REF mix.exs: benchee reference outside frozen allowlist …            unannotated :timer.tc (zz_shim_probe.exs:1,2)
     - TIMER-TC scripts/bench/zz_shim_probe.exs:1: unannotated :timer.tc …
     - TIMER-TC scripts/bench/zz_shim_probe.exs:2: unannotated :timer.tc …
   self-check shim: injected benchee dep + unannotated :timer.tc -> REFUSED (non-vacuity proof)
== bench-framework gate census (/Users/sac/smalt)
   VERDICT: PASS
   self-check clean: real tree -> PASS
court_exit=0
```

Non-vacuity is witnessed three ways: (1) the pre-fix real tree FAILed exit 1
on exactly the two ticketed lines; (2) the court's scratch shim
(temp copy, unannotated `:timer.tc` + injected benchee) is REFUSED; (3) the
post-fix real tree PASSes — the flip tracks the annotation, nothing else.
Real-tree file untouched by the shim (court runs on a
`.cache/tmp/bench_framework_gate_selfcheck_*` copy; real tree re-census PASS).

## Probe executes post-relocation

```
$ timeout 120 mix run --no-start scripts/bench/pb4_merkle_dual.exs; echo probe_exit=$?
ground-truth: local replica + variant byte-identical to real seal_receipt (live DETS, n=10)
n=10: identity=OK … n=100: identity=OK … n=10000: identity=OK … n=100000: identity=OK
wrote 16 rows to /Users/sac/smalt/tmp/bench/pb4-merkle-dual.jsonl
probe_exit=0
```

(identity=OK at every n; only a pre-existing charlist-sigil warning at line 315,
unrelated to this change.)

## Falsifier status

F1 close condition met: `just bench-framework-gate` exits 0 and
`bench-framework-gate-court` is green on the tree carrying the pb4 annotation.
