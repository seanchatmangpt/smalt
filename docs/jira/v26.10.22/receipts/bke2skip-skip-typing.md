# BK-E2SKIP — e2e-court SKIP typing audit

**Standing:** **ALIVE** (both skips honestly typed by this lane's disposition; neither was typed anywhere before this receipt — finding, KD row flagged not minted)
Context: solo
Date: 2026-10-22
Owner: BK-E2SKIP
Harness: `workspace/scripts/e2e-court.mjs` (read-only audit; no repo source edits)

## Embedded run output (2026-10-22, substrate UP pid 76567, ports 9443/9444 UP)

Direct run `node workspace/scripts/e2e-court.mjs` aborted in Leg 5 with EADDRINUSE
— KD-173C lane ports 39751/39752 are HARDCODED in e2e-court.mjs:502/534 and port
39751 was held by a live `next-server` (pid 48868, holds LISTEN socket → live lane,
not an orphan, left running per the tree-aware rule). Lane-safe re-run used a
temporary port-shifted copy (`workspace/scripts/.bke2skip-e2e-court.mjs`,
39751→39851, 39752→39852; deleted after the run — no repo source edits):

```
[PASS] serial frame codec round-trip — 64x 0x7E payload survives stuffing/destuffing (134-byte frame)
[SKIP] composition: panel rendering — DOM/Web Serial rendering is not executable in node — witnessed instead at the type layer below
[PASS] composition: panel component type-surface — tsc --strict --noEmit clean over components+app+lib
[PASS] live: ARM read-only probe — GET http://127.0.0.1:9443/subscriptions?api-version=2020-01-01 -> 200 ({"value":[{"displayName":"Sovereign Smalt Subscription",...
[PASS] popcorn bundle presence — beam.wasm + otp manifest + host html present; host imports ./out/index.mjs: true
[SKIP] live: popcorn iframe src — no Next server on :3100 (ECONNREFUSED) — start one to run the live leg
```

Verbatim SKIP lines (also witnessed in expl7-bff-courts-errc.md:39-40, identical text):

```
# SKIP: composition: panel rendering: DOM/Web Serial rendering is not executable in node — witnessed instead at the type layer below
# SKIP: live: popcorn iframe src: no Next server on :3100 (ECONNREFUSED) — start one to run the live leg
```

ARM live leg **PASSed** this run (substrate up), so the ARM-probe skip seen in
kd171r-secret-gate.md / expl7r1-bff-repairs.md is the same environment-gated class
as the popcorn leg: it fires only when the substrate is down, and flips to PASS
when the substrate is up — it is NOT one of the stable 2.

## Per-skip disposition

### 1. `composition: panel rendering` — typed: FACE-ABSENT (structural, PERMANENT-SKIP)

- Skip site: e2e-court.mjs:367-369 (unconditional `record(..., 'SKIP', ...)`).
- Claim: DOM/Web Serial rendering is not executable in plain node; the face under
  test (browser rendering) is absent from the harness's runtime, and the face is
  witnessed at the compensating type layer (tsc --strict --noEmit, PASS same run).
  Header comment (lines 18-19) states the design: "node cannot execute DOM
  rendering, so rendering is honestly SKIPped; the component tree is witnessed at
  the type layer".
- Honesty check: PASS — the condition (always) matches the claim (structural
  non-executability of DOM in node). The skip reads as a skip, never as a pass,
  and names its compensating witness. Same typed class the repo already uses for
  `acr=SKIP(face-absent::acr_face_absent)` (bkskipport-fetch-ports.md:80 —
  PERMANENT-SKIP surface-absent).
- Owner/precedent: bk114-verification-reruns.md:16, expl7-bff-courts-errc.md:39,
  ath2-nextjs-client.md, kd171r-secret-gate.md — all witness it; none type it.
- Terminal-gate: PERMANENT-SKIP (runtime face absent by design; closure = a
  browser/wrapper runtime leg, out of scope for this harness).

### 2. `live: popcorn iframe src` — typed: ENVIRONMENT-GATED (DISPATCHED, not permanent)

- Skip site: e2e dev server (`next dev -H 127.0.0.1 -p ${WS_PORT:-3100}`); skip
  branch e2e-court.mjs:486 — fires on ECONNREFUSED to `http://127.0.0.1:${WS_PORT:-3100}/popcorn/index.html`.
- Claim: "no Next server on :3100 — start one to run the live leg." Honesty check:
  PASS — lsof confirmed nothing listening on 3100 (only substrate on 9443), the
  observed error was ECONNREFUSED, and the skip text names the exact dispatch
  action. Condition matches claim exactly.
- Terminal-gate: DISPATCHED — the skip message itself carries the dispatch
  command. Not permanent; flips to PASS whenever a Next server listens on :3100.
  (WS_PORT env var re-hosts it.)
- Owner/precedent: witnessed in expl7-bff-courts-errc.md:40, ath2-nextjs-client.md:71
  ("pre-existing skip, not this lane" — untyped there too), bk114-verification-reruns.md:16.

## Findings (flagged for KD row — not minted unilaterally)

1. **Neither e2e-court skip is typed anywhere pre-receipt.** The repo's typed
   skip vocabulary exists (`face-absent`, `environment-gated`, `kd101-airgap`,
   `wasm-transport` — bkskipport-fetch-ports.md:73-81, kd166-witness.md:61) and
   the terminal-gate rule demands typed-permanent-or-dispatched, but no receipt
   or KD row applies it to the two e2e-court skips; every prior receipt says only
   "pre-existing, loud". Typed dispositions above close this for v26.10.22.
2. **KD-173C lane ports hardcoded** at e2e-court.mjs:502/534
   (39751/39752, no env override), so concurrent lanes cannot run the court
   concurrently. Flag for: env-overridable KD-173C ports (e.g. `SMALT_KD173C_PORT_A/B`).
3. **Pre-existing cleanup race in kd173c-harness.mjs:56** — `rmSync` (recursive)
   cleanup of `~/.cache/tmp/kd173c-next-*` raced a still-writing `next dev` child
   and crashed the run AFTER both skips were recorded (ENOTEMPTY). Not this
   lane's file; owner should wrap the cleanup in bounded retry or skip cleanup on
   ENOTEMPTY. This crash aborted the run before the PASS/FAIL/SKIP summary line,
   so the direct run did not reach the exit-0 verdict block (reached and PASSed
   in expl7r1-bff-repairs.md:123).
