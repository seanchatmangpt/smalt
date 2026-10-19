# mod-r4 — ratchet auto-execute inject module

Standing: **PARTIAL_ALIVE** (guards + bounded prompt ALIVE on a real-file court; the
Context: solo(node --check inject.js + node /tmp/inject-court.mjs real-file court)
final `$.prompt.submit` hop is static — it only resolves inside a live Claude Code
session, see boundary below).

Subject: `/Users/sac/smalt/mods/ratchet/lib/inject.js` (lease: lib/inject.js only)

## Surface (docs-grounded)

Mods docs, "Start a turn from a background job" (`/docs/en/plugins/mods/api`),
cross-named by the overview's "submit a prompt as if you had typed it" and the
events page's "Follow a turn" section: `$.prompt.submit({ text, asUser: true })`
sends text as the user's own words, waits for session idle, then starts a new turn
and resolves when that turn starts. The docs warn not to `await` it from a handler
running during Claude's turn — `injectDispatch` awaits internally so the caller can
observe refusals, and is therefore intended for background contexts (timer callback,
`/command` handler), not `prompt.submit`/`tool.call` hooks.

## Exports

- `initInject($)` — binds the mods API handle once from `register(on)`.
- `injectDispatch(promptText)` — async; returns `{ ok: true, text, ticket }` or a
  typed refusal `{ ok: false, refused, detail }`. Refusal vocab:
  `API_NOT_BOUND`, `DISPATCH_LOCKED`, `RATE_LIMITED`, `UNBOUNDABLE_PROMPT`.
- `parseTicketId(text)` / `boundedPromptFor(text)` — exported for courts.

## Guards (guard order: API bound -> lock -> rate window -> ticket parse)

1. **Rate limit**: `lastInjectAt` timestamp in
   `mods/ratchet/state/inject-state.json`; refusal `RATE_LIMITED` inside 5 min.
   The window is reserved *before* submit and rolled back if submit throws, so a
   crash or transient fault cannot open an injection loop.
2. **dispatchLock**: truthy lock in the state file (anything but literal `false`
   reads as locked — fail-closed) refuses with `DISPATCH_LOCKED`; a missing state
   file correctly reads unlocked (nothing can be holding a lock that doesn't exist).
3. **Bounded + named**: only `AZB-nn` (regex `\bAZB-\d{1,3}\b`, this window's
   register) is accepted; slug is sanitized to `[a-z0-9-]` max 40 chars; the
   submitted text is exactly
   `AZB ratchet: dispatch an agent for <TICKET-ID> per docs/jira/v26.10.18/azsim-burn/TICKETS.md — receipt to docs/jira/v26.10.18/receipts/azb-NN-<slug>.md`.
   Nothing from promptText reaches the submission outside those two slots.

## Validation receipts (real output)

`node --check`:

```
$ node --check /Users/sac/smalt/mods/ratchet/lib/inject.js && echo "SYNTAX_OK"
SYNTAX_OK
```

Guard court (real files on disk via a node:fs-backed `$.fs` adapter; `mkdir -p`
via a real `$.process.run`/execFile; `prompt.submit` recorded, not faked to pass —
the court asserts on what it submitted):

```
$ node /tmp/inject-court.mjs; echo "exit=$?"
T1 {"ok":false,"refused":"UNBOUNDABLE_PROMPT","detail":"no AZB-nn ticket id in promptText"}
T2 {"ok":false,"refused":"DISPATCH_LOCKED","detail":"a receipt write in flight (dispatchLock in /Users/sac/smalt/mods/ratchet/state/inject-state.json)"}
T3a {"ok":true,"text":"AZB ratchet: dispatch an agent for AZB-20 per docs/jira/v26.10.18/azsim-burn/TICKETS.md — receipt to docs/jira/v26.10.18/receipts/azb-20-overlap-court-ring.md","ticket":"AZB-20"}
T3b state { |   "lastInjectAt": 1792383681216, |   "dispatchLock": false, |   "lastTicket": "AZB-20" | }
T3c {"ok":false,"refused":"RATE_LIMITED","detail":"next injection in 299991ms"}
T3d submit.calls [{"text":"AZB ratchet: dispatch an agent for AZB-20 per docs/jira/v26.10.18/azsim-burn/TICKETS.md — receipt to docs/jira/v26.10.18/receipts/azb-20-overlap-court-ring.md","asUser":true}]
exit=0
```

(T2's detail line above is abbreviated for width; the module emits
"a receipt write is in flight (…)". The court also exercised the first-write
mkdir path: the state dir was deleted before T3a and T3a still succeeded.)

Court-found defect, fixed in this session: `$.fs` exposes no mkdir and
`mods/ratchet/state/` did not exist — first `writeState` threw ENOENT. Fix: fall
back to `$.process.run(['mkdir', '-p', …])` before retrying the write.

## Witnessed-vs-static boundary

**Witnessed (real execution this session)**: syntax validity; every guard path and
its typed refusals; the exact bounded submission text and `asUser: true` payload;
state persistence and the mkdir fallback; window rollback on submit throw is
implemented but not separately courted (single throw path, exercised by inspection
only — marked UNKNOWN).

**Static (not witnessable outside a live session)**: the actual `$.prompt.submit`
resolution — the mods API exists only inside Claude Code's process, and the docs'
idle-wait/turn-start semantics cannot be exercised from a bare node process. The
court's submit recorder proves what the module *sends*, not that a live host
*accepts* it. Closing witness: load the mod (`--plugin-dir mods/ratchet`), call
`injectDispatch` from a timer or `/command`, and observe the turn start with the
prompt rendered as user-typed. Until then this receipt's standing is PARTIAL_ALIVE,
not ALIVE.

## Falsifier

A live-session run where `$.prompt.submit({ text, asUser: true })` renders the
mod-attribution sentence (i.e. `asUser` is not honored), or where two
`injectDispatch` calls <5 min apart both start turns despite the state file.
