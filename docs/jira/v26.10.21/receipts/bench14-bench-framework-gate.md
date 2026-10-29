# BENCH-14 receipt — prospective zero-framework bench-framework gate

- **Date**: 2026-10-21
- **Repo**: /Users/sac/smalt
- **Lane**: BENCH-14 (writer), v26.10.21 OTP-29 window
- **Contract**: BENCH-9 verdict — deletion is a measurement no-op, enforcement is
  prospective (`docs/jira/v26.10.21/receipts/bench9-deletion-audit.md`)
**Standing**: ALIVE (green gate + flip proven on this exact subject, exits re-read below)
Context: solo

## Artifact

- Gate: `scripts/bench_framework_gate.py` (fail-closed census, exit 0 pass / 1 fail)
- Recipe: `justfile.d/47-bench-framework.just` → `just bench-framework-gate`
  (gate) + `just bench-framework-gate-court` (non-vacuity self-check);
  root `justfile` imports the module.

## Enforcement (prospective, frozen allowlist)

1. No benchee / benchee_html dep or NEW benchee reference in mix.exs / mix.lock /
   lib/ / test/ / scripts/ (ex `_build`, `deps`, `node_modules`). Frozen allowlist:
   `scripts/bench/benchee_runner.exs` — the BENCH-9-cited evidence record
   (`docs/jira/v26.10.14/receipts/errc2-benchee.md`). The gate's own source and
   recipe are self-exempt.
2. No new `Benchee.run` / unannotated `:timer.tc` in `scripts/bench` — frozen
   allowlist = the 3 BENCH-9-classified probes (b8_amqp_beam.exs x2,
   pb6_dual_boundary.exs x7, c10_affidavit_seal.exs x1), or a per-site
   `# BENCH-CLASS: probe` annotation.
3. Fail-closed: missing/unreadable mix.exs or mix.lock is FAIL, not skip.

## Green receipt (actual output, this subject)

```
$ just bench-framework-gate; echo "exit=$?"
== bench-framework gate census (/Users/sac/smalt)
   benchee allowlist : 1 file(s), frozen
   :timer.tc probes  : 3 file(s), frozen (BENCH-9 classified)
   VERDICT: PASS
exit=0
```

## Non-vacuity flip (actual output, this subject)

`--self-check` mints a temp copy, injects a `SHIM-COURT`-marked benchee dep pair
into mix.exs + an unannotated `:timer.tc` probe into scripts/bench, and demands
the census REFUSE; then demands the clean real tree PASS:

```
$ just bench-framework-gate-court; echo "court_exit=$?"
== bench-framework gate census (/Users/sac/.cache/tmp/bench_framework_gate_selfcheck_j7csx_2j)
   benchee allowlist : 1 file(s), frozen
   :timer.tc probes  : 3 file(s), frozen (BENCH-9 classified)
   VERDICT: FAIL (3 violation(s))
     - BENCHEE-REF mix.exs: benchee reference outside frozen allowlist ...
     - TIMER-TC scripts/bench/zz_shim_probe.exs:1: unannotated :timer.tc ...
     - TIMER-TC scripts/bench/zz_shim_probe.exs:2: unannotated :timer.tc ...
   self-check shim: injected benchee dep + unannotated :timer.tc -> REFUSED (non-vacuity proof)
== bench-framework gate census (/Users/sac/smalt)
   VERDICT: PASS
   self-check clean: real tree -> PASS
court_exit=0
```

A gate that cannot refuse exits 1 as VACUOUS — the flip is the proof, not the PASS.

## Annotation arm (separately executed)

A temp census with a `# BENCH-CLASS: probe`-annotated `:timer.tc` site PASSES
(exit 0, zero violations) — the annotation escape hatch is real, not dead code.

## Replay

```
just bench-framework-gate && just bench-framework-gate-court
```

KD-COVERS: none (script gate, no lib/ shim row).
