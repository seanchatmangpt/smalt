# PAT-C: 12-pattern verification court — receipt

**Standing:** **PARTIAL_ALIVE** — court executes for real (logic tier genuinely runs the
codec court; DOM lint genuinely parses `app/terminal/page.tsx`); browser tier typed
SKIP loudly. FAIL rows are the honest pre-PAT-A state, not court defects.

Context: solo

## Toolchain finding (checked first, per charter)

- `workspace/package.json` has `playwright@^1.64.1`; `workspace/node_modules/playwright`
  and `playwright-core` are installed. **Browsers are NOT downloaded**
  (`~/Library/Caches/ms-playwright` lacks `chromium_headless_shell-1248`; a real
  `chromium.launch()` probe failed: "Executable doesn't exist"). Air-gap: no fetch
  attempted, per charter. Court tier for interactive patterns = plain-mjs (logic +
  DOM lint), browser tier typed SKIP with reason.
- Existing node courts reused: `workspace/scripts/codec-court.mjs` (spawned for real,
  exit 0 — covers P7/P11 logic and P3's SEQ_REGRESSION monotonicity).

## Artifacts

- `workspace/scripts/pattern-court.mjs` — the court. Three tiers:
  - **logic**: spawns codec court for real → P7 (convoy magic 0x534D4C54 + 41-byte
    header), P11 (corrupted payload → typed `bad_crc32`), P3 monotonicity logic.
  - **dom-lint**: static source assertion that `app/terminal/page.tsx` emits every
    selector in the contract table (the PAT-A deliverable). Non-vacuity note: P10's
    matcher was tightened from the bare phase string to
    `data-status="SYNC_REFUSED_BY_SERVER"` after the loose form passed vacuously on
    the `Phase` type-string in page.tsx (caught in run 1, fixed before receipt).
  - **browser**: SKIP with typed reason (browsers absent under air-gap; P4/P9 also
    gated on SYNC-1 server).
- `workspace/tests-patterns/selector-contract.json` — contract fixture (mirror of the
  PATTERN-LANGUAGE.md selector table), drives the lint.
- `justfile.d/50-pattern-court.just` — new module; one-line import appended to root
  `Justfile` (root was already dirty from concurrent lanes; change is additive only).
  `just patterns-court` → runs the court, propagates its exit code.

## 12-row verdict (real run, exit 1)

| # | Pattern | Tier | Verdict | Detail |
|---|---|---|---|---|
| P1 | Ontological Airlock | dom-lint | FAIL | page.tsx missing `data-action="admit"`, `data-status`, `data-seq` |
| P2 | Visible Andon Cord | dom-lint | FAIL | page.tsx missing `data-andon-rule` |
| P3 | Monotonic Turnstile | dom-lint+logic | FAIL | page.tsx missing `role="log"`, `data-frame-seq`; codec logic ok |
| P4 | Local Hearth | browser | SKIP | playwright browsers absent under air-gap + live server (SYNC-1) |
| P5 | Cold Ash Rehydration | browser | SKIP | playwright browsers absent (`page.reload` offline) |
| P6 | Bounded Arena | dom-lint+logic | FAIL | missing `data-andon-rule="ALLOC_CAP_EXCEEDED"`; ALLOC_CAP_BYTES 16MiB ok in guard.ts |
| P7 | Sealed Convoy | logic | PASS | codec court exit 0 |
| P8 | Fast-Forward Sluice | dom-lint | FAIL | missing `data-receipt` |
| P9 | Commutative weave | browser | SKIP | needs live server (SYNC-1) + two browser contexts |
| P10 | Elastic Snapback | dom-lint | FAIL | missing `data-status="SYNC_REFUSED_BY_SERVER"` (loose matcher passed vacuously in run 1; tightened) |
| P11 | Sabotage Trapdoor | logic | PASS | codec court: corrupted payload → typed `bad_crc32` |
| P12 | Constant Seal | dom-lint | FAIL | missing `data-receipt-bytes="320"`, `data-receipt-verified` |

Totals: **2 PASS / 3 SKIP / 7 FAIL** — exit 1, as expected until PAT-A lands the DOM
contract on page.tsx (then P1/P2/P3/P6/P8/P10/P12 flip to PASS) and SYNC-1 + browser
downloads enable P4/P5/P9.

## Commands

```
just patterns-court        # exit 1 — 2 PASS / 3 SKIP / 7 FAIL (honest pre-PAT-A)
node -e "chromium.launch()…" probe  # BROWSER-FAIL: executable doesn't exist
```

## Falsifier / close conditions

- Falsifier of the court itself: a vacuous DOM-lint pass. Witnessed once (P10 loose
  matcher) and closed by tightening the fixture; a lint matcher that matches a TS
  type-string rather than an emitted JSX attribute is a court defect.
- Close: PAT-A lands selectors → P1/P2/P3/P6/P8/P10/P12 PASS, exit 0 (SKIP rows
  remain typed). SYNC-1 + `npx playwright install` (when the air-gap policy allows)
  un-SKIPs P4/P5/P9.
