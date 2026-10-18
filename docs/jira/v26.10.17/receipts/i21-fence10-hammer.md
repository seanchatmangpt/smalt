# i21 — Fence 10 hammer: BLOCKED (dep-graph regression, zero tests executed)

Standing: BLOCKED (0/12 legs reached the test suite; acceptance 12/12 green NOT met)
Context: solo

Subject: 10 consecutive solo runs + 2 load legs of
`MIX_BUILD_ROOT=_build-ft-vf10 mix test test/affidavit_wasm_failclosed_test.exs`,
cwd /Users/sac/smalt, per the fence-10 fix receipt
`docs/jira/v26.10.17/receipts/i21-fence10-fix.md` (standing ALIVE as of 2026-10-17 20:46).

## Blocker

Every leg aborts at Mix's dependency check, before any test compiles or runs:

```
Unchecked dependencies for environment test:
* ex4pm (Hex package)
  the dependency ex4pm 26.10.8
  > In mix.exs:  {:ex4pm, "~> 26.10.8", [env: :prod, hex: :ex4pm, ...]}
  does not match the requirement specified
  > In deps/ash_ex4pm/mix.exs:
    {:ex4pm, "== 26.10.1", [only: [:dev, :test], ...]}
** (Mix) Can't continue due to errors on dependencies
```

Root cause: commit 248e119 ("B1 CLOSED — ex4pm hex-only", 2026-10-17 20:47)
bumped root `mix.exs` to `{:ex4pm, "~> 26.10.8"}` and dropped the `override: true`
(mix.exs:117-120), while the locked `ash_ex4pm` 26.10.4 (mix.lock line 4) pins
`== 26.10.1`. The hex latest `ash_ex4pm` is 26.10.4 (hex.pm releases:
26.10.4/26.10.3/26.10.2/26.10.1) — no released version satisfies the new pin, so
the dev/test dep graph is unsatisfiable tree-wide and `mix.lock` is internally
inconsistent (lock says ex4pm 26.10.8 alongside ash_ex4pm requiring 26.10.1).
This is a pre-existing (commit-introduced) breakage, not session-introduced:
this lane edited nothing.

Per-run wall times are meaningless (abort at ~0.5-0.9s during dep check):

| leg | wall | result |
|-----|------|--------|
| 1-10 (solo) | 0.52-0.91s each | abort: "Can't continue due to errors on dependencies", 0 tests |
| 11-12 (load legs) | not run | deliberately skipped — an abort under load proves nothing; no hogs launched by this lane |

## Unblocks, in order of authority

1. B1 author/operator: publish `ash_ex4pm` allowing ex4pm `~> 26.10.8`, or
   re-pin `{:ex4pm, "== 26.10.1", override: true}` until then. Both are
   mix.exs edits — outside this lane's no-edit mandate.
2. Alternatively `mix deps.update ash_ex4pm` after (1); today it resolves nothing.

## Side findings

- Stray `yes` CPU hog (PID 9515, orphaned, elapsed 15:37, PPID 1) was alive on
  this machine at lane start — leftover from the prior i21 lane's load leg
  despite that receipt's "hogs killed, pgrep empty" claim. Killed it;
  `pgrep -x yes` now empty (exit 1). Timing of the prior receipt's hog leg is
  therefore suspect.
- `_build-ft-vf10` is stale across the board (`mix deps` reports nearly all
  deps "build is outdated"); even with the pin fixed the first run recompiles.

## Falsifier replay

`cd /Users/sac/smalt && MIX_BUILD_ROOT=_build-ft-vf10 mix test test/affidavit_wasm_failclosed_test.exs`
— currently exit 1 with the dep-conflict abort above. Re-run after the pin fix.
