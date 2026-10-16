# fin-22 — Final index + FINAL.md (finish lane)

- Repo: /Users/sac/smalt, branch main, landed head `518b31a` (uncommitted doc edits by this lane only).
- Date: 2026-10-15. Trigger: G-4 receipt `fin-21-final-wrap.md` appeared (poll, ~<1 min into lane start).

## Executed

1. `just receipt-index` → exit 0: `receipts=73 sdk=15 total=88 suspects=2`; rewrote
   `RECEIPTS.md` + `receipts/INDEX.md`. Verified generator auto-includes the fin-18
   (UNKNOWN), fin-19 (ALIVE), fin-21 (UNKNOWN) rows — no manual append needed
   (no fin-20 receipt exists; only the WO receipt `20-arm-gateway-hygiene.md`).
2. Wrote `docs/jira/v26.10.14/FINAL.md` (10-line release wrap: landing commit,
   court-x2 verdict, publish-dry verdict, publication gate, counts, pointers).

## Verified facts cited in FINAL.md

- court-x2: `receipts/dod-07-court-x2.md` — PARTIAL_ALIVE, two-green NOT minted
  (flake-class failures; isolation 105/0 cosmos, 21/0 semantic-projection).
- publish-dry: `receipts/dod-08-publish-dry.md` — all-PASS witnessed pre-commit
  (inner-tar key grep 0, leak grep 0, regen identity); not re-run post-commit.
- KD register: 51 OPEN rows (KD-01..KD-51), counted from `KNOWN_DIVERGENCES.md`.
- Standing mix re-read from regenerated `RECEIPTS.md` (grep counts, this session).

## Standing

ALIVE for the index regeneration + FINAL.md authoring (real commands, real output).
Publication gate = signing.key rotation, coordinator decision — unchanged.
