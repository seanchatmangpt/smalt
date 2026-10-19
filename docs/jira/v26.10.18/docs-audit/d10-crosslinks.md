# D10 — cross-link integrity audit (2026-10-18)

Markdown links: 0 of 1,153 broken (docs-dod discipline holds). Section
anchors: zero path#anchor cross-doc links exist (nothing to break); 10
prose cross-refs spot-checked, all resolve.

Backticked cited paths: 96 occurrences across 45 files, grouped:
A. ~55 hits — v26.10.16 restructure moved files to docs/archive/ |
   how-to/ | reference/ without updating flat backticked paths
   (CHEAT_SCAN, PUBLISH_CHECK, NAMING_SWEEP, RELEASE_NOTES_v26.10.14,
   DEV_LOOP, ARCHITECTURE, REGISTRY, NOTICE, CORPUS_ENVELOPES,
   command-reference)
B. ~20 hits — v26.10.15 scripts consolidated/deleted
   (substrated_install/substrate_client/substrate_legacy -> substrate.sh;
   receipts.py -> receipt_index.py; superfans family; corpus/)
C. ~8 hits — telemetry/receipt artifacts never committed
   (wave-telemetry.jsonl variants, sdk-corpus/)
D. ~6 hits — draft-only/dangling drafts cited as landed
   (v26.10.17 NEXT_WINDOW strike draft, PUBLISH_RECORD addendum drafts)

Recommendations: (1) batch-rewrite group A flat paths to archived
locations (mechanical; docs frozen this window — v26.10.18 WO);
(2) groups C/D are receipts-integrity findings for the v26.10.15/17
lanes (artifacts cited as evidence never committed); (3) zz-fake /
fake-lane are intentional fixtures, not defects.
