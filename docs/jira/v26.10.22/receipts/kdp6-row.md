# Receipt: KD-P6 — KD-176 register row (MAA nonce-registry bounds)

- **Lane**: KD-P6 (registrar)
- **Date**: 2026-10-22
- **Subject**: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` (canonical table, KD-176 row),
  `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md` (pointer: mint-from bump KD-176 → KD-177,
  long-form pointer row)
- **Standing**: **ALIVE**
- **Context**: solo

## Disposition decision (typed)

**Minted-then-closed, registrar close-typing CLOSED-WITH-EVIDENCE.** The leak was real and
existed on HEAD for the EXPL8-R → BK-MAAP6 window (BK-MAASKEP probe: 200 real attests →
ETS {0, 200} permanent rows), so suppressing it as repair-class-only would drop a
witnessed defect from the register. But it is a resource-bound divergence class
(attacker-controlled unbounded registry state vs real MAA's bounded nonce handling), not
a wire-format delta — so the row is minted as **registration-style, documented, not
tool-flipped**: the BK-MAAP6 repair site in `lib/smalt/attestation/maa.ex` carries
`# KD-COVERS: KD-168`, not a KD-176 token (I own only the register + receipt; no lib/
edits), so `scripts/kd_flip.py` has no covers-map entry for KD-176 and the row is closed
by registrar close-typing with the evidence receipt named, mirroring the KD-175F
close-typing precedent.

## Embedded evidence (re-read from disk at mint time)

- BK-MAASKEP witness of the leak on HEAD:
  `docs/jira/v26.10.22/receipts/bkmaaskep-maa-audit.md` P6 — "200 successful attests with
  distinct nonces → `ets_size_before_after_200: {0, 200}` — every consumed nonce row
  persists forever … monotonic growth for the life of the VM keyed by attacker-controlled
  strings".
- BK-MAAP6 repair + court:
  `docs/jira/v26.10.22/receipts/bkmaap6-nonce-bounds.md` — standing ALIVE, Context: solo;
  `Result: 5 passed` (20 consecutive solo runs, 0 failures); 47 passed regression bundle;
  non-vacuous az2_maa shim court PASS, RESTORE byte-exact. Court legs: TTL sweep frees
  220 consumed rows → table size 0 (real future timestamps, not sleeps); 257-byte nonce →
  typed `invalidparameter`, no row written, 256-byte boundary nonce attests normally;
  65 536-entry cap evicts the uniquely-oldest consumed row; P5 owner-ref'd reservations
  survive a foreign nonceReplay release.

## Post-mint gates (this session, this tree)

```
$ python3 scripts/kd_flip.py            # read-only
KD-COVERS covers-map: 121 KD ids from 144 files
FLIP-ELIGIBLE: 1
  KD-168: witness docs/jira/v26.10.22/receipts/kdp6-row.md
FLIP-PENDING-WITNESS: 0
WITNESS-AMBIGUOUS: 1 (KD-174 — pre-existing, not this lane's row)
kd_flip exit=0

$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 317 receipt cites across 6 registers -> OK
fence exit=0

$ just docs-dod-check
... all OK ... kd-receipt-fence: checked 317 receipt cites across 6 registers -> OK
exit=0
```

NOTE (coordinator handoff): this receipt postdates the maa.ex shim mtime and names
KD-168 in its KD-COVERS context, so the read-only kd_flip now lists KD-168 (the AZ-2
MAA protocol-face row, owned elsewhere) as FLIP-ELIGIBLE with this receipt as witness.
No `--apply` was run — KD-168's flip belongs to its owning lane/coordinator.

## Scope

Only the two register files and this receipt written/staged; no lib/ edits; no git state
commands run (coordinator owns git).
