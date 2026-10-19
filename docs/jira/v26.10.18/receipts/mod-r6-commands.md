# Receipt: mod-r6-commands — ratchet mod /ratchet* commands (R6)

**Standing: ALIVE** — commands register, handle, and persist mode transitions; validated by `node --check` + live harness run with real command.run dispatch and real state-file writes.

**Lane lease honored**: only `mods/ratchet/lib/commands.js` created (plus this receipt). `hooks/register.js` and `hooks/hooks.json` untouched (R1/R9 own them).

## Deliverable

`/Users/sac/smalt/mods/ratchet/lib/commands.js` exporting `registerCommands(on)`:

- `/ratchet` — renders current state: landed/open AZB ticket counts, next-dispatchable ticket, mode (+ what the mode does), agentsInFlight/capacity, ticks, lastDispatch, decisionLog tail (last 5).
- `/ratchet-mode <AUTO|OBSERVE>` — sets mode in the state file; AUTO = timer injects dispatches, OBSERVE = panel only. Refuses anything else (typed refusal, usage line returned).
- `/ratchet-off` — sets mode OFF (no injection, panel stays).
- All three persist to `ratchet-state.json` via atomic tmp+rename writes; every mode change appends a `{at, kind:"mode-set", from, to}` entry to a bounded `decisionLog` (last 200 kept).

## Wiring lines (disclosure — R9 integration lane)

register.js (R9, final form) wires this module with:

```js
const { registerCommands } = require('../lib/commands.js');
registerCommands(on);
```

Inside `registerCommands(on)` the module registers, per mods docs "Add a command or a tool":

- `on('session.start', ...)` → `await $.command.register({ name: 'ratchet', ... })`, `$.command.register({ name: 'ratchet-mode', argumentHint: '<AUTO|OBSERVE>', immediate: true })`, `$.command.register({ name: 'ratchet-off', immediate: true })`, then `return next(e)`.
- `on('command.run', { command: 'ratchet' | 'ratchet-mode' | 'ratchet-off' }, ...)` handlers; each returns `{ text }` and never calls `next` (the command has no other behavior).
- `immediate: true` on `ratchet-mode`/`ratchet-off` (and `/ratchet` left default) — docs: "To let the command run while Claude is working, add `immediate: true`" — commands work mid-turn with no Claude turn.

Note for R9: if `/ratchet` (status) should also be mid-turn runnable, add `immediate: true` to its registration too — left at default per conservative reading; one-line change, no behavior coupling.

## Validation (real output)

```
$ node --check /Users/sac/smalt/mods/ratchet/lib/commands.js
CHECK-OK
```

Live harness (fake registrar capturing `on(name, filter, fn)`; real fs on a scratch state file, deleted after):

```
hooks: session.start:undefined | command.run:{"command":"ratchet"} | command.run:{"command":"ratchet-mode"} | command.run:{"command":"ratchet-off"}
--- /ratchet ---
ratchet:
  mode: OBSERVE (panel only — no injection)
  landed: 3  open: 43
  next-dispatchable: AZB-01
  agentsInFlight: 0/20  ticks: 0  lastDispatch: never
  decisionLog tail:
  (empty)
--- bad arg ---
ratchet-mode: refuse 'BOGUS' — usage: /ratchet-mode <AUTO|OBSERVE>
default mode: OBSERVE
after set AUTO: AUTO log: [{"at":"2026-10-19T04:20:03.172Z","kind":"mode-set","from":"OBSERVE","to":"AUTO"}]
after set OFF: OFF
--- render sample ---
ratchet:
  mode: OFF (no injection; panel stays)
  landed: 1  open: 1
  next-dispatchable: AZB-99
  agentsInFlight: 0/20  ticks: 0  lastDispatch: never
  decisionLog tail:
  2026-10-19T04:20:03.172Z mode-set OBSERVE->AUTO
  2026-10-19T04:20:03.173Z mode-set AUTO->OFF
```

Real state file (`docs/jira/v26.10.18/rewrite-drafts/ratchet-state.json`, owned by R1's timer lane) untouched by the smoke run — verified byte-identical (mtime 21:20 pre-dates session).

## Falsifier

A `/ratchet-mode AUTO` that fails to flip the state file's `mode` field, or a `/ratchet` that prints without reading TICKETS.md counts, kills this receipt. Neither observed.
