# i29 — Full soak leg: `mix test` (stress excluded)

Standing: **BLOCKED** — compile abort, not a count (compile-abort ≠ failure count, W672 census law). Zero tests executed.

Date: 2026-10-18. Subject: /Users/sac/smalt @ main, HEAD `dda0bf5c504268a6d3b620c691520d97c1c384ac` (`dda0bf5-dirty`; foreign in-flight edits present, owned by other lanes; this lane made no edits, no git).

Context: full.

## Identities (verbatim)

```
Erlang/OTP 28 [erts-16.2] [source] [64-bit] [smp:16:16] [ds:16:16:10] [async-threads:1] [jit]

Elixir 1.19.5 (compiled with Erlang/OTP 28)
```

```
dda0bf5c504268a6d3b620c691520d97c1c384ac
dda0bf5-dirty
```

Command: `MIX_BUILD_ROOT=_build-ft-fs4 mix test` (2 runs; full log `/tmp/fs4-full.log`).

## Result

Run 1 and run 2 — identical abort point, both runs:

```
== Compilation error in file test/azsim/sovereign_midnight/sovereign_midnight_test.exs ==
** (Code.LoadError) could not load /burn-evidence/test/support/assert_eventually.ex. Reason: enoent
    (elixir 1.19.5) lib/code.ex:2339: Code.find_file!/2
    (elixir 1.19.5) lib/code.ex:1605: Code.require_file/2
    test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1: (file)
    (elixir 1.19.5) lib/kernel/parallel_compiler.ex:648: Kernel.ParallelCompiler.require_file/2
    (elixir 1.19.5) lib/kernel/parallel_compiler.ex:531: anonymous fn/5 in Kernel.ParallelCompiler.spawn_workers/8
```

Tail -3 verbatim (run 1, as dispatched):

```
    (elixir 1.19.5) lib/code.ex:2339: Code.find_file!/2
    test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1: (file)
    (elixir 1.19.5) lib/kernel/parallel_compiler.ex:648: Kernel.ParallelCompiler.require_file/2
```

## Cause

`test/azsim/sovereign_midnight/sovereign_midnight_test.exs` line 1:
`Code.require_file("test/support/assert_eventually.ex", "/burn-evidence")` —
`/burn-evidence` does not exist on this machine. The file is UNTRACKED
(`git status`: `?? test/azsim/sovereign_midnight/`, mirror copy at
`?? docs/jira/v26.10.18/burn/sovereign_midnight_test.exs`) — a foreign
in-flight edit from another lane, not this lane's file.

## Classification vs FLAKE_LEDGER F18–F23 + i24–i29

**KNOWN-IN-REPAIR — recurrence of the /burn-evidence class** (the class whose
falsifier (b) is still open in `receipts/i28-stress-verify.md`: "after
/dr-burn-evidence lane lands, plain `mix test` must produce a count again").
Fix dda0bf5 repaired the azure_common_issues face; this is a NEW FACE of the
same mechanism (absolute require of a nonexistent mount), different file:
`test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1`.

Not F18 (store_churn list_prefix), not F19/F20 (torn-DETS probe),
not F21 (fence-11 noproc), not F22 (perf-ratio load skew), not F23 (60 s
saturation-timeout class) — the abort precedes any test execution, so no
F18–F23 face could even manifest this leg.

## Follow-up (owning lane / coordinator)

- Same fix shape as dda0bf5: `__DIR__`-relative require, or land the
  /burn-evidence mount the file was written against.
- Untracked-file disclosure: this lane owns no edits; the blocking file is
  foreign in-flight (see Compile-freeze SLA, disclosure law).
