# ratchet

A smalt marketplace mod that keeps a 20-agent ratchet in flight: N agents
concurrently ratcheting tickets to done, with a panel, auto-execute, and a
court gate. Plugin root: `/Users/sac/smalt/mods/ratchet`.

## What the mod does

- **20-agent ratchet** — holds a fixed cohort (default capacity 20) of agents
  in flight over the ticket DAG, so work keeps advancing while capacity is
  available instead of serializing behind a single driver.
- **Panel** — a live view of the ratchet: cohort capacity, in-flight tickets,
  decision log, blocked count (`/ratchet panel`).
- **Auto-execute** — when the gate admits, dispatch prompts are injected
  without a per-ticket human prompt, deduped to one injection per 5-minute
  tick (`lastDispatch` timestamp in the state file; timers, never sleeps).
- **Court gate** — nothing is marked done without a court receipt. A ticket
  that has not been courted stays open; the ratchet never fabricates a done
  state. A second gate (`hooks/lib/gate.js`) denies hand-edits of generated
  artifacts, force-push to main, and `rm -rf /` at PreToolUse.

## Layout

```
.claude-plugin/plugin.json   plugin manifest (ratchet 0.1.0)
hooks/hooks.json             Register -> node ${CLAUDE_PLUGIN_ROOT}/hooks/register.js
hooks/register.js            timer tick (5 min): load state -> outstanding -> gate -> inject
hooks/turn.js                turn.complete handler: DAG dep check -> DISPATCH/SKIP/IDLE/BLOCKED
hooks/lib/gate.js            PreToolUse deny gate (generated artifacts, force-push, rm -rf /)
hooks/lib/state.js           tmp-dir state store, keyed by cwd
lib/state.js                 turn-facing state + computeNextAction over the ticket DAG
```

## Install

### Marketplace (persistent)

```
claude plugin marketplace add /Users/sac/smalt/mods
/plugin install ratchet@smalt-mods
```

### One session (`--plugin-dir`)

```
claude --plugin-dir /Users/sac/smalt/mods/ratchet
```

### Validation

```
$ claude plugin validate /Users/sac/smalt/mods/ratchet
Validating plugin manifest: /Users/sac/smalt/mods/ratchet/.claude-plugin/plugin.json
✔ Validation passed with warnings
exit=0
```

(The only warning is missing `author` attribution in the manifest.)

## Command surface

| Command | Effect |
|---|---|
| `/ratchet` | Show ratchet state: cohort size, in-flight, done, blocked, last dispatch |
| `/ratchet on` | Start the ratchet (20-agent cohort over the ticket DAG, auto-execute enabled) |
| `/ratchet off` | Stop dispatching; in-flight agents finish their current ticket |
| `/ratchet panel` | Open the live panel view |

## State file contract

Three state surfaces, each written atomically or event-appended:

- **Dispatcher state**
  (`docs/jira/v26.10.18/rewrite-drafts/ratchet-state.json`): capacity,
  `agentsInFlight`, `lastDispatch` (ISO timestamp, the 5-minute dedup key),
  `ticks`. Written via same-directory tmp file + POSIX rename (atomic). If
  absent or unreadable it is re-initialized from defaults — a missing state
  file is never a dispatch signal by itself.
- **Turn state** (`mods/ratchet/state.json`, override `RATCHET_STATE_PATH`):
  ticket list with `status` (OPEN / IN_FLIGHT / DONE) and `deps` edges, a
  bounded `decisionLog` (last 50 entries), `dispatchLock`, `lastDispatchAt`.
  A ticket flips to DISPATCH only with deps satisfied; `DONE` is a
  court-receipt-gated transition, not an agent assertion.
- **Gate event log** (`$TMPDIR/ratchet-state-<cwd-key>.json`): append-only
  event ring (last 100) with per-kind counters (`gate-block` etc.), keyed by
  cwd so concurrent sessions don't fight.

## Honest boundary

- **Injection requires an interactive session.** The ratchet injects prompts
  via the mods API (`submit-prompt-as-typed`) into a live Claude Code
  session; it cannot start or drive a session that is not already running.
- **Hooks don't run in WSL.** The hook registration path
  (`hooks/hooks.json` -> `register.js`) is a no-op under WSL; on WSL the
  ratchet is prompt-driven only.
- **Panel is terminal/Desktop/VSCode only.** There is no web panel; the
  panel surface renders in terminal, Claude Desktop, and VSCode hosts.
