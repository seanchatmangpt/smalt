# BK-RETOK — arm_gateway KD-174 mis-mint re-token to KD-175

- **Lane**: BK-RETOK (`/Users/sac/smalt`, canonical checkout)
- **Date**: 2026-10-22
- **Standing**: ALIVE
- **Context**: solo
- **Subject**: `lib/smalt/arm_gateway/router.ex:7202` only (one-file diff)

## What and why

KD-174F flagged that the EXPL9-R2 F1 oversized-body guard on the ATOM alias
face (`sb_atom_alias/3`, arm_gateway router.ex:7202) carried
`# EXPL9-R2 F1 (KD-COVERS: KD-174)` — a mis-minted token. KD-174 is the
Kafka legacy-face row (request-version gate / magic-2 payload, two-layer
reconciliation in `receipts/kd174f-truth-cell.md`); the fence here is the
EXPL9 F1 oversized-body guard, whose register row is KD-175. EXPL9-REG
already re-tokened egress_router.ex; arm_gateway was missed. No behavior
change: comment token only.

## Edit

```
-    # EXPL9-R2 F1 (KD-COVERS: KD-174): the ATOM alias face previously matched
+    # EXPL9-R2 F1 (KD-COVERS: KD-175): the ATOM alias face previously matched
```

## Embedded grep — before

```
$ grep -rn "KD-174" lib/
lib/smalt/arm_gateway/router.ex:7202:    # EXPL9-R2 F1 (KD-COVERS: KD-174): the ATOM alias face previously matched
```
(1 hit, the mis-mint; no kafka-scoped KD-COVERS tokens for KD-174 existed
anywhere in lib/ — KD-174's own surface carries no shim.)

## Embedded grep — after

```
$ grep -rn "KD-174" lib/
(none)

$ grep -n "KD-COVERS: KD-175" lib/smalt/arm_gateway/router.ex lib/smalt/egress_router.ex
lib/smalt/arm_gateway/router.ex:7202:    # EXPL9-R2 F1 (KD-COVERS: KD-175): the ATOM alias face previously matched
lib/smalt/egress_router.ex:42:  # EXPL-9 F2b (KD-COVERS: KD-175): crash-path fence, GAP-AZB20-3 class. Before
lib/smalt/egress_router.ex:837:        # KD-COVERS: KD-175 (EXPL-9 F2) — the read_body match was unguarded:
lib/smalt/egress_router.ex:992:  # EXPL-9 F2 (KD-COVERS: KD-175): oversized Put Range body message.
lib/smalt/egress_router.ex:1127:          # EXPL-9 F4 (KD-COVERS: KD-175) — same unguarded read_body escape as
lib/smalt/egress_router.ex:3982:  # EXPL-9 F2b (KD-COVERS: KD-175): crash-path fence handler. Renders the
```

## Verification

```
$ python3 scripts/kd_flip.py   # read-only
KD-COVERS covers-map: 120 KD ids from 144 files
  KD-175: [CLOSED-WITH-EVIDENCE] lib/smalt/arm_gateway/router.ex, lib/smalt/egress_router.ex
FLIP-ELIGIBLE: 0 / FLIP-PENDING-WITNESS: 1 (KD-168 registrar hold — pre-existing)
exit=0

$ python3 scripts/kd_receipt_fence.py
kd-receipt-fence: checked 329 receipt cites across 6 registers + 2 pattern docs -> OK
exit=0

$ just docs-dod-check
... OK (all receipt paths) ...
kd-receipt-fence: checked 329 receipt cites across 6 registers + 2 pattern docs -> OK
```

KD-175's covers cell now correctly names both arm_gateway/router.ex and
egress_router.ex; KD-174 carries zero KD-COVERS tokens (correct: it has no
lib/ shim — it is a register-only row whose falsifier is unmet, OPEN).
