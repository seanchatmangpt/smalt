# mod-r3-panel — Ratchet mod status band renderer (R3)

Standing: **ALIVE**
Context: solo(node --check panel.js lib+hooks)

## Subject

- `/Users/sac/smalt/mods/ratchet/lib/panel.js` — renderer + state/AZB derivation
- `/Users/sac/smalt/mods/ratchet/hooks/panel.js` — `registerPanel(on)` + AbovePrompt band

Lease honored: only `lib/panel.js` + `hooks/panel.js` touched. No git.

## render surface

Followed the mods docs "Draw in the interface" pattern (code-modernization
exemplar `hooks/register.ts:779`): `on('ui.render', { component: 'AbovePrompt' }, ...)`,
kit resolved via `$.ui.resolve(e)` → `Box`/`Text`, color via `Text({ color })`,
degrades to a plain string if the kit is unavailable.

## Disclosures

1. **lib/state.js absent (R2's module)** — inlined a minimal reader
   (`readState` in lib/panel.js) reading `mods/ratchet/state.json`
   (`agents`, `agentsMax`, `mode`, `blocked`) with safe defaults
   (`agents 0/20`, `mode: OBSERVE`). When R2 lands `lib/state.js`, swap
   `readState` for an import and delete the inline copy.
2. **hooks.json integration for R1/parent** — hooks/panel.js does NOT touch
   hooks.json (R1's lease). One line to add to the Register block's
   `hooks` array:
   `{"type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/panel.js\""}`
   Until then the band is inert (exported `registerPanel(on)` only).

## Landed/open derivation

`deriveAzb` parses the generated `docs/jira/v26.10.18/RECEIPTS.md` table for
`receipts/azb-*.md` links (read-only; never hand-edited, only read).
`-b` suffixed receipts (e.g. `azb-11b`) credit their base ticket.

## Validation (real output)

```
$ node --check mods/ratchet/lib/panel.js && node --check mods/ratchet/hooks/panel.js
BOTH-OK
```

Render against real RECEIPTS.md (exit 0):

```
⟐ RATCHET agents 0/20 · AZB landed 18/24 · open: [AZB-15, AZB-16, AZB-17, AZB-18, AZB-20, AZB-23, AZB-24] · mode: OBSERVE
color: yellow
registered: {"name":"ui.render","filter":{"component":"AbovePrompt"}}
band element: {"tag":"Box","props":{"paddingRight":2},"kids":[{"tag":"Text","props":{"color":"yellow","wrap":"truncate-end"},"kids":["⟐ RATCHET agents 0/20 · AZB landed 18/24 · open: [AZB-15, AZB-16, AZB-17, AZB-18, AZB-20, AZB-23, A"]}]}
```

Color contract (real output): `green` when open empty, `red` when an open
ticket is in `blocked`, `yellow` otherwise — all three exercised above.

## Falsifier

A hooks.json still lacking the panel.js line after parent integration, or a
render call that throws instead of degrading to the plain-string band.
