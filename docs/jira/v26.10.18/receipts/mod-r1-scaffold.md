# mod-r1-scaffold — ratchet mod scaffold

Standing: PASS (scaffold ALIVE at scaffold scope; runtime TIMER behavior is compile-checked + unit-smoked, not yet witnessed in a live mods host)
Context: solo(node --check hooks/register.js + unit smoke)

Date: 2026-10-18
Lane files: `mods/ratchet/.claude-plugin/plugin.json`, `mods/ratchet/hooks/hooks.json`, `mods/ratchet/hooks/register.js` ONLY (other lanes add modules via imports).

## What landed

- `/Users/sac/smalt/mods/ratchet/.claude-plugin/plugin.json` — name `ratchet`, description "20-agent ratchet: keeps N agents in flight ratcheting tickets to done".
- `/Users/sac/smalt/mods/ratchet/hooks/hooks.json` — SessionStart hook invoking `node "${CLAUDE_PLUGIN_ROOT}/hooks/register.js"`.
- `/Users/sac/smalt/mods/ratchet/hooks/register.js` — `register(on)` registers a TIMER hook (every 5 min). Each tick: load state from `docs/jira/v26.10.18/rewrite-drafts/ratchet-state.json` (init from defaults if absent), compute outstanding work from `docs/jira/v26.10.18/azsim-burn/TICKETS.md`, gate on capacity + lastDispatch dedup, and submit exactly one prompt via the mods API `submit-prompt-as-typed` surface:

  `AZB ratchet tick: dispatch agents for the highest-priority ticket without a receipt per docs/jira/v26.10.18/azsim-burn/TICKETS.md`

  All state writes are atomic (same-dir tmp + `fs.renameSync`). Zero `Process.sleep` — timers are the only mechanism. Everything exported for tests.

## Deviation (disclosed)

Task specified hooks.json "pointing to register.js" under a Register-style registration; `claude plugin validate` rejects `Register` as an unknown hook event ("hooks.Register: unknown hook event; entry ignored at runtime"). Used the known `SessionStart` event to invoke register.js, which then registers the TIMER via the mods API inside the host. This removed the runtime-ignored-entry warning.

Also disclosed: `lastDispatch` is stamped only on confirmed injection (an initial version stamped it even when the mods API surface was absent; fixed and retested).

## Validation (real output)

```
$ node --check hooks/register.js
CHECK_OK   (exit 0)

$ claude plugin validate /Users/sac/smalt/mods/ratchet
Validating plugin manifest: /Users/sac/smalt/mods/ratchet/.claude-plugin/plugin.json

⚠ Found 1 warning:
  ❯ author: No author information provided. Consider adding author details for plugin attribution

✔ Validation passed with warnings
VALIDATE_EXIT=0
```

Behavior smoke (temp state file, real fs):

```
tick1 (no state file, mixed tickets): {"injected":true,"outstanding":1,"cause":"under-capacity"}
state1 exists: true, lastDispatch set: true
tick2 (+1 min):  {"injected":false,"cause":"dedup-window"}
tick3 (+5 min, no API surface): {"injected":false,"lastDispatch":null}   // no phantom stamp
tick3' (+5 min, with API):      {"injected":true,"lastDispatch":"2026-10-18T00:10:00.000Z"}
tick4 (agentsInFlight=20):      {"injected":false,"cause":"at-capacity"}
prompt text: EXACT-MATCH vs DISPATCH_PROMPT constant
tmp-leftover: 0   (atomic-write temp files cleaned by rename)
```

## Falsifier / open items

- The 5-minute TIMER firing inside a live mods host is not yet witnessed (no mods host run in this lane). First live host run should show exactly one injection per tick and the state file advancing `lastDispatch`.
- Outstanding-work heuristic (receipt/DONE markers over AZB- ticket lines in TICKETS.md) should be reconciled with TICKETS.md's actual format when that file lands its next revision.
