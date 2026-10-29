# BK-99 — KD-164 pointer-doc fold (BK-86 handoff executed)

**Standing:** **ALIVE** — pointer doc synced to the canonical register; both gates
green; no structural fix owed.
Context: solo
Date: 2026-10-21
Repo: /Users/sac/smalt (main)

## What ran

Executed BK-86's handoff (`receipts/bk86-kd164-fold.md`) now that BK-85 landed
KD-164 (`receipts/bk85-seal-invariant.md`, standing ALIVE).

1. **Canonical register check (step 2 first, read-only)** — KD-164 row exists
   in `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (line 344), well-formed
   6-cell row: surface = affidavit wasm seal CTRT invariant gate; divergence =
   host-caller skipped the guest delta write; evidence = BK-85 receipt + court
   + shim court; close condition met 2026-10-21; status CLOSED-WITH-EVIDENCE.
   `python3 scripts/kd_flip.py` read-only: exit 0,
   `FLIP-ELIGIBLE: 0` / `FLIP-PENDING-WITNESS: 0` — zero skew, no structural
   fix needed. No edit made to the canonical register.
2. **Pointer doc bump (step 1)** — `docs/jira/v26.10.21/KNOWN_DIVERGENCES.md`:
   - range KD-01..KD-163 (160 rows) → KD-01..KD-164 (161 rows)
   - next-mint KD-164 → KD-165 (highest minted id KD-164)
   - "Rows minted this window" bullet added for KD-164 (affidavit seal CTRT
     probe / blake3 caller-write bug, CLOSED-WITH-EVIDENCE, evidence =
     `../v26.10.22/receipts/bk85-seal-invariant.md`); closing note updated
     to "all four minted 2026-10-21", KD-164 superseding BK-86's no-fold hold.
3. **Gates (step 3)** —
   - `just kd-stale` → exit 0, `FLIP-PENDING-WITNESS: 0`
   - `just docs-dod-check` → exit 0, all 60 paths OK

## Diff (this lane)

- `docs/jira/v26.10.21/KNOWN_DIVERGENCES.md` (pointer bump, above)
- `docs/jira/v26.10.22/receipts/bk99-kd164-pointer.md` (this receipt)

Not committed, per dispatch. No code, gate, or canonical-register change.

## Supersedes

BK-86's no-fold disposition (`receipts/bk86-kd164-fold.md`): its handoff
clause is now fully discharged — KD-164 minted by BK-85, pointer synced,
zero skew witnessed post-mint.
