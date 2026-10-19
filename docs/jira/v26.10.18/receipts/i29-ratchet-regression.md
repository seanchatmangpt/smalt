# i29 — ratchet mod regression after naming-sweep repair lane

Standing: PASS (ALIVE for the exercised surface)
Date: 2026-10-18
Context: solo (single lane; no other writer on mods/ratchet during the run)

## Scope

Post-repair regression of `mods/ratchet` after the naming-sweep lane changed
repo-root derivation to module-relative (`SMALT_ROOT` override). No edits, no
git operations.

## 1. Full test suite (from /Users/sac/smalt)

```
node --test mods/ratchet/test/
ℹ tests 29
ℹ pass 29
ℹ fail 0
ℹ skipped 0
ℹ duration_ms 905.52975
```

## 2. Plugin manifest validation

```
claude plugin validate /Users/sac/smalt/mods/ratchet
✔ Validation passed
exit=0
```

(README documents one warning for missing `author` attribution in older runs;
this run passed with no warnings shown.)

## 3. Cwd independence smoke (from /tmp)

```
cd /tmp && node --test /Users/sac/smalt/mods/ratchet/test/
ℹ tests 29
ℹ pass 29
ℹ fail 0
ℹ duration_ms 989.626917
```

No ENOENT, no `mods/mods/...` paths, same pass count as in-repo run.
Root derivation observed live: `TICKETS_PATH: /Users/sac/smalt/docs/jira/v26.10.18/azsim-burn/TICKETS.md`
resolved correctly from /tmp via `module-relative || SMALT_ROOT`
(`mods/ratchet/lib/commands.js:14`).

## 4. Read-only trigger exercise

No manual dispatch trigger exists outside a live Claude Code session —
README: "Injection requires an interactive session" (`submit-prompt-as-typed`
into the running host; prompt-driven only). Exercised the `/ratchet status`
path read-only from /tmp:

```
ratchet:
  mode: OBSERVE (panel only — no injection)
  landed: 3  open: 43
  next-dispatchable: AZB-01
  agentsInFlight: 0/20  ticks: 0  lastDispatch: never
```

Emitted prompt count: **0** (correct — OBSERVE mode injects nothing). The
dispatch path itself is exercised by the suite against a recording sink
(`test/inject.test.js`): 2 prompts submitted (AZB-15, AZB-07), both matching
the exact bounded template; dedup/lock/UNBOUNDABLE refusals all submit 0.

## Verdict

29/29 both cwds, manifest valid, module-relative root verified from a foreign
cwd, no regressions from the repair lane. Errors: none.
