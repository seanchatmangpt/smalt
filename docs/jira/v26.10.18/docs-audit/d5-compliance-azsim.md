# D5 — compliance (C1-C7) + azsim README/TICKETS audit (2026-10-18)

## C1_ARM_REST: 3 findings
- Line citations stale (send_arm_error now router.ex:518; plugs :53-54/:101/:132; handle_rg_delete :708; check_version :1947)
- LRO one-writer redesign not reflected (evaluate/1 lazy-persist described; actual: pure reader + Sweeper flip_due/fail_closed)
- Canonical corpus helper (resilient_clear) unmentioned

## C2/C5/C6/C7: loci-drift-only, counts match (16/16, 18/18, 17/17)
## C3: resilient setup landed but undocumented
## C4: test-count drift 42 -> 49 (only hard corpus mismatch; lens-6 + lens-5 request-id blocks landed post-measure)
## azsim README: 16/24 receipts (15 green + AZB-22 typed RED), 8 outstanding (15/16/17/18/19/20/23/24); README status line stale
