# BK-W3C8 — W3C-FORMALIZATION matrix refresh (per-row on-disk verification)

**Standing: ALIVE** · Context: solo · 2026-10-22

Lane BK-W3C8 (docs lane; owns
`docs/jira/v26.10.22/W3C-FORMALIZATION.md`). Every row's "current standing"
cell re-read against disk before any edit. No operator-asserted numbers —
every change cites a receipt or a file verified in this session.

## Per-row verification (all 11 rows)

| # | Row | Disk check | Action |
|---|---|---|---|
| 1 | RDF 1.2 / RDF-star | Surface: `tmp/w3ca2/` probe present (`Cargo.toml`, `main.rs`, `round1-canonical.nq`); receipts `w3ca-conformance-census.md` + `bk113-rdfstar-probe.md` on disk. Cell current | none |
| 2 | VC 2.0 | STALE — cell said "Not implemented"; `lib/smalt/receipt/vc_export.ex` + `receipts/w3cb-vc-export.md` (PARTIAL_ALIVE, 9/9 court) landed 2026-10-21 | cell rewritten with receipt anchor + typed UNSUPPORTED cryptosuite gap |
| 3 | Solid + ACP | No ACP matchers/`noneOf` in lib (only `law_compiler.ex` hits); guard-based posture unchanged | none (honest UNBUILT work order kept) |
| 4 | RDFC-1.0 | Receipts on disk; RDF.ex 3.0.1 confirmed in `mix.lock`; `RDF.Canonicalization` not referenced in smalt lib/ (dep-only dead code claim holds) | none |
| 5 | WASI 0.2 | `gl_alloc/gl_call` present in `lib/smalt/wasm/worker.ex` + `workspace/lib/engine/law-worker-bridge.ts`, `guard.ts` | none |
| 6 | PROV-O | Receipts `bk111-provo-agent-chain.md` (ALIVE) + `bk129rr-pplan-agent-chain.md` (PASS) on disk. STALE sub-claim: "OcelNdjson … out of this GAP's scope" — BK-111 actually closed the ocel_ndjson half (`eo:Agent` object + `prov:wasAssociatedWith` relationship, `agent_chain_violations/1`, 4/4 court, receipt lines 27–52) | WO cell corrected to three-emitter scope |
| 7 | WebCrypto | Census-only confirmed: no signing keys in the journal path; `subtle.digest` in `workspace/lib/engine/merkle.ts`. Seam named in `w3ce-browser-runtime.md` (SYNC-1 signature field) | standing cell rewritten as CENSUS-FIRST with seam + receipt anchor |
| 8 | Web Locks | Already current (BK-119B + BK-WLB cells landed with 4479eac2). Surfaces verified: `useWebLocks.ts`, `tab-lease.ts`, `weblocks-court.mjs`, `weblocks-browser-court.mjs` + both receipts | none |
| 9 | Service Workers | STALE — cell said "none"; `workspace/public/sw.js` (build-pinned cache, same-origin-GET air-gap law, precache `/`, `/console`, `/wasm/graphlaw.wasm`) + `workspace/components/sw-register.tsx` landed per `w3ce-browser-runtime.md` (row 9 implemented+gated) | cell rewritten as LANDED with receipt anchor |
| 10 | COOP/COEP + manifest | STALE — cell said "loopback dev server defaults"; `workspace/next.config.mjs` carries `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` on `/(.*)`; `workspace/public/manifest.webmanifest` on disk | cell rewritten as LANDED with receipt anchor |
| 11 | WebAuthn L3 | Census-only confirmed (no RP endpoint; STS bearer JWT surface in `lib/smalt/arm_gateway/router.ex`/`application.ex`). Census names the typed RP-ID constraint (registrable domain, `localhost` origin, never raw `127.0.0.1`) | standing cell rewritten as CENSUS-ONLY with the typed constraint + receipt anchor |

## GAP disposition ledger

GAP-1a/4a/6a dispositions match disk. GAP-6a CLOSED standing confirmed across
three emitters (receipts above). GAP-1a/4a falsifier probe present at
`tmp/w3ca2/` — added an on-disk check note to the ledger: probe replayable
as-is; tmp/ untracked, re-derivable from the bk113 receipt's recorded probe
structure (receipt names `/tmp/w3ca2/probe-rs/` `src/main.rs` as holding the
logic; it does NOT embed the source, so the in-repo copy is the live
artifact). Flip rule unchanged.

## Files touched by this lane

- `docs/jira/v26.10.22/W3C-FORMALIZATION.md` (rows 2, 6, 7, 9, 10, 11 + GAP
  ledger probe note)
- this receipt

## Verification commands

```
ls workspace/lib/engine/useWebLocks.ts workspace/lib/engine/tab-lease.ts \
   workspace/scripts/weblocks-court.mjs workspace/scripts/weblocks-browser-court.mjs \
   workspace/public/sw.js workspace/public/manifest.webmanifest \
   workspace/components/sw-register.tsx workspace/next.config.mjs \
   lib/smalt/receipt/vc_export.ex tmp/w3ca2/main.rs
grep -n 'Cross-Origin-Opener-Policy\|Cross-Origin-Embedder-Policy' workspace/next.config.mjs   # 2 hits
grep -rl 'prov#' lib/                                                                          # andon.ex, receipt_engine.ex
grep -iE 'purrdf|rdf"' mix.lock                                                                # rdf 3.0.1
```

All cited receipts on disk under `docs/jira/v26.10.22/receipts/`:
`w3ca-conformance-census.md`, `bk113-rdfstar-probe.md`, `bk111-provo-agent-chain.md`,
`bk129rr-pplan-agent-chain.md`, `w3cb-vc-export.md`, `w3ce-browser-runtime.md`,
`bk119b-weblocks-port.md`, `bkwl-browser-witness.md`.
