# BK-GWS7V — gws7 witness failure root-caused and fixed (it was gate 6, not gate 5)

Standing: ALIVE
Context: solo
Date: 20261022T0915Z

## Premise check (BK-WIT attribution corrected)

BK-WIT (bkwit-witness-all.md) named **gate 5** ("hung guest times out fail-closed
and the pool self-heals") as the run's only real failure, `{:gate_timeout,
:fail_closed}`. Fresh runs on the converged tree show **gate 5 is green** (6/6
pre-fix runs) — the deterministic failure is **gate 6** ("guest trap (exit 86)
aborts only its worker", `refute Process.alive?(worker)` got true at
test/integration/wasm_sandbox_court.exs:107). The witness's gate-5 attribution
was wrong in name only: both legs share the same substrate defect class
(racy containment assertion), and the witness-all retry log named the file,
not the leg, as the flake locus.

## Fresh 3-run verdict (pre-fix, quiet machine, load 4-8)

`MIX_BUILD_ROOT=_build-bkgws7v mix test test/integration/wasm_sandbox_court.exs`
— 3/3 runs `5/6 passed`, identical failure:

```text
1) test gate 6: guest trap (exit 86) aborts only its worker
   test/integration/wasm_sandbox_court.exs:97
   Expected false or nil, got true
   code: refute Process.alive?(worker)
   arguments: #PID<0.2847.0>
```

Also verified isolated (`mix test ...:97`) 3/3 identical. Verdict: **real
defect, not load-sensitivity** — a fixed sleep/ratio-fence would not have
fixed it.

## Root cause

`Worker.run` stub exit-status arm returns via GenServer
`{:stop, reason, reply, state}`: the reply is delivered BEFORE the worker
processes its own termination. The caller resumes synchronously and checks
`Process.alive?(worker)` while the worker's exit is still pending on the
scheduler queue. Whether the caller wins the race depends on scheduler
layout/load — deterministic failure when the caller wins (quiet machine,
6/6 here), occasional pass under load (why the leg survived earlier waves
and was mislabeled a "contention flake" in bkgwsskep2-wave-verify.md).

The `lib/` behavior is contract-correct: the worker does terminate and the
pool heals over the EXIT (gate 3 covers crash-only respawn; post-fix runs
confirm). The defect is the court's assertion observing an asynchronous
transition synchronously.

## Fix (court-only, one leg)

test/integration/wasm_sandbox_court.exs gate 6: the bare synchronous
`refute Process.alive?(worker)` is replaced by a bounded poll on actual
death via the one audited poll implementation (`SmaltTest.Internal.Poll`,
no-sleep doctrine compliant — no new sleep site). The contract asserted is
unchanged: the worker MUST terminate (a hung-forever worker still fails
typed at the 5s poll deadline); only the observation is now asynchronous-
safe. `lib/smalt/wasm/` is untouched.

## Post-fix receipt (embedded output)

```text
$ for i in 1 2 3; do MIX_BUILD_ROOT=_build-bkgws7v mix test \
    test/integration/wasm_sandbox_court.exs; echo "run $i exit=$?"; done
run 1 exit=0
run 2 exit=0
run 3 exit=0

Result: 6 passed   (all three runs, ~1.9s each)
```

Green ×3 on the same quiet machine where the failure was deterministic.
Non-vacuity: the pre-fix failure (6/6 above) is the mutation witness — the
changed assertion is the only line between `Expected ... got true` and pass.

## Residue

- fd-inheritance law re-witnessed during this lane: piping `mix test` into
  `tail` hung ~20 min because the surviving `--hang` stub inherits the pipe
  write-end (same class as the GWSSKEP2 stage-1 pipeline deadlock). Runs
  must redirect to files, not pipes. Not re-filed — precedent recorded in
  same-checkout-fanout addition 4.
- BK-WIT's "load-sensitivity suspect: 300ms budget" is closed: the 300ms
  fail-closed budget is correct and green ×6; no lib/ change warranted.

## Files

- test/integration/wasm_sandbox_court.exs (gate-6 assertion fix)
- docs/jira/v26.10.22/receipts/bkgws7v-gate5.md (this receipt)
