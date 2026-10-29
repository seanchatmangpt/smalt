# BK-STAND2 — ad-hoc standing token normalization (13 witness-window rows)

**Standing:** PARTIAL_ALIVE — 13/13 ad-hoc witness-window rows normalized to the canonical vocabulary, content-preserving, zero fabrication; witness-window NO-STANDING 27 → 13 (residue is the 13 prose-only rows, untouched owner residue).

Context: solo

## Method

Followed BK-WPARSE's typed residue: each ad-hoc token replaced with the closest honest canonical token (from `scripts/receipt_index.py` `STANDING_TOKENS`) plus a parenthetical/Notes line preserving the original nuance. Evidence untouched. No token list widening (parser unchanged).

## Per-row mapping (embedded)

| receipt | was | now | rationale |
|---|---|---|---|
| v26.10.20/cost3-egress-quantification.md | COMPUTED-FROM-PUBLISHED-RATES | PARTIAL_ALIVE | provenance note, not a standing → nuance to Notes line; fetches witnessed, projections/rate math real, fleet-volume legs labeled SCENARIO |
| v26.10.20/cost4-migration-displacement.md | COMPUTED-FROM-PUBLISHED-RATES | PARTIAL_ALIVE | same — every rate cited to a fetched meter; fleet mix/volumes labeled SCENARIO |
| v26.10.20/kd24-double-slash-put-witness.md | OBSOLETE | CLOSED (KD-24 row OBSOLETE — close condition already met on wire, live-wire evidence embedded) | row disposition is a close; parenthetical keeps the stale-row nuance |
| v26.10.20/kd25-shape-gate-witness.md | OBSOLETE | CLOSED (KD-25 row OBSOLETE — both sku shapes witness on the wire) | same |
| v26.10.20/kd26-lro-terminal-witness.md | OBSOLETE | CLOSED (KD-26 row OBSOLETE — provisioningState already written post-LRO, witnessed) | same |
| v26.10.20/kd27-metadata-authority-witness.md | OBSOLETE | CLOSED (KD-27 row OBSOLETE — authority request-derived, witnessed) | same |
| v26.10.20/powl3-projection-reauthor-superseded.md | N/A | SKIP-LOUD (no artifact landed by this lane; superseded by original-lane re-landing) | loud skip, not a silent N/A; real green test run embedded in the receipt |
| v26.10.20/rg404-t21-404-root-cause.md | REPRODUCED-AND-ROOT-CAUSED | ALIVE (REPRODUCED-AND-ROOT-CAUSED — client-side KD-157, server store clean; 5×2560 lifecycles green + 3/3 wire repro) | the root-cause finding is witnessed by executed courts → ALIVE |
| v26.10.20/scvd-value-discovery.md | COMPUTED-FROM-PUBLISHED-RATES | PARTIAL_ALIVE | provenance note → Notes; fetched rate cards + measured workloads real, assumption legs labeled |
| v26.10.20/w30-ci-matrix-sketch.md | SKETCH | UNKNOWN (SKETCH — design artifact, nothing landed) | doctrine: compositions/artifacts UNKNOWN until falsified; `[UNTESTED-ASSUMPTION]` markers preserved |
| v26.10.22/bk86-kd164-fold.md | UNWITNESSED | SKIP-LOUD (no-fold — witness absent within bounded window; KD-164 NOT minted, register unchanged) | the lane's outcome is a loud typed refusal to fold; bounded poll record embedded |
| v26.10.22/bkp20-export-disposition.md | UNBUILT-for-static | UNSUPPORTED (static export) — build failure falsifies the claim; served console is the witnessed truth | task-specified mapping; embedded build-failure output untouched |
| v26.10.22/kdim-ifmatch-row.md | REFUTED-WITNESS | ALIVE (witnessed refutation — emulator honors If-Match → 412; root cause probe mis-shape; no KD row) | the refutation is the witnessed outcome → ALIVE |
| v26.10.22/spofb-boundary-audit.md | SUSPECT | UNKNOWN (SUSPECT — 2 OPEN defect classes, findings typed and unverified; no edits) | SUSPECT is not in STANDING_TOKENS; open unverified findings = UNKNOWN per doctrine |

## Gates (embedded)

```
$ python3 scripts/witness_all.py --dry-run
  BEFORE: grep -c 'WITNESS-FAIL.*NO-STANDING' = 27
  AFTER:  grep -c 'WITNESS-FAIL.*NO-STANDING' = 13   (the 13 prose-only rows)
$ python3 scripts/receipt_index.py    # rc=0; 1445 receipts; bkp20 now parses standing=UNSUPPORTED
$ just docs-dod-check                 # rc=0; kd-receipt-fence 325 cites OK
```

RECEIPTS.md / receipts/INDEX.md for v26.10.20 + v26.10.22 regenerated as direct generated outputs (deterministic from disk; include concurrent lanes' receipts on disk at regen time — BK-WPARSE precedent).

Standing: PARTIAL_ALIVE — normalization complete and gated; the 13 remaining NO-STANDING rows are prose-only owner residue outside this lane's mandate.
