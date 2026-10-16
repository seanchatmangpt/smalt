# WS-12 Receipt — Workspace E2E Court + Architecture Landing

- Date: 2026-10-15
- Lane: WS-12 (workspace, `/Users/sac/smalt/workspace`)
- Subject: `workspace/scripts/e2e-court.mjs`, `workspace/ARCHITECTURE.md`,
  `docs/jira/v26.10.14/ws/README.md`
- Blob identity (git hash-object, 12-hex), base commit `3fc2543e53ef`:
  - `e2e-court.mjs` 61e9313c2697
  - `ARCHITECTURE.md` 7e390858a9cf
  - `ws/README.md` 6013ad421b59
- Scope discipline: only the three lane-owned files written. All other
  workspace files were read-only (scaffold and peer-lane files untouched).

## Deliverables

1. `workspace/scripts/e2e-court.mjs` — plain-node E2E court (no test
   framework, verdicts PASS/FAIL/SKIP, exit 0 only with zero FAILs):
   - compile `lib/**` via tsc 6.0.3 to a temp outDir (generated tsconfig in
     the temp dir: commonjs output, node10 resolution + `ignoreDeprecations`,
     node typeRoots) and dynamic-import every lib module;
   - targeted checks: CRC-16/CCITT-FALSE vector 0x29B1, ETF round-trip over
     representative terms, Bellman determinism (two bit-identical runs),
     JCS canonical ordering, verb-gate refuse/pass (4 mutation verbs, GET,
     `/read`, suggestion layer), attestation valid/tampered/unsupported
     trio, ledger chain + guardedFetch refusal, serial frame codec
     round-trip (all-0x7E payload);
   - composition smoke: DOM rendering honestly SKIPped (not executable in
     node); component type-surface witnessed by `tsc --strict --noEmit`
     over components+app+lib;
   - optional live leg: ARM read-only GET probe, SKIP when no substrate.
2. `workspace/ARCHITECTURE.md` — C4 (context/container/component) landing:
   3-panel workspace, AtomVM wasm+silicon substrate, Web Serial, zero-
   actuation, Azure Sovereign one-way WORM export path. Cost table excluded
   by design; link-note instead.
3. `docs/jira/v26.10.14/ws/README.md` — index of the 12 workspace lanes.

## Verification (executed)

`node scripts/e2e-court.mjs`, full output preserved at
`/tmp/ws12-court-run.txt` (session-scratch; rerun to reproduce — the court
is deterministic apart from the temp-dir name and the live-leg outcome):

```text
# PASS=33 FAIL=6 SKIP=2  (exit 1)
```

All six WS-12 targeted checks PASS:

- `[PASS] crc16 vector 0x29B1 — crc16CcittFalse("123456789") = 0x29B1`
- `[PASS] bellman determinism — 2 runs bit-identical (1590118 bytes of
  value+policy tables); policy path imager-hi->spectro->__idle__; integer
  fixed-point: true`
- `[PASS] jcs canonical ordering — {"a":{"b":[3,{"c":2,"n":1}],"y":2},
  "m":"x","z":1}; insertion-order invariant holds`
- `[PASS] verb-gate refuse/pass — 8 gate cases (4 mutation verbs refused,
  GET + /read pass, suggestion layer agrees)`
- `[PASS] attestation trio — valid=allowed; tampered=DIGEST_MISMATCH;
  unsupported=UNKNOWN_DEVICE`
- `[PASS] ledger chain + guardedFetch refusal — chain intact across
  refusal + read + guarded DELETE refusal (3 entries)`
- `[PASS] serial frame codec round-trip — 64x 0x7E payload survives
  stuffing/destuffing (134-byte frame)`

26/29 lib modules import and export cleanly.

## Findings (owned by other lanes — court witnesses, does not fix)

1. **ETF bignum decoder bug (WS-08, `lib/atomvm/etf.ts`)** — decoder reads
   the SMALL_BIG sign byte at `bytes[c.pos + n]` (after the magnitude
   digits) while the encoder writes sign BEFORE digits. Isolated probe:
   `256n -> 0n`, `18446744073709551616n -> 0n` (silent corruption), and
   `255n` / `12345678901234567890123n` throw `ETF_BIG_SIGN`. Fix shape:
   read sign at `c.pos` and digits at `c.pos+1..n`, advance `c.pos += n+1`.
2. **`lib/attestation/validator.ts` (WS-10)** — imports `'./canonical.ts'`
   and `'./boot-digests.ts'` with explicit `.ts` extensions; tsc 6 rejects
   them (TS5097) and the commonjs-compiled `validator.js` requires
   `./canonical.ts` at runtime and fails: `Cannot find module
   './canonical.ts'`.
3. **Missing runtime deps (WS-05/09)** — `lib/azure/arm-client.ts` and
   `lib/azure/resource-queries.ts` require `@azure/arm-resources`, and
   `lib/azure/eh-stream.ts` requires `@azure/event-hubs`; none are in
   `workspace/node_modules` → import FAIL. (`blob-export`, `cosmos-manifest`,
   `sb-telemetry` import cleanly because their `@azure/*` imports are
   type-only.)
4. **Azure strict type errors (WS-05/09)** — `cosmos-manifest.ts`
   (ItemResponse generic mismatch, upsert arg count), `resource-queries.ts`
   (value-use of a type-only import), `sb-telemetry.ts` (Sender/Receiver
   not exported by the installed @azure/service-bus types), `eh-stream.ts`
   (subscribe startPosition shape). These fail the `tsc --strict --noEmit`
   type-surface check.

## Skips (honest)

- `composition: panel rendering` — SKIP: DOM/Web Serial rendering is not
  executable in plain node; witnessed instead at the type layer.
- `live: ARM read-only probe` — SKIP: no smalt substrate listening on
  `http://127.0.0.1:9443` (ECONNREFUSED); live leg not run.

## Standing

- Court verdict: **FAIL** (exit 1) — 6 findings, none owned by WS-12; every
  WS-12-owned check passes. The court itself is the deliverable and is
  ALIVE on its own subject: it compiles, imports, asserts, and renders an
  honest verdict over the current tree.
- Replay: `cd /Users/sac/smalt/workspace && node scripts/e2e-court.mjs`.
- Falsifier for this receipt: run the court; if it reports PASS=39 FAIL=0
  the findings above have been repaired by their lanes and this receipt's
  verdict section is stale.
