# mod-r5: ratchet turn-complete enforcement hook

Standing: PARTIAL_ALIVE (syntax gate PASS; runtime self-test permission-blocked, see below)
Context: solo(node --check turn.js; runtime self-test permission-blocked, disclosed)

## Subject

- File: `/Users/sac/smalt/mods/ratchet/hooks/turn.js` (sole lease file; register.js and hooks.json untouched)
- Exports: `registerTurn(on)` — subscribes a handler to the `turn.complete` event via the bus `on(event, handler)` per mods docs "React to events".

## hooks.json wiring line (disclosure — NOT edited, parent owns it)

`hooks.json` already contains the Register hook (unchanged):

```json
"command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/register.js\""
```

Parent wiring note: `register.js` (does not exist yet, owned by another work order) must add, after creating the event bus:

```js
require('./turn.js').registerTurn(on);
```

No hooks.json change is required for this work order.

## Behavior

- On `turn.complete`: computes next action from the state file (`mods/ratchet/state.json`, overridable via `RATCHET_STATE_PATH`). Prefers `lib/state.js` `computeNextAction` and `lib/inject.js` `injectDispatch` if present; both are absent as of this receipt, so the inline minimal equivalents run (same guards).
- Dispatch guards: 5-minute dedup (`lastDispatchAt`), `dispatchLock`, capacity default 20 (`inFlight < capacity`), OPEN ticket with all `deps` DONE.
- Inline inject sets `dispatchLock=true`, stamps `lastDispatchAt`, flips the named ticket OPEN→IN_FLIGHT, and records a named-ticket prompt (`ticket <id>: <title>`).
- Every decision (DISPATCH / SKIP / IDLE / BLOCKED / DONE / ERROR) appends to `decisionLog` in the state file, capped at the 50 most recent entries.
- Handler never throws; failures are logged as ERROR decisions.

## Verification

```
$ node --check /Users/sac/smalt/mods/ratchet/hooks/turn.js && echo CHECK_OK
CHECK_OK
```

Exit 0. Not hand-waved: the `require.main === module` self-check block (fake bus, fires `turn.complete({turnId:'selftest'})`, prints the state path) exists for runtime verification but its execution was denied by the permission system in this session, so runtime behavior is UNVERIFIED — no runtime PASS is claimed.

## Prior state (pre-existing, untouched)

`hooks/hooks.json` and `.claude-plugin/plugin.json` (219 / manifest bytes) were present before this work order; no `lib/` directory, no `register.js`, no state file existed.

## Falsifier

Drop a `lib/inject.js` and confirm the `via` field in the DISPATCH decisionLog entry flips from `inline` to `lib`; or set two OPEN tickets with chained deps and confirm BLOCKED until the dep flips DONE.
