# Receipt — mod-r2-state (ratchet mod state module)

Standing: PASS
Subject: `/Users/sac/smalt/mods/ratchet/lib/state.js` (ESM, sole leased file)
Date: 2026-10-18

## Scope

State module for the ratchet mod: parses
`docs/jira/v26.10.18/azsim-burn/TICKETS.md` (AZB-NN ids, Lane, Deps incl.
`AZB-05..08` range syntax), globs `docs/jira/v26.10.18/receipts/azb-*.md`,
derives LANDED/OPEN per ticket with a deps-satisfied flag, DAG-order priority
(first OPEN ticket with all deps LANDED), and read/write for
`ratchet-state.json` `{lastTick, lastDispatch, dispatchedTickets[], mode}`.
Pure functions; only `node:fs`/`node:path`; zero sleeps. `azb-11b-*` does not
match the ticket-receipt regex (not a ticket receipt).

## Verification (real output)

```
$ node --check /Users/sac/smalt/mods/ratchet/lib/state.js && echo CHECK_OK
CHECK_OK

$ node -e 'import(".../state.js").then(m => { ... stateFromRepo("/Users/sac/smalt") ... })'
ticketCount: 24 receiptsTotal: 18
landed(18): AZB-01,AZB-02,AZB-03,AZB-04,AZB-05,AZB-06,AZB-07,AZB-08,AZB-09,AZB-10,AZB-11,AZB-12,AZB-13,AZB-14,AZB-16,AZB-19,AZB-21,AZB-22
open(6): AZB-15[lane=burn,deps=AZB-09+AZB-10,ready=true] AZB-17[lane=burn,deps=AZB-14+AZB-15+AZB-16,ready=false] AZB-18[lane=burn,deps=AZB-17,ready=false] AZB-20[lane=interop,deps=AZB-10,ready=true] AZB-23[lane=freeze (I20 analogue),deps=AZB-22,ready=true] AZB-24[lane=freeze,deps=AZB-23,ready=false]
nextTicket: AZB-15 nextLane: burn
AZB-22: {"id":"AZB-22","lane":"burn (coordinator)","deps":["AZB-11","AZB-12","AZB-18","AZB-19","AZB-20","AZB-21"],"status":"LANDED","receipt":"azb-22-burn-ring.md","depsSatisfied":false}
AZB-23: {"id":"AZB-23","lane":"freeze (I20 analogue)","deps":["AZB-22"],"status":"OPEN","receipt":null,"depsSatisfied":true}
```

Cross-check against disk: 24 tickets in TICKETS.md; 18 `azb-NN-*` receipts
(AZB-15, 17, 18, 20, 23, 24 open) — matches the directory listing exactly.
DAG priority resolves to AZB-15 (deps AZB-09+AZB-10 both landed); AZB-20 and
AZB-23 are also ready. AZB-22 is LANDED with `depsSatisfied: false` (AZB-18
still open) — status derives from receipts, the flag from deps; both reported
so the ratchet never masks an out-of-order landing.

## Notes

- One defect found and fixed in-session before validation: initial parser
  assumed Lane/Deps were bullet-leading fields; TICKETS.md carries them inline
  on a single `- **Q** … **Lane** … **Deps** …` line. Fixed to inline regex.
- Falsifier: add `azb-15-dr-subtrees.md` to receipts/ → AZB-15 flips LANDED
  and nextTicket moves to AZB-17 (its deps AZB-14+15+16 become all-landed).
  Executed as a merged receipt-map (no disk write):
  `AZB-15: LANDED | nextTicket: AZB-17 | receiptsTotal: 20` — matches
  prediction, ratchet flips are receipt-gated and not hand-minted.
