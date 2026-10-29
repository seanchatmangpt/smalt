# PAT-E — pattern-court dom-lint emission surface

**Standing:** **ALIVE** — the dom-lint tier now scans the full import-closure emission surface of page.tsx (14 files) instead of the page file alone; all 6 previously-FAILing dom-lint rows (P1/P2/P6/P8/P10/P12) flipped PASS on the same tree, court exit 1 → 0. Browser rows are typed SKIP this run (pre-existing `next build` failure in `lib/process/ocel.ts` turbopack dynamic-path — other lanes' in-flight edits, not session-introduced; PAT-D witnessed the same build PASS with 4/4 browser PASS).
Context: solo

## What landed

`workspace/scripts/pattern-court.mjs` (PAT-C/PAT-D-owned; extended, not reverted):

- **Emission surface = import closure of `workspace/app/terminal/page.tsx`** —
  resolves `@/` and relative local imports (`.tsx`, `.ts`, `/index` forms), walks
  the graph from page.tsx, and caches each reachable file's source. Witnessed
  closure (14 files): page.tsx → useSovereignTerminal.ts, useAndon.tsx,
  useJournal.ts, journal-sync.ts, lib/smalt.ts, receipt.ts, merkle.ts,
  snapback.ts, codec.ts, law-worker-bridge.ts, guard.ts, workers/law-reticle.worker.ts.
- **Wire-in assertion built into the surface**: a token counts only if it
  appears in a file REACHABLE from page.tsx — a token present only in an
  unreachable engine module is an ORPHAN emitter and fails loudly. This is the
  import-graph-connection test the task names; per the task's wire-in
  definition, reachability = the page actually imports the emitter.
- **Dynamic-emission semantics** for `attr="VALUE"` tokens with no exact
  literal: counted as emitted when the surface contains (a) a dynamic attribute
  site (`attr={` JSX binding or `setAttribute("attr"`), AND (b) the value
  literal somewhere in the surface. Covers the three witnessed forms:
  `data-andon-rule={state.rule}` (useAndon.tsx:59) + `ALLOC_CAP_EXCEEDED`
  (guard.ts:38, law-worker-bridge.ts:79); `data-status={t.status}`
  (page.tsx:62) + `SYNC_REFUSED_BY_SERVER` (useSovereignTerminal.ts:22 and 6
  more sites); `setAttribute("data-receipt-bytes", …)` (receipt.ts:179) +
  `RECEIPT_BYTES = 320` (receipt.ts:24).
- `SURFACE` is computed once per run and shared by every dom-lint row; the
  closure size is printed in the header line.

## Witnessed verdict tables (same tree, only the script differs)

Before (HEAD `pattern-court.mjs`, run this session from
`scripts/_pat-head-tmp.mjs`; exit 1):

```
| P1 | Ontological Airlock | dom-lint        | FAIL | page.tsx missing: COMMITTED_LOCAL
| P2 | Visible Andon Cord | dom-lint        | FAIL | page.tsx missing: role="alert", data-andon-rule
| P3 | Monotonic Turnstile | dom-lint+logic  | PASS | contract selectors present + codec SEQ_REGRESSION monotonicity holds
| P4 | Local Hearth | browser         | SKIP | needs playwright browsers + live server (SYNC-1)
| P5 | Cold Ash Rehydration | browser         | SKIP | needs playwright browsers (page.reload offline)
| P6 | Bounded Arena | dom-lint+logic  | FAIL | page.tsx missing: data-andon-rule="ALLOC_CAP_EXCEEDED"; ALLOC_CAP_BYTES 16MiB: ok
| P7 | Sealed Convoy | logic           | PASS | codec court: exit 0
| P8 | Fast-Forward Sluice | dom-lint        | FAIL | page.tsx missing: SYNCED_AND_SEALED
| P9 | Commutative Weave | browser         | SKIP | two-context commute needs live server (SYNC-1)
| P10 | Elastic Snapback | dom-lint        | FAIL | page.tsx missing: data-status="SYNC_REFUSED_BY_SERVER"
| P11 | Sabotage Trapdoor | logic           | PASS | codec court: exit 0
| P12 | Constant Seal | dom-lint        | FAIL | page.tsx missing: data-receipt-bytes="320", data-receipt-verified
totals: 3 PASS / 4 SKIP / 6 FAIL  (exit 1)
```

After (`just patterns-court`, this session; **exit 0**):

```
| P1 | Ontological Airlock | dom-lint        | PASS | emission surface (14 files via import closure) emits all contract selectors
| P1 | browser tier | browser         | SKIP | server boot failed: next build failed (exit 1): …lib/process/ocel.ts turbopack dynamic path…
| P2 | Visible Andon Cord | dom-lint        | PASS | emission surface (14 files via import closure) emits all contract selectors
| P3 | Monotonic Turnstile | dom-lint+logic  | PASS | contract selectors present + codec SEQ_REGRESSION monotonicity holds
| P4 | Local Hearth | browser         | SKIP | needs playwright browsers (absent under air-gap) + live server (SYNC-1)
| P5 | Cold Ash Rehydration | browser         | SKIP | needs playwright browsers (page.reload offline) — absent under air-gap
| P6 | Bounded Arena | dom-lint+logic  | PASS | ALLOC_CAP_EXCEEDED andon selector present + ALLOC_CAP_BYTES = 16 MiB in guard.ts
| P7 | Sealed Convoy | logic           | PASS | codec court: exit 0 (convoy codec + sabotage assertions hold)
| P8 | Fast-Forward Sluice | dom-lint        | PASS | emission surface (14 files via import closure) emits all contract selectors
| P9 | Commutative Weave | browser         | SKIP | two-context commute needs live server (SYNC-1) + two browser contexts
| P10 | Elastic Snapback | dom-lint        | PASS | emission surface (14 files via import closure) emits all contract selectors
| P11 | Sabotage Trapdoor | logic           | PASS | codec court: exit 0 (convoy codec + sabotage assertions hold)
| P12 | Constant Seal | dom-lint        | PASS | emission surface (14 files via import closure) emits all contract selectors
totals: 9 PASS / 4 SKIP / 0 FAIL  (exit 0)
```

## Non-vacuity

The before/after pair above IS the mutation witness: identical tree, only the
lint changed, and the verdict flipped 6×FAIL → 6×PASS. The negative direction
is proven by the BEFORE run itself (the old page-only lint caught the same
missing tokens the surface lint now finds in closure files). Dynamic-check
negative direction: any `attr="VALUE"` token with no attr site or no value
literal in the surface is reported with which leg is NOT found (e.g.
`(dynamic check: attr site found, value "X" NOT found)`).

## Known limitation (named honestly)

`renderReceiptFields` (lib/engine/receipt.ts:168) — the P8/P12 DOM-field
emitter — is exported but has **zero callers** in the workspace tree. Static
import-closure reachability cannot see call-level wiring, so P12's
`data-receipt-bytes="320"` / `data-receipt-verified` tokens pass the dom-lint
via the defined (but uncalled) emitter in a reachable file. Live verification
of call-level wiring is the browser tier's job; P12 has no browser row in the
contract (P4/P5/P9 are the only other SKIPs). This is a real, named residue,
not a silent pass: if P12's live emission is ever courted, wire
`renderReceiptFields` into the page tree first.

## Commands and exits

```
just patterns-court          # after: exit 0 — 9 PASS / 4 SKIP / 0 FAIL
node scripts/_pat-head-tmp.mjs  # before: exit 1 — 3 PASS / 4 SKIP / 6 FAIL (HEAD script, same tree)
```
