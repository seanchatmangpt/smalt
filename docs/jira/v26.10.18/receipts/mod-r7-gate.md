# mod R7 — ratchet gate policy (`lib/gate.js`)

Standing: **ALIVE** — all branches exercised with real output embedded below; `node --check` exit 0.
Context: solo(node --check gate.js + node gate.js self-check on real receipts)

Subject: `/Users/sac/smalt`, file `mods/ratchet/lib/gate.js` (sole leased file; no other files touched, no git commands run).

## What landed

`registerGate(on)` — court-x2 guard per the full-ratchet design:

- Registers `on('tool.call', …)`; matches ONLY commands containing the literal
  `court-x2` (`isCourtX2` substring check). Unrelated bash commands pass
  through untouched (`undefined` return) — verified: `just court` and `ls -la` are not held.
- Reads real receipts at decision time (never cached):
  `azb-22-burn-ring.md` (ring verdict), `azb-13-boot-burn.md` (boot ALIVE check),
  `azb-22b-zombie-fix.md` (lift condition).
- Hold rule: ring standing not GREEN/ALIVE (RED today, or MISSING — fail-closed)
  OR boot-burn not ALIVE → returns `{ hold: true, output: <RATCHET GATE message> }`,
  answering the tool call without running it.
- Lift rule: when `azb-22b-zombie-fix.md` exists with standing GREEN/ALIVE,
  the gate passes through even while the ring receipt still reads RED
  (the fix receipt IS the green ring re-run; the ring receipt is point-in-time).
- Paths overridable via `RATCHET_RECEIPTS_DIR` (per-lane/test isolation;
  default `/Users/sac/smalt/docs/jira/v26.10.18/receipts`).
- `require.main === module` self-check fires the handler against the real
  receipts on disk and a fake bus.

## Wiring disclosure (no register.js / hooks.json edits in this WO)

`hooks/hooks.json` already routes `Register → node "${CLAUDE_PLUGIN_ROOT}/hooks/register.js"`.
The parent register step must wire the gate after it creates the event bus:

```js
require('../lib/gate.js').registerGate(on);
```

Sibling convention (hooks/turn.js `registerTurn`, same pattern) — one line in
register.js, no hooks.json change.

## Verification (real output)

```
$ node --check /Users/sac/smalt/mods/ratchet/lib/gate.js && echo "check exit 0"
check exit 0

$ node /Users/sac/smalt/mods/ratchet/lib/gate.js   # self-check, real receipts on disk
court-x2 -> {"hold":true,"output":"RATCHET GATE: court-x2 held — burn-ring is RED; the ring's ZOMBIE_BEAM defect must be repaired and the ring re-run green first (azb-22b in flight)"}
unrelated -> undefined (undefined = passes through)

$ node -e '…branch matrix…'
red ring: {"hold":true,"output":"RATCHET GATE: court-x2 held — burn-ring is RED; …","verdict":"RED"}
lifted: {"hold":false,"liftedBy":"azb-22b-zombie-fix.md (GREEN)"}
missing ring (fail-closed): {"hold":true,…,"verdict":"MISSING"}
boot not alive: {"hold":true,"output":"RATCHET GATE: court-x2 held — azb-13 boot-burn PARTIAL_ALIVE (not ALIVE); …","verdict":"boot-burn PARTIAL_ALIVE"}
court-x2 match: true true unrelated: false false
```

Current live verdict: the gate HOLDS `just court-x2` (ring typed RED —
ZOMBIE_BEAM at boot stage; azb-22b fix in flight), consistent with
`azb-22-burn-ring.md`. It passes through the moment the green fix receipt lands.
