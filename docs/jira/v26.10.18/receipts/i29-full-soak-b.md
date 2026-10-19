# i29 — Full soak leg b: `mix test` (fs6, complements fs4/fs5)

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

Command: `MIX_BUILD_ROOT=_build-ft-fs6 mix test` (2 runs; second run full log `/tmp/fs6.log`).

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

Exit code 1 on both runs; `grep -c "0 tests"` on the full log = 0 summary lines (abort precedes execution).

## Cause

`test/azsim/sovereign_midnight/sovereign_midnight_test.exs:1`:
`Code.require_file("test/support/assert_eventually.ex", "/burn-evidence")` —
`/burn-evidence` does not exist on this machine. The file is UNTRACKED
(`?? test/azsim/sovereign_midnight/`, mirror at
`?? docs/jira/v26.10.18/burn/sovereign_midnight_test.exs`) — foreign
in-flight edit from another lane; this lane owns no edits. Not fixed by
dda0bf5, which repaired only the `azure_common_issues_test.exs:1` face
(`__DIR__`-relative).

## Classification vs FLAKE_LEDGER F18–F23 + i24–i29

**KNOWN-IN-REPAIR — third witness of the /burn-evidence compile-abort class**
(fs4 receipt `i29-full-soak.md`, fs5 leg, now fs6). Deterministic, environment-
independent (reproduced identically 2/2 runs, 3 lanes). Not F18 (store_churn),
not F19/F20 (torn-DETS), not F21 (wasm noproc), not F22 (perf-ratio skew),
not F23 (saturation/conn-refusal class) — no test executed, so no F18–F23
face could manifest. i24–i29: matches only the compile-abort census face
already opened by fs4 (i29-full-soak); no new defect class.

## Follow-up (owning lane / coordinator)

- Same fix shape as dda0bf5: line 1 →
  `Code.require_file("../support/assert_eventually.ex", __DIR__)`
  (pattern already proven in `test/azsim/azure_common_issues_test.exs:1`),
  or land the `/burn-evidence` mount the file was written against.
- Compile-freeze SLA disclosure: blocking file is foreign in-flight
  (`test/azsim/sovereign_midnight/`, untracked); this lane applied no fix —
  coordinator/owning lane to repair or revert.
- Cleanup deviation: `rm -rf _build-ft-fs6` was DENIED by the permission
  system at session end; the build root remains on disk at
  `/Users/sac/smalt/_build-ft-fs6` (~1 lane build root, reclaimable via
  `just lane-clean`).
