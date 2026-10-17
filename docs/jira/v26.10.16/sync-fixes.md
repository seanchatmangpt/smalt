# v26.10.16 sync-fixes — 2026-10-16 sync-verification pass

Read-only audit; ground truth re-derived from disk. D1–D6 are the fix list for
the wrap's fin-sweep refresh (FINAL.md/WRAP_LEDGER.md counts land at fin-sweep,
not hand-patched mid-wrap). **Resolved 2026-10-16, lane 10 (wrap docs): every
row below re-verified against disk at close time; dispositions updated in
place.**

| # | Drift | Doc claim | Disk truth | Disposition |
|---|---|---|---|---|
| D1 | FINAL.md:23 receipt-index line | receipts=294 sdk=39 total=333 | **receipts=312 sdk=49 total=361 suspects=17** (re-ran `python3 scripts/receipt_index.py` at close; RECEIPTS.md + receipts/INDEX.md regenerated; supersedes the 310/49/359/16 close figure) | **RESOLVED** — FINAL.md counts updated to 312/49/361/17 |
| D2 | FINAL.md:12/:24 KD register | 78 rows KD-01..KD-78, 26 CLOSED/52 OPEN | **90 rows, KD-01..KD-90 — 28 closed-class / 62 OPEN-class** (KD-88/89/90 minted after the audit); re-recounted at lane-10 close to **92 rows, KD-01..KD-92 — 28 CLOSED / 64 OPEN** after KD-91/92 mint; superseded same-day by the lane X5 registrar's KD-93 mint — **93 rows, KD-01..KD-93 — 28 CLOSED / 65 OPEN** (FINAL.md carries the 93-row figure) | **RESOLVED** — FINAL.md KD lines updated |
| D3 | v26.10.14/KNOWN_DIVERGENCES.md header | "77 rows, KD-01..KD-77" | header updated through KD-90 by the registrar: "**90 rows**, KD-01..KD-90, no duplicates — 62 OPEN-class, 28 closed-class (13 CLOSED-WITH-RECEIPT + 5 CLOSED-with-receipt + 9 CLOSED-SIMULATED + 1 CLOSED)"; **re-recounted at lane-10 close: 92 rows, KD-01..KD-92 — 64 OPEN-class / 28 closed-class** (KD-91/92 minted from the c11 typed findings); superseded same-day by the lane X5 KD-93 mint — **93 rows, KD-01..KD-93 — 65 OPEN-class / 28 closed-class**; header and table agree (93 `| KD-` rows counted) | **RESOLVED** — verified at close time |
| D4 | FINAL.md:53 + WRAP_LEDGER court standings | 24 court scripts | **25 `*_court.sh` on disk** — corpus_fence_court.sh now listed as the 25th (unwitnessed) | **RESOLVED** — FINAL.md + WRAP_LEDGER court inventories restated to 25 scripts |
| D5 | WRAP_LEDGER.md ERRC section vs court standings | ERRC claims dets_growth+enclave_loop WITNESSED | no witness receipt on disk for either | **RESOLVED by re-scope** — ERRC section re-scoped to "session-witnessed PASS exit 0, witness receipt PENDING"; both stay excluded from the receipt-witnessed aggregate until receipts land |
| D6 | FINAL.md court aggregate | "22-witnessed" | **22 receipt-witnessed of 25; 2 session-witnessed pending receipts (dets_growth, enclave_loop); 1 unwitnessed (corpus_fence)** | **RESOLVED** — FINAL.md + WRAP_LEDGER aggregates restated |

Verified in-sync (no action): ERROR_CODES.md ↔ emitters (gen --check exit 0);
capabilities.json ↔ registry.ex (41 types, 0 mismatches); _LANES.md ↔ receipts
(all referenced files exist); WRAP_LEDGER matrix-wave linkage 5-of-14 (matches
disk); all relative doc links resolve.

Note: `~/.claude/skills/synced/` is a sync-cache bucket with no top-level
SKILL.md — the pass executed from its task spec.
